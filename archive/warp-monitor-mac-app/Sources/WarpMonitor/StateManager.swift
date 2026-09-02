import Foundation
import CryptoKit

// MARK: - Lightweight file logger (shared with WarpMonitorApp layer)
// Writes to /tmp/warp-monitor-debug.log so GUI-launched processes leave traces.
// Package-internal (not public) — used only for diagnostic purposes.
func wmDebugLog(_ msg: String) {
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

/// StateManager orchestrates the SQLite reader and log tailer.
/// It maintains a per-session-id state machine and builds the WarpMonitorState JSON.
/// Phase 3: wires Pusher with diff-only push + 60s heartbeat.
public final class StateManager: @unchecked Sendable {

    // MARK: - Dependencies

    private let sqliteReader: SQLiteReader
    private let logTailer: LogTailer
    public private(set) var pusher: Pusher?

    /// Reads AI-generated session titles from Claude Code transcript files.
    private let aiTitleReader = AITitleReader()

    /// Last published status per session id, keyed by session — used only for the
    /// running/finished hysteresis in `activityStatus`.
    ///
    /// Keyed by session rather than by tab position because a tab's index is not
    /// a stable identity: tabs open and close, and the folder's session set
    /// changes underneath them. Keying hysteresis on position meant a tab could
    /// inherit the previous status of a completely different session.
    private var previousSessionStatus: [String: ClaudeStatus] = [:]

    // MARK: - Push behaviour flags

    /// When true, push state changes via Pusher. When false, just emit via onStateUpdated.
    public var pushEnabled: Bool = false

    /// When true, also print JSON to stdout via onStateUpdated even when pushing.
    public var printEnabled: Bool = false

    /// Optional provider for whether Warp is currently running.
    /// Set by the app layer (WarpMonitorApp, CLI) using NSRunningApplication.
    /// When nil, StateManager assumes Warp is running and relies solely on SQLite errors
    /// to detect a down state.
    public var warpRunningProvider: (() -> Bool)?

    // MARK: - In-memory session map: session_id -> state

    private var sessionMap: [String: ClaudeSessionState] = [:]
    private let sessionLock = NSLock()

    // MARK: - Notification ring buffer (max 50)

    private var notifications: [WarpNotification] = []
    private let maxNotifications = 50

    // MARK: - Push deduplication

    private var lastPushedHash: String = ""
    private var lastPushTime: Date = .distantPast
    private let heartbeatInterval: TimeInterval = 60

    // MARK: - Current state

    public private(set) var currentState: WarpMonitorState?

    /// Called whenever state is updated (for stdout printing, UI, etc.)
    public var onStateUpdated: ((WarpMonitorState) -> Void)?

    // MARK: - Init

    public init(dbPath: String = SQLiteReader.defaultDBPath, logPath: String = LogTailer.defaultLogPath) {
        self.sqliteReader = SQLiteReader(dbPath: dbPath)
        self.logTailer = LogTailer(logPath: logPath)
    }

    // MARK: - Configure Pusher

    public func configurePusher(configPath: String = "~/.warp-monitor.env") {
        let p = Pusher(configPath: configPath)
        p.onResult = { [weak self] result in
            self?.handlePushResult(result)
        }
        pusher = p
    }

    // MARK: - Sleep/wake

    /// Call this when the Mac wakes from sleep (e.g. from NSWorkspace.didWakeNotification).
    /// Forces a re-query and re-push regardless of hash — ensures the phone recovers quickly.
    /// The app layer (WarpMonitorApp, CLI) registers the OS notification and calls this.
    public func forceRefreshAfterWake() {
        walQueue.async { [weak self] in
            guard let self else { return }
            // Reset hash so the next refresh always pushes even if tabs haven't changed.
            self.lastPushedHash = ""
            self.refresh()
        }
    }

    // MARK: - Start

    public func start() {
        // Wire log tailer callbacks
        logTailer.onEvent = { [weak self] event in
            self?.handleOSC777Event(event)
        }
        logTailer.onNotification = { [weak self] notif in
            self?.appendNotification(notif)
        }

        // Start the log tailer
        logTailer.start()

        // Immediately read SQLite and emit/push state
        refresh()

        // Set up WAL watcher and heartbeat timer
        setupWALWatcher()
        setupHeartbeatTimer()
    }

    public func stop() {
        logTailer.stop()
        walWatcherTimer?.cancel()
        heartbeatTimer?.cancel()
    }

    // MARK: - WAL Watcher (5s polling timer; Phase 4 upgrades to kqueue)

    private var walWatcherTimer: DispatchSourceTimer?
    // QoS .userInitiated: App Nap does not throttle timers on this class, so the 5s
    // poll and 60s heartbeat fire on schedule even when the app has no visible window.
    // .utility would be coalesced during App Nap, causing the push-stall bug.
    private let walQueue = DispatchQueue(label: "ph.advo.warp-monitor.walwatcher", qos: .userInitiated)

    private func setupWALWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: walQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            wmDebugLog("[walTimer] fired")
            self?.pruneStaleSessionsAndRefresh()
        }
        timer.resume()
        walWatcherTimer = timer
    }

    // MARK: - Heartbeat timer (60s)

    private var heartbeatTimer: DispatchSourceTimer?

    private func setupHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: walQueue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            wmDebugLog("[heartbeatTimer] fired")
            self?.heartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    /// Force a push even if state hasn't changed — keeps the phone page alive.
    private func heartbeat() {
        guard pushEnabled, let pusher, let state = currentState else {
            wmDebugLog("[heartbeat] skipped: pushEnabled=\(pushEnabled) pusher=\(pusher != nil) state=\(currentState != nil)")
            return
        }
        let timeSinceLastPush = Date().timeIntervalSince(lastPushTime)
        guard timeSinceLastPush >= heartbeatInterval else {
            wmDebugLog("[heartbeat] skipped: timeSinceLastPush=\(Int(timeSinceLastPush))s < \(Int(heartbeatInterval))s")
            return
        }
        wmDebugLog("[heartbeat] pushing (timeSinceLastPush=\(Int(timeSinceLastPush))s)")
        // Rebuild state with fresh pushed_at timestamp
        let heartbeatState = rebuildWithFreshTimestamp(state)
        pusher.push(state: heartbeatState)
        lastPushTime = Date()
    }

    // MARK: - Refresh

    @discardableResult
    public func refresh() -> WarpMonitorState {
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let now = isoNow()

        // Check if Warp is running using the injected provider.
        // The app layer sets warpRunningProvider using NSRunningApplication (AppKit).
        // When not set (e.g. in tests), assume Warp is running.
        let warpIsRunning = warpRunningProvider?() ?? true

        // Try SQLite read
        var tabGroups: [WarpTabGroup]
        var ungroupedTabs: [WarpTab]
        var warpRunning = warpIsRunning
        var readerError: String? = nil

        do {
            let (groups, ungrouped) = try sqliteReader.readTabGroups()
            tabGroups = groups
            ungroupedTabs = ungrouped
        } catch {
            // Schema mismatch or DB access error — set error marker so phone shows
            // "Mac reader error" rather than a silent empty tab list.
            warpRunning = false
            tabGroups = []
            ungroupedTabs = []
            readerError = "schema_mismatch: \(error.localizedDescription)"
        }

        // If Warp is not running, clear tab groups (no point showing stale data)
        // but do NOT set readerError — the phone banner handles this via warp_running=false.
        if !warpIsRunning {
            tabGroups = []
            ungroupedTabs = []
            readerError = nil  // don't conflate "Warp closed" with "reader error"
        }

        // Apply Claude session data from log tailer
        sessionLock.lock()
        let sessions = sessionMap
        sessionLock.unlock()

        // Correlate sessions to tabs using CWD matching
        let (correlatedGroups, correlatedUngrouped, orphans) = correlateSessions(
            sessions: sessions,
            tabGroups: &tabGroups,
            ungroupedTabs: &ungroupedTabs
        )

        let notifCopy: [WarpNotification]
        sessionLock.lock()
        notifCopy = notifications
        sessionLock.unlock()

        let state = WarpMonitorState(
            pushed_at: now,
            mac_hostname: hostname,
            warp_running: warpRunning,
            tab_groups: correlatedGroups,
            ungrouped_tabs: correlatedUngrouped,
            notifications: notifCopy,
            orphan_sessions: orphans,
            mac_reader_error: readerError
        )

        currentState = state
        onStateUpdated?(state)

        // Push only if state changed (or heartbeat handles it separately)
        if pushEnabled {
            pushIfChanged(state)
        }

        return state
    }

    // MARK: - Diff-only push

    private func pushIfChanged(_ state: WarpMonitorState) {
        guard let pusher else { return }

        let hash = stateHash(state)
        guard hash != lastPushedHash else {
            // State unchanged — heartbeat timer handles periodic push
            return
        }

        wmDebugLog("[pushIfChanged] state changed — pushing")
        lastPushedHash = hash
        lastPushTime = Date()
        pusher.push(state: state)
    }

    private func stateHash(_ state: WarpMonitorState) -> String {
        // Hash the JSON-encoded state minus the pushed_at timestamp
        // (pushed_at changes every refresh but doesn't represent a real state change)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        // Build a comparable representation without timestamp
        struct ComparableState: Encodable {
            let warp_running: Bool
            let tab_groups: [WarpTabGroup]
            let ungrouped_tabs: [WarpTab]
            let orphan_sessions: [ClaudeSession]
            let mac_reader_error: String?
            // Exclude notifications (they have UUIDs that change on every parse)
            // and pushed_at (changes every call)
        }

        let comparable = ComparableState(
            warp_running: state.warp_running,
            tab_groups: state.tab_groups,
            ungrouped_tabs: state.ungrouped_tabs,
            orphan_sessions: state.orphan_sessions,
            mac_reader_error: state.mac_reader_error
        )

        guard let data = try? encoder.encode(comparable) else { return UUID().uuidString }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Rebuild state with fresh timestamp (for heartbeat)

    private func rebuildWithFreshTimestamp(_ state: WarpMonitorState) -> WarpMonitorState {
        WarpMonitorState(
            pushed_at: isoNow(),
            mac_hostname: state.mac_hostname,
            warp_running: state.warp_running,
            tab_groups: state.tab_groups,
            ungrouped_tabs: state.ungrouped_tabs,
            notifications: state.notifications,
            orphan_sessions: state.orphan_sessions,
            mac_reader_error: state.mac_reader_error
        )
    }

    // MARK: - Push result handler

    private func handlePushResult(_ result: Pusher.PushResult) {
        switch result {
        case .ok:
            break // Success — nothing to log
        case .notConfigured(let msg):
            fputs("[warp-monitor] Not configured: \(msg)\n", stderr)
        case .authError:
            fputs("[warp-monitor] Auth error (401). Check PUSH_SECRET in ~/.warp-monitor.env\n", stderr)
        case .validationError(let body):
            fputs("[warp-monitor] Validation error (400): \(body)\n", stderr)
        case .networkError(let err):
            fputs("[warp-monitor] Network error: \(err.localizedDescription) (will retry)\n", stderr)
        case .httpError(let code, let body):
            fputs("[warp-monitor] HTTP \(code): \(body)\n", stderr)
        }
    }

    // MARK: - Activity detection constants
    //
    // A Claude Code session appends to its JSONL transcript while it is working
    // and stops when it finishes and waits for the user.  Transcript mtime is
    // therefore a direct activity signal — effectively free because AITitleReader
    // already stats each transcript file for its title cache.
    //
    // Activity window: 60 seconds.
    //   • Claude can pause several seconds between tool calls (network, disk, LLM
    //     latency).  Too tight a window causes false "done" flickers mid-task.
    //   • 60 s is long enough to cover realistic tool-call gaps without lying for
    //     long after a session genuinely finishes.
    //
    // Hysteresis grace: 15 seconds.
    //   • When a tab transitions from running → not-recently-written, we do NOT
    //     immediately flip it to "finished".  Instead we wait one more poll cycle
    //     (grace = 15 s > poll interval = 5 s) before committing the transition.
    //   • This prevents oscillation: if a session writes at t=59 s and is polled
    //     at t=60 s it would immediately look stale.  With grace it stays "running"
    //     until t=75 s — one clean boundary past the activity window.
    //   • Implementation: tabs already in "running" state (from log events or a
    //     previous poll) keep their status for `activityGrace` extra seconds beyond
    //     `activityWindow` before being demoted to "finished".
    //
    // In-flight detection (inFlight parameter):
    //   • If the session's last log event was tool_complete or prompt_submit with no
    //     subsequent stop/idle_prompt, the session is in-flight: Claude is between
    //     tool calls, waiting on a network response, or the subagent wrote to a
    //     different transcript path than the one we stat.
    //   • In that case we treat the session as .running even when the transcript is
    //     briefly quiet — the 10-minute timeout is the safety net.
    //   • This correctly reports tabs like "continue everything" and "usage" whose
    //     orchestrator transcript writes to a subagent path rather than the main one.
    //
    // Sticky states (blocked / error):
    //   • blocked and error are NOT time-decayed. A session stays blocked/error until
    //     a NEW event (session_start, prompt_submit, tool_complete, stop, idle_prompt)
    //     supersedes it in the log state machine.
    //   • The recency check that existed here previously was the bug: it caused
    //     stop_failure sessions to revert to "finished" once they aged past the
    //     activity window, discarding the error signal entirely.
    //   • Now activityStatus() passes blocked/error through unconditionally when
    //     logStatus is set — no age check, no time-decay.
    //
    // Process liveness: only establishes that a Claude REPL *exists* for this tab.
    //   • A live `claude` process does NOT mean Claude is working.  It means the
    //     REPL is open and sitting at a prompt.  This assumption was the bug in Phase 1.
    //   • After the fix: process liveness → status is "finished" (done, waiting),
    //     unless transcript mtime says otherwise (running) or log says blocked/error.
    //
    // Timeout/prune interaction with sticky states:
    //   • The 10-minute running timeout in checkTimeout() ONLY fires for .running
    //     sessions. blocked and error sessions are NOT affected by it.
    //   • The 30-minute prune in isStale ONLY prunes .finished sessions. blocked
    //     and error sessions are never pruned — they require user action to clear.
    //   • This means pruneStaleSessionsAndRefresh() cannot erase a live error or
    //     blocked entry even after days without activity.

    static let activityWindow: TimeInterval = 60   // seconds
    static let activityGrace: TimeInterval  = 15   // seconds of hysteresis

    // MARK: - Session correlation (one row per Claude session)
    //
    // ---------------------------------------------------------------------------
    // Why a session, and not a Warp tab, is the unit
    // ---------------------------------------------------------------------------
    // Warp does not record which Claude session belongs to which tab. Verified
    // against every available source:
    //
    //   • OSC 777 event payload — carries session_id and cwd only. No pane id,
    //     no tab id, no TTY.
    //   • warp.sqlite — terminal_panes/pane_leaves/pane_nodes/tabs have no TTY,
    //     no pid, and no Claude conversation link (agent_conversations is empty
    //     and belongs to Warp's own agent, not Claude Code).
    //   • lsof on a live `claude` pid — shows no open transcript handle, because
    //     Claude Code appends and closes. So pid → session cannot be resolved.
    //   • pane_leaves.custom_vertical_tabs_title — populated for only 3 of 17
    //     tabs observed, and those were user labels, not AI titles. Unusable as
    //     a join key.
    //
    // The previous implementation papered over this with two positional
    // heuristics — tabs sorted by id paired against processes sorted by TTY, and
    // "hand the Nth newest transcript in this folder to the Nth tab". Both
    // fabricated a mapping that does not exist, and the fabrication moved:
    // transcript mtime order re-sorts whenever any session writes a line, so a
    // tab's supposed session changed identity every few seconds. That is exactly
    // what produced the reported symptoms — a blocked/error/running state
    // appearing on the wrong tab, and appearing to spread across every tab in
    // a folder as the index shifted from one poll to the next.
    //
    // A Claude session, by contrast, has a real and stable identity: its
    // session_id, which is also its transcript filename. Its status comes only
    // from its own event stream and its own transcript. So the session is the
    // row. A folder is only ever a grouping label, never a source of status.
    //
    // Consequences, stated plainly:
    //   • Row count follows sessions, not tabs. A folder with 3 tabs and 4 live
    //     sessions shows 4 rows.
    //   • A Warp tab whose folder has no live session still appears, as an idle
    //     "no Claude" row, so the user's layout does not silently lose entries.
    //   • Nothing is ever aggregated across a folder. There is no code path left
    //     by which one session's failure can colour another session's row.

    private func correlateSessions(
        sessions: [String: ClaudeSessionState],
        tabGroups: inout [WarpTabGroup],
        ungroupedTabs: inout [WarpTab]
    ) -> ([WarpTabGroup], [WarpTab], [ClaudeSession]) {

        // ── 1. Index Warp tabs by folder ─────────────────────────────────────
        // A tab tells us which group a folder's work should display under, and
        // supplies folder-level context (pinned). It never tells us which
        // session it owns, so it is used for placement only — never for status.
        struct FolderRef {
            let groupIdx: Int?   // nil = ungrouped
            let pinned: Bool
        }
        var folderByCWD: [String: FolderRef] = [:]

        for (gi, group) in tabGroups.enumerated() {
            for tab in group.tabs where !tab.cwd.isEmpty {
                let key = normalizeCWD(tab.cwd)
                let pinned = (folderByCWD[key]?.pinned ?? false) || tab.pinned

                guard let existing = folderByCWD[key] else {
                    folderByCWD[key] = FolderRef(groupIdx: gi, pinned: pinned)
                    continue
                }

                // Two tabs at the same cwd can sit in different groups, and then
                // there is no fact about which group owns the folder's work.
                // Prefer the group whose name matches the folder name — a
                // "television" folder belongs under the TELEVISION group, not
                // under whichever group happened to be enumerated first.
                let folderName = URL(fileURLWithPath: key).lastPathComponent
                let existingMatches = existing.groupIdx.map {
                    namesMatch(tabGroups[$0].name, folderName)
                } ?? false
                let candidateMatches = namesMatch(group.name, folderName)

                let winner = (candidateMatches && !existingMatches) ? gi : existing.groupIdx
                folderByCWD[key] = FolderRef(groupIdx: winner, pinned: pinned)
            }
        }
        for tab in ungroupedTabs where !tab.cwd.isEmpty {
            let key = normalizeCWD(tab.cwd)
            if folderByCWD[key] == nil {
                folderByCWD[key] = FolderRef(groupIdx: nil, pinned: tab.pinned)
            }
        }

        // ── 2. Build one row per live session ────────────────────────────────
        var rowsByGroup: [Int: [WarpTab]] = [:]
        var ungroupedRows: [WarpTab] = []
        var orphanSessions: [ClaudeSession] = []
        var cwdsWithSessions: Set<String> = []
        var nextStatusBySession: [String: ClaudeStatus] = [:]

        for (_, sess) in sessions {
            let cwd = normalizeCWD(sess.cwd)

            // Title and transcript mtime for THIS session, addressed by its own
            // id. Exact by construction — the id is the transcript filename.
            let titleResult = aiTitleReader.resolve(cwd: cwd, sessionId: sess.sessionId)

            // Status for THIS session only.
            //   1. blocked/error are sticky — they persist until a newer event
            //      for this same session supersedes them in the state machine.
            //   2. otherwise transcript activity decides running vs finished,
            //      with hysteresis against this session's own previous status.
            let status: ClaudeStatus
            if sess.status == .blocked || sess.status == .error || sess.status == .warning {
                status = sess.status == .warning ? .blocked : sess.status
            } else {
                status = activityStatus(
                    transcriptMtime: titleResult.transcriptMtime,
                    currentStatus: previousSessionStatus[sess.sessionId],
                    logStatus: sess.status,
                    inFlight: sess.isInFlight
                )
            }
            nextStatusBySession[sess.sessionId] = status

            // Place the session under the folder it belongs to. Exact match
            // first, then the nearest ancestor: a session started in
            // `television/mac-app` is work inside the `television` tab's tree and
            // belongs on screen next to it, not exiled to a separate list.
            //
            // This only decides which group the row is drawn under. It never
            // claims a specific tab owns the session, so it cannot reintroduce
            // the mis-attribution this rewrite removed.
            guard let (folderKey, folder) = resolveFolder(for: cwd, in: folderByCWD) else {
                // Not inside any open tab's directory tree at all.
                orphanSessions.append(makeClaudeSession(sess))
                continue
            }
            cwdsWithSessions.insert(folderKey)

            // Headline: the session's own AI title, else the folder name. A Warp
            // tab's label is deliberately NOT used — we cannot attribute a tab
            // label to a specific session without re-introducing the guess.
            let folderName = URL(fileURLWithPath: cwd).lastPathComponent
            let displayTitle = titleResult.aiTitle
                ?? (folderName.isEmpty ? "Session \(sess.sessionId.prefix(8))" : folderName)

            let row = WarpTab(
                id: sess.sessionId,          // real, unique, stable
                title: displayTitle,
                custom_title: nil,
                cwd: sess.cwd,
                pinned: folder.pinned,
                claude_status: status,
                claude_sessions: [makeClaudeSession(sess)],
                ambiguous_cwd: false,        // nothing is ambiguous any more
                is_focused: false,
                git_branch: GitBranchReader.shared.branch(for: sess.cwd),
                tty: nil,                    // removed: the pairing was the bug
                claude_pid: nil,
                ai_title: titleResult.aiTitle,
                title_source: titleResult.source
            )

            if let gi = folder.groupIdx {
                rowsByGroup[gi, default: []].append(row)
            } else {
                ungroupedRows.append(row)
            }
        }

        // ── 3. Keep Warp tabs whose folder has no live session ───────────────
        // These render as idle "no Claude" rows so the user's layout stays whole.
        // Their id is namespaced so it can never collide with a session id.
        for (gi, group) in tabGroups.enumerated() {
            for tab in group.tabs {
                let key = tab.cwd.isEmpty ? "" : normalizeCWD(tab.cwd)
                guard tab.cwd.isEmpty || !cwdsWithSessions.contains(key) else { continue }
                rowsByGroup[gi, default: []].append(idleRow(from: tab))
            }
        }
        var ungroupedOut: [WarpTab] = ungroupedRows
        for tab in ungroupedTabs {
            let key = tab.cwd.isEmpty ? "" : normalizeCWD(tab.cwd)
            guard tab.cwd.isEmpty || !cwdsWithSessions.contains(key) else { continue }
            ungroupedOut.append(idleRow(from: tab))
        }

        // ── 4. Assemble, in a deterministic order ────────────────────────────
        // Sort is by title then id so the push-dedup hash is stable across polls
        // that changed nothing. Display ordering by urgency is the phone's job.
        var outGroups = tabGroups
        for gi in outGroups.indices {
            outGroups[gi].tabs = (rowsByGroup[gi] ?? []).sorted(by: rowOrder)
        }
        // A group whose tabs all vanished would render as an empty card.
        outGroups = outGroups.filter { !$0.tabs.isEmpty }

        previousSessionStatus = nextStatusBySession

        return (outGroups, ungroupedOut.sorted(by: rowOrder), orphanSessions)
    }

    /// Compare a Warp group name to a folder name, ignoring case and any
    /// separators the user typed for readability ("ADVO ROADS" ~ "advoroads").
    func namesMatch(_ a: String, _ b: String) -> Bool {
        func squash(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let sa = squash(a), sb = squash(b)
        return !sa.isEmpty && sa == sb
    }

    /// Find the open-tab folder a session's cwd sits in.
    ///
    /// Returns the exact folder when one matches, otherwise the *deepest*
    /// ancestor folder, so a session in `advoroads/process/features/mmda-pitch`
    /// resolves to `advoroads` rather than to `/`. Returns nil when the cwd is
    /// not inside any open tab's tree.
    ///
    /// Matching is on path components, not raw string prefixes: `/foo/bar-baz`
    /// must not be treated as living inside `/foo/bar`.
    func resolveFolder<T>(
        for cwd: String,
        in folders: [String: T]
    ) -> (key: String, value: T)? {
        if let exact = folders[cwd] { return (cwd, exact) }

        var best: (key: String, value: T)?
        for (key, value) in folders where cwd.hasPrefix(key + "/") {
            if best == nil || key.count > best!.key.count {
                best = (key, value)
            }
        }
        return best
    }

    /// Deterministic row ordering: title, then id as a tiebreak.
    private func rowOrder(_ a: WarpTab, _ b: WarpTab) -> Bool {
        if a.title != b.title { return a.title < b.title }
        return a.id < b.id
    }

    /// A Warp tab with no Claude session running in its folder.
    /// Keeps Warp's own label, since here there is no session to contradict it.
    private func idleRow(from tab: WarpTab) -> WarpTab {
        WarpTab(
            id: "tab:\(tab.id)",
            title: tab.title,
            custom_title: tab.custom_title,
            cwd: tab.cwd,
            pinned: tab.pinned,
            claude_status: .idle,
            claude_sessions: [],
            ambiguous_cwd: false,
            is_focused: tab.is_focused,
            git_branch: tab.git_branch,
            tty: nil,
            claude_pid: nil,
            ai_title: nil,
            title_source: tab.title_source
        )
    }

    // MARK: - Activity status (mtime-based)

    /// Determine running vs. finished using transcript mtime.
    ///
    /// Priority (highest first):
    ///   1. blocked/error from `logStatus` — sticky; returned as-is with no time-decay.
    ///      A session stays blocked/error until a NEW log event supersedes it.
    ///   2. running — `inFlight` is true (last log event was tool_complete or
    ///      prompt_submit with no subsequent stop/idle_prompt).  The session is between
    ///      tool calls; transcript may be briefly quiet even though work continues.
    ///   3. running — transcript was written within `activityWindow` seconds.
    ///      If the tab is currently running, extend the window by `activityGrace`
    ///      (hysteresis: prevents oscillation on consecutive polls near the boundary).
    ///   4. finished — process exists, transcript is quiet and session is not in-flight.
    ///   5. finished — no transcript at all (new process, no transcript yet written).
    ///
    /// - Parameters:
    ///   - transcriptMtime: modification time of the session's JSONL transcript, or nil.
    ///   - currentStatus: the tab's current claude_status (used for hysteresis), or nil.
    ///   - logStatus: status from the log-event state machine, or nil when no log session.
    ///   - inFlight: true when the last observed log event was tool_complete or
    ///     prompt_submit and no stop/idle_prompt has been seen since — meaning Claude is
    ///     actively working but may not have written to transcript recently.
    func activityStatus(
        transcriptMtime: Date?,
        currentStatus: ClaudeStatus?,
        logStatus: ClaudeStatus?,
        inFlight: Bool = false
    ) -> ClaudeStatus {
        // Priority 1: sticky blocked/error — no age check, no time-decay.
        // These states persist until a new event (session_start, prompt_submit,
        // tool_complete, stop, idle_prompt) supersedes them in the state machine.
        if let ls = logStatus, ls == .blocked || ls == .error { return ls }

        // Priority 2: in-flight — last event was tool_complete or prompt_submit.
        // The session is between tool calls; it is running even if the transcript
        // is momentarily quiet (subagent may write to a different path).
        if inFlight { return .running }

        let now = Date()
        if let mtime = transcriptMtime {
            let age = now.timeIntervalSince(mtime)
            // Apply hysteresis: extend the activity window by `activityGrace` when
            // the tab is already in "running" state to avoid oscillation.
            let effectiveWindow = (currentStatus == .running)
                ? StateManager.activityWindow + StateManager.activityGrace
                : StateManager.activityWindow
            return age <= effectiveWindow ? .running : .finished
        }

        // No transcript found — process exists but transcript not yet written, or
        // cwd is not a Claude project directory.  Default to finished (not running):
        // a new session will get an OSC 777 sessionStart event within seconds and
        // transition to running via the log-event path.
        return .finished
    }

    // MARK: - ClaudeSession builder

    private func makeClaudeSession(_ sess: ClaudeSessionState) -> ClaudeSession {
        ClaudeSession(
            session_id: sess.sessionId,
            project: sess.project,
            last_event: sess.lastEvent,
            last_event_at: isoDate(sess.lastEventAt),
            tool_name: sess.toolName,
            error_type: sess.errorType,
            agent: sess.agent,
            blocked_reason: sess.blockedReason,
            last_query: sess.lastQuery
        )
    }

    // NOTE: there is deliberately no folder-wide status aggregation function here
    // any more. Rolling several sessions up into one "worst status" value and
    // stamping it onto tabs is what made a single failure turn every tab in a
    // folder red. Each row now carries exactly one session's own status.

    // MARK: - Handle OSC 777 event

    private func handleOSC777Event(_ event: OSC777Event) {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if sessionMap[event.sessionId] == nil {
            sessionMap[event.sessionId] = ClaudeSessionState(
                sessionId: event.sessionId,
                cwd: event.cwd,
                project: event.project
            )
        }

        sessionMap[event.sessionId]!.apply(
            event: event.event,
            at: event.receivedAt,
            toolName: event.toolName,
            errorType: event.errorType,
            agent: event.agent,
            summary: event.summary,
            query: event.query
        )

        // Update cwd in case it changed (shouldn't normally, but be safe)
        sessionMap[event.sessionId]!.cwd = event.cwd

        // Trigger a state refresh on the WAL queue to avoid blocking the log queue
        walQueue.async { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Notification ring buffer

    private func appendNotification(_ notif: WarpNotification) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        notifications.append(notif)
        if notifications.count > maxNotifications {
            notifications.removeFirst(notifications.count - maxNotifications)
        }
    }

    // MARK: - Prune stale sessions and refresh

    private func pruneStaleSessionsAndRefresh() {
        sessionLock.lock()
        // Timeout check: downgrade running sessions silent for 10+ minutes
        for key in sessionMap.keys {
            sessionMap[key]?.checkTimeout()
        }
        // Prune finished sessions older than 30 minutes
        sessionMap = sessionMap.filter { !$0.value.isStale }
        sessionLock.unlock()

        refresh()
    }

    // MARK: - CWD normalization

    private func normalizeCWD(_ raw: String) -> String {
        var path = raw
        while path.hasSuffix("/") && path != "/" {
            path = String(path.dropLast())
        }
        if let resolved = realpath(path, nil) {
            let result = String(cString: resolved)
            free(resolved)
            return result
        }
        return path
    }
}
