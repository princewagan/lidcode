import Foundation

/// One rate-limit window as Claude reports it.
public struct UsageWindow: Codable, Sendable, Equatable {
    /// A percentage, 0...100 — not a fraction. Kept in the units the source uses so a
    /// value read here can be compared against what Anthropic's own UI shows.
    public var utilization: Double
    public var resetsAt: Date?
    /// The same number as `utilization`, clamped to 0...1 for a ring gauge.
    public var fraction: Double
    /// e.g. "2h 30m". nil when the reset time is unknown or already past.
    public var resetDisplay: String?

    public init(utilization: Double, resetsAt: Date?, asOf now: Date = Date()) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.fraction = min(1, max(0, utilization / 100))
        self.resetDisplay = Self.display(until: resetsAt, asOf: now)
    }

    /// nil rather than "0m" once the window has rolled: the file is only refreshed
    /// every five minutes, so a just-past reset time means "we do not know yet", and
    /// counting down into negative numbers would be a worse lie than saying nothing.
    static func display(until resetsAt: Date?, asOf now: Date) -> String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let minute = Int(remaining) / 60
        let hour = minute / 60
        if hour > 0 { return "\(hour)h \(String(format: "%02d", minute % 60))m" }
        if minute > 0 { return "\(minute)m" }
        return "under a minute"
    }
}

/// Usage data for a single Claude account.
///
/// The fetcher runs per-account and the reader preserves producer order — ADVO
/// first, then PRINCE — so the UI can render them in a stable, predictable sequence
/// without sorting by key or label.
public struct ClaudeAccountUsage: Codable, Sendable, Equatable {
    /// Short machine-readable key, e.g. "advo" or "prince".
    public var key: String
    /// Display name, e.g. "ADVO" or "PRINCE".
    public var label: String
    /// "ok" | "signed_out" | "expired" | "error" — passed through so a new status
    /// from the producer degrades to an unfamiliar string rather than crashing.
    public var status: String
    /// Only present when status is "ok".
    public var fiveHour: UsageWindow?
    /// Only present when status is "ok".
    public var sevenDay: UsageWindow?
    /// "normal" | "warning" | "critical". nil when status is not "ok".
    public var severity: String?
    /// The value the producer uses for `CLAUDE_SECURESTORAGE_CONFIG_DIR` for this
    /// account. nil for the default account (PRINCE), which needs no env var. Matches
    /// the same field written by `fetch-usage.py` so Swift never hardcodes any path.
    public var storageDir: String?

    /// When these numbers were actually read from Anthropic.
    ///
    /// Distinct from the file's own `fetchedAt`, and the distinction is the point: the
    /// fetcher now falls back to the last good reading when a poll fails, so the file can
    /// be a minute old while one account's figures are ten minutes old. Without a
    /// per-account stamp, carried-forward numbers would be presented as current.
    public var asOf: Date?
    /// True when this reading was reused because the latest poll for this account failed.
    public var isCarried: Bool
    /// What went wrong on the poll that was carried over — "error" or "expired".
    /// nil when `isCarried` is false.
    public var degraded: String?

    public init(
        key: String,
        label: String,
        status: String,
        fiveHour: UsageWindow? = nil,
        sevenDay: UsageWindow? = nil,
        severity: String? = nil,
        storageDir: String? = nil,
        asOf: Date? = nil,
        isCarried: Bool = false,
        degraded: String? = nil
    ) {
        self.key = key
        self.label = label
        self.status = status
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.severity = severity
        self.storageDir = storageDir
        self.asOf = asOf
        self.isCarried = isCarried
        self.degraded = degraded
    }

    /// Decoded key by key so a snapshot written by an older `lidcode` binary still
    /// loads — same reason `Setting` and `RuntimeSnapshot` do it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "error"
        fiveHour = try container.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
        severity = try container.decodeIfPresent(String.self, forKey: .severity)
        storageDir = try container.decodeIfPresent(String.self, forKey: .storageDir)
        asOf = try container.decodeIfPresent(Date.self, forKey: .asOf)
        isCarried = try container.decodeIfPresent(Bool.self, forKey: .isCarried) ?? false
        degraded = try container.decodeIfPresent(String.self, forKey: .degraded)
    }

    /// How stale these particular numbers are, or nil when they are from this poll.
    public func carriedAgeDisplay(asOf now: Date = Date()) -> String? {
        guard isCarried, let asOf else { return nil }
        let second = Int(now.timeIntervalSince(asOf))
        guard second > 0 else { return "just now" }
        if second < 60 { return "\(second)s ago" }
        if second < 3600 { return "\(second / 60)m ago" }
        return "\(second / 3600)h ago"
    }
}

