import Foundation

/// How hot the Mac is, relabelled for humans.
///
/// Derived from two sources that are both individually wrong. `ProcessInfo.thermalState`
/// is the supported one, but on Apple silicon it reports `.nominal` right up until the
/// OS is already throttling — accurate about *pressure*, blind as a temperature. The die
/// sensors (see `TemperatureSensor`) give a live number but no notion of what the OS
/// intends to do about it. `ThermalReader` takes the worse of the two, so neither can
/// hide heat from the governor.
///
/// LidCode still only manages risk from what it observes; it does not override hardware.
public enum ThermalLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public var rank: Int {
        switch self {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        }
    }

    public var display: String {
        switch self {
        case .nominal:  return "Normal"
        case .fair:     return "Fair"
        case .serious:  return "Hot"
        case .critical: return "Very hot"
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:  self = .nominal
        case .fair:     self = .fair
        case .serious:  self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

/// Where a live die temperature crosses into each `ThermalLevel`.
///
/// Named and public because they are a policy choice, not a measurement: they decide
/// when an overnight run gets warned about or stopped. Apple silicon idles in the 30s
/// and runs a sustained all-core build in the 80s-90s without complaint, so the bands
/// are set well above "warm" — the point is to catch a machine cooking behind a shut
/// lid, not to nag about a compile.
public enum ThermalThreshold {
    /// Working hard, still fine.
    public static let fairCelsius: Double = 65
    /// Sustained heat worth surfacing in the menu bar.
    public static let seriousCelsius: Double = 80
    /// Hot enough that a closed lid has no way out of it.
    public static let criticalCelsius: Double = 95

    /// Lower bound inclusive at every step: exactly 65 °C is `.fair`, exactly 95 °C is
    /// `.critical`.
    public static func level(forCelsius celsius: Double) -> ThermalLevel {
        switch celsius {
        case ..<fairCelsius:      return .nominal
        case ..<seriousCelsius:   return .fair
        case ..<criticalCelsius:  return .serious
        default:                  return .critical
        }
    }
}

public struct ThermalReading: Codable, Sendable, Equatable {
    /// The effective level: the worse of the OS pressure state and the die temperature.
    public var level: ThermalLevel
    /// Live CPU die temperature. nil when no sensor is readable — an Intel Mac, a future
    /// macOS that drops the private symbols, or a VM. `Optional` rather than a sentinel
    /// so "unknown" can never be compared against a threshold by accident.
    ///
    /// Defaulted in the initializer, and optional for `Codable`, so older `state.json`
    /// and every existing `ThermalReading(level:)` call site keep working untouched.
    public var celsius: Double?
    /// True when the last successful temperature read was more than 30 seconds ago.
    /// Set by `LidCodeRuntime.makeSnapshot()` from `lastThermalAt`.
    /// Always false when `celsius` is nil (sensor simply unavailable, not stale).
    public var isCelsiusStale: Bool

    public init(level: ThermalLevel, celsius: Double? = nil, isCelsiusStale: Bool = false) {
        self.level = level
        self.celsius = celsius
        self.isCelsiusStale = isCelsiusStale
    }

    // MARK: - Codable (manual to keep isCelsiusStale backward-compatible)
    //
    // `ThermalReading` is written to `state.json` by older app versions that did not have
    // `isCelsiusStale`. Synthesized decoding would fail on the missing key; `decodeIfPresent`
    // with a sensible default keeps both old and new files readable.

    private enum CodingKeys: String, CodingKey {
        case level, celsius, isCelsiusStale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decode(ThermalLevel.self, forKey: .level)
        celsius = try container.decodeIfPresent(Double.self, forKey: .celsius)
        isCelsiusStale = try container.decodeIfPresent(Bool.self, forKey: .isCelsiusStale) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(level, forKey: .level)
        try container.encodeIfPresent(celsius, forKey: .celsius)
        try container.encode(isCelsiusStale, forKey: .isCelsiusStale)
    }

    /// "52°" when the die temperature is known, the level's word when it is not.
    public var display: String {
        guard let celsius else { return level.display }
        return "\(Int(celsius.rounded()))°"
    }
}

public enum ThermalReader {
    /// Shared so symbol resolution and the sensor walk happen once per process, and so
    /// the read cache is shared across every caller rather than per-instance.
    internal static let sensor = TemperatureSensor.shared

    public static func read() -> ThermalReading {
        let osLevel = ThermalLevel(ProcessInfo.processInfo.thermalState)
        guard let celsius = sensor.readCelsius() else { return ThermalReading(level: osLevel) }
        // Worse-of, never average-of: the OS knows about throttling the sensors cannot
        // see, and the sensors see heat the OS has not reacted to yet. Taking the max
        // means adding the live reading can only ever make the governor more cautious.
        return ThermalReading(
            level: max(osLevel, ThermalThreshold.level(forCelsius: celsius)),
            celsius: celsius)
    }
}
