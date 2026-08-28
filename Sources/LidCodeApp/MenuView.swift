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
            meterSection
            usageSection
            // The panel's only divider, and it earns its place: everything above is a
            // readout or the one switch, everything below is configuration. The six
            // dividers this replaces were separating things that were already separated
            // by whitespace, which is how a small panel ends up looking like a form.
            Divider()
            SettingSection(model: model, isExpanded: $model.isSettingExpanded)
            // Pins the content to the top of whatever height the window happens to be.
            //
            // A `VStack` centres itself in a container taller than its content, so any
            // moment the window was larger than it needed to be — a resize arriving a
            // frame late, a measurement one update behind — put *half the surplus above
            // the content*. That is the space appearing at the top: not the window
            // growing upward, but the content sliding down inside it.
            //
            // `minLength: 0` means the ideal height is unchanged, so this costs nothing
            // when the fit is exact and only does something when it is not.
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340)
        // Nothing in this panel animates, by rule.
        //
        // It is a readout you open for four seconds, so motion adds no information — and
        // every animation tried here has cost something. The countdown ring was the worst:
        // `timerFraction` is recomputed from `Date()` on every render, so an eased arc
        // re-animated on each redraw and the ring never settled. The panel also resizes its
        // own window, which animated layout fights.
        //
        // The duration slider is the one thing that feels alive, and it does that without
        // an animation at all: its knob is driven straight from the pointer position, so
        // there is nothing for SwiftUI to interpolate. See `DurationSlider`.
        //
        // A blanket transaction rather than deleting modifiers one at a time: this way a
        // `withAnimation` added later cannot quietly bring the twitch back.
        .transaction { $0.animation = nil }
    }

    // MARK: - Header

    /// One line: a dot, the state, and how long it has been in it.
    ///
    /// This used to be four lines — status, elapsed, the live agent's project name, and a
    /// third line counting other sessions — held open at a fixed 26pt whether or not any
    /// of it applied. The project name was the weakest of them: it answered "what is
    /// running" for a panel whose actual question is "will it keep running", and it was
    /// the single noisiest string here because it changed every time you switched tabs.
    ///
    /// The long form is not gone, it moved into the tooltip. Hover costs no space.
    private var header: some View {
        HStack(spacing: 8) {
            // A plain dot, not the dot-inside-a-halo this replaces. Two concentric circles
            // at 18pt is a lot of drawing to say a thing one 7pt circle says.
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(statusTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            // Trailing, so the elapsed clock appearing when a hold starts cannot push the
            // title sideways — it grows into the gap instead of out of it.
            Spacer(minLength: 6)

            if snapshot.isAwakeHeld {
                Text(elapsedDisplay)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 18)
        .help(statusDetail)
    }

    /// Severity within the one family, never a second hue. See `Palette`.
    private var statusColor: Color {
        if snapshot.isStalled || snapshot.blockedBy != nil { return Palette.brandDeep }
        if snapshot.isAwakeHeld || snapshot.isClamshellActive { return Palette.brand }
        return Palette.brandSoft
    }

    /// "Holding back" is its own state, distinct from "Idle".
    ///
    /// Idle means nothing wants the Mac awake. Holding back means something does and the
    /// governor is refusing — which is what you are looking at when five leases are live
    /// and the Mac is sleeping anyway.
    ///
    /// Closed-lid protection no longer gets its own title. It is a property of the hold,
    /// not a different state, and the power button one line below already says "lid can
    /// close" — saying it twice in 340 points is how the panel got wordy in the first
    /// place.
    private var statusTitle: String {
        if snapshot.isStalled { return "Not responding" }
        if snapshot.blockedBy != nil { return "Holding back" }
        if snapshot.isAwakeHeld || snapshot.isClamshellActive { return "Keeping awake" }
        return snapshot.isUserPaused ? "Paused by you" : "Idle"
    }

    /// The sentence the header used to print. Now the header's tooltip: the same
    /// information for the reader who wants it, and none of the width for the one who
    /// does not.
    private var statusDetail: String {
        if snapshot.isStalled { return "The engine stopped ticking. Quit and reopen LidCode" }
        if let blocked = snapshot.blockedBy {
            return "\(blocked.summary). Won't re-arm until it recovers"
        }
        // Named explicitly, because the alternative reads as a broken switch: with work
        // running, "off" and "off but five things want it on" look identical until the
        // panel says which one you are in.
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
        // The lease list was a section; it is one clause now. Three names is the most that
        // fits a tooltip line, and `lidcode lease` prints the rest.
        return "Held by \(snapshot.activeLease.prefix(3).joined(separator: ", "))"
    }

    private var elapsedDisplay: String {
        let second = snapshot.runtimeSecond
        return second < 3600
            ? "\(second / 60)m"
            : "\(second / 3600)h \((second % 3600) / 60)m"
    }

    // MARK: - Control

    /// The switch, plus the two rows that only exist when something is wrong.
    ///
    /// The guard toggles and the duration slider used to live here, directly under the
    /// button — three more controls and about seventy words of label wrapped around the
    /// one control anybody came for. They moved into `SettingSection`, unchanged: still
    /// one click away, no longer competing with the switch for the top of the panel.
    private var control: some View {
        VStack(alignment: .leading, spacing: 8) {
            PowerButton(
                isEnabled: model.isEnabled,
                isSwitching: model.isSwitching,
                isProtected: snapshot.isClamshellActive,
                onToggle: { model.setEnabled($0) }
            )

            if !model.isHelperReady { helperRow }
            if let alert = model.alert { alertRow(alert) }
        }
    }

    /// Only drawn while the helper is missing. The switch stays live either way — hiding a
    /// capability is not the same as explaining it — and turning it on without the helper
    /// runs the install rather than throwing an error.
    ///
    /// One line now, where it was two plus a code path. The second line ("A small root
    /// daemon, installed once") and the fallback script path are both in the tooltip: they
    /// are answers to a question you only ask once, and they were being printed to
    /// everybody who had not installed it yet, forever.
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
                    // Borderless buttons draw their label in the accent colour, which is
                    // blue on a default Mac — the last place a foreign hue could reach the
                    // panel without any code asking for it.
                    .tint(Palette.brand)
            }
        }
        // Fixed, because the row swaps a button for a spinner mid-install and the two do
        // not measure the same. See the note on `BarGauge.rowHeight`.
        .frame(height: 18)
        .help(HelperInstaller.canInstall
              ? "Installs a small root LaunchDaemon so the hold survives the lid closing. macOS will ask for your password once."
              : "Run Script/install-helper.sh to install the root helper that keeps the hold alive with the lid shut.")
    }

    /// The only thing the deleted footer was still carrying.
    ///
    /// Quit moved to the status item's right-click menu, which is where every other
    /// menu-bar app keeps it — but the alert had nowhere else to go, and a socket that
    /// failed to bind must not fail silently: the app looks completely normal while every
    /// `lidcode` command reports "LidCode is not running".
    private func alertRow(_ alert: String) -> some View {
        Text(alert)
            .font(.system(size: 10))
            .foregroundStyle(Palette.brandDeep)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 14, alignment: .leading)
            // Truncated on purpose, with the whole message on hover: a wrapping error can
            // be four lines tall, and an alert that resizes the window is how a transient
            // problem becomes a moving target you cannot click.
            .help(alert)
    }

    // MARK: - Meters

    /// The two readings that can actually end a hold, and nothing else.
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
            // "AC" rather than the percentage while plugged in, because on mains the
            // battery is no longer something that can end the hold — which is the only
            // question this row exists to answer. The charge level is still in the bar,
            // and the exact number is in the tooltip.
            value: battery.isOnMain ? "AC" : (percent.map { "\($0)%" } ?? "—")
        )
        .help(percent.map { "\($0)% · \(battery.sourceDisplay)" } ?? battery.sourceDisplay)
    }

    /// A real number in degrees, not a word.
    ///
    /// This used to draw `ProcessInfo.thermalState`, which on Apple silicon sits at
    /// `.nominal` essentially always — so the gauge showed a quarter-full green circle
    /// captioned "normal" on a Mac that was genuinely cooking, and never moved. That is why
    /// it read as neither accurate nor live. It now shows the hottest CPU die sensor, read
    /// from the same IOKit HID sensors Activity Monitor uses, sampled every tick. The word
    /// survives in the tooltip, where it costs nothing.
    private var thermalBar: some View {
        let thermal = snapshot.thermal
        let celsius = thermal.celsius
        return BarGauge(
            label: "Temp",
            // Mapped across the range the governor actually cares about — 30° is cold, the
            // critical threshold is full — rather than 0...100, which would leave the bar
            // parked near half for every temperature a Mac ever reaches.
            fraction: celsius.map { min(1, max(0.04, ($0 - 30) / (ThermalThreshold.criticalCelsius - 30))) }
                // With no sensor, the coarse OS level still positions the bar: an empty
                // track reads as "cool" rather than "no data".
                ?? Double(thermal.level.rank + 1) / 4,
            color: Palette.color(for: thermal.level),
            value: celsius.map { "\(Int($0.rounded()))°" } ?? "—"
        )
        .help(celsius == nil
              ? "No die sensor readable. Showing the coarse level macOS reports: \(thermal.level.display.lowercased())"
              : "Hottest CPU die sensor · \(thermal.level.display.lowercased())")
    }

    // MARK: - Prince

    /// Claude's two rate-limit windows, on the same bars as everything else.
    ///
    /// Deliberately the same shape as battery and heat rather than a special widget: they
    /// are the same kind of fact — a number with a ceiling you can hit — and giving them
    /// their own visual language was most of why the old panel felt like two apps stacked
    /// on top of each other. Read from the file WarpMonitor's launchd agent refreshes every
    /// five minutes, so this panel and the phone view can never disagree.
    ///
    /// Absent entirely when the usage file does not exist. An empty section with two zeroed
    /// bars would claim a reading of zero, which is the opposite of "unavailable".
    @ViewBuilder
    private var usageSection: some View {
        if let usage = snapshot.usage {
            VStack(alignment: .leading, spacing: 6) {
                // "resets in 2h 30m" is one short string and the only thing on this panel
                // that says when the ceiling lifts, which is exactly the fact you need to
                // decide whether to start a run now or after breakfast. Kept.
                SectionLabel(
                    text: "Prince",
                    trailing: usage.isStale ? "stale" : usage.fiveHour.resetDisplay.map { "resets in \($0)" })

                usageBar("5-hour", usage.fiveHour, isStale: usage.isStale)
                usageBar("1-week", usage.sevenDay, isStale: usage.isStale)
            }
        }
    }

    private func usageBar(_ label: String, _ window: UsageWindow, isStale: Bool) -> some View {
        BarGauge(
            label: label,
            fraction: window.fraction,
            // Muted rather than hidden when the file has gone stale. A bar that vanishes
            // resizes the panel; a quiet one says "this number is old", which is the honest
            // thing and also the thing that holds still.
            color: isStale ? Palette.brandSoft : Palette.usageColor(percent: window.utilization),
            value: "\(Int(window.utilization.rounded()))%"
        )
        .help(isStale
              ? "Last read over five minutes ago — the usage file has not refreshed"
              : window.resetDisplay.map { "Resets in \($0)" } ?? "Reset time unknown")
    }
}
