import Foundation
import SQLite3

// MARK: - Internal state machine type

/// Per-session state tracked across OSC 777 events.
private struct InternalSession {
    var id: String
    var agent: String
    var cwd: String
    var project: String
    var lastEvent: String
    var lastEventAt: Date
    /// Derived from last event via the state machine.
    var status: AgentStatus
    /// When status last changed (not last-seen).
    var statusChangedAt: Date
    var lastSeenAt: Date
    var timedOut: Bool = false

    // MARK: - State machine

    /// Apply an event and return true if status changed.
    @discardableResult
    mutating func apply(event: String, at date: Date) -> Bool {
        let previous = status
        lastEvent = event
        lastEventAt = date
        lastSeenAt = date

        switch event {
        case "session_start", "prompt_submit", "tool_complete":
            status = .running
        case "idle_prompt", "stop":
            status = .finished
        case "permission_request":
            status = .blocked
        case "stop_failure":
            status = .error
        default:
            // Unknown events fail closed: do not change status.
            break
        }

        if status != previous {
            statusChangedAt = date
            return true
        }
        return false
    }

    /// Check for 10-minute running timeout. Returns true when status changed.
    /// Uses `asOf` rather than `Date()` so tests with synthetic timestamps work correctly.
    @discardableResult
    mutating func checkTimeout(asOf now: Date = Date()) -> Bool {
        guard status == .running else { return false }
        let elapsed = now.timeIntervalSince(lastEventAt)
        if elapsed > 600 {
            status = .finished
            timedOut = true
            lastEvent = "stop"      // wire-safe (closest semantic match)
            statusChangedAt = now
            return true
        }
        return false
    }

    /// True when this session should be pruned from the snapshot.
    /// Uses `asOf` so tests with synthetic timestamps work correctly.
    func isStale(asOf now: Date = Date()) -> Bool {
        status == .finished && now.timeIntervalSince(lastEventAt) > 1800
    }

    /// True when this session's last event was tool_complete or prompt_submit
    /// and no subsequent stop/idle_prompt has been seen.
    var isInFlight: Bool {
        guard status == .running else { return false }
        return lastEvent == "tool_complete" || lastEvent == "prompt_submit"
    }

}

// MARK: - AgentLogLine (public API, kept for test compatibility)

/// One parsed `Received OSC 777 notification` line.
public struct AgentLogLine: Sendable, Equatable {
    public var at: Date
    public var sessionId: String
    public var agent: String
    public var project: String
    public var cwd: String
    public var event: String
    public var toolName: String?
}

// MARK: - AgentSessionReader

/// Reads live agent activity out of Warp's log and builds an `AgentSessionSnapshot`.
///
/// The reader maintains an in-memory state machine for each session keyed by session UUID.
/// On every `read()` call it:
///   1. Checks if warp.log has changed (by mtime+size); re-parses only on change.
///   2. Applies the activity-window corroboration (transcript mtime) to classify
///      running vs. finished with hysteresis.
///   3. Runs the timeout and prune rules.
///   4. Resolves titles via AITitleReader.
///   5. Returns `AgentSessionSnapshot` with all non-pruned sessions.
///
/// Strictly read-only. The Warp database is opened `mode=ro`.
public final class AgentSessionReader: @unchecked Sendable {

    // MARK: - Constants (kept public for tests)

    /// Running sessions silent for more than this many seconds are timed out.
    public static let staleAfterSecond: TimeInterval = 600

    /// How much of the warp.log tail to read per refresh.
    public static let tailByteLimit: UInt64 = 512 * 1024

    /// Fallback name from Warp sqlite is re-read at most this often.
    public static let fallbackCacheSecond: TimeInterval = 30

    // MARK: - Activity window / hysteresis (ported from WarpMonitor StateManager)

    /// A transcript written within this many seconds of now means the session is active.
    static let activityWindow: TimeInterval = 60

    /// Extra grace when transitioning from running → not-recently-written.
    /// Prevents oscillation on polls near the boundary.
    static let activityGrace: TimeInterval = 15

    // MARK: - Log parsing markers

    private static let lineMarker = "Received OSC 777 notification"
    private static let bodyMarker = "body="

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    // MARK: - Working / idle event sets (kept public for tests)

    /// Events that mean the session is actively working.
    /// `permission_request` is included: the agent is blocked on the user but
    /// the run is live and the Mac must not be allowed to sleep.
    public static let workingEvent: Set<String> = [
        "session_start", "prompt_submit", "tool_complete", "permission_request",
    ]

