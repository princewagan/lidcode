import Foundation

/// Detects which Claude account is currently in use by inspecting the live `claude`
/// process table.
///
/// ## Why "newest process wins"
///
/// A user switching between accounts leaves old sessions from the previous account
/// alive in the background. Testing for any ADVO process would therefore mis-classify
/// the active account: the stale ADVO session wins even after the user has moved back
/// to PRINCE. The newest `claude` process carries the active session's environment, so
/// its `CLAUDE_SECURESTORAGE_CONFIG_DIR` is the ground truth.
///
/// ## Two-step ps approach
///
/// Step 1 (`-Ao pid=,etime=,comm=`): cheap — reads only PID, elapsed time, and the
/// executable path for every process. `comm` is the full path on macOS; its last path
/// component is matched exactly against "claude". No environment is fetched here.
///
/// Step 2 (`-ww -E -o command= -p <pid>`): targeted — fetches argv and environment
/// for the single newest `claude` PID only. There are ~58 claude processes on a busy
/// Mac and each env dump is ~1 KB, so running step 2 across all of them at once would
/// generate ~60 KB every tick. Reading just one keeps the cost trivial.
///
/// ## Caching and non-blocking design
///
/// The runtime ticks every 5 seconds. Running two `ps` calls per tick is wasteful,
/// and the active account changes on human timescales (minutes), not machine timescales
/// (seconds). The result is cached for 10 seconds — two ticks.
///
/// Both callers (`MenuBarContent.init` and `usageSection`) run on the main thread.
/// On a Mac loaded with many Claude sessions, a `ps` call can stall for up to 3 s
/// (the timeout), which would freeze the UI for the same duration — exactly the
/// machine state LidCode exists for. `readStorageDir()` therefore never runs `ps` on
/// the calling thread. When the cache is stale it schedules a background refresh and
/// returns the previous cached value immediately. The consequence: for the first few
/// seconds after launch the menu bar falls back to the top-level summary window, then
/// corrects itself once the first background refresh lands. A momentarily generic
/// number beats a frozen UI.
public enum ActiveClaudeAccountReader {

    /// How long a cached result is reused before the next `ps` pair is issued.
    public static let cacheTTL: TimeInterval = 10

    /// A scan that overruns this is a scan that would have held the runtime queue.
    /// Three seconds is ~100x the observed cost of `ps -A` on a busy Mac.
    static let timeoutSecond: Double = 3

    private static let lock = NSLock()
    private static var cachedDir: String??   // outer optional: "have a result"; inner: the dir
    private static var cachedAt: Date?
    private static var refreshInFlight = false

    private static let refreshQueue = DispatchQueue(
        label: "com.lidcode.active-account-reader",
        qos: .utility)

    // MARK: - Public API

    /// Returns the storage dir of the newest running `claude` process as a
    /// doubly-nested optional — preserving the three distinct states:
    ///
    ///   - `nil`          — detection failed (ps timed out, no claude process found),
    ///                      or no refresh has landed yet. The caller must fall back;
    ///                      this is NOT the default account.
    ///   - `.some(nil)`   — newest process carries no `CLAUDE_SECURESTORAGE_CONFIG_DIR`,
    ///                      i.e. the default (PRINCE) account is active.
    ///   - `.some(path)`  — newest process carries the given path as the config dir.
    ///
    /// This method always returns immediately without blocking. When the cache is stale
    /// it schedules a background `ps` refresh and returns the previous cached value
    /// (or `nil` on the very first call before any refresh has landed). The cache is
    /// updated — and callers corrected — on the next SwiftUI / Combine tick after the
    /// refresh completes, typically within one second.
    public static func readStorageDir() -> String?? {
        lock.lock()
        let now = Date()
        let isFresh = cachedAt.map { now.timeIntervalSince($0) < cacheTTL } ?? false

        if isFresh {
            let result: String?? = cachedDir
            lock.unlock()
            return result
        }

        // Cache is stale (or has never been populated). Return what we have now and
        // schedule a background refresh — but only if one is not already in flight.
        let snapshot: String?? = cachedDir
        let shouldSchedule = !refreshInFlight
        if shouldSchedule { refreshInFlight = true }
        lock.unlock()

        if shouldSchedule {
            refreshQueue.async {
                let fresh = fetchNewestClaudeStorageDir()
                lock.lock()
                cachedDir = fresh
                cachedAt = Date()
                refreshInFlight = false
                lock.unlock()
            }
        }

        return snapshot
    }

    // MARK: - Implementation

