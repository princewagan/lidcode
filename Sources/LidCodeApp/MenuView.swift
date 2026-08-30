import SwiftUI
import LidCodeKit

/// Five things, in this order: what state the Mac is in, the switch that changes it, the
/// two readings that can end a hold, the two that decide whether starting one is worth
/// anything, and the settings drawer.
///
/// Everything else that used to be here is gone. The panel had grown to eight sections —
/// activity log, lease list, sparkline, timer bar, agent roster, health report, three
/// rings, two more rings — and each was defensible on its own while the set was
/// unreadable: a menu-bar dropdown you open for four seconds cannot ask you to triage a
/// dashboard. Most of what was cut is not lost, it is *elsewhere*: the lease list is
/// `lidcode lease`, the log is `lidcode log`, the health sweep is `lidcode health`, and
/// the long explanations now live in `.help` tooltips, which cost no vertical space and
/// are read by exactly the person who wants them.
///
/// What survived is the answer to "is my Mac going to stay awake, and what would stop
/// it". Battery and heat can stop it. Claude's rate limits cannot stop it but decide
/// whether the run is worth starting: an overnight job against a 98%-consumed weekly
/// window is eight hours of keeping a Mac awake to be told no.
///
/// System metrics that cannot end a hold — CPU load, memory pressure, network throughput
/// — are still deliberately absent. Activity Monitor already draws them.
struct MenuView: View {
    @ObservedObject var model: AppModel

