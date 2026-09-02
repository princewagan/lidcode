import Foundation

/// Reads system memory state from two sysctl keys and `ps -Ao rss,comm`.
///
/// Shape follows `ClaudeUsageReader`: pure enum, NSLock static cache, 5s TTL keyed on a
/// monotonic timestamp rather than file mtime. Both shell commands are bounded by
/// `ShellCommand.run(..., timeoutSecond: 2)` so a stall returns nil and the runtime
/// carries forward its last good reading rather than blocking the queue.
public enum MemoryReader {
    private static let lock = NSLock()
    private static var cachedReading: MemoryReading?
    private static var cachedAt: Date?

    /// How long a reading may be reused without re-querying the kernel.
    ///
    /// Matches the runtime tick interval: five-second-old data is still the freshest the
    /// UI would ever show, so caching it for one tick costs nothing.
    public static let ttlSecond: TimeInterval = 5

    /// Called on the runtime's 5 s tick.  Returns nil when the shell commands time out
    /// or produce unparseable output.
    public static func read(asOf now: Date = Date()) -> MemoryReading? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedReading, let at = cachedAt,
           now.timeIntervalSince(at) < ttlSecond {
            return cached
        }

        let reading = readFresh(asOf: now)
        cachedReading = reading
        cachedAt = now
        return reading
    }

    // MARK: - Internal

    private static func readFresh(asOf now: Date) -> MemoryReading? {
        guard let pressure = readPressure() else { return nil }
        guard let (swapUsed, swapTotal, swapPercent) = readSwap() else { return nil }
        let apps = readApps()

        return MemoryReading(
            pressure: pressure,
            usedPercent: swapPercent,
            swapUsedMegabyte: swapUsed,
            swapTotalMegabyte: swapTotal,
            app: apps,
            readAt: now
        )
    }

    // MARK: - Pressure

    /// `sysctl -n kern.memorystatus_vm_pressure_level` → 1/2/4
    static func readPressure() -> MemoryPressureLevel? {
        guard let output = ShellCommand.run(
            "/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"],
            timeoutSecond: 2
        ) else { return nil }
        guard let raw = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return MemoryPressureLevel(rawValue: raw)
    }

    // MARK: - Swap

    /// `sysctl -n vm.swapusage` → (usedMB, totalMB, usedPercent)
    ///
    /// Example line:
    ///   `total = 2048.00M  used = 998.56M  free = 1049.44M  (encrypted)`
    ///
    /// Guard: when total == 0 (desktop Mac with swap disabled), usedPercent is 0.
    static func readSwap() -> (used: Double, total: Double, percent: Double)? {
        guard let output = ShellCommand.run(
            "/usr/sbin/sysctl", ["-n", "vm.swapusage"],
            timeoutSecond: 2
        ) else { return nil }

        guard let total = extractMegabyte(label: "total", from: output),
              let used  = extractMegabyte(label: "used",  from: output)
        else { return nil }

        let percent = total > 0 ? (used / total * 100) : 0
        return (used: used, total: total, percent: percent)
    }

    /// Extract the numeric MB value following `label = `.
    ///
    /// Input:  `total = 2048.00M  used = 998.56M  free = 1049.44M  (encrypted)`
    /// Call:   `extractMegabyte(label: "total", from: ...)` → 2048.0
    static func extractMegabyte(label: String, from text: String) -> Double? {
        // Match "label = <number>M"
        let pattern = "\(label) = ([0-9]+\\.?[0-9]*)M"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range])
    }

    // MARK: - Apps

    /// `ps -Ao rss,comm` — group by app name, sum RSS (KB → MB), sort descending.
    ///
    /// Merging rules:
    /// - Strip `.app/Contents/MacOS/...` suffix: `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser` → `Brave`
    /// - Merge `claude` and `claude.exe` into one row named `Claude`.
    static func readApps() -> [MemoryApp] {
        guard let output = ShellCommand.run(
            "/bin/ps", ["-Ao", "rss,comm"],
            timeoutSecond: 2
        ) else { return [] }
        return parseApps(from: output)
    }

    /// Exposed for testing.
    static func parseApps(from output: String) -> [MemoryApp] {
        var accumulated: [String: (rssKB: Double, count: Int)] = [:]

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Format: "<rss> <comm>"  where rss is in KB.
            guard let spaceIndex = trimmed.firstIndex(of: " ") else { continue }
            let rssString = String(trimmed[..<spaceIndex])
            let comm = String(trimmed[trimmed.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)

            guard let rssKB = Double(rssString) else { continue }

            let name = appName(from: comm)
            accumulated[name, default: (0, 0)].rssKB += rssKB
            accumulated[name, default: (0, 0)].count  += 1
        }

        return accumulated
            .map { MemoryApp(name: $0.key, megabyte: $0.value.rssKB / 1024, count: $0.value.count) }
            .sorted { $0.megabyte > $1.megabyte }
    }

    /// Derive the human-readable app name from a `comm` field.
    ///
    /// - `claude` and `claude.exe` → `Claude`
    /// - Full path with `.app/Contents/MacOS/...` → the component before `.app`
    /// - Bare binary name → returned as-is
    static func appName(from comm: String) -> String {
        // Normalise: strip leading whitespace
        let s = comm.trimmingCharacters(in: .whitespaces)

        // Claude family merge
        let lower = s.lowercased()
        if lower == "claude" || lower == "claude.exe" { return "Claude" }

        // Strip .app bundle path: find the last ".app" occurrence and take the component before it.
        if let dotApp = s.range(of: ".app", options: .backwards) {
            // Walk back from ".app" to the preceding "/" to extract the app name.
            let before = s[..<dotApp.lowerBound]
            if let slash = before.lastIndex(of: "/") {
                return String(before[before.index(after: slash)...])
            }
            // No slash — the whole string up to ".app" is the name.
            return String(before)
        }

        // Bare binary: take the basename.
        if s.contains("/"), let slash = s.lastIndex(of: "/") {
            return String(s[s.index(after: slash)...])
        }

        return s
    }
}
