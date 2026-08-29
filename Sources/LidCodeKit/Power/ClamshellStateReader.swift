import Foundation

// MARK: - PhysicalLidState

/// The physical state of the laptop lid as reported by IORegistry.
public enum PhysicalLidState: String, Codable, Sendable {
    case open
    case closed
    case unknown
}

// MARK: - ClamshellReading

/// A single sampled lid-state observation, with a staleness flag.
public struct ClamshellReading: Codable, Sendable, Equatable {
    /// The observed lid position.
    public var state: PhysicalLidState
    /// When this reading was taken.
    public var readAt: Date
    /// True when `readAt` is older than 30 seconds.
    public var isStale: Bool

    public init(state: PhysicalLidState, readAt: Date, isStale: Bool) {
        self.state = state
        self.readAt = readAt
        self.isStale = isStale
    }
}

// MARK: - ClamshellStateReader

/// Reads the physical lid state from IORegistry using `ioreg`.
///
/// Detection method: `ioreg -r -k AppleClamshellState -d 4` prints
/// `"AppleClamshellState" = Yes` when the lid is physically closed, and
/// `"AppleClamshellState" = No` when it is open. Missing key or
/// command failure → `.unknown`.
///
/// Desktop Macs and machines that do not publish `AppleClamshellState`
/// return `.unknown`. The two consumers of this value both treat `.unknown`
/// as `.open` for safety: the brightness reconcile only dims when the state
/// is `.closed`, and the status panel shows the physical lid badge only
/// when the state is known. `disablesleep` is no longer gated on lid state
/// at all — it is set pre-emptively when the user arms closed-lid protection,
/// because macOS clamshell-sleeps within ~1–2 s of the lid closing, far
/// faster than the 5 s tick could react if we waited to confirm `.closed`.
///
/// Thread safety: the result cache is protected by `NSLock`. `read()` is
/// safe to call from any thread.
public final class ClamshellStateReader: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = ClamshellStateReader()

    // MARK: - Constants

    /// Cache a reading for this many seconds before re-running ioreg.
    private static let cacheTTL: TimeInterval = 5

    /// A reading older than this is marked stale in `ClamshellReading.isStale`.
    private static let staleAfter: TimeInterval = 30

    // MARK: - Private state

    private let lock = NSLock()
    private var cached: ClamshellReading?

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Discards the cached reading so the next `read()` goes straight to ioreg.
    ///
    /// Called when a screen-sleep notification fires, which is the earliest signal that
    /// the lid has closed. Without this, the tick + cache combination means the runtime
    /// cannot see `.closed` for up to 10 seconds — long after macOS has already slept.
    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Returns the current lid state, using a 5-second cache.
    ///
    /// On cache miss, runs `ioreg -r -k AppleClamshellState -d 4` with a
    /// 3-second hard timeout (via `ShellCommand`). An empty result or a
    /// timeout is reported as `.unknown`.
    public func read() -> ClamshellReading {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let c = cached, now.timeIntervalSince(c.readAt) < Self.cacheTTL {
            // Return a fresh copy with isStale re-computed from "now".
            return ClamshellReading(
                state: c.state,
                readAt: c.readAt,
                isStale: now.timeIntervalSince(c.readAt) > Self.staleAfter
            )
        }

        let state = Self.queryIOReg()
        let reading = ClamshellReading(state: state, readAt: now, isStale: false)
        cached = reading
        return reading
    }

    // MARK: - Private helpers

    /// Runs the ioreg command and parses the output.
    private static func queryIOReg() -> PhysicalLidState {
        guard let output = ShellCommand.run(
            "/usr/sbin/ioreg",
            ["-r", "-k", "AppleClamshellState", "-d", "4"],
            timeoutSecond: 3
        ) else {
            return .unknown
        }
        return parseOutput(output)
    }

    /// Parses ioreg output for `"AppleClamshellState" = Yes/No`.
    ///
    /// Public and static for testability.
    public static func parseOutput(_ output: String) -> PhysicalLidState {
        // ioreg output looks like:
        //   "AppleClamshellState" = Yes
        //   "AppleClamshellState" = No
        // There may be leading whitespace and surrounding markup.
        for line in output.split(separator: "\n") {
            guard line.contains("AppleClamshellState") else { continue }
            if line.contains("= Yes") { return .closed }
            if line.contains("= No")  { return .open }
        }
        return .unknown
    }
}
