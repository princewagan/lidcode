import Foundation

/// Detects which Claude account is currently active by inspecting the live `claude`
/// process table and preferring the busiest session over the newest one.
///
/// ## Why "busiest wins", not "newest wins"
///
/// The previous rule ("newest process = active account") was wrong in practice.
/// Switching to a fresh terminal and leaving it idle produces a new `claude` process
/// almost immediately; that idle process then wins the "newest" test even though the
/// real work is happening in an older session on another account. The symptom: the
/// active label always shows the wrong account after any new terminal is opened.
///
/// A `claude` process doing coding work consumes measurable CPU — typically 5–40%
/// over macOS's ~1-minute decaying average (`%cpu` in `ps`). An idle session sitting
/// at a prompt is near 0%. Selecting the row with the highest `cpuPercent` therefore
/// picks the session that is actively coding, which is exactly what "active" means.
///
/// ## Sticky last-used cache
///
/// CPU load is ephemeral: a session that just finished a long task will briefly read
/// near 0% even though it was the one doing work. To prevent the label from flickering
/// to the wrong account between tasks, the reader applies a one-way sticky rule:
///
///   - `isBusy == true`  → overwrite `cachedDir` with the busiest session's dir AND
///                          persist it to UserDefaults so a relaunch keeps the last
///                          account rather than going blank.
///   - `isBusy == false` → leave `cachedDir` unchanged. An existing cached value
///                          continues to be returned. Only on a cold launch (no cached
///                          value yet) is the idle guess used — so the panel is never
///                          blank on first open, even if every session happens to be idle.
///
/// ## Two-step ps approach
///
/// Step 1 (`-Ao pid=,etime=,pcpu=,comm=`): cheap — reads PID, elapsed time, CPU
/// percent, and the executable path for every process. `comm` is the full path on
/// macOS; its last path component is matched exactly against "claude". `%cpu` is
/// macOS's decaying average over ~1 minute of real time — exactly the "is this session
/// working right now?" window we care about. No environment is fetched here.
///
/// Step 2 (`-ww -E -o command= -p <pid>`): targeted — fetches argv and environment
/// for the single selected `claude` PID only. There are ~58 claude processes on a busy
/// Mac; each env dump is ~1 KB, so running step 2 across all of them would generate
/// ~60 KB every tick. Reading just one keeps the cost trivial.
///
/// ## Caching and non-blocking design
///
/// The runtime ticks every 5 seconds. The active account changes on human timescales
/// (minutes), not machine timescales (seconds). The result is cached for 10 seconds —
/// two ticks.
///
/// Both callers run on the main thread. On a Mac loaded with many Claude sessions, a
/// `ps` call can stall for up to 3 s (the timeout), which would freeze the UI.
/// `readStorageDir()` therefore never runs `ps` on the calling thread. When the cache
/// is stale it schedules a background refresh and returns the previous cached value
/// immediately. The consequence: for the first few seconds after launch the menu bar
/// falls back to the last-known (or top-level summary) account, then corrects itself
/// once the first background refresh lands.
public enum ActiveClaudeAccountReader {

    /// How long a cached result is reused before the next `ps` pair is issued.
    public static let cacheTTL: TimeInterval = 10

    /// A `claude` process is considered "actively coding" when its CPU percent
    /// (macOS's ~1-minute decaying average) is at or above this threshold.
    /// 2% is well above the noise floor of an idle session (~0%) but well below
    /// any session doing real work (typically 5–40%).
    public static let busyCpuPercent: Double = 2.0

    /// A scan that overruns this is a scan that would have held the runtime queue.
    /// Three seconds is ~100x the observed cost of `ps -A` on a busy Mac.
    static let timeoutSecond: Double = 3

    // MARK: - State (all access protected by `lock`)

    private static let lock = NSLock()
    private static var cachedDir: String??    // outer optional: "have a result"; inner: the dir
    private static var cachedAt: Date?
    private static var refreshInFlight = false
    private static var defaultsLoaded = false // loaded from UserDefaults at most once

    private static let refreshQueue = DispatchQueue(
        label: "com.lidcode.active-account-reader",
        qos: .utility)

    /// UserDefaults key for persisting the last-known active storage dir across relaunches.
    ///
    /// Encoding contract (mirrors the String?? semantic):
    ///   - key absent     → no persisted knowledge (nil outer)
    ///   - empty string   → default account was active (inner nil, i.e. .some(nil))
    ///   - any other string → that config dir path (.some(path))
    private static let defaultsKey = "lidcode.active-claude-storage-dir"

    // MARK: - Public API