    /// Events that mean the session has handed control back.
    public static let idleEvent: Set<String> = ["stop", "stop_failure", "idle_prompt"]

    public static func isWorking(event: String) -> Bool { workingEvent.contains(event) }

    // MARK: - Dependencies

    private let logURL: URL
    private let databaseURL: URL
    private let aiTitleReader: AITitleReader

    // MARK: - Cache for log file

    private let lock = NSLock()
    /// In-memory state machine, keyed by session id.
    private var sessionMap: [String: InternalSession] = [:]
    private var logCachedSize: UInt64?
    private var logCachedModifiedAt: Date?

    /// Previous status per session, used for activity-window hysteresis.
    private var previousStatus: [String: AgentStatus] = [:]

    // MARK: - Fallback name cache

    private var cachedFallbackName: String?
    private var fallbackReadAt: Date?

    // MARK: - Init

    public init(logURL: URL? = nil, databaseURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logURL = logURL ?? home.appendingPathComponent("Library/Logs/warp.log")
        self.databaseURL = databaseURL ?? home.appendingPathComponent(
            "Library/Group Containers/2BBY89MBSN.dev.warp"
                + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite")
        self.aiTitleReader = AITitleReader()
    }

    // MARK: - Primary read (new API)

    /// Returns the current session truth snapshot.
    ///
    /// Cheap enough to call on the runtime's 5s tick: an unchanged log costs
    /// one `stat` and a dictionary pass.
    ///
    /// W1 integration note (step 2.5): replace `session = sessionReader.read()` with
    /// `agentSession = sessionReader.readAgentSession()` in LidCodeRuntime.swift after
    /// renaming the ivar from `session: SessionSnapshot` to `agentSession: AgentSessionSnapshot`.
    public func readAgentSession(asOf now: Date = Date()) -> AgentSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        refreshLogIfChanged()
        pruneAndTimeout(asOf: now)

        // Build AgentSessionInfo for every non-pruned session.
        var infos: [AgentSessionInfo] = []
        var nextPreviousStatus: [String: AgentStatus] = [:]

        for (_, sess) in sessionMap {
            // Corroborate status with transcript mtime.
            let titleResult = aiTitleReader.resolve(cwd: sess.cwd, sessionId: sess.id)
            let effectiveStatus = activityStatus(
                logStatus: sess.status,
                transcriptMtime: titleResult.transcriptMtime,
                currentStatus: previousStatus[sess.id],
                inFlight: sess.isInFlight,
                asOf: now
            )
            nextPreviousStatus[sess.id] = effectiveStatus

            // Codex fallback: if no transcript exists, use log-event state machine
            // with a shorter idle window. The effectiveStatus above already handles
            // this via activityStatus returning .finished when transcriptMtime is nil
            // and the session is not in-flight.
            //
            // CODEX_VERIFY: Real-world verification needed. Codex sessions emit OSC 777
            // events and are processed identically to Claude sessions here. The key
            // question is whether Codex writes JSONL transcripts to ~/.claude/projects/.
            // If not, the fallback path (log-event only, no transcript corroboration)
            // is the correct behaviour — but the shorter idle window (120s vs 600s) for
            // Codex needs live testing to confirm the right threshold.

            // Resolve title.
            let resolvedTitle: String
            let resolvedTitleSource: String
            if let aiTitle = titleResult.aiTitle {
                resolvedTitle = aiTitle
                resolvedTitleSource = "ai-title"
            } else {
                // Try Warp pane title from sqlite.
                let warpTitle = warpPaneTitle(for: sess.cwd)
                if let wt = warpTitle {
                    resolvedTitle = wt
                    resolvedTitleSource = "warp-pane-title"
                } else {
                    resolvedTitle = Self.basename(of: sess.cwd)
                    resolvedTitleSource = "cwd-basename"
                }
            }

            // Determine statusChangedAt: it was recorded when the event was applied,
            // but if effectiveStatus differs from the log status (because transcript
            // corroboration demoted running → finished), we use now as the change time.
            let changedAt = effectiveStatus == sess.status
                ? sess.statusChangedAt
                : now

            infos.append(AgentSessionInfo(
                id: sess.id,
                agent: sess.agent,
                cwd: sess.cwd,
                project: sess.project,
                title: resolvedTitle,
                titleSource: resolvedTitleSource,
                status: effectiveStatus,
                lastEvent: sess.lastEvent,
                lastSeenAt: sess.lastSeenAt,
                statusChangedAt: changedAt
            ))
        }

        previousStatus = nextPreviousStatus

        // Sort: running first, then blocked, error, finished. Within a group: most-recently-seen first.
        let statusOrder: (AgentStatus) -> Int = {
            switch $0 {
            case .running: return 0
            case .blocked: return 1
            case .error: return 2
            case .finished: return 3
            }
        }
        infos.sort { a, b in
            let sa = statusOrder(a.status), sb = statusOrder(b.status)
            if sa != sb { return sa < sb }
            return a.lastSeenAt > b.lastSeenAt
        }

        var snapshot = AgentSessionSnapshot(sessions: infos)
        if snapshot.activeCount == 0 {
            snapshot.fallbackName = fallbackName(asOf: now)
        }
        return snapshot
    }

