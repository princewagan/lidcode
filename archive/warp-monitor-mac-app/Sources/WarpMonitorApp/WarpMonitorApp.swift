import SwiftUI
import AppKit
import ServiceManagement
import WarpMonitor
import os

// MARK: - App Entry Point
// Uses SwiftUI @main App struct + MenuBarExtra.
// LSUIElement=YES in Info.plist (injected by build-app-bundle.sh) suppresses the
// Dock icon at the OS level before NSApplication is created. Calling
// NSApp.setActivationPolicy(.accessory) from App.init() crashes with EXC_BREAKPOINT
// (SIGTRAP / force-unwrap nil) because NSApp is nil at that point in the lifecycle —
// the SwiftUI run loop has not yet initialised NSApplication.

// Lightweight file logger for headless GUI debugging.
// Writes timestamped lines to /tmp/warp-monitor-debug.log.
// Intentionally kept: provides persistent evidence when the process has no tty.
// The WarpMonitor library exports wmDebugLog; call it via the module import.
private func debugLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(msg)\n"
    if let data = line.data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/warp-monitor-debug.log")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

@main
struct WarpMonitorMenuBarApp: App {

    @StateObject private var appState = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel(alertLevel: appState.alertLevel)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Alert level

/// Loudest state across all tabs, used by both the menu bar icon and statusColor/statusLabel.
enum AlertLevel {
    case error      // red  — stop_failure
    case blocked    // amber — permission_request or legacy warning
    case running    // blue — something is in progress
    case ok         // green — all finished or idle, Warp running
    case warpClosed // orange — Warp not running
    case noData     // gray — nothing pushed yet
}

// MARK: - Menu bar icon

private struct MenuBarLabel: View {
    let alertLevel: AlertLevel

