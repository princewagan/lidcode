import Foundation

// MARK: - OSC 777 parsed payload

public struct OSC777Event: Sendable {
    public let sessionId: String
    public let cwd: String
    public let project: String
    public let event: ClaudeEvent
    public let toolName: String?
    public let errorType: String?
    /// The agent name from the OSC 777 body (e.g. "claude").
    public let agent: String?
    /// Human-readable description from a permission_request event's "summary" field.
    /// Describes what Claude is asking the user to approve.
    public let summary: String?
    /// The user's original request text from a stop_failure event's "query" field.
    public let query: String?
    public let receivedAt: Date

    /// Raw JSON body string for notification storage
    public let bodyRaw: String
}

// MARK: - Log line raw JSON shape

private struct OSC777Body: Codable {
    let v: Int?
    let agent: String?
    let event: String?
    let session_id: String?
    let cwd: String?
    let project: String?
    let tool_name: String?
    let error_type: String?
    /// From permission_request events: describes what Claude wants to do.
    let summary: String?
    /// From stop_failure events: the user's original request text.
    let query: String?
}

// MARK: - LogTailer

/// Reads new lines from warp.log using a byte-offset approach.
/// Calls onEvent for each parsed OSC 777 Claude event.
public final class LogTailer: @unchecked Sendable {

    public static let defaultLogPath = "/Users/princewagan/Library/Logs/warp.log"

    /// Maximum bytes to read from the END of the log during the startup backfill pass.
    /// 16 MB covers roughly 80+ hours of events at observed log density (~294 bytes/event)
    /// while reading in a single syscall — fast enough to complete in < 2 s on a cold launch.
    /// Increased from 4 MB so that sessions whose last event was stop_failure or
    /// permission_request many hours ago are recovered and their sticky state is preserved.
    static let backfillByteLimit: UInt64 = 16 * 1024 * 1024

    /// Only replay events that occurred within this many seconds of now during backfill.
    /// Sticky states (error, blocked) must survive until a NEW event supersedes them,
    /// so we set this window wide enough to cover a full working day (24 hours).
    /// The 10-minute running timeout still applies to .running sessions via checkTimeout().
    /// Sessions that genuinely finished long ago come in as finished or idle and are
    /// harmlessly pruned by the 30-minute stale rule.
    static let backfillWindowSeconds: TimeInterval = 24 * 3600  // 24 hours

    private let logPath: String
    private var fileHandle: FileHandle?
    private var lastOffset: UInt64 = 0
    private var lastInode: UInt64 = 0
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var fallbackTimer: DispatchSourceTimer?
    // QoS .userInitiated: App Nap coalesces .utility timers on backgrounded apps.
    // The fallback 2s timer must fire reliably; .userInitiated is not throttled by App Nap.
    private let queue = DispatchQueue(label: "ph.advo.warp-monitor.logtailer", qos: .userInitiated)

    public var onEvent: ((OSC777Event) -> Void)?
    public var onNotification: ((WarpNotification) -> Void)?

    // NOTE: ISO8601DateFormatter is not Sendable, so we allocate one per call-site
    // rather than sharing a static instance.  Each parse call creates a formatter;
    // the cost is negligible versus file I/O (~microseconds per construction).
    // Alternatives (nonisolated(unsafe) or @unchecked) were rejected because they
    // paper over thread-safety rather than eliminate the hazard.