    // MARK: - Legacy backward-compat read (step 2.5 migration shim)
    //
    // LidCodeRuntime.swift (W1) currently calls `session = sessionReader.read()` where
    // `session` is typed as `SessionSnapshot`. This deprecated shim keeps that line
    // compiling until W1 migrates to `agentSession = sessionReader.readAgentSession()`.
    //
    // DO NOT USE in new code. Remove once W1's step 2.5 commit lands.

    @available(*, deprecated, message: "Use readAgentSession() instead. This shim exists for LidCodeRuntime.swift until W1 migrates (step 2.5).")
    public func read(asOf now: Date = Date()) -> SessionSnapshot {
        let agentSnapshot = readAgentSession(asOf: now)
        let active: [AgentSession] = agentSnapshot.sessions
            .filter { $0.status == AgentStatus.running }
            .map { info in
                AgentSession(
                    id: info.id,
                    agent: info.agent,
                    project: info.project,
                    cwd: info.cwd,
                    lastEvent: info.lastEvent,
                    lastSeenAt: info.lastSeenAt,
                    isWorking: true
                )
            }
        return SessionSnapshot(
            active: active,
            primary: active.first,
            otherCount: max(0, active.count - 1),
            fallbackName: agentSnapshot.fallbackName
        )
    }

    // MARK: - Activity status (ported from WarpMonitor StateManager.activityStatus)

    /// Determine effective status using transcript mtime + hysteresis.
    ///
    /// Priority:
    ///   1. blocked or error from logStatus — sticky, returned as-is.
    ///   2. inFlight — last event was tool_complete or prompt_submit → .running.
    ///   3. Transcript recently written (within activityWindow + grace) → .running.
    ///   4. Otherwise → .finished.
    private func activityStatus(
        logStatus: AgentStatus,
        transcriptMtime: Date?,
        currentStatus: AgentStatus?,
        inFlight: Bool,
        asOf now: Date
    ) -> AgentStatus {
        // Sticky: blocked and error are never time-decayed.
        if logStatus == .blocked || logStatus == .error { return logStatus }

        // In-flight: Claude is between tool calls.
        if inFlight { return .running }

        if let mtime = transcriptMtime {
            let age = now.timeIntervalSince(mtime)
            let effectiveWindow = (currentStatus == .running)
                ? Self.activityWindow + Self.activityGrace
                : Self.activityWindow
            return age <= effectiveWindow ? .running : .finished
        }

        // No transcript: default to finished. A new session_start event will
        // transition it to running via the log-event path.
        return .finished
    }

    // MARK: - Log refresh

