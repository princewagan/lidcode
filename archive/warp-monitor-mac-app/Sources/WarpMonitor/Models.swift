import Foundation

// MARK: - Claude Status State Machine

public enum ClaudeStatus: String, Codable, Sendable {
    case running
    case finished
    /// Claude is waiting on user approval for a tool action (permission_request).
    /// Supersedes the generic "warning" value emitted by old binary versions.
    case blocked
    /// A stop_failure occurred — something went wrong.
    /// Supersedes the generic "warning" value emitted by old binary versions.
    case error
    /// Legacy value emitted by old Mac binary versions. New binary never emits this.
    /// Kept in the enum so blobs from old binaries are still Codable without crashing.
    case warning
    case idle
}

public enum ClaudeEvent: String, Codable, Sendable {
    case sessionStart    = "session_start"
    case promptSubmit    = "prompt_submit"
    case toolComplete    = "tool_complete"
    case idlePrompt      = "idle_prompt"
    case stop            = "stop"
    case stopFailure     = "stop_failure"
    case permissionRequest = "permission_request"
}

// MARK: - Claude Session

public struct ClaudeSession: Codable, Sendable {
    public let session_id: String
    public let project: String
    public let last_event: String
    public let last_event_at: String
    public var tool_name: String?
    public var error_type: String?
    /// Agent name from the OSC 777 event body (e.g. "claude").
    /// nil for sessions produced by old binary versions that did not capture this field.
    /// Swift's JSONEncoder omits nil optionals, matching the Zod .optional() schema.
    public var agent: String?
    /// Human-readable description of what Claude is asking permission for.
    /// Populated from the "summary" field of a permission_request event.
    /// Truncated to 200 chars to keep the blob small.
    public var blocked_reason: String?
    /// The user's original query text at the time of a stop_failure event.
    /// Populated from the "query" field of a stop_failure event.
    /// Truncated to 200 chars.
    public var last_query: String?

    public init(
        session_id: String,
        project: String,
        last_event: String,
        last_event_at: String,
        tool_name: String? = nil,
        error_type: String? = nil,
        agent: String? = nil,
        blocked_reason: String? = nil,
        last_query: String? = nil
    ) {
        self.session_id = session_id
        self.project = project
        self.last_event = last_event
        self.last_event_at = last_event_at
        self.tool_name = tool_name
        self.error_type = error_type
        self.agent = agent
        self.blocked_reason = blocked_reason
        self.last_query = last_query
    }
}

// MARK: - Warp Tab

public struct WarpTab: Codable, Sendable {
    public let id: String
    public let title: String
    public let custom_title: String?
    public let cwd: String
    public let pinned: Bool
    public var claude_status: ClaudeStatus
    public var claude_sessions: [ClaudeSession]
    public var ambiguous_cwd: Bool
    /// True when this tab's pane is the currently focused terminal pane.
    /// The DB column (pane_leaves.is_focused) defaults to TRUE for all rows in
    /// the current Warp schema, so we cannot reliably identify a single focused
    /// tab. This field is emitted as explicit false until Warp changes its schema.
    /// It is optional on the Zod side so old pushes still validate.
    public var is_focused: Bool
    /// Current git branch for this tab's working directory.
    /// Parsed from <cwd>/.git/HEAD ("ref: refs/heads/<name>").
    /// nil when: cwd is empty, .git not found, or HEAD is detached.
    /// Swift's JSONEncoder emits nil as JSON null when using a custom encoder.
    public var git_branch: String?
    /// TTY name of the Claude process inferred to be running in this tab.
    /// e.g. "ttys005". nil when no Claude process could be paired with this tab.
    /// Pairing is heuristic: tabs and processes are sorted (tab id asc, tty asc)
    /// and matched 1:1 within the same cwd. This is not a guarantee.
    /// Optional — old Mac binary pushes omit this field and still validate.
    public var tty: String?
    /// PID of the Claude process inferred to be running in this tab.
    /// nil when no Claude process could be paired with this tab.
    /// Optional — old Mac binary pushes omit this field and still validate.
    public var claude_pid: Int?
    /// AI-generated session title from the Claude Code transcript.
    /// Extracted from the last `{"type":"ai-title","aiTitle":"..."}` line in the
    /// ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl file.
    /// nil when no transcript is found or no ai-title has been written yet.
    /// Optional — old Mac binary pushes omit this field and still validate.
    public var ai_title: String?
    /// Which title derivation rule produced the displayed title.
    /// One of: "warp-pane-title", "warp-custom-title", "cwd-basename", "tab-id",
    ///         "ai-title-exact", "ai-title-fallback", "no-ai-title", "no-transcript".
    /// Optional — omitted when nil; useful for debugging and reports.
    public var title_source: String?

