import Foundation

/// How a hold behaves once the work it was protecting goes quiet.
public enum HoldMode: String, Codable, Sendable, CaseIterable {
    /// Release the Mac once no lease has been active for `idleReleaseSecond`.
    case smart
    /// Hold for the full requested window regardless of what is running.
    case manual
}

/// Why a hold ended. Every session records exactly one of these — the whole point
/// is that a run which stopped overnight is never a mystery in the morning.
public enum StopReason: String, Codable, Sendable {
    case workFinished
    case timerExpired
    case batteryFloor
    case thermalCritical
    case userStopped
    case appQuit
    /// The helper's deadman switch fired: the app stopped heartbeating.
    case heartbeatLost

    public var summary: String {
        switch self {
        case .workFinished:     return "All watched work finished"
        case .timerExpired:     return "Session timer expired"
        case .batteryFloor:     return "Battery crossed the floor"
        case .thermalCritical:  return "Thermal state critical"
        case .userStopped:      return "Stopped by you"
        case .appQuit:          return "LidCode quit"
        case .heartbeatLost:    return "Heartbeat lost, reverted by helper"
        }
    }
}

/// Everything the menu bar, the CLI and the log need to answer "why is my Mac awake?".
public struct RuntimeSnapshot: Codable, Sendable {
    public var isAwakeHeld: Bool
    public var isAssertionActive: Bool
    public var isClamshellActive: Bool
    public var mode: HoldMode
    public var startedAt: Date?
    public var expiresAt: Date?
    /// Labels of every lease currently keeping the Mac awake. Singular by convention.
    public var activeLease: [String]
    public var battery: BatteryReading
    public var thermal: ThermalReading
    public var lastStopReason: StopReason?
    /// The last completed health sweep. nil until the first one lands, which is why
    /// the panel draws a "checking" state rather than a wall of green on open.
    public var health: HealthReport?
    /// Non-nil while the governor is refusing to let anything re-acquire a hold. The
    /// difference between "nothing wants the Mac awake" and "something does, and it is
    /// not being allowed" is the single most confusing state this tool has, so it is
    /// carried explicitly rather than inferred.
    public var blockedBy: StopReason?
    public var isAutoWatchOn: Bool
    /// The user turned the hold off by hand and nothing automatic may turn it back on.
    public var isUserPaused: Bool
    /// Live agent session truth, read from Warp's OSC 777 log every tick.
    ///
    /// Never nil — an empty `AgentSessionSnapshot` is a complete answer ("nothing is
    /// running"), and making the UI unwrap an optional invites the empty and idle
    /// states being drawn the same way.
    public var agentSession: AgentSessionSnapshot
    /// Claude's rate-limit windows, when the usage file exists. nil is genuinely
    /// "unavailable", not "zero".
    public var usage: ClaudeUsage?
    /// The physical lid state — whether the laptop lid is open, closed, or unknown.
    /// Populated by `ClamshellStateReader.shared.read()` on every tick.
    public var physicalLid: ClamshellReading
    /// Number of sleep-blocking IOPMAssertion entries that are NOT owned by LidCode.
    /// Parsed from `pmset -g assertions` every 6 ticks. Useful for the UI to explain
    /// "other apps are also blocking sleep" (e.g. Claude Code spawns caffeinate per session).
    public var foreignBlockerCount: Int
    /// How long the machine has been continuously at or above `thermalCeiling`. nil
    /// when it is below the ceiling.
    ///
    /// Published rather than kept private because the thermal stop is now a *sustained*
    /// rule, and a stop that will fire in eleven minutes is only comprehensible if the
    /// panel can show the clock that is running.
    public var hotSinceSecond: Int?
    /// The runtime's watchdog: no tick has completed for over a minute.
    ///
    /// This is the freeze made visible. Every path that could wedge the runtime queue
    /// is bounded now, but "bounded" is a claim about code that exists today, and the
    /// failure it protects against is silent by nature — the app keeps drawing its last
    /// snapshot and simply stops updating. A flag that says so is the difference
    /// between a bug report and a mystery.
    public var isStalled: Bool

