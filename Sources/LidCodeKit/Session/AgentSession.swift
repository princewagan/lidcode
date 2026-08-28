import Foundation

// MARK: - AgentStatus
//
// The four states a Claude/Codex session can be in.
// Only .running satisfies the keep-awake predicate.
// .blocked and .error are sticky (never timed out, never pruned).

public enum AgentStatus: String, Codable, Sendable {
    /// Actively executing. Only this status satisfies the keep-awake predicate.
    case running
    /// Waiting on user (permission_request). Does NOT keep the Mac awake.
    case blocked
    /// stop_failure occurred. Does NOT keep the Mac awake.
    case error
    /// stop / idle_prompt / timed out. Does NOT keep the Mac awake.
    case finished
}

// MARK: - AgentSessionInfo

/// One agent run, fully characterised with status and title.
///
/// This replaces the old `AgentSession` type with a richer model that includes
/// proper status classification (running/blocked/error/finished) and a resolved
/// display title from the Claude Code transcript or Warp's own database.
public struct AgentSessionInfo: Codable, Sendable, Equatable, Identifiable {
    /// Session UUID — also the transcript filename (`<session-id>.jsonl`).
    public var id: String
    /// "claude", "codex", or whatever OSC 777 emits. Not filtered.
    public var agent: String
    /// Absolute path to the session's working directory.
    public var cwd: String
    /// Project display name (basename of cwd, or `project` field from OSC 777).
    public var project: String
    /// Resolved human-readable title.
    /// Priority: ai-title from JSONL > pane_leaves.custom_vertical_tabs_title > cwd basename.
    public var title: String
    /// Which resolution rule produced `title`.
    /// One of: "ai-title" | "warp-pane-title" | "cwd-basename"
    public var titleSource: String
    /// Derived status from the state machine + transcript corroboration.
    public var status: AgentStatus
    /// Raw event string of the most recent OSC 777 event for this session.
    public var lastEvent: String
    /// Timestamp of the most recent OSC 777 event.
    public var lastSeenAt: Date
    /// Timestamp when `status` last CHANGED (not last-seen).
    /// Used for "10m ago" relative display.
    public var statusChangedAt: Date

    public init(
        id: String,
        agent: String,
        cwd: String,
        project: String,
        title: String,
        titleSource: String,
        status: AgentStatus,
        lastEvent: String,
        lastSeenAt: Date,
        statusChangedAt: Date
    ) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.project = project
        self.title = title
        self.titleSource = titleSource
        self.status = status
        self.lastEvent = lastEvent
        self.lastSeenAt = lastSeenAt
        self.statusChangedAt = statusChangedAt
    }
}

// MARK: - AgentSessionSnapshot

/// The complete session truth snapshot delivered to the runtime on every tick.
public struct AgentSessionSnapshot: Codable, Sendable, Equatable {
    /// ALL non-pruned sessions, all statuses (running, blocked, error, finished).
    public var sessions: [AgentSessionInfo]
    /// Sessions where status == .running. The single number the hold predicate reads.
    public var activeCount: Int { sessions.filter { $0.status == AgentStatus.running }.count }
    /// cwd basename when nothing is running. Used by the UI subtitle fallback.
    public var fallbackName: String?

    public init(sessions: [AgentSessionInfo] = [], fallbackName: String? = nil) {
        self.sessions = sessions
        self.fallbackName = fallbackName
    }

    /// Empty snapshot — "nothing is running".
    public static let empty = AgentSessionSnapshot()

    // MARK: - Codable (manual to handle computed activeCount)

    private enum CodingKeys: String, CodingKey {
        case sessions, fallbackName, activeCount
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessions, forKey: .sessions)
        try c.encodeIfPresent(fallbackName, forKey: .fallbackName)
        // Encode computed value so CLI/decode consumers can read it without recomputing.
        try c.encode(activeCount, forKey: .activeCount)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([AgentSessionInfo].self, forKey: .sessions) ?? []
        fallbackName = try c.decodeIfPresent(String.self, forKey: .fallbackName)
        // activeCount is computed; ignore the encoded value.
    }

    // Equatable: activeCount is derived from sessions so it is not compared separately.
    public static func == (lhs: AgentSessionSnapshot, rhs: AgentSessionSnapshot) -> Bool {
        lhs.sessions == rhs.sessions && lhs.fallbackName == rhs.fallbackName
    }
}

// MARK: - Deprecated compatibility shim
//
// The old SessionSnapshot and AgentSession types are kept here so that existing
// call sites in LidCodeRuntime.swift and the CLI still compile while the
// integration agent (W1) performs the migration in a separate commit.
// Remove these declarations once W1 has replaced all usages.

@available(*, deprecated, renamed: "AgentSessionInfo")
public struct AgentSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var agent: String
    public var project: String
    public var cwd: String
    public var lastEvent: String
    public var lastSeenAt: Date
    public var isWorking: Bool

    public init(
        id: String, agent: String, project: String, cwd: String,
        lastEvent: String, lastSeenAt: Date, isWorking: Bool
    ) {
        self.id = id; self.agent = agent; self.project = project; self.cwd = cwd
        self.lastEvent = lastEvent; self.lastSeenAt = lastSeenAt; self.isWorking = isWorking
    }
}

@available(*, deprecated, renamed: "AgentSessionSnapshot")
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public var active: [AgentSession]
    public var primary: AgentSession?
    public var otherCount: Int
    public var fallbackName: String?

    public init(
        active: [AgentSession] = [], primary: AgentSession? = nil,
        otherCount: Int = 0, fallbackName: String? = nil
    ) {
        self.active = active; self.primary = primary
        self.otherCount = otherCount; self.fallbackName = fallbackName
    }

    public static let empty = SessionSnapshot()
}