    /// Full two-step detection. Returns `String??`:
    ///   - `.some(.some(path))` — ADVO (or any non-default account)
    ///   - `.some(.none)` — PRINCE (default account; env var absent from newest process)
    ///   - `.none` — detection failed (no claude process, or ps timed out)
    static func fetchNewestClaudeStorageDir() -> String?? {
        // Step 1: collect all claude PIDs with their elapsed time.
        guard let rows = claudeRows() else { return nil }
        guard !rows.isEmpty else { return nil }

        // Newest process = smallest elapsed time.
        let newest = rows.min(by: { $0.elapsedSecond < $1.elapsedSecond })!

        // Step 2: read the env of that one process.
        guard let envText = ShellCommand.run(
            "/bin/ps", ["-ww", "-E", "-o", "command=", "-p", "\(newest.pid)"],
            timeoutSecond: timeoutSecond)
        else { return nil }

        return extractStorageDir(from: envText)
    }

    // MARK: - Pure parsing (static so tests can reach them without spawning processes)

    /// Parse the table produced by `ps -Ao pid=,etime=,comm=` and return only rows
    /// whose `comm` last path component is exactly "claude".
    static func claudeRows() -> [ClaudeRow]? {
        guard let text = ShellCommand.run(
            "/bin/ps", ["-Ao", "pid=,etime=,comm="],
            timeoutSecond: timeoutSecond)
        else { return nil }
        return parseClaudeRows(from: text)
    }

    /// Parse the raw `ps -Ao pid=,etime=,comm=` text. Exposed as `internal` so tests
    /// can call it without hitting the filesystem.
    static func parseClaudeRows(from text: String) -> [ClaudeRow] {
        text.split(separator: "\n").compactMap { line in
            parseClaudeRow(from: String(line))
        }
    }

    /// Parse a single `ps` line. Returns nil if the line is malformed or the
    /// executable is not `claude`.
    static func parseClaudeRow(from line: String) -> ClaudeRow? {
        // Format: "  <pid>  <etime>  <comm...>"
        // Whitespace-split: first token is pid, second is etime, rest is comm.
        let parts = line.trimmingCharacters(in: .whitespaces)
                        .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        guard let pid = Int32(parts[0]) else { return nil }
        let etime = String(parts[1])
        let comm  = String(parts[2]).trimmingCharacters(in: .whitespaces)

        // `comm` is the full path; take the last component and match exactly.
        let name = (comm as NSString).lastPathComponent
        guard name == "claude" else { return nil }

        let elapsed = parseEtime(etime)
        return ClaudeRow(pid: pid, elapsedSecond: elapsed)
    }

    /// Convert a `ps` etime field to a total number of seconds.
    ///
    /// The three formats `ps` produces:
    ///   `mm:ss`       — less than one hour
    ///   `hh:mm:ss`    — one hour or more, less than one day
    ///   `dd-hh:mm:ss` — one day or more
    ///
    /// An unparseable value is returned as `Int.max` so the caller's `min` picks
    /// any parseable row over it; the worst case is that an unreadable row is silently
    /// skipped rather than crashing.
    static func parseEtime(_ etime: String) -> Int {
        // Split on "-" first to extract optional day component.
        let dayParts = etime.split(separator: "-", maxSplits: 1)
        let days: Int
        let timePart: String
        if dayParts.count == 2 {
            days     = Int(dayParts[0]) ?? 0
            timePart = String(dayParts[1])
        } else {
            days     = 0
            timePart = etime
        }

        let colonParts = timePart.split(separator: ":")
        switch colonParts.count {
        case 2:
            // mm:ss
            let mm = Int(colonParts[0]) ?? 0
            let ss = Int(colonParts[1]) ?? 0
            return days * 86_400 + mm * 60 + ss
        case 3:
            // hh:mm:ss
            let hh = Int(colonParts[0]) ?? 0
            let mm = Int(colonParts[1]) ?? 0
            let ss = Int(colonParts[2]) ?? 0
            return days * 86_400 + hh * 3_600 + mm * 60 + ss
        default:
            return Int.max
        }
    }

    /// Scan the combined argv+env text produced by `ps -ww -E -o command= -p <pid>`
    /// for a token that starts with `CLAUDE_SECURESTORAGE_CONFIG_DIR=`.
    ///
    /// Returns `.some(path)` when found, `.some(nil)` when the token is absent
    /// (meaning the process is the default account), and `.none` when the input is
    /// empty (ps returned nothing — the process exited between the two calls).
    static func extractStorageDir(from envText: String) -> String?? {
        let trimmed = envText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prefix = "CLAUDE_SECURESTORAGE_CONFIG_DIR="
        // Tokens are space-separated in the combined argv+env output.
        for token in trimmed.split(separator: " ") {
            if token.hasPrefix(prefix) {
                let value = String(token.dropFirst(prefix.count))
                return .some(value.isEmpty ? nil : value)
            }
        }
        // Token absent — this process carries no config dir, i.e. it is the default account.
        return .some(nil)
    }
}

// MARK: - Supporting types

/// A `claude` process row from the cheap first-step `ps` scan.
public struct ClaudeRow: Equatable {
    public var pid: Int32
    /// Total elapsed time in seconds since the process started.
    public var elapsedSecond: Int

    public init(pid: Int32, elapsedSecond: Int) {
        self.pid = pid
        self.elapsedSecond = elapsedSecond
    }
}