    /// The user explicitly overrode the thermal/battery guard (F1-F4 button cycle).
    /// When true, the hold continues despite a guard warning. Warnings still show.
    public var isGuardOverrideOn: Bool

    /// True when the user has enabled closed-lid protection but `disablesleep` may not
    /// be 1 yet — either because the hold has not started or the helper is temporarily
    /// disconnected. Distinct from `isClamshellActive`, which means pmset has agreed.
    public var isClamshellArmed: Bool

    /// The most recent memory reading. nil until the first successful `MemoryReader.read()`
    /// on the runtime tick, or when both shell commands time out.
    public var memory: MemoryReading?

    public init(
        isAwakeHeld: Bool = false,
        isAssertionActive: Bool = false,
        isClamshellActive: Bool = false,
        mode: HoldMode = .smart,
        startedAt: Date? = nil,
        expiresAt: Date? = nil,
        activeLease: [String] = [],
        battery: BatteryReading = .unknown,
        thermal: ThermalReading = .init(level: .nominal),
        lastStopReason: StopReason? = nil,
        health: HealthReport? = nil,
        blockedBy: StopReason? = nil,
        isAutoWatchOn: Bool = true,
        isUserPaused: Bool = false,
        agentSession: AgentSessionSnapshot = .empty,
        usage: ClaudeUsage? = nil,
        hotSinceSecond: Int? = nil,
        isStalled: Bool = false,
        physicalLid: ClamshellReading = ClamshellReading(state: .unknown, readAt: Date(), isStale: true),
        foreignBlockerCount: Int = 0,
        isGuardOverrideOn: Bool = false,
        isClamshellArmed: Bool = false,
        memory: MemoryReading? = nil
    ) {
        self.isAwakeHeld = isAwakeHeld
        self.isAssertionActive = isAssertionActive
        self.isClamshellActive = isClamshellActive
        self.mode = mode
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.activeLease = activeLease
        self.battery = battery
        self.thermal = thermal
        self.lastStopReason = lastStopReason
        self.health = health
        self.blockedBy = blockedBy
        self.isAutoWatchOn = isAutoWatchOn
        self.isUserPaused = isUserPaused
        self.agentSession = agentSession
        self.usage = usage
        self.hotSinceSecond = hotSinceSecond
        self.isStalled = isStalled
        self.physicalLid = physicalLid
        self.foreignBlockerCount = foreignBlockerCount
        self.isGuardOverrideOn = isGuardOverrideOn
        self.isClamshellArmed = isClamshellArmed
        self.memory = memory
    }