    public init(logPath: String = LogTailer.defaultLogPath) {
        self.logPath = logPath
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    /// Production start: backfills from the last `backfillByteLimit` bytes (bounded to 2 hours),
    /// replays events through the state machine in log order, then switches to live tailing
    /// from the current end of file — no gap and no double-processing.
    public func start() {
        queue.async { [weak self] in
            self?.performBackfillAndOpen()
            self?.setupWatcher()
            self?.setupFallbackTimer()
        }
    }

    /// Test-only start: opens the file at byte 0 so tests can write content and call readNewLines() directly.
    /// Does NOT install FSEvents or a timer — tests drive reads manually.
    func startForTesting() {
        openLog(seekToEnd: false)
    }

    /// Test-only: directly invoke the backfill replay logic on arbitrary Data.
    /// `readStart` > 0 causes the first (likely-truncated) line to be dropped,
    /// matching production behaviour when the byte cap cuts mid-line.
    func replayBackfillDataForTesting(_ data: Data, readStart: UInt64 = 0) {
        replayBackfillData(data, readStart: readStart)
    }

    public func stop() {
        dispatchSource?.cancel()
        fallbackTimer?.cancel()
        fileHandle?.closeFile()
        fileHandle = nil
    }

    // MARK: - Startup: backfill then open for live tailing

    /// Reads the tail of the log (up to backfillByteLimit), replays events in timestamp
    /// order through the shared onEvent callback, then positions lastOffset at the current
    /// end of file so live tailing picks up exactly where backfill left off.
    ///
    /// Safety guarantees:
    ///   - Never writes, truncates, or appends to the log file.
    ///   - Silently degrades on any error (missing file, unreadable, bad bytes, etc.).
    ///   - Partial lines at the read boundary are skipped (forward-scan to first `\n`).
    ///   - Non-UTF-8 bytes cause that chunk to be skipped (lossless fallback).
    private func performBackfillAndOpen() {
        guard let fh = FileHandle(forReadingAtPath: logPath) else {
            // File doesn't exist — start empty, watcher will open it when created.
            return
        }

        // Capture inode before reading.
        self.lastInode = inode(at: logPath) ?? 0

        // Determine read window: last min(fileSize, backfillByteLimit) bytes.
        let fileSize = fh.seekToEndOfFile()
        guard fileSize > 0 else {
            // Empty file — position at 0 and proceed to live tailing.
            fh.seek(toFileOffset: 0)
            self.lastOffset = 0
            self.fileHandle = fh
            return
        }

        let readStart: UInt64
        if fileSize <= LogTailer.backfillByteLimit {
            readStart = 0
        } else {
            readStart = fileSize - LogTailer.backfillByteLimit
        }

        fh.seek(toFileOffset: readStart)
        let rawData = fh.readDataToEndOfFile()

        // After backfill read, record the true end-of-file offset so live tailing
        // starts exactly here — no gap, no double-processing of events just read.
        let liveTailStart = fh.seekToEndOfFile()
        self.lastOffset = liveTailStart
        self.fileHandle = fh

        // Parse and replay — failures are isolated per-event; never crash.
        replayBackfillData(rawData, readStart: readStart)
    }

    /// Parses `data` as a UTF-8 log chunk (possibly starting mid-line) and replays
    /// all OSC 777 Claude events through `onEvent` in log order.
    ///
    /// - `readStart`: the byte offset within the file where `data` begins.
    ///   When > 0 the first line is likely truncated at the left; we skip it.
    private func replayBackfillData(_ data: Data, readStart: UInt64) {
        // Tolerate non-UTF-8 bytes by replacing them — we prefer partial parses
        // over a total blackout.
        guard let text = String(data: data, encoding: .utf8)
               ?? String(data: data, encoding: .isoLatin1) else {
            return
        }

        var lines = text.components(separatedBy: "\n")

        // The first line is almost certainly truncated at readStart > 0.
        // Drop it unconditionally when we didn't start at the file beginning.
        if readStart > 0, !lines.isEmpty {
            lines.removeFirst()
        }

        let cutoff = Date().addingTimeInterval(-LogTailer.backfillWindowSeconds)

        for line in lines {
            // Extract the log-line timestamp (first 20 chars: "YYYY-MM-DDTHH:MM:SSZ")
            // and skip events outside the 2-hour window.  This avoids re-animating
            // sessions that finished hours ago.
            //
            // We still feed them to the state machine IF they are within the window;
            // the 10-minute running timeout applied by StateManager will demote them
            // to finished if their last event is > 10 minutes old.
            if let lineDate = extractTimestamp(from: line), lineDate < cutoff {
                // Older than the window — skip to avoid unnecessary state machine churn.
                continue
            }

            // Parse the line using the exact same code path as live tailing.
            // Pass the log-line timestamp as receivedAt so timeouts are calculated
            // against the historical date, not now.
            parseBackfillLine(line)
        }
    }

    /// Extract the ISO 8601 timestamp from the beginning of a Warp log line.
    /// Expected format: "2026-08-19T13:09:35Z [INFO] ..."
    /// Returns nil if the line is shorter than 20 chars or the timestamp doesn't parse.
    private func extractTimestamp(from line: String) -> Date? {
        // Quick length guard before any allocations.
        guard line.count >= 20 else { return nil }
        let startIdx = line.startIndex
        let endIdx = line.index(startIdx, offsetBy: 20)
        let tsSlice = String(line[startIdx..<endIdx])
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: tsSlice)
    }