    private func refreshLogIfChanged() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path) else {
            sessionMap = [:]
            logCachedSize = nil
            logCachedModifiedAt = nil
            return
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attrs[.modificationDate] as? Date
        if logCachedSize == size, logCachedModifiedAt == modifiedAt { return }

        logCachedSize = size
        logCachedModifiedAt = modifiedAt

        let (data, isPartial) = tail(size: size)
        applyTailData(data, dropsPartialFirstLine: isPartial)
    }

    private func tail(size: UInt64) -> (Data, Bool) {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return (Data(), false) }
        defer { try? handle.close() }
        let offset = size > Self.tailByteLimit ? size - Self.tailByteLimit : 0
        if offset > 0 {
            guard (try? handle.seek(toOffset: offset)) != nil else { return (Data(), false) }
        }
        let data = (try? handle.readToEnd()) ?? Data()
        return (data, offset > 0)
    }

    private func applyTailData(_ data: Data, dropsPartialFirstLine: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        var rows = text.split(separator: "\n", omittingEmptySubsequences: true)
        if dropsPartialFirstLine, !rows.isEmpty { rows.removeFirst() }

        // Replay events into the state machine in log order.
        // A new log scan replaces the old in-memory state entirely.
        var fresh: [String: InternalSession] = [:]
        for line in rows {
            guard let parsed = Self.parse(line: line) else { continue }
            if fresh[parsed.sessionId] == nil {
                fresh[parsed.sessionId] = InternalSession(
                    id: parsed.sessionId,
                    agent: parsed.agent,
                    cwd: parsed.cwd,
                    project: parsed.project,
                    lastEvent: parsed.event,
                    lastEventAt: parsed.at,
                    status: AgentStatus.running,  // will be overwritten by apply()
                    statusChangedAt: parsed.at,
                    lastSeenAt: parsed.at
                )
                // Apply the first event to set correct status.
                fresh[parsed.sessionId]!.apply(event: parsed.event, at: parsed.at)
            } else {
                // Only apply if this event is newer (log is append-ordered, but be safe).
                if parsed.at >= fresh[parsed.sessionId]!.lastEventAt {
                    fresh[parsed.sessionId]!.apply(event: parsed.event, at: parsed.at)
                    // Update cwd in case it changed.
                    fresh[parsed.sessionId]!.cwd = parsed.cwd
                }
            }
        }

        // Carry over blocked/error sessions from the previous map even if they
        // fell outside the tail window — these are sticky and require user action.
        for (id, old) in sessionMap where (old.status == AgentStatus.blocked || old.status == AgentStatus.error) {
            if fresh[id] == nil {
                fresh[id] = old
            }
        }

        sessionMap = fresh
    }

    // MARK: - Timeout and prune

    private func pruneAndTimeout(asOf now: Date) {
        for key in sessionMap.keys {
            sessionMap[key]?.checkTimeout(asOf: now)
        }
        // Prune finished sessions older than 30 minutes.
        // Blocked and error sessions are NEVER pruned.
        sessionMap = sessionMap.filter { !$0.value.isStale(asOf: now) }
    }

    // MARK: - Warp database: pane title

    /// Read the `custom_vertical_tabs_title` for the pane matching `cwd` from Warp's sqlite.
    /// Returns nil when Warp is not installed, the db is locked, or no matching row exists.
    private func warpPaneTitle(for cwd: String) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }

        var cursor: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.tabQuery, -1, &cursor, nil) == SQLITE_OK,
              let statement = cursor else {
            sqlite3_finalize(cursor)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let targetBasename = Self.basename(of: cwd)
        var paneTitle: String?
        var fallback: String?

        while sqlite3_step(statement) == SQLITE_ROW {
            let rowCwd = Self.column(statement, 2) ?? ""
            let rowPaneTitle = Self.column(statement, 4)
            let rowCustomTitle = Self.column(statement, 1)

            // Match by cwd or basename.
            let matches = rowCwd == cwd || Self.basename(of: rowCwd) == targetBasename
            if matches {
                if let pt = rowPaneTitle, !pt.isEmpty {
                    paneTitle = pt
                } else if let ct = rowCustomTitle, !ct.isEmpty {
                    paneTitle = ct
                }
            }

            // Accumulate general fallback.
            if fallback == nil {
                fallback = Self.rowName(statement)
            }
        }

        return paneTitle
    }

    private func openDB() -> OpaquePointer? {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(
            Self.uri(forPath: databaseURL.path), &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK, let database = handle else {
            sqlite3_close(handle)
            return nil
        }
        return database
    }

    // MARK: - Warp database fallback name (no session running)

    private func fallbackName(asOf now: Date) -> String? {
        if let readAt = fallbackReadAt, now.timeIntervalSince(readAt) < Self.fallbackCacheSecond {
            return cachedFallbackName
        }
        fallbackReadAt = now
        cachedFallbackName = Self.warpTabName(databaseURL: databaseURL)
        return cachedFallbackName
    }

    // MARK: - SQL query (step 2.4a: includes custom_vertical_tabs_title)

    /// Column indices: 0=t.id, 1=t.custom_title, 2=tp.cwd, 3=pl.is_focused,
    ///                 4=pl.custom_vertical_tabs_title
    static let tabQuery = """
        SELECT t.id,
               t.custom_title,
               tp.cwd,
               pl.is_focused,
               pl.custom_vertical_tabs_title
        FROM tabs t
        LEFT JOIN pane_nodes pn ON pn.tab_id = t.id AND pn.is_leaf = 1
        LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id
        LEFT JOIN terminal_panes tp ON tp.id = pl.pane_node_id
        ORDER BY t.id;
        """

    /// Returns the tab name from the last row in the result set.
    /// Prefers `custom_vertical_tabs_title` (column 4) > `custom_title` (column 1)
    /// > cwd basename (column 2). This is the priority order from step 2.4a.
    public static func warpTabName(databaseURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(
            uri(forPath: databaseURL.path), &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK, let database = handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(database) }

        var cursor: OpaquePointer?
        guard sqlite3_prepare_v2(database, tabQuery, -1, &cursor, nil) == SQLITE_OK,
              let statement = cursor else {
            sqlite3_finalize(cursor)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var name: String?
        var focusedName: String?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let candidate = rowName(statement) else { continue }
            name = candidate
            if sqlite3_column_int(statement, 3) != 0 { focusedName = candidate }
        }
        return name ?? focusedName
    }

    /// Column 4 (custom_vertical_tabs_title) wins over column 1 (custom_title)
    /// wins over column 2 (cwd basename).
    static func rowName(_ statement: OpaquePointer) -> String? {
        // Priority 1: Warp's own pane title (agent's wording, e.g. "Fix sleep policy")
        if let paneTitle = column(statement, 4), !paneTitle.isEmpty { return paneTitle }
        // Priority 2: user-set custom tab title
        if let title = column(statement, 1), !title.isEmpty { return title }
        // Priority 3: cwd basename
        guard let cwd = column(statement, 2), !cwd.isEmpty else { return nil }
        let folder = basename(of: cwd)
        return folder.isEmpty ? nil : folder
    }

    static func column(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    // MARK: - URI encoding for SQLite

    public static func uri(forPath path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "?", with: "%3f")
            .replacingOccurrences(of: "#", with: "%23")
        return "file:\(escaped)?mode=ro"
    }

    // MARK: - Log line parsing (kept public for tests)

    public static func parse(line: some StringProtocol) -> AgentLogLine? {
        guard line.contains(lineMarker) else { return nil }
        guard let space = line.firstIndex(of: " ") else { return nil }
        guard let at = timestampFormatter.date(from: String(line[line.startIndex..<space])) else {
            return nil
        }
        guard let marker = line.range(of: bodyMarker) else { return nil }
        let body = line[marker.upperBound...]
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
            let field = json as? [String: Any],
            let sessionId = field["session_id"] as? String, !sessionId.isEmpty,
            let event = field["event"] as? String, !event.isEmpty
        else { return nil }

        let cwd = field["cwd"] as? String ?? ""
        let project = field["project"] as? String ?? ""
        return AgentLogLine(
            at: at,
            sessionId: sessionId,
            agent: field["agent"] as? String ?? "",
            project: project.isEmpty ? Self.basename(of: cwd) : project,
            cwd: cwd,
            event: event,
            toolName: field["tool_name"] as? String)
    }

    // MARK: - sessions(fromTail:) (kept public for legacy tests)

    /// Re-parses a raw tail buffer into a flat session dictionary.
    /// Status is computed from the last event only (no mtime corroboration).
    /// Used only by the legacy `AgentSessionTailTest` tests; the live code path
    /// uses the stateful `applyTailData(_:dropsPartialFirstLine:)` instead.
    @available(*, deprecated, message: "Use read() -> AgentSessionSnapshot instead")
    public static func sessions(fromTail data: Data, dropsPartialFirstLine: Bool) -> [String: AgentSession] {
        let text = String(decoding: data, as: UTF8.self)
        var rows = text.split(separator: "\n", omittingEmptySubsequences: true)
        if dropsPartialFirstLine, !rows.isEmpty { rows.removeFirst() }

        var store: [String: AgentSession] = [:]
        for line in rows {
            guard let parsed = parse(line: line) else { continue }
            if let existing = store[parsed.sessionId], existing.lastSeenAt > parsed.at { continue }
            store[parsed.sessionId] = AgentSession(
                id: parsed.sessionId,
                agent: parsed.agent,
                project: parsed.project,
                cwd: parsed.cwd,
                lastEvent: parsed.event,
                lastSeenAt: parsed.at,
                isWorking: isWorking(event: parsed.event))
        }
        return store
    }

    static func basename(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
