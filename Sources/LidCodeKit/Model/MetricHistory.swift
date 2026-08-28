import Foundation

/// One tick's worth of what the menu draws over time.
public struct MetricSample: Codable, Sendable, Equatable {
    public var at: Date
    public var leaseCount: Int
    public var batteryPercent: Int?
    public var thermalRank: Int
    public var isHeld: Bool

    public init(at: Date, leaseCount: Int, batteryPercent: Int?, thermalRank: Int, isHeld: Bool) {
        self.at = at
        self.leaseCount = leaseCount
        self.batteryPercent = batteryPercent
        self.thermalRank = thermalRank
        self.isHeld = isHeld
    }
}

/// A fixed-size ring of recent samples, for the sparkline.
///
/// Bounded on purpose: this exists to draw a 60-pixel-wide chart, not to be a
/// datastore. The activity log on disk is where history that matters lives.
/// Guarded by its own lock rather than by the caller's queue.
///
/// Written from the runtime's serial queue on every tick and read from the main thread
/// when the panel redraws. Routing that read through the runtime queue — which is what
/// it used to do — put a `queue.sync` on the main thread for a 48-element array copy,
/// and every main-thread `queue.sync` is one more way for a wedged queue to freeze the
/// menu bar. A lock this uncontended costs nothing and cannot participate in that.
public final class MetricHistory: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var storage: [MetricSample] = []

    /// 180 samples at the runtime's 5s tick — 15 minutes. Deeper than the menu's strip
    /// draws (it asks for the most recent 48, about 4 minutes), so the extra is
    /// headroom for a wider chart rather than something currently shown.
    public init(capacity: Int = 180) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public func append(_ sample: MetricSample) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(sample)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public var sample: [MetricSample] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func recent(limit: Int) -> [MetricSample] {
        lock.lock()
        defer { lock.unlock() }
        guard limit < storage.count else { return storage }
        return Array(storage.suffix(max(0, limit)))
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }
}
