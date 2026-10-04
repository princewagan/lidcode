import SwiftUI
import LidCodeKit

/// Lidcode controls alongside the OpenUsage-style provider dashboard.
struct MenuView: View {
    @AppStorage("showMemoryList") private var showMemoryList = true
    @AppStorage("appTheme") private var themeName = AppTheme.blue.rawValue
    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .blue }

    @ObservedObject var model: AppModel
    var contentOnly = false

    private var snapshot: RuntimeSnapshot { model.snapshot }
    private var setting: Setting { model.setting }

    var body: some View {
        if contentOnly {
            content
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                VStack(spacing: 0) {
                    content
                    DashboardFooter(model: model)
                }.frame(width: model.dashboardWidth).background(DashboardTheme.tray)
                if model.isOptionsOpen { DashboardOptions(model: model) }
            }
        }
    }

    var content: some View {
        VStack(spacing: 0) {
            if model.screen != .dashboard { navigationBar }
            VStack(alignment: .leading, spacing: 14) {
                switch model.screen {
                case .dashboard:
                    VStack(alignment: .leading, spacing: 10) {
                        header
                        control
                        sliderSection
                        meterSection
                    }.padding(14).dashboardCard()
                    ProviderDashboard(model: model)
                    sessionSection
                    memorySection
                case .about:
                    Text("Lidcode \(LidCodeVersion.current)").font(.title3)
                    Text("Keep your Mac awake while your agents work.")
                    Link("Releases & updates", destination: URL(string: "https://github.com/princewagan/lidcode/releases/latest")!)
                case .customize:
                    CustomizeProviders(model: model)
                case .settings:
                    SettingSection(model: model, isExpanded: .constant(true))
                        .padding(14).dashboardCard()
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Enable Terminal command") { model.installCLI() }
                            .buttonStyle(.bordered)
                            .help("Control Lidcode from Terminal or scripts.")
                        if let message = model.cliInstallMessage {
                            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }

                }
            }.padding(14)
                .id(model.screen)
                .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                .animation(.easeInOut(duration: 0.12), value: model.screen)
        }
        .frame(width: model.dashboardWidth)
        .frame(minHeight: 250, alignment: .top)
        .tint(theme.color)
        .background(DashboardTheme.tray)
    }

    private var navigationBar: some View {
        ZStack {
            Text(model.screen == .customize ? "Customize" : model.screen == .about ? "About Lidcode" : "Settings")
                .font(.system(size: 14, weight: .semibold))
            HStack {
                Button { model.screen = .dashboard } label: {
                    Image(systemName: "chevron.backward").frame(width: 24, height: 24)
                }.buttonStyle(.borderless).help("Back").accessibilityLabel("Back")
                Spacer()
            }
        }.padding(.horizontal, 14).frame(height: 44).background(.regularMaterial)
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
                // Time *left*, not time served.
                //
                // The header showed elapsed minutes, which answers a question nobody has
                // at 1am. The one that matters is whether the timer you set is still
                // running and how much of it is left — and a countdown that visibly moves
                // is also the only way to tell a working timer from a stuck one without
                // reading the log.
                Text(remainingDisplay)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    // Fixed width so digit changes don't shift the layout
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .frame(height: 18)
        .help(statusDetail)
    }

    /// C3: "Keeping awake · N active"
    /// C4: "Waiting for a session" when mode ON but nothing running
    ///
    /// The wording and the precedence behind it live on `RuntimeSnapshot` so the
    /// push payload can carry the same line to the phone. Keeping a second copy
    /// here is what let the dashboard fall behind the menu in the first place.
    private var statusColor: Color {
        switch snapshot.displayStatus.kind {
        case .stalled, .blocked:   return Color(nsColor: .systemRed)
        case .holding:             return theme.color
        case .waiting, .paused, .idle: return theme.color.opacity(0.65)
        }
    }

    private var statusTitle: String {
        snapshot.displayStatus.title
            .replacingOccurrences(of: " active sessions", with: " active")
            .replacingOccurrences(of: " active session", with: " active")
    }

    private var statusDetail: String { snapshot.displayStatus.detail }

    /// "2h 14m left" while a timer is running, elapsed time when the hold has no deadline.
    private var remainingDisplay: String {
        if let remaining = snapshot.remainingDisplay { return remaining.caption }
        let second = snapshot.runtimeSecond
        return second < 3600
            ? "\(second / 60)m"
            : "\(second / 3600)h \((second % 3600) / 60)m"
    }

    // MARK: - Control (F1-F4 button cycle)

    private var control: some View {
        VStack(alignment: .leading, spacing: 8) {
            PowerButton(
                isEnabled: model.buttonIsEnabled,
                isSwitching: model.isSwitching,
                isProtected: model.buttonIsProtected,
                isGuardBlocked: snapshot.blockedBy != nil && !snapshot.isGuardOverrideOn,
                isGuardOverride: snapshot.isGuardOverrideOn,
                onToggle: { _ in handleButtonCycle() }
            )
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
            .foregroundStyle(Color(nsColor: .systemRed))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 14, alignment: .leading)
            .help(alert)
    }

    // MARK: - Warning row (G1-G3)

    @ViewBuilder
    private var warningRow: some View {
        if let text = warningText {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(warningColor)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.15), value: text)
        }
    }

    private var memoryWarningLevel: MemoryPressureLevel {
        guard setting.isMemoryWarningOn, let memory = snapshot.memory else { return .normal }
        return memory.displayLevel(warnSwapPercent: setting.memoryWarnSwapPercent,
                                   criticalSwapPercent: setting.memoryCriticalSwapPercent)
    }

    private var warningText: String? {
        var messages: [String] = []
        if snapshot.thermal.level >= .serious {
            let heat = snapshot.thermal.level == .critical ? "Very hot" : "Hot"
            messages.append("\(heat) — check airflow")
        } else if case .thermalCritical? = snapshot.blockedBy {
            messages.append("Cooling down")
        }
        if case .thermalCritical? = snapshot.blockedBy {
            messages[0] = "Paused · " + messages[0]
        }
        if case .batteryFloor? = snapshot.blockedBy {
            messages.append("Paused — low battery")
        }
        if memoryWarningLevel >= .warn {
            messages.append("\(memoryWarningLevel == .critical ? "Memory very low" : "Memory low") — close unused apps")
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private var warningColor: Color {
        let critical = snapshot.thermal.level == .critical
            || memoryWarningLevel == .critical || snapshot.blockedBy != nil
        return Color(nsColor: critical ? .systemRed : .systemOrange)
    }

    // MARK: - Meters

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            batteryBar
            VStack(alignment: .leading, spacing: 6) {
                thermalBar
                memoryBar
                warningRow
                if warningText == nil, let alert = model.alert { alertRow(alert) }
                if !model.isHelperReady { helperRow }
            }
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
                isOnMain: battery.isOnMain, accent: theme.color),
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
            color: Palette.color(for: thermal.level, accent: theme.color),
            value: celsius.map { "\(Int($0.rounded()))°" } ?? "—"
        )
        .help(celsius == nil
              ? "No die sensor readable. Showing the coarse level macOS reports: \(thermal.level.display.lowercased())"
              : "Hottest CPU die sensor · \(thermal.level.display.lowercased())")
    }

    private var memoryBar: some View {
        let memory = snapshot.memory
        let level = memory?.displayLevel(
            warnSwapPercent: setting.memoryWarnSwapPercent,
            criticalSwapPercent: setting.memoryCriticalSwapPercent)
        return BarGauge(
            label: "Memory",
            fraction: (memory?.usedPercent ?? 0) / 100,
            color: level == .critical ? Palette.brandDeep
                : level == .warn ? Color(nsColor: .systemOrange) : theme.color.opacity(0.65),
            value: memory.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—"
        )
        .help("Percentage of your Mac’s RAM currently in use")
    }

    // MARK: - Memory

    /// Memory usage section — display-only, never ends a hold.
    ///
    /// Hidden when the memory list preference is off or no reading is available. The
    /// per-process rows sum RSS (resident set size), which counts shared frameworks once
    /// per process that maps them, so the total across rows overcounts physical usage.
    /// This matches what Activity Monitor shows and is what users recognise, but it is
    /// not a unique-memory figure. The tooltip on the section label says so.
    @ViewBuilder
    private var memorySection: some View {
        if showMemoryList, let mem = snapshot.memory {
            let trailingLabel = "\(Int(mem.usedPercent.rounded()))% used"

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Memory", trailing: trailingLabel)
                    .help("Memory usage. Per-process figures sum RSS — shared frameworks are counted once per process that maps them, so the totals overcount physical usage. Use these for relative comparison, not exact accounting.")

                // Top consumers — name left, size right, no bar.
                let rows = mem.app.prefix(setting.memoryAppRowCount)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, app in
                    HStack {
                        Text(app.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(memoryAppSize(app.megabyte))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 14)
                }
            }
        }
    }

    /// Format a megabyte value as "X.XX GB" when >= 1024, "XXX MB" below.
    private func memoryAppSize(_ megabyte: Double) -> String {
        if megabyte >= 1024 {
            return String(format: "%.2f GB", megabyte / 1024)
        }
        return "\(Int(megabyte.rounded())) MB"
    }

    // MARK: - Duration slider (J5: moved from settings drawer to main panel)

    @ViewBuilder
    private var sliderSection: some View {
        DurationSlider(
            second: setting.holdSecond,
            isEnabled: model.isEnabled,
            onCommit: { model.setHoldSecond($0) },
            // Freezes the panel's own re-layout for the duration of the drag. Without it
            // the five-second publish re-measures and re-frames the window mid-gesture.
            onInteracting: { model.isInteracting = $0 })
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

/// Host MenuView itself so its AppStorage and model observation remain active.
struct DashboardContent: View {
    @ObservedObject var model: AppModel
    var body: some View { MenuView(model: model, contentOnly: true) }
}
