import SwiftUI
import AppKit
import LidCodeKit

/// Real app icons, borrowed from the copy already installed on this Mac.
///
/// The alternative — bundling PNGs of each vendor's logo — means redistributing other
/// companies' trademarked artwork inside a binary, and shipping icons that go stale
/// the moment a vendor rebrands. Asking the system for the icon of an app the user
/// already installed avoids both: nothing is redistributed, the artwork is always the
/// current official one, and an agent that is not installed simply has no icon to show
/// rather than a wrong one.
@MainActor
enum AppIconResolver {
    /// Keyed by the candidate list. The value is `NSImage?` rather than `NSImage` so a
    /// miss is cached too — otherwise every redraw re-hits Launch Services for an app
    /// that is not installed, at ~60 lookups a second while the menu is open.
    private static var cache: [String: NSImage?] = [:]

    static func icon(for candidate: [String]) -> NSImage? {
        guard !candidate.isEmpty else { return nil }
        let key = candidate.joined(separator: "|")
        if let cached = cache[key] { return cached }

        let workspace = NSWorkspace.shared
        let resolved = candidate
            .lazy
            .compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { workspace.icon(forFile: $0.path) }

        cache[key] = resolved
        return resolved
    }

    /// Apps come and go while LidCode is running; the menu's Refresh drops the cache so
    /// installing Cursor does not require a restart to see its icon.
    static func forget() { cache.removeAll() }
}

// The `AgentIcon` view that used to live here is gone with the agent roster it drew — a
// section listing every AI tool on the Mac with a colour icon each, which is a thing to
// look at rather than an answer to "will my Mac stay awake". The resolver above stays:
// `AppModel.refreshHealth()` still drops its cache, so a freshly installed agent is
// picked up without a restart, and the CLI's health output reads the same source.