    private var snapshot: RuntimeSnapshot { model.snapshot }
    private var setting: Setting { model.setting }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            control
            warningRow        // G1-G3: hardware-state driven warnings
            meterSection
            usageSection
            // Duration slider moved here from settings drawer (J5).
            sliderSection
            sessionSection    // C1, C2, C11: grouped session list at the bottom
            foreignBlockerRow // C12: other apps blocking sleep
            // The panel's only divider, and it earns its place: everything above is a
            // readout or the one switch, everything below is configuration. The six
            // dividers this replaces were separating things that were already separated
            // by whitespace, which is how a small panel ends up looking like a form.
            Divider()
            SettingSection(model: model, isExpanded: $model.isSettingExpanded)
            // Pins the content to the top of whatever height the window happens to be.
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340)
        // Smoothness (J1-J4): replace the blanket animation kill with targeted stability.
        // Layout uses fixed heights and monospacedDigit fonts on numbers so digits never
        // cause reflow. Short animations on colour/label transitions (0.15s ease-out)
        // are applied per-element. The slider manages its own drag state locally.
        // The blanket `.transaction { $0.animation = nil }` is removed; individual
        // rows that must not animate (like window-resize paths) are marked separately.
    }

    // MARK: - Header (C3, C4)

    /// One line: a dot, the state, and how long it has been in it.
    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                // Smooth colour transition on status change
                .animation(.easeOut(duration: 0.15), value: statusColor)

            Text(statusTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .animation(.easeOut(duration: 0.15), value: statusTitle)

            Spacer(minLength: 6)

            if snapshot.isAwakeHeld {
                Text(elapsedDisplay)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    // Fixed width so digit changes don't shift the layout
                    .frame(minWidth: 32, alignment: .trailing)
            }
        }
        .frame(height: 18)
        .help(statusDetail)
    }

    private var statusColor: Color {
        if snapshot.isStalled || snapshot.blockedBy != nil { return Palette.brandDeep }
        if snapshot.isAwakeHeld || snapshot.isClamshellActive { return Palette.brand }
        return Palette.brandSoft
    }

    /// C3: "Keeping awake · N active sessions" (singular when 1)
    /// C4: "Waiting for a session" when mode ON but nothing running
    private var statusTitle: String {
        if snapshot.isStalled { return "Not responding" }
        if snapshot.blockedBy != nil { return "Holding back" }
        if snapshot.isAwakeHeld || snapshot.isClamshellActive {
            let n = snapshot.agentSession.activeCount
            if n > 0 { return "Keeping awake · \(n) active session\(n == 1 ? "" : "s")" }
            return "Keeping awake"
        }
        // C4: auto-watch is on and user hasn't paused — watching, waiting for a session.
        // model.isEnabled is false here (no hold yet), so check isAutoWatchOn directly.
        if snapshot.isAutoWatchOn && !snapshot.isUserPaused {
            return "Waiting for a session"
        }
        return snapshot.isUserPaused ? "Paused by you" : "Idle"
    }

    private var statusDetail: String {
        if snapshot.isStalled { return "The engine stopped ticking. Quit and reopen LidCode" }
        if let blocked = snapshot.blockedBy {
            return "\(blocked.summary). Won't re-arm until it recovers"
        }
        if snapshot.isUserPaused && !snapshot.isAwakeHeld {
            return snapshot.activeLease.isEmpty
                ? "Auto-watch won't turn this back on"
                : "\(snapshot.activeLease.count) running. Auto-watch won't turn this back on"
        }
        if let reason = snapshot.lastStopReason, !snapshot.isAwakeHeld {
            return "Last stop: \(reason.summary)"
        }
        if snapshot.activeLease.isEmpty {
            return snapshot.mode == .manual ? "Manual hold" : "Releases when work stops"
        }
        return "Held by \(snapshot.activeLease.prefix(3).joined(separator: ", "))"
    }

    private var elapsedDisplay: String {
        let second = snapshot.runtimeSecond
        return second < 3600
            ? "\(second / 60)m"
            : "\(second / 3600)h \((second % 3600) / 60)m"
    }

    // MARK: - Control (F1-F4 button cycle)

    private var control: some View {
        VStack(alignment: .leading, spacing: 8) {
            PowerButton(
                isEnabled: model.isEnabled,
                isSwitching: model.isSwitching,
                isProtected: snapshot.isClamshellActive,
                isGuardBlocked: snapshot.blockedBy != nil && !snapshot.isGuardOverrideOn,
                isGuardOverride: snapshot.isGuardOverrideOn,
                onToggle: { _ in handleButtonCycle() }
            )

            if !model.isHelperReady { helperRow }
            if let alert = model.alert { alertRow(alert) }
        }
    }

    /// F1-F4 button cycle logic.
    ///
    /// State 1: BLOCKED (guard firing, mode ON, not override) → press → State 2
    /// State 2: OVERRIDE (guard bypassed, mode ON) → press → State 3
    /// State 3: DISABLED (mode OFF) → press → State 4 = back to State 1
    /// The cycle loops. At State 3→4, the guard is still present so we land back in State 1.
    private func handleButtonCycle() {
        let isBlocked = snapshot.blockedBy != nil && !snapshot.isGuardOverrideOn
        let isOverride = snapshot.isGuardOverrideOn
        let isEnabled = model.isEnabled

        if isEnabled && isBlocked {
            // State 1 → 2: BLOCKED → OVERRIDE
            model.setGuardOverride(true)
        } else if isEnabled && isOverride {
            // State 2 → 3: OVERRIDE → DISABLED
            model.setGuardOverride(false)
            model.setEnabled(false)
        } else if !isEnabled {
            // State 3 → 1/4: DISABLED → back to enabled (guard may re-block)
            model.setEnabled(true)
        } else {
            // Normal toggle (no guard active)
            model.setEnabled(!isEnabled)
        }
    }

    private var helperRow: some View {
        HStack(spacing: 8) {
            Text(model.isInstallingHelper ? "Installing helper…" : "Lid-shut needs the helper")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.isInstallingHelper {
                ProgressView().controlSize(.small)
            } else if HelperInstaller.canInstall {
                Button("Install…") { model.installHelper() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(Palette.brand)
            }
        }
        .frame(height: 18)
        .help(HelperInstaller.canInstall
              ? "Installs a small root LaunchDaemon so the hold survives the lid closing. macOS will ask for your password once."
              : "Run Script/install-helper.sh to install the root helper that keeps the hold alive with the lid shut.")
    }

    private func alertRow(_ alert: String) -> some View {
        Text(alert)
            .font(.system(size: 10))
            .foregroundStyle(Palette.brandDeep)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 14, alignment: .leading)
            .help(alert)
    }

    // MARK: - Warning row (G1-G3)

    /// Hardware-state driven warnings — always reflect real conditions, never button state.
    /// G1: non-blocking high temp → orange text
    /// G2: blocking high temp → shows real elapsed minutes
    /// G3: blocking battery → real battery percent
    @ViewBuilder
    private var warningRow: some View {
        if let text = warningText {
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(warningColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 14, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: text)
        }
    }

    private var warningText: String? {
        let thermal = snapshot.thermal
        let battery = snapshot.battery

        // G2: blocking high temp — show elapsed minutes
        if let blocked = snapshot.blockedBy {
            if case .thermalCritical = blocked {
                let minutes = snapshot.hotSinceSecond.map { $0 / 60 } ?? 0
                return "Paused — high temp for ~\(minutes) minute\(minutes == 1 ? "" : "s")"
            }
            // G3: blocking battery — show real percent
            if case .batteryFloor = blocked {
                let pct = battery.percent.map { "\($0)%" } ?? "low"
                return "Paused — battery at \(pct)"
            }
        }

        // G1: non-blocking high temp
        if thermal.level >= .serious {
            return "Temp is high — cool your Mac"
        }

        return nil
    }

    private var warningColor: Color {
        if snapshot.blockedBy != nil { return Palette.brandDeep }
        return Palette.brand   // non-blocking warning in brand orange
    }

    // MARK: - Meters

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            batteryBar
            thermalBar
        }
    }

    private var batteryBar: some View {
        let battery = snapshot.battery
        let percent = battery.percent
        return BarGauge(
            label: "Battery",
            fraction: Double(percent ?? 100) / 100,
            color: Palette.batteryColor(
                percent: percent,
                setting: setting.softBatteryPercent,
                hard: setting.hardBatteryPercent,
                isOnMain: battery.isOnMain),
            value: battery.isOnMain ? "AC" : (percent.map { "\($0)%" } ?? "—")
        )
        .help(percent.map { "\($0)% · \(battery.sourceDisplay)" } ?? battery.sourceDisplay)
    }

    private var thermalBar: some View {
        let thermal = snapshot.thermal
        let celsius = thermal.celsius
        return BarGauge(
            label: "Temp",
            fraction: celsius.map { min(1, max(0.04, ($0 - 30) / (ThermalThreshold.criticalCelsius - 30))) }
                ?? Double(thermal.level.rank + 1) / 4,
            color: Palette.color(for: thermal.level),
            value: celsius.map { "\(Int($0.rounded()))°" } ?? "—"
        )
        .help(celsius == nil
              ? "No die sensor readable. Showing the coarse level macOS reports: \(thermal.level.display.lowercased())"
              : "Hottest CPU die sensor · \(thermal.level.display.lowercased())")
    }

    // MARK: - Claude usage

    @ViewBuilder
    private var usageSection: some View {
        if let usage = snapshot.usage {
            // Render one block per account in producer order (ADVO first, then PRINCE).
            // Falling back to the single-block path when accounts is empty means an old
            // file format never causes a blank panel.
            //
            // Detect the active account so the corresponding block can be labelled.
            // readStorageDir() returns String?? — nil means detection failed, .some(nil)
            // means the default account is active, .some(path) means a non-default account.
            let detectedDir: String?? = ActiveClaudeAccountReader.readStorageDir()
            if usage.accounts.isEmpty {
                usageBlock(
                    label: "Claude",
                    trailing: usage.isStale ? "stale" : usage.fiveHour.resetDisplay.map { "resets in \($0)" },
                    fiveHour: usage.fiveHour,
                    sevenDay: usage.sevenDay,
                    isStale: usage.isStale,
                    accountStatus: "ok",
                    isActive: false)
            } else {
                ForEach(usage.accounts, id: \.key) { acct in
                    let trailing: String? = usage.isStale
                        ? "stale"
                        : acct.fiveHour?.resetDisplay.map { "resets in \($0)" }
                    // An account is active when detection succeeded and its storageDir
                    // matches the detected config dir (nil matches the default account).
                    let isActive: Bool = {
                        guard let configDir = detectedDir else { return false }
                        return acct.storageDir == configDir
                    }()
                    usageBlock(
                        label: acct.label,
                        trailing: trailing,
                        fiveHour: acct.fiveHour,
                        sevenDay: acct.sevenDay,
                        isStale: usage.isStale,
                        accountStatus: acct.status,
                        isActive: isActive)
                }
            }
        }
    }

    /// One labelled pair of bars for a single account.
    ///
    /// When the account is not "ok" the bars are greyed at 0 and a short status
    /// phrase replaces the reset-countdown — the row still appears so the user knows
    /// the account exists and what state it is in.
    ///
    /// When `isActive` is true, "active" is appended to the trailing label so the user
    /// can tell at a glance which account the menu bar number refers to.
    @ViewBuilder
    private func usageBlock(
        label: String,
        trailing: String?,
        fiveHour: UsageWindow?,
        sevenDay: UsageWindow?,
        isStale: Bool,
        accountStatus: String,
        isActive: Bool
    ) -> some View {
        let isOk = accountStatus == "ok"
        // Status phrase shown instead of bars for non-ok accounts.
        let statusPhrase: String? = {
            switch accountStatus {
            case "ok":          return nil
            case "signed_out":  return "signed out"
            case "expired":     return "needs login"
            default:            return "error"
            }
        }()

        // Build the trailing label: append "active" alongside the reset countdown or
        // status phrase. The countdown is the most useful thing on an ok account, so it
        // stays primary; "active" appears after a separator so neither displaces the other.
        let trailingWithActive: String? = {
            let base = isOk ? trailing : statusPhrase
            guard isActive else { return base }
            if let base { return "\(base) · active" }
            return "active"
        }()

        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label, trailing: trailingWithActive)
            usageBar("5-hour", fiveHour, isStale: isStale, isOk: isOk)
            usageBar("1-week", sevenDay, isStale: isStale, isOk: isOk)
        }
    }

    private func usageBar(_ label: String, _ window: UsageWindow?, isStale: Bool, isOk: Bool = true) -> some View {
        let fraction = (isOk ? window?.fraction : nil) ?? 0
        let utilization = (isOk ? window?.utilization : nil) ?? 0
        let resetDisplay = window?.resetDisplay
        return BarGauge(
            label: label,
            fraction: fraction,
            color: (!isOk || isStale) ? Palette.brandSoft : Palette.usageColor(percent: utilization),
            value: isOk ? "\(Int(utilization.rounded()))%" : "—"
        )
        .help(isStale
              ? "Last read over five minutes ago — the usage file has not refreshed"
              : (!isOk
                 ? "Account unavailable"
                 : resetDisplay.map { "Resets in \($0)" } ?? "Reset time unknown"))
    }

    // MARK: - Duration slider (J5: moved from settings drawer to main panel)

    @ViewBuilder
    private var sliderSection: some View {
        // Only show when there's something to time (mode is relevant to the user)
        DurationSlider(second: setting.holdSecond) { model.setHoldSecond($0) }
    }

    // MARK: - Session list (C1, C2, C11)

    @ViewBuilder
    private var sessionSection: some View {
        let sessions = snapshot.agentSession.sessions
        let active = sessions.filter { $0.status == .running }
        let waiting = sessions.filter { $0.status == .blocked }
        let errors = sessions.filter { $0.status == .error }

        if !active.isEmpty || !waiting.isEmpty || !errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sessionGroup(label: "ACTIVE", sessions: active, dotColor: .blue)
                sessionGroup(label: "WAITING", sessions: waiting, dotColor: Color(nsColor: .systemOrange))
                sessionGroup(label: "ERROR", sessions: errors, dotColor: .red)
            }
        }
    }

    /// One group of sessions with a small uppercase label. Omitted entirely when empty.
    @ViewBuilder
    private func sessionGroup(label: String, sessions: [AgentSessionInfo], dotColor: Color) -> some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .kerning(0.3)

                // Cap at 6 visible rows + "+N more" (C1/C11 spec cap ~6)
                let visible = Array(sessions.prefix(6))
                let extra = sessions.count - 6

                ForEach(visible) { session in
                    sessionRow(session: session, dotColor: dotColor)
                }

                if extra > 0 {
                    Text("+\(extra) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(height: 16)
                }
            }
        }
    }

    private func sessionRow(session: AgentSessionInfo, dotColor: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(session.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(relativeTime(session.statusChangedAt))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                // Fixed width so timestamps don't cause row-width jitter
                .frame(minWidth: 44, alignment: .trailing)
        }
        .frame(height: 18)
    }

    // MARK: - Foreign blocker line (C12)

    @ViewBuilder
    private var foreignBlockerRow: some View {
        if snapshot.foreignBlockerCount > 0 {
            let n = snapshot.foreignBlockerCount
            Text("\(n) other app\(n == 1 ? "" : "s") also blocking sleep")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
                .help("Parsed from pmset -g assertions. Claude Code spawns caffeinate -i per session.")
        }
    }

    // MARK: - Relative time helper

    private func relativeTime(_ date: Date, from now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