    /// Returns the storage dir of the actively-coding `claude` process as a
    /// doubly-nested optional — preserving the three distinct states:
    ///
    ///   - `nil`          — detection failed (ps timed out, no claude process found),
    ///                      or no refresh has landed yet. The caller must fall back;
    ///                      this is NOT the default account.
    ///   - `.some(nil)`   — active process carries no `CLAUDE_SECURESTORAGE_CONFIG_DIR`,
    ///                      i.e. the default (PRINCE) account is active.
    ///   - `.some(path)`  — active process carries the given path as the config dir.
    ///
    /// This method always returns immediately without blocking. When the cache is stale
    /// it schedules a background `ps` refresh and returns the previous cached value
    /// (or the last-persisted value from UserDefaults on the very first call). The
    /// cache is updated — and callers corrected — on the next SwiftUI / Combine tick
    /// after the refresh completes, typically within one second.
    public static func readStorageDir() -> String?? {
        lock.lock()

        // Lazy one-time load from UserDefaults — only before the first refresh has
        // ever landed so we don't clobber a live result with a stale persisted one.
        if !defaultsLoaded {
            defaultsLoaded = true
            if cachedDir == nil {
                cachedDir = loadPersistedDir()
            }
        }

        let now = Date()
        let isFresh = cachedAt.map { now.timeIntervalSince($0) < cacheTTL } ?? false

        if isFresh {
            let result: String?? = cachedDir
            lock.unlock()
            return result
        }

        // Cache is stale (or has never been populated by a live refresh). Return what
        // we have now and schedule a background refresh — but only if one is not already
        // in flight.
        let snapshot: String?? = cachedDir
        let shouldSchedule = !refreshInFlight
        if shouldSchedule { refreshInFlight = true }
        lock.unlock()

        if shouldSchedule {
            refreshQueue.async {
                let (fresh, isBusy) = fetchActiveClaudeStorageDir()
                lock.lock()
                // Sticky rule: only overwrite the cached dir when the picked session
                // is actually busy. An idle session should never displace the last
                // account that was seen doing real work.
                if isBusy {
                    cachedDir = fresh
                    lock.unlock()
                    persistDir(fresh)
                } else if cachedDir == nil {
                    // Cold launch with no prior knowledge — accept the idle guess so
                    // the panel is not permanently blank on a quiet machine.
                    cachedDir = fresh
                    lock.unlock()
                } else {
                    lock.unlock()
                    // Existing cached value is kept; nothing to persist.
                }
                lock.lock()
                cachedAt = Date()
                refreshInFlight = false
                lock.unlock()
            }
        }

        return snapshot
    }

    // MARK: - Implementation

    /// Full two-step detection. Returns `(dir: String??, isBusy: Bool)`:
    ///   - `dir` follows the same String?? convention as `readStorageDir()`
    ///   - `isBusy` is true when the picked process's CPU is at or above `busyCpuPercent`
    static func fetchActiveClaudeStorageDir() -> (dir: String??, isBusy: Bool) {
        // Step 1: collect all claude PIDs with elapsed time and CPU percent.
        guard let rows = claudeRows() else { return (nil, false) }
        guard !rows.isEmpty else { return (nil, false) }

        // Pick the busiest session; if nothing is busy, pickActiveRow still returns
        // the least-idle row so step 2 can attempt an env read.
        guard let (picked, isBusy) = pickActiveRow(from: rows) else { return (nil, false) }

        // Step 2: read the env of the selected process only.
        guard let envText = ShellCommand.run(
            "/bin/ps", ["-ww", "-E", "-o", "command=", "-p", "\(picked.pid)"],
            timeoutSecond: timeoutSecond)
        else { return (nil, false) }

        let dir = extractStorageDir(from: envText)
        return (dir, isBusy)
    }

    /// Select the row that represents the actively-coding session.
    ///
    /// - Returns the row with the highest `cpuPercent`. Ties are broken by smaller
    ///   `elapsedSecond` (the newer process wins — consistent with the previous rule
    ///   and sensible when two sessions are equally busy).
    /// - `isBusy` is `true` when the winning row's `cpuPercent >= busyCpuPercent`.
    /// - Returns `nil` for an empty array.
    ///
    /// This function is pure (no I/O) so tests can exercise it directly.
    static func pickActiveRow(from rows: [ClaudeRow]) -> (row: ClaudeRow, isBusy: Bool)? {
        guard !rows.isEmpty else { return nil }
        let best = rows.max { a, b in
            if a.cpuPercent != b.cpuPercent { return a.cpuPercent < b.cpuPercent }
            // Tie on CPU: prefer the newer process (smaller elapsedSecond).
            return a.elapsedSecond > b.elapsedSecond
        }!
        return (best, best.cpuPercent >= busyCpuPercent)
    }