    /// Title came from Warp's own `pane_leaves.custom_vertical_tabs_title`.
    ///
    /// Warp writes the agent's title into that column (e.g. "✳ Create test admin
    /// and staff accounts"), so it is literally the label the user sees on the
    /// tab. It therefore outranks any transcript-derived guess: when a tab has
    /// this source, StateManager leaves `ai_title` nil so the UI shows Warp's
    /// own wording rather than a second, possibly mismatched, title.
    public static let warpPaneTitleSource = "warp-pane-title"

    public init(
        id: String,
        title: String,
        custom_title: String?,
        cwd: String,
        pinned: Bool,
        claude_status: ClaudeStatus = .idle,
        claude_sessions: [ClaudeSession] = [],
        ambiguous_cwd: Bool = false,
        is_focused: Bool = false,
        git_branch: String? = nil,
        tty: String? = nil,
        claude_pid: Int? = nil,
        ai_title: String? = nil,
        title_source: String? = nil
    ) {
        self.id = id
        self.title = title
        self.custom_title = custom_title
        self.cwd = cwd
        self.pinned = pinned
        self.claude_status = claude_status
        self.claude_sessions = claude_sessions
        self.ambiguous_cwd = ambiguous_cwd
        self.is_focused = is_focused
        self.git_branch = git_branch
        self.tty = tty
        self.claude_pid = claude_pid
        self.ai_title = ai_title
        self.title_source = title_source
    }

    // Custom encoder: always emit custom_title and git_branch as explicit null when absent,
    // and always emit is_focused as explicit false rather than omitting the key.
    // tty, claude_pid, ai_title, and title_source are omitted when nil (optional on the Zod side).
    // This ensures the JSON wire format is maximally predictable for the phone reader.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(custom_title, forKey: .custom_title)   // encodes null when nil
        try c.encode(cwd, forKey: .cwd)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(claude_status, forKey: .claude_status)
        try c.encode(claude_sessions, forKey: .claude_sessions)
        try c.encode(ambiguous_cwd, forKey: .ambiguous_cwd)
        try c.encode(is_focused, forKey: .is_focused)       // always explicit false
        try c.encode(git_branch, forKey: .git_branch)       // encodes null when nil
        try c.encodeIfPresent(tty, forKey: .tty)            // omitted when nil
        try c.encodeIfPresent(claude_pid, forKey: .claude_pid) // omitted when nil
        try c.encodeIfPresent(ai_title, forKey: .ai_title)  // omitted when nil
        try c.encodeIfPresent(title_source, forKey: .title_source) // omitted when nil
    }
}

// MARK: - Warp Tab Group

public struct WarpTabGroup: Codable, Sendable {
    public let id: String
    public let name: String
    public let color: String?
    public let collapsed: Bool
    public var tabs: [WarpTab]

    public init(id: String, name: String, color: String?, collapsed: Bool, tabs: [WarpTab] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.tabs = tabs
    }

    // Custom encoder: always emit color as explicit null when absent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)               // encodes null when nil
        try c.encode(collapsed, forKey: .collapsed)
        try c.encode(tabs, forKey: .tabs)
    }
}

