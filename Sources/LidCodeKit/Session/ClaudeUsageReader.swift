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

public struct ClaudeUsage: Codable, Sendable, Equatable {
    public var fiveHour: UsageWindow
    public var sevenDay: UsageWindow
    /// "normal" | "warning" | "critical", passed through rather than enumerated so a
    /// new level from the producer degrades to an unfamiliar string instead of nil.
    public var severity: String
    public var fetchedAt: Date
    /// true when `fetchedAt` is older than `staleAfterSecond`.
    public var isStale: Bool

    public init(
        fiveHour: UsageWindow,
        sevenDay: UsageWindow,
        severity: String,
        fetchedAt: Date,
        isStale: Bool
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.severity = severity
        self.fetchedAt = fetchedAt
        self.isStale = isStale
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
        return refreshed
    }

    // MARK: - Parsing

    private struct Payload: Decodable {
        struct Window: Decodable {
            var utilization: Double?
            var resetsAt: String?
        }
        var fetchedAt: String?
        var fiveHour: Window?
        var sevenDay: Window?
        var severity: String?
    }

    public static func parse(_ data: Data, asOf now: Date = Date()) -> ClaudeUsage? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        // A file with no timestamp cannot be aged, and an un-ageable reading is exactly
        // the thing this reader exists to avoid showing.
        guard let fetchedAt = payload.fetchedAt.flatMap(date(fromIso:)) else { return nil }

        let usage = ClaudeUsage(
            fiveHour: window(payload.fiveHour, asOf: now),
            sevenDay: window(payload.sevenDay, asOf: now),
            severity: payload.severity ?? "normal",
            fetchedAt: fetchedAt,
            isStale: false)
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
