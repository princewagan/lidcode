import AppKit
import SwiftUI

/// Exports the real SwiftUI views with safe fixture data for visual review.
/// No server, helper, provider requests, or local credentials are accessed.
@MainActor
enum DashboardPreview {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Pending transitions keep the previous presentation; confirmed protection
        // is the only state allowed to advertise that the lid can close.
        let buttonCases: [(Bool, Bool, Bool, String)] = [
            (false, false, false, "OFF"), (false, true, false, "OFF"),
            (true, false, true, "ON · lid can close"),
            (true, true, true, "ON · lid can close"), (true, false, false, "ON")
        ]
        for (enabled, switching, protected, expected) in buttonCases {
            let button = PowerButton(isEnabled: enabled, isSwitching: switching,
                                     isProtected: protected, onToggle: { _ in })
            guard button.line == expected else { throw CocoaError(.validationMissingMandatoryProperty) }
        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            for screen in ["dashboard", "hot", "very-hot", "hot-memory", "memory-warn", "memory-alert", "customize", "settings", "empty", "options", "about", "power", "four-accounts", "five-accounts", "eight-accounts"] {
                let model = AppModel()
                model.configurePreview(empty: screen == "empty", hot: screen == "hot" || screen == "hot-memory", memoryAlert: screen == "memory-alert", accountCount: screen == "four-accounts" ? 4 : screen == "five-accounts" ? 5 : screen == "eight-accounts" ? 8 : 2, veryHot: screen == "very-hot", memoryWarn: screen == "memory-warn" || screen == "hot-memory")
                if screen == "customize" { model.screen = .customize }
                if screen == "settings" { model.screen = .settings }
                if screen == "options" { model.isOptionsOpen = true }
                if screen == "about" { model.screen = .about }
                let root = screen == "power" ? AnyView(VStack(spacing: 10) {
                    ForEach(buttonCases.indices, id: \.self) { index in
                        let item = buttonCases[index]
                        PowerButton(isEnabled: item.0, isSwitching: item.1,
                                    isProtected: item.2, onToggle: { _ in })
                    }
                }.padding(14).frame(width: DashboardTheme.width).background(DashboardTheme.tray))
                    : AnyView(MenuView(model: model))
                let hosting = NSHostingView(rootView: root)
                hosting.appearance = NSAppearance(named: appearance)
                let size = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: directory.appendingPathComponent("\(screen)-\(name).png"))
                window.orderOut(nil)
            }
        }
        // Regression: navigate after the same observed root is already hosted.
        let navigationModel = AppModel()
        navigationModel.configurePreview()
        let navigationHost = NSHostingView(rootView: DashboardContent(model: navigationModel))
        let navigationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: DashboardTheme.width, height: 500),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        navigationWindow.contentView = navigationHost
        navigationHost.layoutSubtreeIfNeeded()
        let dashboardHeight = navigationHost.fittingSize.height
        navigationModel.screen = .about
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        navigationHost.layoutSubtreeIfNeeded()
        guard navigationHost.fittingSize.height < dashboardHeight else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        navigationModel.screen = .settings
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        navigationHost.layoutSubtreeIfNeeded()
        guard navigationHost.fittingSize.height > 250 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        navigationModel.screen = .customize
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        navigationHost.layoutSubtreeIfNeeded()
        guard navigationHost.fittingSize.height != 250 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        navigationWindow.orderOut(nil)
        // Theme changes must update the hosted root without a runtime/model tick.
        let savedTheme = UserDefaults.standard.object(forKey: "appTheme")
        defer {
            if let savedTheme { UserDefaults.standard.set(savedTheme, forKey: "appTheme") }
            else { UserDefaults.standard.removeObject(forKey: "appTheme") }
        }
        navigationModel.screen = .about
        func themedNavigation(_ theme: AppTheme) throws -> Data {
            UserDefaults.standard.set(theme.rawValue, forKey: "appTheme")
            NotificationCenter.default.post(name: .lidCodeThemeDidChange, object: theme.rawValue)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            navigationHost.layoutSubtreeIfNeeded()
            let bounds = navigationHost.bounds
            let header = NSRect(x: 0, y: navigationHost.isFlipped ? 0 : bounds.height - 44,
                                width: bounds.width, height: 44)
            guard let bitmap = navigationHost.bitmapImageRepForCachingDisplay(in: header) else {
                throw CocoaError(.fileWriteUnknown)
            }
            navigationHost.cacheDisplay(in: header, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
        let blueNavigation = try themedNavigation(.blue)
        let purpleNavigation = try themedNavigation(.purple)
        guard blueNavigation != purpleNavigation else {
            print("Theme regression: hosted navigation tint did not change within 100 ms without a model tick")
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var renderedThemes: Set<Data> = [blueNavigation, purpleNavigation]
        for theme in AppTheme.allCases where theme != .blue && theme != .purple {
            guard renderedThemes.insert(try themedNavigation(theme)).inserted else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
        }
        guard try themedNavigation(.blue) == blueNavigation else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        print("Hosted theme regression passed: all six colors update within 100 ms without a model tick")
        print("Dashboard previews rendered; hosted navigation regression passed")
    }
}