// MARK: - Warp Notification

public struct WarpNotification: Codable, Sendable {
    public let id: String
    public let received_at: String
    public let title: String
    public let body_raw: String
    public let parsed_event: String?

    public init(id: String, received_at: String, title: String, body_raw: String, parsed_event: String?) {
        self.id = id
        self.received_at = received_at
        self.title = title
        self.body_raw = body_raw
        self.parsed_event = parsed_event
    }

    // Custom encoder: always emit parsed_event as explicit null when absent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(received_at, forKey: .received_at)
        try c.encode(title, forKey: .title)
        try c.encode(body_raw, forKey: .body_raw)
        try c.encode(parsed_event, forKey: .parsed_event) // encodes null when nil
    }
}

// MARK: - Top-Level State

public struct WarpMonitorState: Codable, Sendable {
    public let schema_version: Int
    public let pushed_at: String
    public let mac_hostname: String
    public let warp_running: Bool
    public var tab_groups: [WarpTabGroup]
    public var ungrouped_tabs: [WarpTab]
    public var notifications: [WarpNotification]
    public var orphan_sessions: [ClaudeSession]
    /// Set when the SQLite reader fails due to schema mismatch or DB access error.
    /// Causes the phone to show "Mac reader error" instead of an empty tab list.
    public var mac_reader_error: String?

    public init(
        pushed_at: String,
        mac_hostname: String,
        warp_running: Bool,
        tab_groups: [WarpTabGroup] = [],
        ungrouped_tabs: [WarpTab] = [],
        notifications: [WarpNotification] = [],
        orphan_sessions: [ClaudeSession] = [],
        mac_reader_error: String? = nil
    ) {
        self.schema_version = 1
        self.pushed_at = pushed_at
        self.mac_hostname = mac_hostname
        self.warp_running = warp_running
        self.tab_groups = tab_groups
        self.ungrouped_tabs = ungrouped_tabs
        self.notifications = notifications
        self.orphan_sessions = orphan_sessions
        self.mac_reader_error = mac_reader_error
    }
}

// MARK: - Internal session tracking (not in JSON output)

public struct ClaudeSessionState: Sendable {
    public var status: ClaudeStatus
    public var cwd: String
    public var project: String
    public var lastEvent: String
    public var lastEventAt: Date
    public var toolName: String?
    public var errorType: String?
    public var sessionId: String
    /// Agent name from the OSC 777 event (e.g. "claude").
    public var agent: String?
    /// Human-readable permission summary from permission_request event's "summary" field.
    /// Truncated to 200 chars to keep the wire blob small.
    public var blockedReason: String?
    /// The user's original request text from a stop_failure event's "query" field.
    /// Truncated to 200 chars.
    public var lastQuery: String?
    /// True when the session was downgraded to finished by the 10-minute timeout rule.
    /// This is an internal flag only — on the wire, last_event is always a valid ClaudeEvent
    /// raw value (we use "stop" as the closest semantic equivalent to a timeout finish).
    public var timedOut: Bool = false