    /// Variant of parseLine that uses the log-line's own timestamp as `receivedAt`.
    /// This is critical for the 10-minute timeout: a session whose last event was
    /// 3 hours ago must NOT appear as `running` after backfill.
    private func parseBackfillLine(_ line: String) {
        guard line.contains("Received OSC 777 notification:") else { return }

        // Extract body JSON
        guard let bodyRange = line.range(of: "body=") else { return }
        let bodyStr = String(line[bodyRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !bodyStr.isEmpty else { return }

        // Title is not needed during backfill (we don't fire onNotification).
        // Skip title extraction to avoid the unused-variable warning.

        guard let bodyData = bodyStr.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(OSC777Body.self, from: bodyData) else { return }

        guard body.agent == "claude" else { return }

        guard let eventStr = body.event,
              let claudeEvent = ClaudeEvent(rawValue: eventStr) else { return }

        guard let sessionId = body.session_id, !sessionId.isEmpty else { return }
        let cwd = normalizeCWD(body.cwd ?? "")
        let project = body.project ?? URL(fileURLWithPath: cwd).lastPathComponent

        // Use the log-line timestamp as receivedAt so the 10-minute timeout rule
        // compares against the real event time, not the current wall-clock time.
        let eventDate = extractTimestamp(from: line) ?? Date()

        let event = OSC777Event(
            sessionId: sessionId,
            cwd: cwd,
            project: project,
            event: claudeEvent,
            toolName: body.tool_name,
            errorType: body.error_type,
            agent: body.agent,
            summary: body.summary,
            query: body.query,
            receivedAt: eventDate,
            bodyRaw: bodyStr
        )

        // Fire event callback — identical to live path; state machine is shared.
        onEvent?(event)

        // Do NOT fire onNotification during backfill: notifications are ephemeral
        // ring-buffer entries for the phone UI.  Replaying 2 hours of old notifications
        // would flood the 50-slot buffer with stale data.
    }

    // MARK: - Open (used by test path only)

    private func openLog(seekToEnd: Bool) {
        guard let fh = FileHandle(forReadingAtPath: logPath) else {
            return
        }
        self.fileHandle = fh
        if seekToEnd {
            let end = fh.seekToEndOfFile()
            self.lastOffset = end
        } else {
            fh.seek(toFileOffset: 0)
            self.lastOffset = 0
        }
        self.lastInode = inode(at: logPath) ?? 0
    }

    // MARK: - FSEvents watcher

    private func setupWatcher() {
        guard let fh = fileHandle else { return }
        let fd = fh.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readNewLines()
        }
        source.resume()
        self.dispatchSource = source
    }

    // MARK: - Fallback timer (2s)

    private func setupFallbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.readNewLines()
        }
        timer.resume()
        self.fallbackTimer = timer
    }

    // MARK: - Read new lines (live tailing)

    func readNewLines() {
        // Check for rotation (inode changed) or truncation
        let currentInode = inode(at: logPath) ?? 0
        if let fh = fileHandle, currentInode != lastInode && lastInode != 0 {
            // Rotation detected
            fh.closeFile()
            dispatchSource?.cancel()
            dispatchSource = nil
            fileHandle = nil
            lastOffset = 0
            lastInode = 0
            openLog(seekToEnd: true)
            setupWatcher()
            return
        }

        guard let fh = fileHandle else {
            // Try to open if file appeared
            openLog(seekToEnd: true)
            if fileHandle != nil { setupWatcher() }
            return
        }

        // Check for truncation
        let fileSize = fh.seekToEndOfFile()
        if fileSize < lastOffset {
            lastOffset = 0
        }

        // Seek to where we left off and read
        fh.seek(toFileOffset: lastOffset)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }

        lastOffset += UInt64(data.count)

        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            parseLine(line)
        }
    }

    // MARK: - Parsing (live path)

    private func parseLine(_ line: String) {
        // Match lines containing OSC 777 notification from Warp
        // Format observed: "... Received OSC 777 notification: title=Some("warp://cli-agent"), body=<json>"
        guard line.contains("Received OSC 777 notification:") else { return }

        // Extract body JSON
        guard let bodyRange = line.range(of: "body=") else { return }
        let bodyStr = String(line[bodyRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !bodyStr.isEmpty else { return }

        // Extract title for the notification record
        let title: String
        if let titleRange = line.range(of: "title=") {
            let afterTitle = String(line[titleRange.upperBound...])
            // title ends at ", body="
            if let commaRange = afterTitle.range(of: ", body=") {
                title = String(afterTitle[..<commaRange.lowerBound])
            } else {
                title = "warp://cli-agent"
            }
        } else {
            title = "warp://cli-agent"
        }

        guard let bodyData = bodyStr.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(OSC777Body.self, from: bodyData) else { return }

        // Only process Claude agent events
        guard body.agent == "claude" else { return }

        // Parse event type
        guard let eventStr = body.event,
              let claudeEvent = ClaudeEvent(rawValue: eventStr) else { return }

        guard let sessionId = body.session_id, !sessionId.isEmpty else { return }
        let cwd = normalizeCWD(body.cwd ?? "")
        let project = body.project ?? URL(fileURLWithPath: cwd).lastPathComponent

        let now = Date()
        let event = OSC777Event(
            sessionId: sessionId,
            cwd: cwd,
            project: project,
            event: claudeEvent,
            toolName: body.tool_name,
            errorType: body.error_type,
            agent: body.agent,
            summary: body.summary,
            query: body.query,
            receivedAt: now,
            bodyRaw: bodyStr
        )

        // Fire event callback
        onEvent?(event)

        // Fire notification callback
        let notif = WarpNotification(
            id: UUID().uuidString,
            received_at: isoDate(now),
            title: title,
            body_raw: bodyStr,
            parsed_event: claudeEvent.rawValue
        )
        onNotification?(notif)
    }

    // MARK: - Helpers

    private func inode(at path: String) -> UInt64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt64(st.st_ino)
    }

    private func normalizeCWD(_ raw: String) -> String {
        // Normalize: strip trailing slash, resolve symlinks if possible
        var path = raw
        while path.hasSuffix("/") && path != "/" {
            path = String(path.dropLast())
        }
        // Attempt realpath resolution
        if let resolved = realpath(path, nil) {
            let result = String(cString: resolved)
            free(resolved)
            return result
        }
        return path
    }
}
