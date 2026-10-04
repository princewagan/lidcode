import AppKit
import SwiftUI

/// Exports the real SwiftUI views with safe fixture data for visual review.
/// No server, helper, provider requests, or local credentials are accessed.
@MainActor
enum DashboardPreview {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            for screen in ["dashboard", "customize", "settings", "empty"] {
                let model = AppModel()
                model.configurePreview(empty: screen == "empty")
                if screen == "customize" { model.screen = .customize }
                if screen == "settings" { model.screen = .settings }
                let root = MenuView(model: model)
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
        print("Dashboard previews rendered")
    }
}
