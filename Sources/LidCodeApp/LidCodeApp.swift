import AppKit
import Combine
import SwiftUI
import LidCodeKit

/// Startup and shutdown go through an app delegate rather than `scenePhase`.
///
/// A menu-bar-only app (`LSUIElement`) never reports an `.active` scene phase, so a
/// `scenePhase` hook silently never fires — the socket server would never start and
/// the CLI would sit there talking to nothing. `applicationWillTerminate` is also the
/// only place guaranteed to run on quit, which is where the assertion and the
/// privileged clamshell toggle must be handed back.
///
/// The status item is owned here rather than declared as a `MenuBarExtra`, for two
/// reasons that both showed up as bugs:
///
///   1. **The icon froze.** A `MenuBarExtra` label closure that reads
///      `delegate.model.snapshot` establishes no dependency on it — SwiftUI tracks
///      `ObservableObject` through a property wrapper, and `@NSApplicationDelegateAdaptor`
///      only republishes when the delegate itself is observable. The scene was evaluated
///      once and the glyph never changed again, so a failing health check could never
///      take the icon. Here the icon is driven by an explicit Combine sink.
///
///   2. **Expanding a section closed the panel.** `menuBarExtraStyle(.window)` is backed
///      by an `NSPanel` that dismisses when it resigns key, and every disclosure in the
///      menu changes the panel's height.
///
/// The dropdown itself is a hand-rolled panel (`MenuPanelController`) rather than the
/// `NSPopover` that replaced the `MenuBarExtra` first: a popover cannot hide its callout
/// arrow, and it anchors to a view, which breaks when a menu-bar manager hides the icon
/// by moving it off-screen. See the notes on `MenuPanel`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private var panelController: MenuPanelController?
    private var iconSink: AnyCancellable?
    private var resizeSink: AnyCancellable?

    // MARK: - Sleep / wake re-entrancy guard

    /// Guards against the wake handler running re-entrantly. A machine can fire both
    /// `didWakeNotification` and `screensDidWakeNotification` in the same wake cycle,
    /// and running the full recovery routine twice concurrently would produce duplicate
    /// log entries and kick two simultaneous immediate ticks.
    private var isWakeHandlerRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.indices.contains(index + 1) {
            do { try DashboardPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            NSApplication.shared.terminate(nil)
            return
        }
        let isFirstLaunch = !FileManager.default.fileExists(atPath: AIProfileStore.url.path)
        model.start()
        installStatusItem()
        installPanel()
        installSleepWakeObservers()
        if isFirstLaunch { panelController?.show(relativeTo: statusItem?.button) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        // Receive both left- and right-click so we can show a context menu on the
        // right-click path without patching the button's action.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        applyStatusBar(MenuBarContent(model.snapshot, setting: model.setting, profiles: model.profiles))

        // The composite icon changes whenever the snapshot or setting changes.
        // `.removeDuplicates(by:)` still prevents redundant redraws.
        let themeChanges = NotificationCenter.default.publisher(for: .lidCodeThemeDidChange)
            .map { _ in () }
            .prepend(())
        iconSink = model.$snapshot
            .combineLatest(model.$setting, model.$profiles)
            .combineLatest(themeChanges)
            .map { state, _ in MenuBarContent(state.0, setting: state.1, profiles: state.2) }
            .removeDuplicates(by: { $0 == $1 })
            .sink { [weak self] content in
                DispatchQueue.main.async { self?.applyStatusBar(content) }
            }
    }

    /// Everything the menu bar draws, kept as one Equatable value so `removeDuplicates`
    /// covers the whole picture rather than just the glyph.
    struct MenuBarContent: Equatable {
        struct Metric: Equatable {
            var text: String
            var label: String
            var remaining: Double
            var themeName: String
        }
        var icon: Icon
        var metricTexts: [Metric]
        var activeBadge: Int?          // nil = hidden
        var blockedBadge: Int?
        var errorBadge: Int?
        var warningKind: WarningKind?
        // Settings for each element's visibility
        var showStateIcon: Bool
        var showActiveBadge: Bool
        var showBlockedBadge: Bool
        var showErrorBadge: Bool
        var showTempWarnIcon: Bool
        var showAlertIcon: Bool

        enum WarningKind: Equatable {
            case hot
            case veryHot
        }

        init(_ snapshot: RuntimeSnapshot, setting: Setting, profiles: [AIProfile]) {
            icon = Icon(snapshot)

            // Selected usage metrics follow the same remaining-percent convention as the dashboard.
            let usage = snapshot.usage
            let readable = usage?.accounts.filter { $0.status == "ok" } ?? []
            func metric(_ enabled: Bool, _ account: ClaudeAccountUsage?, _ keyPath: KeyPath<ClaudeAccountUsage, UsageWindow?>) -> Metric? {
                guard enabled, let currentUsage = usage, let account,
                      account.asOf.map({ Date().timeIntervalSince($0) <= ClaudeUsageReader.staleAfterSecond }) ?? !currentUsage.isStale,
                      let window = account[keyPath: keyPath] else { return nil }
                let remaining = min(100, max(0, 100 - window.utilization))
                let themeName = UserDefaults.standard.string(forKey: "appTheme") ?? AppTheme.blue.rawValue
                return Metric(text: "\(Int(remaining.rounded()))%", label: "\(account.label) \(keyPath == \.fiveHour ? "5h" : "1w")", remaining: remaining, themeName: themeName)
            }
            metricTexts = profiles.filter(\.isEnabled).flatMap { profile in
                let account = readable.first { $0.key == profile.id }
                let claude = profile.provider == .claude
                return [metric(profile.menuBarShow5h ?? (claude ? setting.menuBarShowClaude5h : setting.menuBarShowCodex5h), account, \.fiveHour),
                        metric(profile.menuBarShow1w ?? (claude ? setting.menuBarShowClaude1w : setting.menuBarShowCodex1w), account, \.sevenDay)].compactMap { $0 }
            }

            // Session count badges (C7-C10)
            let sessions = snapshot.agentSession.sessions
            let activeCount = sessions.filter { $0.status == .running }.count
            let blockedCount = sessions.filter { $0.status == .blocked }.count
            let errorCount = sessions.filter { $0.status == .error }.count

            activeBadge = activeCount > 0 ? activeCount : nil
            blockedBadge = blockedCount > 0 ? blockedCount : nil
            errorBadge = errorCount > 0 ? errorCount : nil

            // Warning slot (H1-H4) — exactly one slot
            let thermal = snapshot.thermal
            if thermal.level >= .serious {
                warningKind = thermal.level == .critical ? .veryHot : .hot
            } else {
                warningKind = nil
            }

            // Visibility toggles (I1, I2)
            showStateIcon = false
            showActiveBadge = false
            showBlockedBadge = false
            showErrorBadge = false
            showTempWarnIcon = true
            showAlertIcon = false
        }
    }

    /// The glyph and the words for it, kept together so the menu bar is legible to
    /// VoiceOver — and so a test can read the state back without screenshotting a
    /// 16-point icon.
    struct Icon: Equatable {
        var symbolName: String
        var label: String

        /// A broken check outranks the hold state. Whether the Mac is awake is visible
        /// everywhere; that the helper died three hours into an overnight run is visible
        /// nowhere else, so it takes the glyph.
        init(_ snapshot: RuntimeSnapshot) {
            if snapshot.health?.overall == .down {
                self.init(symbolName: "exclamationmark.triangle.fill", label: "LidCode: a check is failing")
            } else if snapshot.isClamshellActive {
                self.init(symbolName: "laptopcomputer.slash", label: "LidCode: protected, lid can close")
            } else if snapshot.isAwakeHeld {
                self.init(symbolName: "bolt.fill", label: "LidCode: keeping awake")
            } else {
                self.init(symbolName: "bolt.slash", label: "LidCode: idle")
            }
        }

        private init(symbolName: String, label: String) {
            self.symbolName = symbolName
            self.label = label
        }
    }

    /// Renders the composite menu bar image: state icon + percent text + count badges + warning icon.
    ///
    /// Rendering approach: compose a single NSImage that is `isTemplate = false`, so all
    /// colours survive the menu bar's dark/light mode without being flattened to monochrome.
    /// The state icon is drawn from an SF Symbol at a reduced size; text and circles are
    /// drawn directly with AppKit APIs. All elements are crisp on Retina because the image
    /// is created at 2× scale (scale = 2) and the status bar scales it down automatically.
    func applyStatusBar(_ content: MenuBarContent) {
        guard let button = statusItem?.button else { return }

        // ── Layout constants ──────────────────────────────────────────────────────
        let barH: CGFloat = 18           // status bar item height
        let iconSize: CGFloat = 14       // SF Symbol point size
        let maxIconH: CGFloat = 15       // ceiling on a symbol's drawn height
        let badgeDiam: CGFloat = 14      // badge circle diameter
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let gap: CGFloat = 3             // space between elements

        // Determine which elements are visible
        let showIcon = content.showStateIcon
        let showPct = !content.metricTexts.isEmpty
        let showActive = content.showActiveBadge && content.activeBadge != nil
        let showBlocked = content.showBlockedBadge && content.blockedBadge != nil
        let showError = content.showErrorBadge && content.errorBadge != nil
        let warnKind = content.warningKind

        /// Render an SF Symbol tinted, and report the size it should actually be drawn at.
        ///
        /// SF Symbols are not square. `thermometer.medium` is tall and narrow;
        /// `laptopcomputer.slash` is short and wide. Both were being drawn into a fixed
        /// 14×14 rect, and `NSImage.draw(in:)` scales to *fill* — so the thermometer was
        /// stretched sideways to more than its natural width and the laptop was squashed.
        /// That is the widened, slightly wrong-looking temperature icon.
        ///
        /// Taking the size from the configured image keeps every glyph at its own aspect
        /// ratio, and returning it lets the measuring pass reserve exactly that width
        /// instead of assuming a square. Height is capped so an unusually tall symbol
        /// cannot outgrow the bar.
        func symbol(_ name: String, color: NSColor) -> (image: NSImage, size: NSSize)? {
            guard let raw = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            else { return nil }
            let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let tinted = raw.withSymbolConfiguration(config) else { return nil }
            var size = tinted.size
            guard size.width > 0, size.height > 0 else { return nil }
            if size.height > maxIconH {
                size = NSSize(width: size.width * (maxIconH / size.height), height: maxIconH)
            }
            return (tinted, size)
        }

        // Built before measuring, because the width each one needs is a property of the
        // glyph rather than a constant we can assume.
        let stateSymbol = showIcon
            ? symbol(content.icon.symbolName, color: .labelColor)
            : nil
        let warnSymbol: (image: NSImage, size: NSSize)? = {
            guard let warn = warnKind else { return nil }
            return symbol("exclamationmark.triangle.fill",
                          color: warn == .veryHot ? .systemRed : .systemOrange)
        }()

        // ── Measure total width ───────────────────────────────────────────────────
        var width: CGFloat = 4  // leading padding
        if let stateSymbol { width += stateSymbol.size.width + gap }
        if showPct {
            let metricsWidth = content.metricTexts.reduce(CGFloat.zero) {
                $0 + 12 + 2 + ($1.text as NSString).size(withAttributes: [.font: pctFont]).width
            } + CGFloat(max(0, content.metricTexts.count - 1)) * gap
            width += metricsWidth + gap
        }
        if showActive { width += badgeDiam + gap }
        if showBlocked { width += badgeDiam + gap }
        if showError { width += badgeDiam + gap }
        if let warnSymbol { width += warnSymbol.size.width + gap }
        width += 2  // trailing padding
        width = max(width, 16)

        // ── Create NSImage ────────────────────────────────────────────────────────
        let imgSize = NSSize(width: width, height: barH)
        let img = NSImage(size: imgSize)
        img.isTemplate = false   // keep colours — do not let menu bar flatten to monochrome

        img.lockFocusFlipped(false)

        var x: CGFloat = 4

        // Draw a pre-tinted symbol at its own size, vertically centred in the bar.
        // `NSImage.draw(in:)` does not consult the current AppKit fill colour, which is
        // why the tint is baked in by `symbol(_:color:)` above rather than set here.
        func draw(_ rendered: (image: NSImage, size: NSSize)) {
            let rect = NSRect(
                x: x,
                y: (barH - rendered.size.height) / 2,
                width: rendered.size.width,
                height: rendered.size.height)
            rendered.image.draw(in: rect)
            x += rendered.size.width + gap
        }

        // State icon — adaptive foreground colour (white in dark menu bar, black in light).
        // labelColor is the correct menu-bar foreground: black on light bar, white on dark.
        if let stateSymbol { draw(stateSymbol) }

        // Percent text
        if showPct {
            let attrs: [NSAttributedString.Key: Any] = [.font: pctFont, .foregroundColor: NSColor.labelColor]
            for (index, metric) in content.metricTexts.enumerated() {
                if index > 0 { x += gap }
                let ringRect = NSRect(x: x, y: (barH - 12) / 2, width: 12, height: 12)
                let ringWidth: CGFloat = 2.5
                let ringRadius = (ringRect.width - ringWidth) / 2
                let ring = NSBezierPath(ovalIn: ringRect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
                ring.lineWidth = ringWidth
                NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setStroke()
                ring.stroke()
                let color = NSColor(AppTheme(rawValue: metric.themeName)?.color ?? AppTheme.blue.color)
                let progress = NSBezierPath()
                progress.lineWidth = ringWidth
                progress.lineCapStyle = .round
                progress.appendArc(withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRadius,
                                   startAngle: 90, endAngle: 90 - 360 * metric.remaining / 100, clockwise: true)
                color.setStroke()
                progress.stroke()
                x += 15
                let size = (metric.text as NSString).size(withAttributes: attrs)
                (metric.text as NSString).draw(at: NSPoint(x: x, y: (barH - size.height) / 2), withAttributes: attrs)
                x += size.width + gap
            }
        }

        // Helper: draw a coloured circle badge with a number
        func drawBadge(count: Int, color: NSColor) {
            let badgeRect = NSRect(x: x, y: (barH - badgeDiam) / 2, width: badgeDiam, height: badgeDiam)
            color.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let numStr = "\(count)"
            let numFont = NSFont.systemFont(ofSize: count > 9 ? 8 : 9, weight: .bold)
            let numAttrs: [NSAttributedString.Key: Any] = [
                .font: numFont,
                .foregroundColor: NSColor.white
            ]
            let numSize = (numStr as NSString).size(withAttributes: numAttrs)
            let numPt = NSPoint(
                x: badgeRect.midX - numSize.width / 2,
                y: badgeRect.midY - numSize.height / 2
            )
            (numStr as NSString).draw(at: numPt, withAttributes: numAttrs)
            x += badgeDiam + gap
        }

        // Active badge — blue
        if showActive, let count = content.activeBadge {
            drawBadge(count: count, color: NSColor.systemBlue)
        }
        // Blocked badge — yellow/orange
        if showBlocked, let count = content.blockedBadge {
            drawBadge(count: count, color: NSColor.systemOrange)
        }
        // Error badge — red
        if showError, let count = content.errorBadge {
            drawBadge(count: count, color: NSColor.systemRed)
        }

        // Warning icon — one slot only (H1-H4).
        // Rendered in the specific warning colour using symbol configuration, not as a
        // template, so the orange/red survives the menu bar's monochrome flatten.
        if let warnSymbol { draw(warnSymbol) }

        img.unlockFocus()

        button.image = img
        var labels = content.metricTexts.map { "\($0.label): \($0.text) left" }
        if let warning = content.warningKind {
            labels.append(warning == .veryHot ? "Very hot — check airflow" : "Hot — check airflow")
        }
        button.toolTip = labels.joined(separator: "\n")
        button.setAccessibilityLabel(labels.isEmpty ? "Lidcode" : button.toolTip)
        button.title = ""
        button.imagePosition = .imageOnly
    }

    // MARK: - Panel

    private func installPanel() {
        let controller = MenuPanelController(rootView: MenuView(model: model))
        panelController = controller

        // The panel sizes itself to the SwiftUI content, so it has to be told when that
        // content changed. `objectWillChange` fires *before* the change lands, hence the
        // hop to the next runloop pass — by then SwiftUI has re-laid-out and
        // `fittingSize` is the new height. This is what makes a disclosure grow the
        // window instead of getting clipped by it.
        resizeSink = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, controller.isVisible else { return }
                // Never re-frame the window while the user is dragging inside it. The
                // publish that drives this fires every five seconds regardless of whether
                // anything about the panel's *height* changed, and a `setFrame` under a
                // live pointer interrupts the gesture — which is half of why the duration
                // slider felt like it was fighting back.
                guard !self.model.isInteracting else { return }
                controller.resize(anchoredTo: self.statusItem?.button)
            }
    }

    @objc private func togglePopover(_ sender: Any?) {
        // Right-click or Ctrl+left-click shows a context menu instead of the panel.
        // This gives users a reliable Quit path even when the panel itself is frozen
        // or the app is in a degraded state after a power event.
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isCtrlClick = event?.type == .leftMouseUp
            && event?.modifierFlags.contains(.control) == true

        if isRightClick || isCtrlClick {
            showContextMenu()
        } else {
            panelController?.toggle(relativeTo: statusItem?.button)
        }
    }

    // MARK: - Context menu (right-click / Ctrl+click)

    /// Shows a lightweight NSMenu for the right-click path.
    ///
    /// Why NSMenu rather than a second panel: the context menu appears even when the
    /// main panel is in a bad state, which is the whole point of having it. It uses
    /// the modern non-deprecated flow: assign the menu to the status item, call
    /// performClick, then immediately clear it so left-clicks go back to the action.
    ///
    /// The deprecated `NSStatusItem.popUpMenu(_:)` was removed in macOS 14+.
    private func showContextMenu() {
        let menu = NSMenu()

        // "Open LidCode" — shows the panel as if the user left-clicked.
        let openItem = NSMenuItem(
            title: "Open LidCode",
            action: #selector(openPanel),
            keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Relaunch the entire app, including runtime, sensors, and panel state.
        let restartItem = NSMenuItem(
            title: "Force Restart",
            action: #selector(forceRestart),
            keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        // "Quit LidCode" — triggers a clean shutdown then terminates.
        let quitItem = NSMenuItem(
            title: "Quit LidCode",
            action: #selector(quitApp),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Assign → click → clear, the non-deprecated pattern for status-item menus.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openPanel() {
        panelController?.show(relativeTo: statusItem?.button)
    }

    @objc private func forceRestart() {
        restartApp()
    }

    /// A separate launcher waits for this PID to exit before starting a fresh app.
    func restartApp() {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
        guard let executable = Bundle.main.executableURL else { return }
        launcher.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; if [ \"$3\" = app ]; then exec /usr/bin/open -n \"$2\"; else exec \"$2\"; fi",
                              "lidcode-relaunch", String(ProcessInfo.processInfo.processIdentifier),
                              bundled ? Bundle.main.bundleURL.path : executable.path,
                              bundled ? "app" : "executable"]
        do { try launcher.run() }
        catch { NSSound.beep(); return }
        quitApp()
    }

    @objc private func quitApp() {
        // Bound quit so a wedged helper socket cannot hold the app hostage.
        //
        // `model.shutdown()` calls `LidCodeRuntime.shutdown()`, which does a
        // `queue.sync` that can block up to ~5 s on a stalled helper. Scheduling a
        // hard `exit(0)` fallback before calling shutdown ensures the app always
        // terminates, even if the helper socket never responds. The 3-second deadline
        // is shorter than the helper's own socket timeout, so on a healthy quit the
        // clean shutdown wins the race; on a wedged quit the fallback fires and the
        // process exits cleanly from the OS's perspective.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            exit(0)
        }
        model.shutdown()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Sleep / wake observers

    /// Registers for the sleep and wake notifications published by NSWorkspace.
    ///
    /// There were previously zero observers for these events anywhere in the app. The
    /// gap mattered for three reasons:
    ///
    ///   1. A sleep/wake cycle can invalidate the IOHIDEventSystem service clients that
    ///      `TemperatureSensor` holds, causing silent nil returns forever after.
    ///
    ///   2. A hard power-off (battery exhaustion) can kill the helper process while the
    ///      heartbeat queue is not running, leaving the socket dead on the next launch.
    ///
    ///   3. The panel's saved screen position becomes stale when the display set changes
    ///      across a sleep, which is the "clicking does nothing" bug's second path.
    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(machineWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil)

        center.addObserver(
            self,
            selector: #selector(machineDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)

        // `screensDidWakeNotification` fires when an external display reconnects or
        // the built-in panel comes back on after a clamshell open. Both events can
        // change the screen geometry that the panel's saved position was based on.
        center.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil)

        // `screensDidSleepNotification` fires on lid close (among other paths). We route
        // it to `checkLidNow` so the brightness dim reacts immediately rather than
        // waiting up to 10s for the cache and tick timer to align.
        center.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil)
    }

    @objc private func screensDidSleep(_ notification: Notification) {
        // Screens sleeping is the earliest observable signal of a lid close. Force an
        // immediate lid-state read and brightness reconcile without waiting for the 5s tick.
        model.checkLidNow()
    }

    @objc private func machineWillSleep(_ notification: Notification) {
        // No blocking work on sleep — the machine needs to sleep promptly. Note the
        // event so we can distinguish a wake that follows a sleep from a cold start,
        // if we need to in the future.
    }

    @objc private func machineDidWake(_ notification: Notification) {
        // See `screensDidWake` for why this is outside the re-entrancy guard.
        model.restoreBrightnessNow()
        wakeUp()
    }

    @objc private func screensDidWake(_ notification: Notification) {
        // Brightness first, and outside the re-entrancy guard below.
        //
        // `wakeUp()` refuses to run twice in the same cycle, and a Mac routinely fires
        // `didWake` and `screensDidWake` together — so whichever arrives second is
        // dropped. That is fine for re-scanning sensors, which only needs doing once, and
        // wrong for the brightness restore, which is the one thing the user is looking
        // straight at while they wait for it. It is idempotent and cheap, so it runs on
        // every signal.
        model.restoreBrightnessNow()

        // Screen geometry changed. Run the same recovery as a full wake — the panel
        // placement may be stale, and sensors may need re-scanning.
        wakeUp()
    }

    /// Full post-wake recovery routine.
    ///
    /// Called from both `didWakeNotification` and `screensDidWakeNotification`. The
    /// re-entrancy guard (`isWakeHandlerRunning`) prevents double-running when both
    /// fire in the same wake cycle.
    private func wakeUp() {
        guard !isWakeHandlerRunning else { return }
        isWakeHandlerRunning = true
        defer { isWakeHandlerRunning = false }

        // 1. Invalidate the panel's saved position. After a sleep the display set may
        //    have changed, so any pinned top-left coordinate is stale. Closing and
        //    clearing pinnedTopLeft means the next open re-derives placement from
        //    whatever screens are actually connected now.
        panelController?.invalidatePlacement()

        // 2. Re-create the status item image. The menu bar can be rebuilt after a
        //    display event, and the icon needs to be re-stamped to remain visible.
        applyStatusBar(MenuBarContent(model.snapshot, setting: model.setting, profiles: model.profiles))

        // 3. Force a health refresh so the panel reflects current state rather than
        //    pre-sleep readings. This also pokes the runtime's observable so the icon
        //    glyph re-evaluates.
        model.refreshHealth()

        // 4. Invalidate the lid-state cache so the next tick reads a fresh value rather
        //    than serving a pre-wake cached reading. screensDidSleep already calls this
        //    on the close path, but without an equivalent call here the 5s cache can
        //    keep returning .closed after the lid opens — delaying a brightness restore
        //    by up to ~10s while the user is actively looking at the screen.
        model.checkLidNow()

        // 5. Call the runtime's wake recovery entry point. This re-scans temperature
        //    sensors (which a sleep can invalidate) and attempts to reconnect the helper
        //    socket if it was lost during a hard power-off. It runs asynchronously on
        //    the runtime queue, so this call returns immediately.
        model.recoverAfterWake()
    }
}

@main
struct LidCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The app's UI is the status item, which the delegate owns. `Settings` is the
    /// cheapest legal scene for an `LSUIElement` app — it renders nothing and gives
    /// SwiftUI's `App` lifecycle something to hold.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
