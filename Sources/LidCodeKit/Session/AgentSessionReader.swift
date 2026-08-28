import Foundation
import SQLite3

/// One agent run, reconstructed from Warp's OSC 777 notification stream.
///
/// The session is a *derived* value, not a record: Warp emits one line per event and
/// never states "this session ended cleanly", so the only honest definition of "still
/// running" is the last event seen plus how long ago it arrived.
public struct AgentSession: Codable, Sendable, Equatable, Identifiable {
    /// The agent's own `session_id` (a UUID string), stable for the life of the run.
    public var id: String
    /// Which CLI produced the event — "claude" today, but the field is not enumerated
    /// because the emitter is a separate app that can add agents without asking us.
    public var agent: String
    /// Display name, e.g. "liddy-0.1.0".
    public var project: String
    public var cwd: String
    public var lastEvent: String
    public var lastSeenAt: Date
    public var isWorking: Bool

    public init(
        id: String,
        agent: String,
        project: String,
        cwd: String,
        lastEvent: String,
        lastSeenAt: Date,
        isWorking: Bool
    ) {
        self.id = id
        self.agent = agent
        self.project = project
        self.cwd = cwd
        self.lastEvent = lastEvent
        self.lastSeenAt = lastSeenAt
        self.isWorking = isWorking
    }
}

public struct SessionSnapshot: Codable, Sendable, Equatable {
    /// Working, non-stale sessions, most recently seen first.
    public var active: [AgentSession]
    /// The one to show in the subtitle. nil when nothing is running.
    public var primary: AgentSession?
    /// `active.count - 1`, floored at 0 — the "+2 more" count.
    public var otherCount: Int
    /// A terminal name from Warp's own database, filled in *only* when no agent is
    /// running. It says "this is the folder you last had open", not "this is working",
    /// so it is kept in its own field and the UI decides whether that is worth showing.
    public var fallbackName: String?

    public init(
        active: [AgentSession] = [],
        primary: AgentSession? = nil,
        otherCount: Int = 0,
        fallbackName: String? = nil
    ) {
        self.active = active
        self.primary = primary
        self.otherCount = otherCount
        self.fallbackName = fallbackName
    }

    public static let empty = SessionSnapshot()
}

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

/// Reads live agent activity out of Warp's log, and falls back to Warp's own database
/// for a folder name when no agent is running.
///
/// Strictly read-only in both directions. The log belongs to Warp and the database is
/// opened `mode=ro` so the WAL is never checkpointed out from under the running app.
public final class AgentSessionReader: @unchecked Sendable {
    /// A session whose last event is older than this is dropped, however it ended.
    ///
    /// Load-bearing: `stop` is not guaranteed. A crashed agent, a closed tab, or a
    /// `kill -9` leaves its last event as `tool_complete` forever, so without a cutoff
    /// the menu would still be announcing a run from three days ago.
    public static let staleAfterSecond: TimeInterval = 600

    /// How much of the tail to read. The log is ~8 MB and grows continuously; at the
    /// observed ~290 bytes per line this covers roughly 1,800 events, far more than
    /// the 10-minute staleness window can ever admit.
    public static let tailByteLimit: UInt64 = 512 * 1024

    /// The fallback name changes when the user switches folders, not by the second.
    public static let fallbackCacheSecond: TimeInterval = 30

    private static let lineMarker = "Received OSC 777 notification"
    private static let bodyMarker = "body="

    /// The leading log timestamp is a fixed-width UTC stamp, not a full ISO8601 grammar.
    ///
    /// Configured once and never mutated, which is the condition under which
    /// `DateFormatter` is documented thread-safe — and it is reused rather than built
    /// per line because a tail pass parses well over a thousand of them.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    /// The last event of a run that is still going. `permission_request` counts: the
    /// agent is blocked on the user, but the run is very much alive and the Mac must
    /// not be allowed to sleep through the prompt.
    public static let workingEvent: Set<String> = [
        "session_start", "prompt_submit", "tool_complete", "permission_request",
    ]

    /// `idle_prompt` sits here rather than with the working events: the agent has
    /// handed control back and is waiting on a human who may never return.
    public static let idleEvent: Set<String> = ["stop", "stop_failure", "idle_prompt"]

    /// Unknown events read as not working. A future event name the emitter adds should
    /// fail closed — claiming work that may not exist would hold the Mac awake forever.
    public static func isWorking(event: String) -> Bool { workingEvent.contains(event) }

    private let logURL: URL
    private let databaseURL: URL

    private let lock = NSLock()
    private var cachedSession: [String: AgentSession] = [:]
    private var cachedSize: UInt64?
    private var cachedModifiedAt: Date?
    private var cachedFallbackName: String?
    private var fallbackReadAt: Date?

    public init(logURL: URL? = nil, databaseURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logURL = logURL ?? home.appendingPathComponent("Library/Logs/warp.log")
        self.databaseURL = databaseURL ?? home.appendingPathComponent(
            "Library/Group Containers/2BBY89MBSN.dev.warp"
                + "/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite")
    }

    /// Cheap enough to call on the runtime's 5s tick: an unchanged log costs one
    /// `stat` and a dictionary filter.
    public func read(asOf now: Date = Date()) -> SessionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        refreshIfChanged()