public struct ClaudeUsage: Codable, Sendable, Equatable {
    public var fiveHour: UsageWindow
    public var sevenDay: UsageWindow
    /// "normal" | "warning" | "critical", passed through rather than enumerated so a
    /// new level from the producer degrades to an unfamiliar string instead of nil.
    public var severity: String
    public var fetchedAt: Date
    /// true when `fetchedAt` is older than `staleAfterSecond`.
    public var isStale: Bool
    /// One entry per account in producer order (ADVO then PRINCE). Empty only when the
    /// file predates the multi-account format and synthesis failed for some reason — the
    /// UI falls back to the top-level windows in that case.
    public var accounts: [ClaudeAccountUsage]

    public init(
        fiveHour: UsageWindow,
        sevenDay: UsageWindow,
        severity: String,
        fetchedAt: Date,
        isStale: Bool,
        accounts: [ClaudeAccountUsage] = []
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.severity = severity
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.accounts = accounts
    }
}

/// Reads the usage snapshot a launchd agent rewrites every five minutes.
///
/// This process never calls Anthropic itself — it only reads a file someone else
/// maintains, which is why a missing or malformed file is silence rather than an error.
public enum ClaudeUsageReader {
    /// Three times the producer's five-minute cadence: one missed refresh is a blip
    /// worth tolerating, two in a row means the fetcher is genuinely broken.
    public static let staleAfterSecond: TimeInterval = 900

    /// Written by `com.warp-monitor.fetch-usage`. Outside the home directory by design
    /// — it is scratch state that should not survive a reboot.
    public static let usageURL = URL(fileURLWithPath: "/tmp/warp-monitor-usage.json")
    public static let errorURL = URL(fileURLWithPath: "/tmp/warp-monitor-usage-error.txt")

    private static let lock = NSLock()
    private static var cachedUsage: ClaudeUsage?
    private static var cachedModifiedAt: Date?

    /// Called on the runtime's 5s tick against a file that changes every 5 minutes, so
    /// the JSON is parsed on roughly one call in sixty.
    public static func read(asOf now: Date = Date()) -> ClaudeUsage? {
        lock.lock()
        defer { lock.unlock() }

        guard let attribute = try? FileManager.default.attributesOfItem(atPath: usageURL.path) else {
            cachedUsage = nil
            cachedModifiedAt = nil
            return nil
        }
        let modifiedAt = attribute[.modificationDate] as? Date
        if cachedUsage == nil || modifiedAt != cachedModifiedAt {
            cachedModifiedAt = modifiedAt
            cachedUsage = (try? Data(contentsOf: usageURL)).flatMap { parse($0, asOf: now) }
        }
        // Recomputed on every read, cache hit or not: both derived values are relative
        // to the clock, not to the file.
        return cachedUsage.map { refreshed($0, asOf: now) }
    }

