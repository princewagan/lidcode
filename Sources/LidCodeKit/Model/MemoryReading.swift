import Foundation

/// The three pressure levels the kernel reports via `sysctl kern.memorystatus_vm_pressure_level`.
///
/// Values are the raw kernel integers: 1 = normal, 2 = warn, 4 = critical.
/// `Comparable` is derived from the raw value so that level comparisons (`>=`) work
/// intuitively: `.critical > .warn > .normal`.
public enum MemoryPressureLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case normal = 1
    case warn = 2
    case critical = 4

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Lowercase string for the push payload, matching the contract the website agent expects.
    public var pushLabel: String {
        switch self {
        case .normal:   return "normal"
        case .warn:     return "warn"
        case .critical: return "critical"
        }
    }
}

/// Memory footprint of a single app, as reported by `ps -Ao rss,comm`.
///
/// NOTE: RSS (resident set size) sums all mapped physical pages, including shared
/// frameworks. Every app that links UIKit, for instance, appears to own those pages,
/// so the sum across processes overcounts real physical usage. This is the practical
/// signal a user recognises — it matches what Activity Monitor shows in the "Memory"
/// column — but it is not a true unique-memory figure. Use it for relative comparison
/// and trend-watching, not for accounting.
public struct MemoryApp: Codable, Sendable, Equatable {
    /// Human-readable app name (basename, with `.app/Contents/MacOS/…` paths stripped).
    public var name: String
    /// Total RSS across all matching processes, converted from KB to MB.
    public var megabyte: Double
    /// Number of processes grouped under this name.
    public var count: Int

    public init(name: String, megabyte: Double, count: Int) {
        self.name = name
        self.megabyte = megabyte
        self.count = count
    }
}

/// A snapshot of system memory state at one point in time.
///
/// NOTE on RSS overcount: `app` entries are built from `ps -Ao rss,comm`, which sums
/// resident set size in KB per process. Shared pages (shared libraries, frameworks) are
/// counted once per process that maps them, so the totals per app and the sum across all
/// apps will be larger than actual physical RAM usage. This matches what Activity Monitor
/// shows and is what users recognise, but it is not a unique-memory figure.
public struct MemoryReading: Codable, Sendable, Equatable {
    /// Kernel-reported memory pressure level.
    public var pressure: MemoryPressureLevel
    /// Approximate used percentage 0...100.
    ///
    /// Derived from `vm.swapusage`: used / total * 100. When swap total is 0 (desktop
    /// Macs without swap configured), this is 0.
    public var usedPercent: Double
    /// Swap used, in megabytes.
    public var swapUsedMegabyte: Double
    /// Swap total capacity, in megabytes.
    public var swapTotalMegabyte: Double
    /// Top memory consumers, sorted descending by megabyte.
    public var app: [MemoryApp]
    /// When this reading was taken.
    public var readAt: Date

    public init(
        pressure: MemoryPressureLevel,
        usedPercent: Double,
        swapUsedMegabyte: Double,
        swapTotalMegabyte: Double,
        app: [MemoryApp],
        readAt: Date
    ) {
        self.pressure = pressure
        self.usedPercent = usedPercent
        self.swapUsedMegabyte = swapUsedMegabyte
        self.swapTotalMegabyte = swapTotalMegabyte
        self.app = app
        self.readAt = readAt
    }

    /// The effective warning level that the UI and health check should display.
    ///
    /// Rule: `max(kernelPressure, swapDerivedLevel)`, so a swap that is nearly
    /// exhausted escalates even when the kernel has not yet promoted its own level.
    ///
    /// - Parameters:
    ///   - warnSwapPercent: threshold (0...100) at which swap usage becomes `.warn`.
    ///   - criticalSwapPercent: threshold (0...100) at which swap usage becomes `.critical`.
    ///
    /// Guard against `swapTotalMegabyte == 0` to avoid a division-by-zero; in that
    /// case the swap-derived level stays `.normal`.
    public func displayLevel(warnSwapPercent: Int, criticalSwapPercent: Int) -> MemoryPressureLevel {
        let swapLevel: MemoryPressureLevel
        if swapTotalMegabyte > 0 {
            let swapPct = swapUsedMegabyte / swapTotalMegabyte * 100
            if swapPct >= Double(criticalSwapPercent) {
                swapLevel = .critical
            } else if swapPct >= Double(warnSwapPercent) {
                swapLevel = .warn
            } else {
                swapLevel = .normal
            }
        } else {
            swapLevel = .normal
        }
        return max(pressure, swapLevel)
    }
}