        // Staleness is re-applied on every read, including cache hits — a quiet log is
        // exactly the case where sessions age out, so skipping it would freeze the menu
        // on the last thing that happened before the machine went idle.
        let active = cachedSession.values
            .filter { $0.isWorking && now.timeIntervalSince($0.lastSeenAt) <= Self.staleAfterSecond }
            .sorted { left, right in
                left.lastSeenAt == right.lastSeenAt
                    ? left.id < right.id
                    : left.lastSeenAt > right.lastSeenAt
            }

        var snapshot = SessionSnapshot(
            active: active,
            primary: active.first,
            otherCount: max(0, active.count - 1))
        if active.isEmpty { snapshot.fallbackName = fallbackName(asOf: now) }
        return snapshot
    }

    // MARK: - Log tail

    /// Re-parses only when the file has actually moved. `size` alone would miss a
    /// truncate-and-rewrite that lands on the same length, so mtime is checked too.
    private func refreshIfChanged() {
        guard let attribute = try? FileManager.default.attributesOfItem(atPath: logURL.path) else {
            // Missing or unreadable is a normal state (Warp not installed), not an error.
            cachedSession = [:]
            cachedSize = nil
            cachedModifiedAt = nil
            return
        }
        let size = (attribute[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attribute[.modificationDate] as? Date
        if cachedSize == size, cachedModifiedAt == modifiedAt { return }

        cachedSize = size
        cachedModifiedAt = modifiedAt
        let (data, isPartial) = tail(size: size)
        cachedSession = Self.sessions(fromTail: data, dropsPartialFirstLine: isPartial)
    }

    /// Returns the trailing window and whether its first line was cut mid-way.
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

    static func sessions(fromTail data: Data, dropsPartialFirstLine: Bool) -> [String: AgentSession] {
        // A byte-offset seek lands mid-UTF8 as often as not; replacement characters in
        // the first line are fine because that line is discarded anyway.
        let text = String(decoding: data, as: UTF8.self)
        var row = text.split(separator: "\n", omittingEmptySubsequences: true)
        if dropsPartialFirstLine, !row.isEmpty { row.removeFirst() }

        var store: [String: AgentSession] = [:]
        for line in row {
            guard let parsed = parse(line: line) else { continue }
            // Last event wins. The log is append-ordered so this is normally just the
            // later line, but an out-of-order stamp must not resurrect an older event.
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

    public static func parse(line: some StringProtocol) -> AgentLogLine? {
        guard line.contains(lineMarker) else { return nil }
        guard let space = line.firstIndex(of: " ") else { return nil }
        guard let at = timestampFormatter.date(from: String(line[line.startIndex..<space])) else {
            return nil
        }
        // The body is unquoted JSON running to end of line, so it cannot be split on
        // "," or "}" — take everything after the marker verbatim and let JSON decide.
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
            // The emitter has been seen omitting "project" on some events; the folder
            // name is the same thing it would have sent.
            project: project.isEmpty ? Self.basename(of: cwd) : project,
            cwd: cwd,
            event: event,
            toolName: field["tool_name"] as? String)
    }

    static func basename(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Warp database fallback

    private func fallbackName(asOf now: Date) -> String? {
        if let readAt = fallbackReadAt, now.timeIntervalSince(readAt) < Self.fallbackCacheSecond {
            return cachedFallbackName
        }
        fallbackReadAt = now
        cachedFallbackName = Self.warpTabName(databaseURL: databaseURL)
        return cachedFallbackName
    }

    /// `is_focused` is selected but only used as a tiebreak: in practice Warp leaves it
    /// set on nearly every row, so trusting it to identify "the" active tab picks the
    /// first tab in the window, which is almost never the one in use. The last row is
    /// the better guess and the ordering makes it deterministic.
    static let tabQuery = """
        SELECT t.id, t.custom_title, tp.cwd, pl.is_focused
        FROM tabs t
        LEFT JOIN pane_nodes pn ON pn.tab_id = t.id AND pn.is_leaf = 1
        LEFT JOIN pane_leaves pl ON pl.pane_node_id = pn.id
        LEFT JOIN terminal_panes tp ON tp.id = pl.pane_node_id
        ORDER BY t.id;
        """

    static func warpTabName(databaseURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        var handle: OpaquePointer?
        // SQLITE_OPEN_READONLY plus a mode=ro URI: belt and braces, because this file
        // is Warp's live database and a stray write or WAL checkpoint from us would
        // corrupt the state of an app we do not own.
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
              let statement = cursor
        else {
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

    private static func rowName(_ statement: OpaquePointer) -> String? {
        // Every observed row has an empty custom_title, but when a user does name a tab
        // that name beats the folder it happens to sit in.
        if let title = column(statement, 1), !title.isEmpty { return title }
        guard let cwd = column(statement, 2), !cwd.isEmpty else { return nil }
        let folder = basename(of: cwd)
        return folder.isEmpty ? nil : folder
    }

    private static func column(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        // Copied before the next step() invalidates the buffer.
        return String(cString: text)
    }

    /// SQLite reads `%` as the start of an escape inside a URI filename, and stops the
    /// path at `?` or `#`. Spaces it tolerates, which is just as well — the real path
    /// has two of them.
    static func uri(forPath path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "?", with: "%3f")
            .replacingOccurrences(of: "#", with: "%23")
        return "file:\(escaped)?mode=ro"
    }
}