    var body: some View {
        switch alertLevel {
        case .error:
            Image(systemName: "terminal.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red, .primary)
        case .blocked, .warpClosed:
            Image(systemName: "terminal.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.orange, .primary)
        case .running:
            Image(systemName: "terminal.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.blue, .primary)
        case .ok:
            Image(systemName: "terminal.fill")
        case .noData:
            Image(systemName: "terminal.fill")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Popover content

struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("Warp Monitor")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(appState.statusColor)
                    .frame(width: 7, height: 7)
                Text(appState.statusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            if let state = appState.currentState {
                // Everything currently live, lifted out of the group list.
                // The list below is organised by folder, which is the wrong axis
                // for "what is happening right now?" — answering that meant
                // scanning every group. Renders nothing when nothing is live.
                ActivityBand(state: state)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Tab groups — sorted by loudest status within group
                        ForEach(state.tab_groups, id: \.id) { group in
                            TabGroupRow(group: group)
                        }

                        // Ungrouped tabs
                        if !state.ungrouped_tabs.isEmpty {
                            GroupHeaderLabel(name: "Ungrouped")
                            ForEach(state.ungrouped_tabs.sorted { statusRank($0.claude_status) < statusRank($1.claude_status) }, id: \.id) { tab in
                                TabEntryRow(tab: tab)
                            }
                        }

                        // Warp closed banner
                        if !state.warp_running {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                Text("Warp is closed")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 440)
            } else {
                Text("No data yet — waiting for first push")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(14)
            }

            Divider()

            // Footer
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.lastPushLabel)
                            .font(.system(size: 10, design: .monospaced))
                            // Stall (>5 min) → red; normal → secondary
                            .foregroundStyle(appState.isPushStalled ? .red : .secondary)
                        if let err = appState.lastError {
                            Text(err)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 5)

                HStack {
                    Toggle("Launch at login", isOn: Binding(
                        get: { appState.launchAtLoginEnabled },
                        set: { appState.setLaunchAtLogin($0) }
                    ))
                    .font(.system(size: 10))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    if let loginErr = appState.launchAtLoginError {
                        Text(loginErr)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
            }
        }
        .frame(width: 320)
    }
}

// MARK: - Status rank (lower = more urgent, floats to top)

private func statusRank(_ s: ClaudeStatus) -> Int {
    switch s {
    case .error:   return 0
    case .blocked: return 1
    case .warning: return 2  // legacy alias for blocked
    case .running: return 3
    case .finished: return 4
    case .idle:    return 5
    }
}

// MARK: - Status appearance (colour + label pair; never colour alone)

private struct StatusAppearance {
    let color: Color
    let label: String
}

private func statusAppearance(_ s: ClaudeStatus) -> StatusAppearance? {
    switch s {
    case .running:
        return StatusAppearance(color: .blue, label: "In progress")
    case .blocked:
        return StatusAppearance(color: .orange, label: "Blocked")
    case .warning:
        // Legacy alias — treat identically to blocked
        return StatusAppearance(color: .orange, label: "Blocked")
    case .error:
        return StatusAppearance(color: .red, label: "Error")
    case .finished:
        return StatusAppearance(color: .green, label: "Done")
    case .idle:
        return nil  // idle rows carry no status badge
    }
}

// MARK: - Activity band (blocked / errored / running, pinned above the list)

/// The live-work summary that sits directly under the header.
///
/// Two sections, ordered by who is waiting on whom. "Needs you" leads because a
/// blocked or failed session has stopped and is burning the user's time; "In
/// progress" is informational and nothing there requires action.
///
/// Rows here are duplicates of rows in the group list below, not moves — the
/// band is a view onto the same state, so a session still appears under its
/// folder. Mirrors ActivityPanel.tsx on the phone so both surfaces answer the
/// same question the same way.
private struct ActivityBand: View {
    let state: WarpMonitorState

    /// Every row on screen, flattened. Grouping is irrelevant here: the whole
    /// point of the band is to ignore which folder work lives in.
    private var allTabs: [WarpTab] {
        state.tab_groups.flatMap(\.tabs) + state.ungrouped_tabs
    }

    /// Blocked and errored, loudest first (blocked outranks error).
    private var needsYou: [WarpTab] {
        allTabs
            .filter { $0.claude_status == .blocked || $0.claude_status == .warning || $0.claude_status == .error }
            .sorted { statusRank($0.claude_status) < statusRank($1.claude_status) }
    }

    private var running: [WarpTab] {
        allTabs.filter { $0.claude_status == .running }
    }

    var body: some View {
        if needsYou.isEmpty && running.isEmpty {
            EmptyView()
        } else {
            // The band stays pinned above the scrolling group list, so it needs
            // its own bound: with many blocked sessions it would otherwise grow
            // tall enough to push the list out of the popover entirely. Capped
            // here and allowed to scroll internally instead.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !needsYou.isEmpty {
                        ActivitySectionHeader(title: "Needs you",
                                              count: needsYou.count,
                                              tint: .orange)
                        ForEach(needsYou, id: \.id) { tab in
                            TabEntryRow(tab: tab)
                        }
                    }

                    if !running.isEmpty {
                        ActivitySectionHeader(title: "In progress",
                                              count: running.count,
                                              tint: .secondary)
                        ForEach(running, id: \.id) { tab in
                            TabEntryRow(tab: tab)
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.04))

            Divider()
        }
    }
}

private struct ActivitySectionHeader: View {
    let title: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(tint)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}

// MARK: - Group header label (typography-only, no hue)

private struct GroupHeaderLabel: View {
    let name: String

    var body: some View {
        Text(name.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }
}

// MARK: - Tab group row

private struct TabGroupRow: View {
    let group: WarpTabGroup
    @State private var expanded = true

    // Loudest status across the group's tabs
    private var groupStatus: ClaudeStatus {
        group.tabs.min(by: { statusRank($0.claude_status) < statusRank($1.claude_status) })?.claude_status ?? .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 0) {
                    // Typography-only group header — no colour dot for the group
                    Text(group.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    // Show loudest status label on the collapsed header
                    if !expanded, let appearance = statusAppearance(groupStatus) {
                        Text(appearance.label)
                            .font(.system(size: 10))
                            .foregroundStyle(appearance.color)
                            .padding(.trailing, 6)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            if expanded {
                // Sort within group: blocked/error float first
                let sorted = group.tabs.sorted { statusRank($0.claude_status) < statusRank($1.claude_status) }
                ForEach(sorted, id: \.id) { tab in
                    TabEntryRow(tab: tab)
                        .padding(.leading, 10)
                }
            }
        }
    }
}

// MARK: - Tab entry row

private struct TabEntryRow: View {
    let tab: WarpTab

    private var appearance: StatusAppearance? { statusAppearance(tab.claude_status) }

    // First non-empty session, for surfacing detail fields
    private var session: ClaudeSession? { tab.claude_sessions.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Line 1: status badge + title
            HStack(spacing: 5) {
                if let a = appearance {
                    // Status: colour dot + text label — never colour alone
                    Circle()
                        .fill(a.color)
                        .frame(width: 6, height: 6)
                    Text(a.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(a.color)
                        .lineLimit(1)
                } else {
                    // Idle — quiet indicator
                    Circle()
                        .strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
                        .frame(width: 6, height: 6)
                    Text("No Claude")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Agent name (e.g. "claude") when a session exists
                if let agent = session?.agent {
                    Text(agent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Line 2: AI title (headline) or raw tab title as fallback.
            // AI title is the session-level description ("Create test admin accounts"),
            // which is what Warp shows in its own tab list.
            Text(tab.ai_title ?? tab.title)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Line 3: repo/path · branch (secondary context, always shown)
            HStack(spacing: 4) {
                if !tab.cwd.isEmpty {
                    Text(shortCWD(tab.cwd))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let branch = tab.git_branch {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 110, alignment: .leading)
                }
            }

            // The TTY line that used to sit here is gone. It reported a guess
            // ("ttys001 (inferred)") produced by pairing tabs to processes by
            // sort position, which was both useless to read and the source of
            // wrong-tab statuses. Rows are now one-per-session and carry a real
            // identity, so there is nothing left to disambiguate.

            // Line 4 (blocked only): blocked_reason — most valuable field
            if tab.claude_status == .blocked || tab.claude_status == .warning,
               let reason = session?.blocked_reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Line 4 (error only): error_type + last_query
            if tab.claude_status == .error {
                if let errorType = session?.error_type {
                    Text(errorType)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(1)
                }
                if let query = session?.last_query, !query.isEmpty {
                    Text(query)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func shortCWD(_ path: String) -> String {
        // Collapse home directory to ~
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let relative = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        // Keep last two path components for brevity
        let components = relative.split(separator: "/").map(String.init)
        if components.count > 2 {
            return "~/" + components.suffix(2).joined(separator: "/")
        }
        return relative.isEmpty ? path : relative
    }
}

// MARK: - App view model

@MainActor
class AppViewModel: ObservableObject {
    @Published var currentState: WarpMonitorState?
    @Published var lastError: String?
    @Published var lastPushTime: Date?
    @Published var launchAtLoginError: String?

    private var manager: StateManager?

    // MARK: - App Nap prevention
    // When launched via `open` (or as a login item), macOS treats an LSUIElement app
    // with no visible window as a background process eligible for App Nap.
    // App Nap coalesces DispatchSourceTimers on .utility QoS queues, silently stalling
    // the 5s poll and 60s heartbeat. The token below opts the process out of App Nap
    // for the lifetime of the app. It does NOT prevent system sleep or display sleep.
    //
    // Options chosen:
    //   .userInitiatedAllowingIdleSystemSleep — suppresses App Nap timer coalescing
    //   .idleDisplaySleepDisabled             — NOT used (too aggressive, battery waste)
    //   .latencyCritical                      — NOT used (prevents ALL sleep; overkill)
    private var activityToken: NSObjectProtocol?

    // MARK: - Launch at login

    var launchAtLoginEnabled: Bool {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled: return true
        default: return false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = enabled
                ? "Bundle required for auto-start. Build the .app (see README)."
                : "Could not unregister: \(error.localizedDescription)"
        }
        UserDefaults.standard.set(enabled, forKey: "launchAtLoginEnabled")
    }

    // MARK: - Computed alert level
    // Inspects ALL active statuses — blocked, error, and legacy warning all trigger the icon.

    var alertLevel: AlertLevel {
        guard let state = currentState else { return .noData }
        if !state.warp_running { return .warpClosed }
        let allTabs = state.tab_groups.flatMap(\.tabs) + state.ungrouped_tabs
        if allTabs.contains(where: { $0.claude_status == .error }) { return .error }
        if allTabs.contains(where: { $0.claude_status == .blocked || $0.claude_status == .warning }) { return .blocked }
        if allTabs.contains(where: { $0.claude_status == .running }) { return .running }
        return .ok
    }

    // hasWarning drives the old MenuBarLabel; now replaced by alertLevel.
    // Kept so any external references do not break, but delegates to alertLevel.
    var hasWarning: Bool {
        switch alertLevel {
        case .error, .blocked, .warpClosed: return true
        default: return false
        }
    }

    var statusColor: Color {
        switch alertLevel {
        case .error:      return .red
        case .blocked:    return .orange
        case .warpClosed: return .orange
        case .running:    return .blue
        case .ok:         return .green
        case .noData:     return .gray
        }
    }

    var statusLabel: String {
        switch alertLevel {
        case .error:      return "Error"
        case .blocked:    return "Needs you"
        case .warpClosed: return "Warp closed"
        case .running:    return "In progress"
        case .ok:         return "Live"
        case .noData:     return "No data"
        }
    }

    var lastPushLabel: String {
        guard let t = lastPushTime else { return "Not pushed yet" }
        let secs = Int(-t.timeIntervalSinceNow)
        if secs < 60 { return "Pushed \(secs)s ago" }
        if secs < 300 { return "Pushed \(secs / 60)m ago" }
        // Stall threshold: 5+ minutes without a successful push — surface urgency.
        return "STALLED \(secs / 60)m ago — check /tmp/warp-monitor-debug.log"
    }

    /// True when the last successful push was more than 5 minutes ago (stall indicator).
    var isPushStalled: Bool {
        guard let t = lastPushTime else { return false }
        return -t.timeIntervalSinceNow > 300
    }

    init() {
        debugLog("[AppViewModel.init] AppViewModel constructed — startManager running immediately")
        // Acquire App Nap prevention token before starting timers.
        // This must happen early: once App Nap activates, timers may already be deferred.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Warp Monitor needs timely timer delivery to push state updates"
        )
        debugLog("[AppViewModel.init] App Nap prevention token acquired: \(activityToken != nil)")
        startManager()
    }

    private func startManager() {
        debugLog("[startManager] Configuring StateManager")
        let m = StateManager()
        m.pushEnabled = true
        m.configurePusher()

        m.warpRunningProvider = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: "dev.warp.Warp-Stable"
            ).isEmpty
        }

        if let err = m.pusher?.configurationError {
            lastError = err
        }

        m.onStateUpdated = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.currentState = state
            }
        }

        m.pusher?.onResult = { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .ok:
                    debugLog("[push.ok] Push succeeded")
                    self?.lastPushTime = Date()
                    self?.lastError = nil
                case .notConfigured(let msg):
                    debugLog("[push.notConfigured] \(msg)")
                    self?.lastError = "Not configured: \(msg)"
                case .authError:
                    debugLog("[push.authError] check PUSH_SECRET")
                    self?.lastError = "Auth error — check PUSH_SECRET"
                case .validationError(let body):
                    debugLog("[push.validationError] \(body)")
                    self?.lastError = "Validation error: \(body)"
                case .networkError(let err):
                    debugLog("[push.networkError] \(err.localizedDescription)")
                    self?.lastError = "Network: \(err.localizedDescription)"
                case .httpError(let code, _):
                    debugLog("[push.httpError] HTTP \(code)")
                    self?.lastError = "HTTP \(code)"
                }
            }
        }

        m.start()
        manager = m
        debugLog("[startManager] StateManager.start() called — timers are running")

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.manager?.forceRefreshAfterWake()
            }
        }
    }
}