    /// The producer's own diagnostic, for a health row. Optional and best-effort.
    public static func lastError() -> String? {
        guard let text = try? String(contentsOf: errorURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func refreshed(_ usage: ClaudeUsage, asOf now: Date) -> ClaudeUsage {
        var refreshed = usage
        refreshed.isStale = now.timeIntervalSince(usage.fetchedAt) > staleAfterSecond
        refreshed.fiveHour.resetDisplay = UsageWindow.display(until: usage.fiveHour.resetsAt, asOf: now)
        refreshed.sevenDay.resetDisplay = UsageWindow.display(until: usage.sevenDay.resetsAt, asOf: now)
        // Per-account reset countdowns are relative to the clock just like the top-level
        // pair — skipping them here would freeze every account's countdown after the first
        // cache hit even though the top-level ones keep ticking.
        refreshed.accounts = usage.accounts.map { acct in
            var a = acct
            if let fh = acct.fiveHour {
                a.fiveHour = UsageWindow(
                    utilization: fh.utilization,
                    resetsAt: fh.resetsAt,
                    asOf: now)
            }
            if let sd = acct.sevenDay {
                a.sevenDay = UsageWindow(
                    utilization: sd.utilization,
                    resetsAt: sd.resetsAt,
                    asOf: now)
            }
            return a
        }
        return refreshed
    }

    // MARK: - Parsing

    private struct Payload: Decodable {
        struct Window: Decodable {
            var utilization: Double?
            var resetsAt: String?
        }
        struct AccountPayload: Decodable {
            var key: String
            var label: String
            var status: String
            var severity: String?
            var storageDir: String?
            var fiveHour: Window?
            var sevenDay: Window?
            /// When this account's numbers were actually read. Absent in files written
            /// before the fetcher gained its carry-forward behaviour.
            var asOf: String?
            var carried: Bool?
            var degraded: String?
        }
        var fetchedAt: String?
        var fiveHour: Window?
        var sevenDay: Window?
        var severity: String?
        var accounts: [AccountPayload]?
    }

    public static func parse(_ data: Data, asOf now: Date = Date()) -> ClaudeUsage? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        // A file with no timestamp cannot be aged, and an un-ageable reading is exactly
        // the thing this reader exists to avoid showing.
        guard let fetchedAt = payload.fetchedAt.flatMap(date(fromIso:)) else { return nil }

        // Decode the accounts array when present. When absent (old file format), synthesise
        // a single "prince" account from the top-level windows so nothing regresses.
        let accounts: [ClaudeAccountUsage]
        if let rawAccounts = payload.accounts {
            accounts = rawAccounts.map { raw in
                let fh = raw.fiveHour.map { window($0, asOf: now) }
                let sd = raw.sevenDay.map { window($0, asOf: now) }
                return ClaudeAccountUsage(
                    key: raw.key,
                    label: raw.label,
                    status: raw.status,
                    fiveHour: fh,
                    sevenDay: sd,
                    severity: raw.severity,
                    storageDir: raw.storageDir,
                    // Falls back to the file's own timestamp so an older file, whose
                    // accounts carry no per-account stamp, still reports an age rather
                    // than nothing.
                    asOf: raw.asOf.flatMap(date(fromIso:)) ?? fetchedAt,
                    isCarried: raw.carried ?? false,
                    degraded: raw.degraded)
            }
        } else {
            // Old single-account file: synthesise the default account so callers can
            // always iterate accounts[] without branching on format version.
            let fh = window(payload.fiveHour, asOf: now)
            let sd = window(payload.sevenDay, asOf: now)
            accounts = [ClaudeAccountUsage(
                key: "prince",
                label: "PRINCE",
                status: "ok",
                fiveHour: fh,
                sevenDay: sd,
                severity: payload.severity ?? "normal")]
        }

        // Top-level windows: use what the file says when present; fall back to zeroed
        // windows when absent (multi-account file without a back-compat summary).
        // parse() returns nil only when fetched_at is unparseable — missing windows
        // are a degraded state worth representing, not a reason to drop the reading.
        let fiveHour = window(payload.fiveHour, asOf: now)
        let sevenDay = window(payload.sevenDay, asOf: now)

        let usage = ClaudeUsage(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            severity: payload.severity ?? "normal",
            fetchedAt: fetchedAt,
            isStale: false,
            accounts: accounts)
        return refreshed(usage, asOf: now)
    }

    private static func window(_ raw: Payload.Window?, asOf now: Date) -> UsageWindow {
        UsageWindow(
            utilization: raw?.utilization ?? 0,
            resetsAt: raw?.resetsAt.flatMap(date(fromIso:)),
            asOf: now)
    }

    /// The file mixes two ISO8601 dialects in one object — `fetched_at` is a plain
    /// `...Z` stamp while `resets_at` carries microseconds and a `+00:00` offset — and
    /// each formatter rejects the other's format outright, so both must be tried.
    static func date(fromIso text: String) -> Date? {
        fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
