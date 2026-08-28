import Foundation

/// One line in the activity log. Append-only JSONL so the CLI, the menu bar and
/// `tail -f` all read the same file without a database.
public struct LogEntry: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case holdStarted
        case holdStopped
        case clamshellOn
        case clamshellOff
        case leaseAdded
        case leaseRemoved
        case safetyWarned
        case helperReverted
        case note
    }

    public var at: Date
    public var kind: Kind
    public var detail: String
    public var reason: StopReason?
    public var batteryPercent: Int?
    public var thermal: ThermalLevel?

    public init(
        at: Date = Date(),
        kind: Kind,
        detail: String,
        reason: StopReason? = nil,
        batteryPercent: Int? = nil,
        thermal: ThermalLevel? = nil
    ) {
        self.at = at
        self.kind = kind
        self.detail = detail
        self.reason = reason
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

/// Append-only JSONL writer with an in-memory ring buffer for O(1) reads.
///
/// ## Why the ring buffer
///
/// The original `recent(limit:)` called `queue.sync { try String(contentsOf: url) }`.
/// This is fine for the CLI, which runs on a background thread. It is fatal for the
/// menu bar, which calls `recentLog` from `AppModel.onChange` — a main-actor closure.
/// A `queue.sync` from main onto a serial queue that is simultaneously appending a
/// disk write blocks the main thread. After a sleep/wake, where the filesystem I/O
/// subsystem is resuming, the block can be seconds long. The menu bar icon stops
/// responding, the UI freezes, and every click accumulates as a pending event.
///
/// The fix is a lock-guarded ring buffer. `append(_:)` adds to the buffer
/// synchronously under the lock — a handful of instructions, never blocking — then
/// dispatches the disk write asynchronously as before. `recent(limit:)` reads only
/// the buffer. It never calls `queue.sync`, never touches the disk, and is safe to
/// call from the main thread or any actor.
///
/// The disk file remains the authoritative record for `tail -f` and CLI consumers.
/// The buffer is populated on init by an async tail-read so it is filled before the
/// first UI draw without blocking startup.
public final class ActivityLog {
    private let url: URL
    private let queue = DispatchQueue(label: "com.lidcode.activitylog")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - In-memory ring buffer

    /// A simple bounded ring buffer. Cap chosen to comfortably exceed any reasonable
    /// UI list (`recentLog(limit:12)`) while staying tiny in memory — 200 encoded
    /// entries is well under 200 KB.
    private static let bufferCapacity = 200

    /// Guarded exclusively by `bufferLock`. Stored oldest-first internally so that
    /// appending is a plain `.append` and the newest-first slice is a single `.suffix`
    /// + `.reversed()` — the same shape callers already expected.
    private var buffer: [LogEntry] = []
    private let bufferLock = NSLock()

    public init(url: URL = LidCodePath.activityLog) {
        self.url = url
        try? LidCodePath.ensureSupportDirectory()

        // Warm the buffer from the tail of the file — asynchronously, so init
        // returns immediately. If the file is empty or missing, the buffer stays empty
        // and fills from live appends. Callers that want the file tail before the
        // first tick simply get a short initial list, which is the same behaviour
        // as before this change.
        queue.async { [weak self] in
            guard let self else { return }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let entries = text
                .split(separator: "\n")
                .suffix(Self.bufferCapacity)
                .compactMap { try? self.decoder.decode(LogEntry.self, from: Data($0.utf8)) }
            self.bufferLock.lock()
            // Only seed if the buffer is still empty — we do not want to overwrite
            // entries that arrived during the async load.
            if self.buffer.isEmpty {
                self.buffer = entries
            }
            self.bufferLock.unlock()
        }
    }

    public func append(_ entry: LogEntry) {
        // Add to the in-memory buffer under the lock immediately. This is the
        // path that `recent(limit:)` reads, so the menu bar sees the entry on the
        // very next read without any queue round trip. The lock is held for only a
        // pointer swap and an integer increment — never for I/O.
        bufferLock.lock()
        buffer.append(entry)
        if buffer.count > Self.bufferCapacity {
            buffer.removeFirst(buffer.count - Self.bufferCapacity)
        }
        bufferLock.unlock()

        // Disk write stays asynchronous: appending to a file has fsync-level cost
        // and must never block the main thread or the runtime queue.
        queue.async { [url, encoder] in
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    /// Newest first, capped. Reads only the in-memory buffer — never the disk,
    /// never `queue.sync`. Safe to call from the main thread or any actor.
    ///
    /// The newest-first guarantee that callers depend on is preserved: internally the
    /// buffer is oldest-first, so `suffix(limit)` gives the newest N and `.reversed()`
    /// flips the order without allocating a separate reverse collection.
    public func recent(limit: Int = 50) -> [LogEntry] {
        bufferLock.lock()
        let slice = buffer.suffix(limit).reversed().map { $0 }
        bufferLock.unlock()
        return slice
    }
}
