import AppKit
import SwiftUI
import Combine
import LidCodeKit

/// The dropdown, as a borderless panel rather than an `NSPopover`.
///
/// Two things forced this, and neither is fixable on a popover:
///
///   1. **The arrow.** `NSPopover` always draws a callout triangle pointing at its
///      anchor. Almost no menu-bar app has one — the platform convention is a plain
///      rounded rectangle hanging under the status item — and there is no API to turn
///      it off.
///
///   2. **Hidden icons.** A popover anchors to its anchor *view*, so it goes wherever
///      that view is. Menu-bar managers like Ice hide an item by moving it off-screen
///      rather than removing it, so the anchor is still a real view at a nonsense
///      position: the panel flew to the top-left corner and the arrow drew itself
///      inside-out trying to point at something off-screen. A panel positions itself,
///      so it can *notice* the anchor is not somewhere a window should hang from and
///      fall back to the corner of the menu bar instead.
final class MenuPanel: NSPanel {
    /// Borderless windows refuse key status by default, which would leave every
    /// toggle and button in the panel dead.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel, its hosted SwiftUI content, and where it appears.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    private let panel: MenuPanel
    private let hosting: NSHostingView<AnyView>
    private let optionsHosting: NSHostingView<DashboardOptions>
    private var optionsSink: AnyCancellable?
    private var screenSink: AnyCancellable?
    private let optionsPanel: MenuPanel
    private let model: AppModel
    private let footerHosting: NSHostingView<DashboardFooter>
    private static let footerHeight: CGFloat = 52
    private let scrollView = NSScrollView()
    private var dismissMonitor: Any?
    /// When the panel last closed, so clicking the status item to dismiss it does not
    /// immediately reopen it — the click resigns key (closing the panel) and *then*
    /// fires the button action, which would otherwise toggle it straight back on.
    private var closedAt = Date.distantPast

    /// Matches the system's own menu-bar dropdowns.
    private static let cornerRadius: CGFloat = 11
    /// Gap between the menu bar and the top of the panel.
    private static let menuBarGap: CGFloat = 4
    /// Keeps the panel off the very edge of the screen.
    private static let screenInset: CGFloat = 8
    /// Home and settings share the same compact width.
    ///
    private var width: CGFloat { model.dashboardWidth }
    /// Fallback height when the SwiftUI layout engine has not yet measured the content.
    ///
    /// This used to be a hard `return` that aborted the entire layout pass, leaving the
    /// panel at its last stale frame. After a sleep/wake or display disconnect, that
    /// stale frame is very likely off-screen, so `panel.isVisible` becomes true (the
    /// window is "on screen" at coordinates no display covers) and every subsequent click
    /// calls `close()` instead of `show()`. To the user the icon simply stops working.
    ///
    /// Using a sensible default lets `show()` position the panel correctly even before
    /// the first layout pass completes — the content will resize it immediately after.
    private static let defaultHeight: CGFloat = 420

    /// Where the panel's top-left corner sits, decided once when it opens.
    ///
    /// The panel grows downward from this point and never re-derives it while visible.
    /// Re-anchoring on every model change meant a 5-second tick could also shift the
    /// window under the pointer, mid-click.
    private var pinnedTopLeft: NSPoint?

    var isVisible: Bool { panel.isVisible }

    init(rootView: MenuView) {
        let width = rootView.model.dashboardWidth
        model = rootView.model
        optionsHosting = NSHostingView(rootView: DashboardOptions(model: rootView.model))
        hosting = NSHostingView(rootView: AnyView(DashboardContent(model: rootView.model)))
        footerHosting = NSHostingView(rootView: DashboardFooter(model: rootView.model))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: Self.defaultHeight)
        hosting.autoresizingMask = []

        panel = MenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        // Follows the user across spaces and sits above a full-screen app, which is
        // where an overnight run is most likely to be watched from.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        optionsPanel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 260),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        optionsPanel.isOpaque = false
        optionsPanel.backgroundColor = .clear
        optionsPanel.hasShadow = true
        optionsPanel.level = .popUpMenu
        optionsPanel.hidesOnDeactivate = false
        optionsPanel.collectionBehavior = panel.collectionBehavior
        optionsPanel.contentView = optionsHosting