    /// Decoded key by key with a fallback, for the same reason `Setting` is.
    ///
    /// This one crosses a version boundary rather than a disk one: `lidcode` lives in
    /// `/usr/local/bin` and the app lives in `/Applications`, so the two are updated
    /// separately and routinely disagree by a release. Synthesized decoding fails the
    /// whole object on one missing key, which would turn `lidcode status` into "LidCode
    /// is not running" against a perfectly healthy app.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAwakeHeld = try container.decodeIfPresent(Bool.self, forKey: .isAwakeHeld) ?? false
        isAssertionActive = try container.decodeIfPresent(Bool.self, forKey: .isAssertionActive) ?? false
        isClamshellActive = try container.decodeIfPresent(Bool.self, forKey: .isClamshellActive) ?? false
        mode = try container.decodeIfPresent(HoldMode.self, forKey: .mode) ?? .smart
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        activeLease = try container.decodeIfPresent([String].self, forKey: .activeLease) ?? []
        battery = try container.decodeIfPresent(BatteryReading.self, forKey: .battery) ?? .unknown
        thermal = try container.decodeIfPresent(ThermalReading.self, forKey: .thermal)
            ?? ThermalReading(level: .nominal)
        lastStopReason = try container.decodeIfPresent(StopReason.self, forKey: .lastStopReason)
        health = try container.decodeIfPresent(HealthReport.self, forKey: .health)
        blockedBy = try container.decodeIfPresent(StopReason.self, forKey: .blockedBy)
        isAutoWatchOn = try container.decodeIfPresent(Bool.self, forKey: .isAutoWatchOn) ?? true
        isUserPaused = try container.decodeIfPresent(Bool.self, forKey: .isUserPaused) ?? false
        agentSession = try container.decodeIfPresent(AgentSessionSnapshot.self, forKey: .agentSession) ?? .empty
        usage = try container.decodeIfPresent(ClaudeUsage.self, forKey: .usage)
        hotSinceSecond = try container.decodeIfPresent(Int.self, forKey: .hotSinceSecond)
        isStalled = try container.decodeIfPresent(Bool.self, forKey: .isStalled) ?? false
        physicalLid = try container.decodeIfPresent(ClamshellReading.self, forKey: .physicalLid)
            ?? ClamshellReading(state: .unknown, readAt: Date(), isStale: true)
        foreignBlockerCount = try container.decodeIfPresent(Int.self, forKey: .foreignBlockerCount) ?? 0
        isGuardOverrideOn = try container.decodeIfPresent(Bool.self, forKey: .isGuardOverrideOn) ?? false
        isClamshellArmed = try container.decodeIfPresent(Bool.self, forKey: .isClamshellArmed) ?? false
        memory = try container.decodeIfPresent(MemoryReading.self, forKey: .memory)
    }

    public var runtimeSecond: Int {
        guard let startedAt else { return 0 }
        return Int(Date().timeIntervalSince(startedAt))
    }

    /// How far through a timed session we are, 0...1. nil when nothing is timed —
    /// a smart-mode hold has no end to fill a bar toward.
    public var timerFraction: Double? {
        guard let startedAt, let expiresAt else { return nil }
        let total = expiresAt.timeIntervalSince(startedAt)
        guard total > 0 else { return nil }
        return min(1, max(0, Date().timeIntervalSince(startedAt) / total))
    }

    /// Rounded, not truncated. `Int()` throws away the fractional second, so a timer
    /// set to 8h reports 28799 the instant it starts and the menu reads "7h 59m left"
    /// — which looks like the button lost a minute somewhere.
    public var remainingSecond: Int? {
        guard let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSinceNow.rounded()))
    }

    /// How a countdown is written in the menu, split by where it is written.
    ///
    /// Lives here rather than in the view because it is pure string work with real
    /// edge cases — zero-padding, the last minute, the hour boundary — and a view is
    /// not a testable place to keep any of them.
    public struct RemainingDisplay: Equatable, Sendable {
        /// Goes inside the ring. **At most two digits**, so a fixed-width circle never
        /// has to scale its own type to fit — see `RingGauge`.
        public var value: String
        /// One character, beside the value.
        public var unit: String
        /// Goes under the ring, where there is room for the precision the ring drops.
        public var caption: String
    }

    public var remainingDisplay: RemainingDisplay? {
        guard timerFraction != nil, let second = remainingSecond else { return nil }
        let hour = second / 3600
        let minute = (second % 3600) / 60

        if hour > 0 {
            return RemainingDisplay(
                value: "\(hour)",
                unit: "h",
                // Zero-padded: an unpadded format wrote 8h00m as "8h0" and 7h05m as "7h5".
                caption: "\(hour)h \(String(format: "%02d", minute))m left")
        }
        if second == 0 {
            return RemainingDisplay(value: "0", unit: "m", caption: "releasing")
        }
        // Rounded up, so the final seconds read "1m" and not a "0m" that is still
        // holding — and the caption agrees with the ring rather than contradicting it.
        let roundedMinute = Int((Double(second) / 60).rounded(.up))
        return RemainingDisplay(
            value: "\(roundedMinute)",
            unit: "m",
            caption: second < 60 ? "under a minute left" : "\(minute)m left")
    }
}
