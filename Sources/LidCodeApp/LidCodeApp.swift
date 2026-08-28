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
        model.start()
        installStatusItem()
        installPanel()
        installSleepWakeObservers()
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
        applyIcon(Icon(model.snapshot))

        // Deduplicated: the runtime publishes every 5s, but the glyph changes rarely.
        // Reassigning the image on every tick would redraw the menu bar for nothing.
        iconSink = model.$snapshot
            .map(Icon.init)
            .removeDuplicates()
            .sink { icon in
                DispatchQueue.main.async { [weak self] in self?.applyIcon(icon) }
            }
    }

    func applyIcon(_ icon: Icon) {
        statusItem?.button?.image = NSImage(
            systemSymbolName: icon.symbolName,
            accessibilityDescription: icon.label
        )
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

        // "Force Restart" — re-runs the wake recovery routine. Useful when the app
        // has gone stale (sensors frozen, helper disconnected) without a full sleep
        // cycle to trigger the automatic recovery.
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
        wakeUp()
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
    }

    @objc private func machineWillSleep(_ notification: Notification) {
        // No blocking work on sleep — the machine needs to sleep promptly. Note the
        // event so we can distinguish a wake that follows a sleep from a cold start,
        // if we need to in the future.
    }

    @objc private func machineDidWake(_ notification: Notification) {
        wakeUp()
    }

    @objc private func screensDidWake(_ notification: Notification) {
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
        applyIcon(Icon(model.snapshot))

        // 3. Force a health refresh so the panel reflects current state rather than
        //    pre-sleep readings. This also pokes the runtime's observable so the icon
        //    glyph re-evaluates.
        model.refreshHealth()

        // 4. Call the runtime's wake recovery entry point. This re-scans temperature
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