    public init(sessionId: String, cwd: String, project: String) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.project = project
        self.status = .running
        self.lastEvent = ClaudeEvent.sessionStart.rawValue
        self.lastEventAt = Date()
    }

    /// Apply a new event to the state machine.
    ///
    /// Signature includes all rich-context fields from the OSC 777 event:
    ///   - agent: the agent name (always "claude" in practice)
    ///   - summary: from permission_request events, describing what Claude asks for
    ///   - query: from stop_failure events, containing the user's original request
    ///
    /// Returns true if the status changed.
    @discardableResult
    public mutating func apply(
        event: ClaudeEvent,
        at date: Date,
        toolName: String? = nil,
        errorType: String? = nil,
        agent: String? = nil,
        summary: String? = nil,
        query: String? = nil
    ) -> Bool {
        let previous = status
        self.lastEvent = event.rawValue
        self.lastEventAt = date
        self.toolName = toolName
        self.errorType = errorType

        // Capture agent name if provided
        if let a = agent { self.agent = a }

        // Capture rich context from specific event types
        switch event {
        case .permissionRequest:
            // summary describes what Claude is asking the user to approve
            if let s = summary {
                self.blockedReason = String(s.prefix(200))
            }
        case .stopFailure:
            // query is the user's original request that triggered the failure
            if let q = query {
                self.lastQuery = String(q.prefix(200))
            }
        default:
            break
        }

        // Status is a pure function of the MOST RECENT event.
        //
        // This deliberately replaces the previous state-dependent transition
        // table, which had two defects that made statuses wrong in practice:
        //
        //  1. From .blocked/.error, only sessionStart/promptSubmit could clear the
        //     state. So the ordinary lifecycle — permission_request (blocked), user
        //     approves, tool_complete, stop — left the session pinned to "blocked"
        //     forever, even though its last event was a clean stop. Observed live:
        //     session 7a7c4063 "Update push skill for commit and push" had
        //     last_event=stop yet reported blocked.
        //  2. From .finished, a later permission_request or stop_failure was
        //     ignored, so a session that finished and was then re-run into an error
        //     kept reporting done.
        //
        // Deriving status from the last event alone fixes both and still gives the
        // sticky behaviour we want: a state persists precisely until a newer event
        // supersedes it, rather than decaying on a timer or latching permanently.
        //
        // LogTailer seeks to the end of warp.log on startup, so sessions are always
        // joined mid-stream; having no prior state to depend on is exactly why a
        // last-event mapping is the right model here.
        switch event {
        case .sessionStart, .promptSubmit, .toolComplete:
            status = .running
        case .idlePrompt, .stop:
            status = .finished
        case .permissionRequest:
            status = .blocked
        case .stopFailure:
            status = .error
        }

        // A newer event supersedes stale context from an older one, otherwise a
        // resolved permission prompt would keep advertising what it was waiting on.
        if event != .permissionRequest { self.blockedReason = nil }
        if event != .stopFailure { self.lastQuery = nil }

        return status != previous
    }

    /// Check for 10-minute running timeout. Returns true if state changed.
    /// Sets timedOut = true and uses "stop" as the wire-safe last_event value
    /// so it remains a valid ClaudeEvent on the JSON wire format.
    @discardableResult
    public mutating func checkTimeout() -> Bool {
        guard status == .running else { return false }
        let elapsed = Date().timeIntervalSince(lastEventAt)
        if elapsed > 600 { // 10 minutes
            status = .finished
            timedOut = true
            // Use "stop" on the wire (closest semantic match to a clean finish).
            // "timed_out" is intentionally NOT used — it is not in the Zod enum.
            lastEvent = ClaudeEvent.stop.rawValue
            return true
        }
        return false
    }

    public var isStale: Bool {
        // Prune finished (including timed-out) sessions older than 30 minutes.
        // Blocked, error, and warning sessions are NOT pruned — they require user action.
        // Running sessions are never pruned.
        (status == .finished) && Date().timeIntervalSince(lastEventAt) > 1800
    }

    /// True when the last observed log event was tool_complete or prompt_submit
    /// and no subsequent stop/idle_prompt has been seen.  In this state the session
    /// is between tool calls: Claude is actively working but the transcript may be
    /// briefly quiet while waiting on a network response, a subagent, or disk I/O.
    /// The 10-minute timeout is the safety net if inFlight lingers too long.
    public var isInFlight: Bool {
        guard status == .running else { return false }
        guard let event = ClaudeEvent(rawValue: lastEvent) else { return false }
        return event == .toolComplete || event == .promptSubmit
    }
}

// MARK: - Helpers

public func isoNow() -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.string(from: Date())
}

public func isoDate(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.string(from: date)
}
