import Foundation

/// The coarse state behind the status line, for anything that needs to colour or
/// branch on it rather than print it.
///
/// The raw values travel in the push payload, so the phone can style a stalled
/// engine differently from an idle one without re-deriving the rules.
public enum RuntimeStatusKind: String, Codable, Sendable, CaseIterable {
    /// The engine stopped ticking. Nothing below this is trustworthy.
    case stalled
    /// A guard is refusing to re-arm — heat, battery, a lost helper.
    case blocked
    /// A hold is live, whether by timer, lease, or a closed lid.
    case holding
    /// Auto-watch is on and armed, but no work has shown up yet.
    case waiting
    /// The user turned it off by hand, and auto-watch will not undo that.
    case paused
    /// Off, and nothing is watching.
    case idle
}

/// The one-line answer to "what is LidCode doing right now?", plus the longer
/// sentence behind it.
public struct RuntimeStatus: Codable, Sendable, Equatable {
    public var kind: RuntimeStatusKind
    /// Short headline — "Keeping awake · 3 active sessions".
    public var title: String
    /// The reason underneath — "Held by claude, codex".
    public var detail: String

    public init(kind: RuntimeStatusKind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

extension RuntimeSnapshot {
    /// The status line, derived once and used everywhere.
    ///
    /// The menu bar and the phone dashboard both read this. They used to derive it
    /// separately — the menu had six states and the dashboard had two — so a Mac
    /// that was paused, blocked, or not responding looked simply "asleep" from the
    /// phone, which is the one place you cannot check the real answer.
    public var displayStatus: RuntimeStatus {
        RuntimeStatus(kind: displayStatusKind, title: displayStatusTitle, detail: displayStatusDetail)
    }

    /// Precedence matters: a stalled engine outranks a guard, and a guard outranks
    /// a live hold. Reporting "Keeping awake" while the engine is dead is the one
    /// failure that would let a run die unnoticed.
    private var displayStatusKind: RuntimeStatusKind {
        if isStalled { return .stalled }
        if blockedBy != nil { return .blocked }
        if isAwakeHeld || isClamshellActive { return .holding }
        if isAutoWatchOn && !isUserPaused { return .waiting }
        return isUserPaused ? .paused : .idle
    }

    private var displayStatusTitle: String {
        switch displayStatusKind {
        case .stalled:
            return "Not responding"
        case .blocked:
            return "Holding back"
        case .holding:
            let n = agentSession.activeCount
            if n > 0 { return "Keeping awake · \(n) active session\(n == 1 ? "" : "s")" }
            return "Keeping awake"
        case .waiting:
            return "Waiting for a session"
        case .paused:
            return "Paused by you"
        case .idle:
            return "Idle"
        }
    }

    private var displayStatusDetail: String {
        if isStalled { return "The engine stopped ticking. Quit and reopen LidCode" }
        if let blocked = blockedBy {
            return "\(blocked.summary). Won't re-arm until it recovers"
        }
        if isUserPaused && !isAwakeHeld {
            return activeLease.isEmpty
                ? "Auto-watch won't turn this back on"
                : "\(activeLease.count) running. Auto-watch won't turn this back on"
        }
        if let reason = lastStopReason, !isAwakeHeld {
            return "Last stop: \(reason.summary)"
        }
        if activeLease.isEmpty {
            return mode == .manual ? "Manual hold" : "Releases when work stops"
        }
        return "Held by \(activeLease.prefix(3).joined(separator: ", "))"
    }
}