        // The rounded, blurred background the popover used to provide for free.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        // Keep the document at its natural height; only the viewport is screen-sized.
        // Overlay scrollers preserve the fixed content width when overflow starts.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = hosting
        backdrop.addSubview(scrollView)
        footerHosting.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(footerHosting)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerHosting.topAnchor),
            footerHosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            footerHosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            footerHosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            footerHosting.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
        panel.contentView = backdrop
        super.init()
        optionsSink = model.$isOptionsOpen.receive(on: RunLoop.main).sink { [weak self] open in
            guard let self else { return }
            self.layout(anchoredTo: nil, animated: false)
            self.updateOptionsPanel(open: open)
        }

        screenSink = model.$screen.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.layout(anchoredTo: nil, animated: false)
                self.hosting.scroll(NSPoint(x: 0, y: self.hosting.isFlipped ? 0 : self.hosting.bounds.height))
            }
        }

        // Dismiss when the *application* stops being active, not when the panel merely
        // resigns key.
        //
        // The global mouse monitor only sees clicks, so Cmd-Tabbing away left the panel
        // floating at `.popUpMenu` level on top of whatever you switched to. But hooking
        // `windowDidResignKey` to fix that would also fire when a `Picker` inside the
        // panel opens its menu — the settings section would dismiss itself the moment
        // you tried to change the thermal ceiling. App-level activation is the signal
        // that actually means "the user went somewhere else".
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil)
    }

    @objc private func applicationDidResignActive() {
        close()
    }

    // MARK: - Showing

    /// The primary entry point from the status-item button.
    ///
    /// This is the safety net for the "clicking does nothing" bug that surfaces after
    /// sleep/wake or a display disconnect. The symptom is:
    ///
    ///   1. Panel was open when the lid shut (or the display disconnected).
    ///   2. Sleep moved it off-screen at the old coordinates.
    ///   3. `panel.isVisible` returns `true` because the window is technically
    ///      on screen — just at coordinates no physical display covers.
    ///   4. Every click goes to `close()` instead of `show()`. Icon appears dead.
    ///
    /// The fix: before routing, check whether a "visible" panel actually intersects any
    /// screen. If it does not, treat it as not-visible, close it (which resets
    /// `pinnedTopLeft`), and immediately re-show it at a freshly computed position.
    func toggle(relativeTo button: NSStatusBarButton?) {
        if panel.isVisible {
            // Validate that the panel is actually on a screen the user can see.
            // An off-screen panel must be healed rather than simply toggled closed,
            // because the user's intent was to open it, not to close a ghost.
            if !panelIntersectsAnyScreen() {
                // Silent close — skip the `closedAt` stamp so the re-open below is
                // not gated by the 0.2 s bounce guard.
                removeDismissMonitor()
                pinnedTopLeft = nil
                panel.orderOut(nil)
                show(relativeTo: button)
            } else {
                close()
            }
        } else if Date().timeIntervalSince(closedAt) > 0.2 {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        // Placement is decided here and only here, while the panel is still hidden.
        pinnedTopLeft = nil
        layout(anchoredTo: button, animated: false)

        // Last-resort clamp: if the frame still does not intersect any screen after
        // layout, force it to the top-right of the main screen before ordering front.
        // This handles the edge case where the SwiftUI fitting size was still zero at
        // the time of layout — the panel would have been placed at the default height
        // fallback, but the mainScreen check here catches any remaining gap.
        if !panelIntersectsAnyScreen() {
            let screen = NSScreen.main ?? NSScreen.screens.first
            if let screen {
                let x = screen.visibleFrame.maxX - width - Self.screenInset
                let y = screen.visibleFrame.maxY - Self.menuBarGap
                let fallbackFrame = PanelGeometry.frame(
                    topLeft: NSPoint(x: x, y: y),
                    width: width,
                    height: Self.defaultHeight)
                panel.setFrame(fallbackFrame, display: false)
            }
        }

        // An accessory app is not active by default, so without this the panel opens
        // behind the frontmost window and loses key on the first click inside it.
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            panel.animator().alphaValue = 1
        }
        hosting.scroll(NSPoint(x: 0, y: hosting.isFlipped ? 0 : hosting.bounds.height))
        installDismissMonitor(button: button)
    }

    func close() {
        // Guarded so a dismissal that arrives twice — a click that both trips the
        // monitor and deactivates the app — cannot re-stamp `closedAt` and swallow the
        // user's next click on the status item.
        guard panel.isVisible else { return }
        removeDismissMonitor()
        model.isOptionsOpen = false
        optionsPanel.orderOut(nil)
        panel.removeChildWindow(optionsPanel)
        closedAt = Date()
        pinnedTopLeft = nil
        panel.orderOut(nil)
    }

    /// Re-measures the SwiftUI content and grows or shrinks the panel to match.
    ///
    /// Only the height moves. The top-left corner was fixed when the panel opened, so a
    /// disclosure pushes the bottom edge down and leaves everything above it exactly
    /// where the user is looking.
    func resize(anchoredTo button: NSStatusBarButton?) {
        layout(anchoredTo: button, animated: true)
    }

    /// Clears the pinned position and closes if currently visible, so the next open
    /// re-derives placement against the current screen set.
    ///
    /// Called by the wake handler in `AppDelegate`. After a sleep/wake the screen
    /// geometry may have changed (different resolution, reconnected external display,
    /// or the built-in panel back on after an external was unplugged), so the old
    /// pinned position is stale by definition.
    func invalidatePlacement() {
        pinnedTopLeft = nil
        close()
    }

    private func updateOptionsPanel(open: Bool) {
        guard open, panel.isVisible else {
            panel.removeChildWindow(optionsPanel)
            optionsPanel.orderOut(nil)
            return
        }
        optionsHosting.layoutSubtreeIfNeeded()
        let size = optionsHosting.fittingSize
        optionsPanel.appearance = panel.appearance
        optionsPanel.setFrame(NSRect(x: panel.frame.maxX - size.width,
                                     y: panel.frame.minY - size.height - 6,
                                     width: size.width, height: size.height), display: true)
        if optionsPanel.parent == nil { panel.addChildWindow(optionsPanel, ordered: .above) }
        optionsPanel.orderFront(nil)
    }

    private func layout(anchoredTo button: NSStatusBarButton?, animated: Bool) {
        // Flush pending layout before measuring. The resize is driven by
        // `objectWillChange`, which fires *before* the change lands, so without this the
        // measurement can be one update behind — the window then holds the previous
        // height while the content is already the new one.
        hosting.layoutSubtreeIfNeeded()

        // Use the measured height when available, but fall back to a sensible default
        // rather than aborting the layout. The old `guard height > 0 else { return }`
        // was the root of the "clicking does nothing" bug: if `show()` was called while
        // the SwiftUI layout engine had not yet measured (common on the first open after
        // a wake), the panel frame was never updated and the panel ordered front at
        // whatever stale off-screen coordinates it last had.
        let rawHeight = hosting.fittingSize.height
        let contentHeight = rawHeight > 0 ? ceil(rawHeight) : Self.defaultHeight
        let height = contentHeight + Self.footerHeight
        hosting.setFrameSize(NSSize(width: width, height: contentHeight))

        let size = NSSize(width: width, height: height)

        let topLeft: NSPoint
        if let pinnedTopLeft {
            topLeft = pinnedTopLeft
        } else {
            let computed = self.topLeft(for: size, button: button)
            topLeft = computed
            pinnedTopLeft = computed
        }

        let targetScreen = NSScreen.screens.first { $0.frame.contains(topLeft) }
            ?? activeScreen()
        let popupSpace = model.isOptionsOpen ? ceil(optionsHosting.fittingSize.height) + 6 : 0
        let visibleHeight = targetScreen.map {
            PanelGeometry.visibleHeight(
                contentHeight: height, topY: topLeft.y,
                screenMinY: $0.visibleFrame.minY + popupSpace, inset: Self.screenInset)
        } ?? height
        var frame = PanelGeometry.frame(
            topLeft: topLeft, width: size.width, height: visibleHeight)
        frame = clampedToScreen(frame)

        guard frame != panel.frame else {
            updateOptionsPanel(open: model.isOptionsOpen)
            return
        }

        // Set, never animate.
        //
        // This used to ease over 0.18s "to match the disclosure animation in the SwiftUI
        // content" — but that animation has since been removed, and every other one with
        // it. So the content snapped to its new layout instantly while the window edge
        // took 180ms to catch up, and for those 180ms the window was the wrong height for
        // what was inside it. That mismatch is what read as the panel shifting: content
        // centred in a box that no longer fitted it. Window and content now change in the
        // same pass, which is the only way they cannot disagree.
        panel.setFrame(frame, display: true)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateOptionsPanel(open: model.isOptionsOpen)
    }

    // MARK: - Placement

    /// Where the panel's top-left corner goes.
    ///
    /// This method NEVER returns nil — the previous optional return type was the source
    /// of the off-screen panel bug. When `topLeft(for:button:)` returned nil, `show()`
    /// still called `panel.makeKeyAndOrderFront(nil)`, placing the panel at whatever
    /// stale frame it last had. After a sleep/wake that stale frame was off-screen, so
    /// every subsequent click reached the `close()` branch and the icon appeared dead.
    ///
    /// The hard fallback at the bottom always produces a point, so the caller gets
    /// a valid placement even when there are no screens at all (lid shut, no external
    /// display — this app's whole raison d'être).
    private func topLeft(for size: NSSize, button: NSStatusBarButton?) -> NSPoint {
        if let anchor = anchorRect(for: button), let screen = screen(containing: anchor) {
            // Centred under the icon, then pushed back inside the screen — an item near
            // the right edge would otherwise hang half of the panel into nothing.
            let x = PanelGeometry.clampedX(
                anchorMidX: anchor.midX,
                width: size.width,
                screenMinX: screen.frame.minX,
                screenMaxX: screen.frame.maxX,
                inset: Self.screenInset)
            return NSPoint(x: x, y: anchor.minY - Self.menuBarGap)
        }

        // No usable anchor: the icon is hidden by a menu-bar manager, has been pushed
        // under the notch, or the status item has no window yet. Hang the panel from
        // the top-right of the active screen, which is where a hidden item's owner
        // would have been anyway.
        if let screen = activeScreen() {
            return NSPoint(
                x: screen.visibleFrame.maxX - size.width - Self.screenInset,
                y: screen.visibleFrame.maxY - Self.menuBarGap)
        }

        // Absolute last resort: no NSScreen at all. This happens when the lid is shut
        // and there is no external display — which is precisely the scenario LidCode
        // manages. Rather than returning nil (which forced the panel to stay at its stale
        // off-screen frame), produce a point derived from the main display bounds via
        // CoreGraphics, which is available even when AppKit reports no screens.
        //
        // The coordinates below place the panel in the top-right area of the main
        // display. If even `CGDisplayBounds` is unavailable, fall back to a hard-coded
        // point that is always on a typical display.
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        if mainBounds.width > 0 {
            return NSPoint(
                x: mainBounds.maxX - size.width - Self.screenInset,
                y: mainBounds.maxY - Self.menuBarGap)
        }
        return NSPoint(x: 100, y: 800)
    }

    /// Adjusts `frame` so it intersects at least one visible screen.
    ///
    /// If the frame already intersects a screen, it is returned unchanged. Otherwise
    /// the frame's origin is recomputed against `activeScreen()` or the main screen,
    /// preserving the panel's size. This is the safety net that catches a placement
    /// produced from a stale button rect or a display that has since disconnected.
    private func clampedToScreen(_ frame: NSRect) -> NSRect {
        // Already visible on some screen — nothing to do.
        if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            return frame
        }

        // Recompute against whichever screen the user is actually looking at.
        let screen = activeScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return frame }

        let x = (screen.visibleFrame.maxX - frame.width - Self.screenInset)
            .clamped(to: screen.visibleFrame.minX, and: screen.visibleFrame.maxX - frame.width)
        let y = screen.visibleFrame.maxY - Self.menuBarGap
        return PanelGeometry.frame(
            topLeft: NSPoint(x: x, y: y),
            width: frame.width,
            height: frame.height)
    }

    /// Returns true if the panel's current frame intersects at least one visible screen.
    private func panelIntersectsAnyScreen() -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
    }

    /// The status item's on-screen rect, or nil when it is not somewhere a panel can
    /// sensibly hang from.
    ///
    /// The validity test is the whole point of this method. Ice and friends hide an
    /// item by moving its window off-screen or shrinking it to nothing, and the button
    /// keeps reporting a frame the entire time — so "does a button exist" is not the
    /// question. "Is it a real, visible slot in the menu bar" is.
    private func anchorRect(for button: NSStatusBarButton?) -> NSRect? {
        guard let button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.bounds)
        guard rect.width > 1, rect.height > 1 else { return nil }
        guard let screen = screen(containing: rect) else { return nil }
        // Must actually be up in the menu bar: an off-screen item lands well below it.
        guard rect.maxY > screen.frame.maxY - 40 else { return nil }
        return rect
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    /// Where the user is looking: the screen under the pointer, else the main one.
    ///
    /// Optional because a Mac can genuinely have **no** screens — lid shut with no
    /// external display, which is this app's whole reason to exist. Subscripting
    /// `NSScreen.screens[0]` there is a crash, and the resize sink runs on every model
    /// change, so a panel left open when the lid closed would have found it.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Dismissal

    /// A borderless panel gets no transient behaviour for free, so clicking away has to
    /// be watched for. Resigning key covers switching apps; the global monitor covers a
    /// click on the desktop or another window of this app.
    private func installDismissMonitor(button: NSStatusBarButton?) {
        removeDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            // Clicking the status item itself is the button's job to handle, and it
            // will toggle. Closing here too would double-fire.
            let mouse = NSEvent.mouseLocation
            if let anchor = self.anchorRect(for: button), anchor.insetBy(dx: -2, dy: -2).contains(mouse) {
                return
            }
            self.close()
        }
    }

    private func removeDismissMonitor() {
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
    }
}

private extension CGFloat {
    /// Two-bound clamp that tolerates a lower bound above the upper one, which happens
    /// when the panel is wider than the screen it is being placed on.
    func clamped(to lower: CGFloat, and upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return Swift.min(Swift.max(self, lower), upper)
    }
}
