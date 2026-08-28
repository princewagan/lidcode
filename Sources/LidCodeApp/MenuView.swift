import SwiftUI
import LidCodeKit

/// The menu answers two questions before anything else: *why is my Mac awake* and
/// *what will stop it*. Controls come after that, not before.
///
/// The gauges are the same questions drawn instead of written. The first row is the two
/// things that can end a hold — battery and heat — plus what is holding it. The second is
/// Claude's own rate limits, which cannot end a hold but decide whether starting one is
/// worth anything: an overnight run against a 98%-consumed weekly window is eight hours of
/// keeping a Mac awake to be told no.
///
/// System metrics that cannot end a hold — CPU load, memory pressure, network throughput —
/// are still deliberately absent. Activity Monitor already draws them, and putting them
/// here would make the one thing this panel is for harder to find.
struct MenuView: View {
    @ObservedObject var model: AppModel

    private var snapshot: RuntimeSnapshot { model.snapshot }
    private var setting: Setting { model.setting }

    var body: some View {
        // Order is a claim about what matters. The control you came here to flip goes
        // first; the readouts that explain what it is doing go under it. The first build
        // had it backwards — the switch sat below four sections of analytics, so the one
        // thing everybody opens this panel for was the last thing they reached.
        VStack(alignment: .leading, spacing: 11) {
            header
            control
            Divider()
            gaugeRow
            usageRow
            Divider()
            session
            Divider()
            AgentSection(model: model, isExpanded: $model.isAgentExpanded)
            Divider()
            HealthSection(model: model, isExpanded: $model.isHealthExpanded)
            Divider()
            SettingSection(model: model, isExpanded: $model.isSettingExpanded)
            Divider()
            activity
            footer
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

    /// Status on the left, live session underneath.
    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.22))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(statusTitle).font(.system(size: 14, weight: .semibold))
                    if snapshot.isAwakeHeld {
                        Text(elapsedDisplay)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                sessionSubtitle
            }
            Spacer(minLength: 8)
            if snapshot.isAwakeHeld {
                Image(systemName: snapshot.isClamshellActive ? "laptopcomputer.slash" : "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
    }

    /// What used to be a sentence explaining the mode is now the name of the thing the Mac
    /// is being kept awake *for*.
    ///
    /// The old subtitle said "Smart, releases when work stops" — true, and useless, because
    /// it never changed. This changes: it names the live agent session, which is the actual
    /// answer to "why is my Mac awake" and the one fact the panel could not previously
    /// supply. Read from the same OSC 777 stream WarpMonitor uses, so the two agree.
    ///
    /// Two lines of space held open whether or not both are used. The count line appears
    /// only with more than one session, and letting it size itself moved the whole panel
    /// every time a second agent started.
    private var sessionSubtitle: some View {
        let session = snapshot.session
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if session.primary != nil {
                    Circle().fill(Color.green).frame(width: 4, height: 4)
                }
                Text(sessionTitle)
                    .font(.system(size: 10, weight: session.primary == nil ? .regular : .medium))
                    .foregroundStyle(session.primary == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(sessionDetail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(height: 26, alignment: .topLeading)
    }

    private var sessionTitle: String {
        let session = snapshot.session
        if let primary = session.primary { return primary.project }
        // The Warp tab name is "the folder you last had open", not "this is working" — so
        // it is offered as context, never dressed up as a live session.
        if let fallback = session.fallbackName { return fallback }
        return "No agent session"
    }

    private var sessionDetail: String {
        let session = snapshot.session
        if session.otherCount > 0 {
            return "+\(session.otherCount) other session\(session.otherCount == 1 ? "" : "s")"
        }
        if let primary = session.primary { return "\(primary.agent) · \(primary.lastEvent)" }
        if session.fallbackName != nil { return "last Warp tab" }
        return statusDetail
    }

    private var statusColor: Color {
        if snapshot.isStalled { return .red }
        if snapshot.blockedBy != nil { return .orange }
        if snapshot.isClamshellActive { return .blue }
        return snapshot.isAwakeHeld ? .green : .secondary
    }

    /// "Holding back" is its own state, distinct from "Idle".
    ///
    /// Idle means nothing wants the Mac awake. Holding back means something does and the
    /// governor is refusing — which is what you are looking at when five leases are live,
    /// the ring is full, and the Mac is sleeping anyway.
    private var statusTitle: String {
        if snapshot.isStalled { return "Not responding" }
        if snapshot.blockedBy != nil { return "Holding back" }
        if snapshot.isClamshellActive { return "Protected, lid can close" }
        if snapshot.isAwakeHeld { return "Keeping awake" }
        return snapshot.isUserPaused ? "Paused by you" : "Idle"
    }

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
        return snapshot.mode == .manual ? "Manual hold" : "Releases when work stops"
    }

    private var elapsedDisplay: String {
        let second = snapshot.runtimeSecond
        return second < 3600
            ? "\(second / 60)m"
            : "\(second / 3600)h \((second % 3600) / 60)m"
    }

    // MARK: - Control

    private var control: some View {
        VStack(alignment: .leading, spacing: 9) {
            PowerButton(
                isEnabled: model.isEnabled,
                isSwitching: model.isSwitching,
                isProtected: snapshot.isClamshellActive,
                onToggle: { model.setEnabled($0) }
            )

            // Side by side, because they are the same kind of decision made about two
            // different resources, and stacking them implied a precedence that does not
            // exist — neither guard outranks the other.
            HStack(spacing: 7) {
                GuardToggle(
                    isOn: setting.isBatteryGuardOn,
                    onLabel: "Disable on \(setting.softBatteryPercent)%",
                    offLabel: "Override battery health",
                    symbolName: "battery.25",
                    detail: setting.isBatteryGuardOn
                        ? "Releases the hold at \(setting.softBatteryPercent)% so the Mac sleeps with enough charge to resume. Click to waive it."
                        : "Waived. The hard \(setting.hardBatteryPercent)% floor still forces sleep — that one cannot be turned off.",
                    onToggle: { model.setBatteryGuard($0) }
                )
                GuardToggle(
                    isOn: setting.isThermalGuardOn,
                    onLabel: "Disable on \(setting.sustainedHeatSecond / 60)m hot temperature",
                    offLabel: "Override temperature",
                    symbolName: "thermometer.medium",
                    detail: setting.isThermalGuardOn
                        ? "Releases the hold after \(setting.sustainedHeatSecond / 60) continuous minutes at or above \(setting.thermalCeiling.display). A brief spike is ignored. Click to waive it."
                        : "Waived. Critical heat with the lid shut still forces sleep — there is no airflow to recover through.",
                    onToggle: { model.setThermalGuard($0) }
                )
            }

            DurationSlider(second: setting.holdSecond) { model.setHoldSecond($0) }

            if !model.isHelperReady { helperRow }

            if let hot = snapshot.hotSinceSecond, hot > 0, setting.isThermalGuardOn {
                Text("Hot for \(hot / 60)m \(hot % 60)s of \(setting.sustainedHeatSecond / 60)m")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Only drawn while the helper is missing. The switch stays live either way — hiding a
    /// capability is not the same as explaining it — and turning it on without the helper
    /// runs the install rather than throwing an error.
    private var helperRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Lid-shut protection needs the helper")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(model.isInstallingHelper ? "Installing…" : "A small root daemon, installed once")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if model.isInstallingHelper {
                ProgressView().controlSize(.small)
            } else if HelperInstaller.canInstall {
                Button("Install…") { model.installHelper() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Installs a root LaunchDaemon. macOS will ask for your password once.")
            } else {
                Text("Script/install-helper.sh")
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Gauges

    private var gaugeRow: some View {
        HStack(alignment: .top, spacing: 4) {
            batteryGauge
            thermalGauge
            sessionGauge
        }
    }

    private var batteryGauge: some View {
        let battery = snapshot.battery
        let percent = battery.percent
        return RingGauge(
            fraction: Double(percent ?? 100) / 100,
            color: Palette.batteryColor(
                percent: percent,
                setting: setting.softBatteryPercent,
                hard: setting.hardBatteryPercent,
                isOnMain: battery.isOnMain),
            content: percent.map { .number("\($0)", unit: "%") } ?? .symbol("powerplug.fill"),
            caption: battery.sourceDisplay
        )
    }

    /// A real number in degrees, not a word.
    ///
    /// This used to draw `ProcessInfo.thermalState`, which on Apple silicon sits at
    /// `.nominal` essentially always — so the ring showed a quarter-full green circle
    /// captioned "normal" on a Mac that was genuinely cooking, and never moved. That is why
    /// it read as neither accurate nor live. It now shows the hottest CPU die sensor, read
    /// from the same IOKit HID sensors Activity Monitor uses, sampled every tick. The word
    /// survives in the caption, where it costs nothing.
    private var thermalGauge: some View {
        let thermal = snapshot.thermal
        let celsius = thermal.celsius
        return RingGauge(
            // Mapped across the range the governor actually cares about — 30° is cold, the
            // critical threshold is full — rather than 0...100, which would leave the ring
            // parked near half for every temperature a Mac ever reaches.
            fraction: celsius.map { min(1, max(0.04, ($0 - 30) / (ThermalThreshold.criticalCelsius - 30))) }
                // Nominal still shows a quarter ring: an empty circle reads as "no data"
                // rather than "cool".
                ?? Double(thermal.level.rank + 1) / 4,
            color: Palette.color(for: thermal.level),
            content: celsius.map { .number("\(Int($0.rounded()))", unit: "°") } ?? .symbol("thermometer.medium"),
            caption: thermal.level.display.lowercased()
        )
    }

    /// One gauge, not an `if`/`else` pair.
    ///
    /// Two `RingGauge`s in separate branches are two *identities* to SwiftUI, so starting
    /// or ending a timer replaced the view instead of updating it — a transition where
    /// there should have been a value change. Computing the inputs keeps one view that
    /// simply changes what it shows.
    private var sessionGauge: some View {
        RingGauge(
            fraction: sessionFraction,
            color: sessionColor,
            content: sessionContent,
            caption: sessionCaption
        )
    }

    private var isTimed: Bool { snapshot.timerFraction != nil }

    private var sessionFraction: Double {
        if let fraction = snapshot.timerFraction { return 1 - fraction }
        return snapshot.activeLease.isEmpty ? 0 : 1
    }

    private var sessionColor: Color {
        if isTimed { return .blue }
        return snapshot.activeLease.isEmpty ? .secondary : .green
    }

    /// At most two digits and one unit character, always.
    ///
    /// The old format put `"7h59"` inside a 44pt circle with `minimumScaleFactor`. As the
    /// countdown changed the string — `"7h59"` → `"7h5"` → `"59"`+`"m"` — its width crossed
    /// the fit boundary, so SwiftUI rescaled the text every few seconds. Scaled text has a
    /// different height, and the row is baseline-aligned, so each rescale moved the glyph
    /// up or back down. That was the twitch: a countdown quietly resizing its own type.
    private var sessionContent: RingGauge.Content {
        guard let remaining = snapshot.remainingDisplay else {
            return .number("\(snapshot.activeLease.count)", unit: nil)
        }
        return .number(remaining.value, unit: remaining.unit)
    }

    /// The precision the ring gave up. A caption truncates when it does not fit, which is a
    /// failure mode that holds still.
    private var sessionCaption: String {
        guard let remaining = snapshot.remainingDisplay else {
            return snapshot.activeLease.count == 1 ? "live lease" : "live leases"
        }
        return remaining.caption
    }

    // MARK: - Claude usage

    /// The two rate-limit windows, on the same rings as everything else.
    ///
    /// Deliberately drawn as gauges rather than a percentage in a row: these are the only
    /// two numbers on the panel with a *hard ceiling you can hit*, which is exactly the
    /// shape a ring communicates and a number does not. Read from the file WarpMonitor's
    /// launchd agent refreshes every five minutes, so this panel and the phone view can
    /// never disagree about how much is left.
    @ViewBuilder
    private var usageRow: some View {
        if let usage = snapshot.usage {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(
                    text: "Claude usage",
                    trailing: usage.isStale ? "stale" : usage.fiveHour.resetDisplay.map { "resets in \($0)" })

                HStack(alignment: .top, spacing: 4) {
                    usageGauge(usage.fiveHour, caption: "5-hour", isStale: usage.isStale)
                    usageGauge(usage.sevenDay, caption: "7-day", isStale: usage.isStale)
                    // A third, empty column so the two rings line up under the *first two*
                    // of the three above rather than spreading across the full width. Two
                    // rows of rings that do not share a grid read as unrelated widgets.
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func usageGauge(_ window: UsageWindow, caption: String, isStale: Bool) -> some View {
        RingGauge(
            fraction: window.fraction,
            // Greyed out rather than hidden when the file has gone stale. A ring that
            // vanishes resizes the panel; a grey one says "this number is old", which is
            // the honest thing and also the thing that holds still.
            color: isStale ? .secondary : Palette.usageColor(percent: window.utilization),
            content: .number("\(Int(window.utilization.rounded()))", unit: "%"),
            caption: caption
        )
    }

    // MARK: - Session

    /// Tall enough for three lease rows and the "+N more" line, always.
    ///
    /// This is the fix for the panel resizing itself seconds after a click. Turning the
    /// switch off releases every lease, so the list collapses from four rows to one line;
    /// turning it back on lets the watcher repopulate it ~10s later and it grows again.
    /// Four rows is about 60pt, so the window jumped by that much — twice — without the
    /// user touching anything in between.
    ///
    /// Reserving the space costs a little emptiness on an idle Mac and buys a panel whose
    /// size is a function of *what you opened*, not of what the watcher happened to find
    /// while you were reading it.
    ///
    /// 66, not 62: three 11pt rows (~13.2 each) plus two 4pt gaps, then a 4pt gap and the
    /// 9pt "+N more" line (~10.8) comes to ~62.4. Sized to the content it has to hold, with
    /// a little margin, rather than to a round number that clips it.
    private static let leaseListHeight: CGFloat = 66

    private var session: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Why awake", trailing: sparklineSpan)

            leaseList
                .frame(height: Self.leaseListHeight, alignment: .topLeading)

            Sparkline(
                value: model.recentSample.map { Double($0.leaseCount) },
                color: .green,
                barCount: AppModel.sparklineSampleCount
            )

            // Always laid out, only sometimes visible. A bar that appears when a timer
            // starts is another 12pt of window movement, and enabling the switch starts a
            // timer — so the action with the biggest jump was the one that also had this.
            SegmentBar(fraction: snapshot.timerFraction ?? 0, color: .blue)
                .opacity(snapshot.timerFraction == nil ? 0 : 1)
        }
    }

    @ViewBuilder
    private var leaseList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if snapshot.activeLease.isEmpty {
                Text(snapshot.isAwakeHeld ? "Held manually, nothing tracked" : "Nothing running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Three, not the whole list: a busy machine can hold a dozen leases, and
                // the panel below this is the part worth scrolling to. The full list is one
                // `lidcode lease` away.
                ForEach(snapshot.activeLease.prefix(3), id: \.self) { lease in
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text(lease)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if snapshot.activeLease.count > 3 {
                    Text("+\(snapshot.activeLease.count - 3) more")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// How far back the sparkline actually reaches — an unlabelled strip invites the reader
    /// to guess, and they will guess wrong on a Mac that just woke up.
    private var sparklineSpan: String? {
        guard let first = model.recentSample.first else { return nil }
        let minute = Int(Date().timeIntervalSince(first.at) / 60)
        return minute < 1 ? "last minute" : "last \(minute)m"
    }

    // MARK: - Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Unanimated on purpose — see the note in `HealthSection`.
            Button {
                model.isActivityExpanded.toggle()
            } label: {
                HStack {
                    SectionLabel(text: "Activity")
                    Image(systemName: model.isActivityExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.recentEntry.isEmpty {
                Text("Nothing yet").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(model.recentEntry.prefix(model.isActivityExpanded ? 10 : 3).enumerated()), id: \.offset) { _, entry in
                Text("\(entry.at.formatted(date: .omitted, time: .shortened))  \(entry.detail)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let alert = model.alert {
                Text(alert).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Quit") {
                model.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}