    // MARK: - Pure parsing (static so tests can reach them without spawning processes)

    /// Parse the table produced by `ps -Ao pid=,etime=,pcpu=,comm=` and return only
    /// rows whose `comm` last path component is exactly "claude".
    static func claudeRows() -> [ClaudeRow]? {
        guard let text = ShellCommand.run(
            "/bin/ps", ["-Ao", "pid=,etime=,pcpu=,comm="],
            timeoutSecond: timeoutSecond)
        else { return nil }
        return parseClaudeRows(from: text)
    }

    /// Parse the raw `ps -Ao pid=,etime=,pcpu=,comm=` text. Exposed as `internal` so
    /// tests can call it without hitting the filesystem.
    static func parseClaudeRows(from text: String) -> [ClaudeRow] {
        text.split(separator: "\n").compactMap { line in
            parseClaudeRow(from: String(line))
        }
    }

    /// Parse a single `ps` line.
    ///
    /// Expected format: `"  <pid>  <etime>  <pcpu>  <comm...>"`
    /// Split with `maxSplits: 3`: [pid, etime, pcpu, comm-rest].
    /// An unparseable `%cpu` field is treated as 0 — the row is still included so
    /// the comm-filter and etime-tie-break still work correctly.
    ///
    /// Returns nil if the line is malformed or the executable is not `claude`.
    static func parseClaudeRow(from line: String) -> ClaudeRow? {
        // maxSplits: 3 captures the comm as a single remainder token even when it
        // contains spaces (which full paths never do, but bare "claude" does not either).
        let parts = line.trimmingCharacters(in: .whitespaces)
                        .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        guard let pid = Int32(parts[0]) else { return nil }
        let etime = String(parts[1])
        let cpuStr = String(parts[2])
        let comm   = String(parts[3]).trimmingCharacters(in: .whitespaces)

        // `comm` is the full path; take the last component and match exactly.
        let name = (comm as NSString).lastPathComponent
        guard name == "claude" else { return nil }

        let elapsed    = parseEtime(etime)
        let cpuPercent = Double(cpuStr) ?? 0.0
        return ClaudeRow(pid: pid, elapsedSecond: elapsed, cpuPercent: cpuPercent)
    }

    /// Convert a `ps` etime field to a total number of seconds.
    ///
    /// The three formats `ps` produces:
    ///   `mm:ss`       — less than one hour
    ///   `hh:mm:ss`    — one hour or more, less than one day
    ///   `dd-hh:mm:ss` — one day or more
    ///
    /// An unparseable value is returned as `Int.max` so the caller's sort picks
    /// any parseable row over it; the worst case is that an unreadable row is silently
    /// treated as the "oldest" rather than crashing.
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

    // MARK: - UserDefaults persistence

    /// Load the last-known storage dir from UserDefaults. Returns nil (outer) when
    /// the key is absent, meaning no account has ever been reliably detected.
    private static func loadPersistedDir() -> String?? {
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? String else {
            return nil   // key absent — no prior knowledge
        }
        // Empty string encodes .some(nil) (default account).
        return stored.isEmpty ? .some(nil) : .some(stored)
    }

    /// Persist the active storage dir so a relaunch starts with a known account
    /// rather than a blank panel.
    private static func persistDir(_ dir: String??) {
        guard let inner = dir else {
            // outer nil means "detection failed" — nothing reliable to persist.
            return
        }
        // inner nil means the default account; encode as empty string.
        UserDefaults.standard.set(inner ?? "", forKey: defaultsKey)
    }
}

// MARK: - Supporting types

/// A `claude` process row from the cheap first-step `ps` scan.
public struct ClaudeRow: Equatable {
    public var pid: Int32
    /// Total elapsed time in seconds since the process started.
    public var elapsedSecond: Int
    /// CPU utilisation as reported by `ps %cpu` — a macOS decaying average over
    /// approximately one minute of real time. This is exactly the "is this session
    /// working right now?" window: a session that has been idle for more than a
    /// minute will read near 0%, while an actively-coding session reads 5–40%+.
    /// An unparseable field is stored as 0 so the row is still considered.
    public var cpuPercent: Double

    public init(pid: Int32, elapsedSecond: Int, cpuPercent: Double = 0) {
        self.pid = pid
        self.elapsedSecond = elapsedSecond
        self.cpuPercent = cpuPercent
    }
}
