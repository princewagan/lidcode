import Foundation

/// User-tunable thresholds. Both battery floors are on for everyone — the whole
/// safety argument collapses if the guardrail is the paid part.
public struct Setting: Codable, Sendable, Equatable {
    /// Soft floor: release the hold and let the Mac sleep normally.
    public var softBatteryPercent: Int
    /// Hard floor: force `pmset sleepnow` regardless of who holds an assertion,
    /// so a run ends in a resumable sleep instead of a sudden shutdown.
    public var hardBatteryPercent: Int
    /// Release when thermal pressure reaches this level or worse.
    public var thermalCeiling: ThermalLevel
    /// Smart mode: how long every lease must be gone before releasing.
    public var idleReleaseSecond: Int
    /// Only hold while on mains power.
    public var isChargingOnly: Bool
    /// Executable name that counts as live work. Matched exactly against the
    /// process's basename (see `ProcessWatcher.matches`), not as a substring.
    public var watchPattern: [String]
    /// Whether the health panel is allowed to touch the network — DNS, and a HEAD to
    /// the API of whichever agent is currently holding a lease. Off makes LidCode
    /// completely silent on the wire; the local half of the panel still works.
    public var isNetworkProbeOn: Bool

    /// Whether the **soft** battery floor is enforced. Off is the "Override battery
    /// health" state: the run keeps going below `softBatteryPercent`.
    ///
    /// It cannot reach `hardBatteryPercent`. That is not an oversight to be tidied up
    /// later — the hard floor exists so a run ends in a resumable sleep instead of a
    /// hard shutdown, and no toggle in this app is allowed to trade a user's work for
    /// twenty more minutes of uptime. See `SafetyGovernor.rule`.
    public var isBatteryGuardOn: Bool
    /// Whether the thermal ceiling is enforced. Off is "Override temperature".
    ///
    /// Same line as the battery guard: it waives the *ceiling* the user chose, never
    /// critical heat behind a shut lid, which has no airflow to recover through.
    public var isThermalGuardOn: Bool
    /// How long the machine must stay at or above `thermalCeiling` before the ceiling
    /// releases the hold.
    ///
    /// The instantaneous check this replaces was twitchy in exactly the wrong
    /// direction: a single all-core burst during a compile touches the ceiling for a
    /// few seconds and used to end an eight-hour run. Heat that matters is heat that
    /// *stays* — a machine cooking behind a shut lid does not cool down on its own in
    /// fifteen minutes, and one that does was never in trouble.
    public var sustainedHeatSecond: Int
    /// The duration slider's value: how long a timed hold runs for.
    public var holdSecond: Int

    public static let softBatteryRange = 15...50
    public static let hardBatteryRange = 4...8
    public static let maxSessionSecond = 8 * 3600
    /// Half an hour to eight hours. The lower bound is not a UI nicety — a hold shorter
    /// than the health sweep's own cadence would expire before the panel had anything
    /// true to say about it.
    public static let holdRange = 1800...maxSessionSecond
    /// The slider snaps to half-hour steps. A duration picked by dragging does not
    /// deserve minute precision, and round numbers are what people actually check
    /// against a clock.
    public static let holdStepSecond = 1800
    /// One minute to one hour. Below a minute is indistinguishable from the
    /// instantaneous check this exists to replace; above an hour, a Mac that has been
    /// at its ceiling that long is not going to be talked down by waiting longer.
    public static let sustainedHeatRange = 60...3600

    /// A ceiling of `.nominal` is not a strict setting, it is a brick: the governor
    /// asks `thermal.level >= ceiling`, and every possible level is `>= .nominal`, so
    /// the Mac would be released the instant anything tried to hold it — permanently,
    /// since the condition can never clear. `.fair` is the lowest ceiling that leaves
    /// a reachable "everything is fine" state.
    public static let thermalCeilingChoice: [ThermalLevel] = [.fair, .serious, .critical]

    public static let `default` = Setting(
        softBatteryPercent: 20,
        hardBatteryPercent: 4,
        thermalCeiling: .critical,
        idleReleaseSecond: 600,
        isChargingOnly: false,
        // Only task-shaped processes — things that start, do work, and exit.
        //
        // Server-shaped tools are deliberately absent: `ollama serve`, the Docker
        // Desktop backend, colima and a `vite` dev server all run for as long as
        // they are installed and open, so watching them by name would hold the Mac
        // awake permanently on an idle machine. Those cases belong to `lidcode claim`,
        // where the thing doing the work says when it starts and stops.
        watchPattern: [
            "claude", "codex", "cursor-agent", "aider",
            "xcodebuild", "swift-frontend", "cargo", "rustc", "make", "ninja", "gradle",
            "npm", "pnpm", "yarn", "tsc", "esbuild",
            "python", "pytest", "uv", "poetry",
            "docker", "ffmpeg", "rsync", "pandoc",
        ],
        isNetworkProbeOn: true,
        // Both guards ship on. The whole safety argument collapses if the guardrail is
        // the part you have to remember to switch on.
        isBatteryGuardOn: true,
        isThermalGuardOn: true,
        sustainedHeatSecond: 900,
        holdSecond: 8 * 3600
    )

    /// Every parameter added after `isNetworkProbeOn` has a default, so the existing
    /// call sites — and the tests that build a `Setting` by hand — keep compiling.
    public init(
        softBatteryPercent: Int,
        hardBatteryPercent: Int,
        thermalCeiling: ThermalLevel,
        idleReleaseSecond: Int,
        isChargingOnly: Bool,
        watchPattern: [String],
        isNetworkProbeOn: Bool = true,
        isBatteryGuardOn: Bool = true,
        isThermalGuardOn: Bool = true,
        sustainedHeatSecond: Int = 900,
        holdSecond: Int = 8 * 3600
    ) {
        self.softBatteryPercent = softBatteryPercent
        self.hardBatteryPercent = hardBatteryPercent
        self.thermalCeiling = thermalCeiling
        self.idleReleaseSecond = idleReleaseSecond
        self.isChargingOnly = isChargingOnly
        self.watchPattern = watchPattern
        self.isNetworkProbeOn = isNetworkProbeOn
        self.isBatteryGuardOn = isBatteryGuardOn
        self.isThermalGuardOn = isThermalGuardOn
        self.sustainedHeatSecond = sustainedHeatSecond
        self.holdSecond = holdSecond
    }

    /// Decoded field by field with a fallback per key.
    ///
    /// Synthesized `Codable` fails the whole decode when one key is missing, and
    /// `Setting.load()` swallows that into `.default` — so adding a field would
    /// silently reset every threshold a user had tuned. Every new field from here on
    /// must be read with `decodeIfPresent`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Setting.default
        softBatteryPercent = try container.decodeIfPresent(Int.self, forKey: .softBatteryPercent)
            ?? fallback.softBatteryPercent
        hardBatteryPercent = try container.decodeIfPresent(Int.self, forKey: .hardBatteryPercent)
            ?? fallback.hardBatteryPercent
        thermalCeiling = try container.decodeIfPresent(ThermalLevel.self, forKey: .thermalCeiling)
            ?? fallback.thermalCeiling
        idleReleaseSecond = try container.decodeIfPresent(Int.self, forKey: .idleReleaseSecond)
            ?? fallback.idleReleaseSecond
        isChargingOnly = try container.decodeIfPresent(Bool.self, forKey: .isChargingOnly)
            ?? fallback.isChargingOnly
        watchPattern = try container.decodeIfPresent([String].self, forKey: .watchPattern)
            ?? fallback.watchPattern
        isNetworkProbeOn = try container.decodeIfPresent(Bool.self, forKey: .isNetworkProbeOn)
            ?? fallback.isNetworkProbeOn
        isBatteryGuardOn = try container.decodeIfPresent(Bool.self, forKey: .isBatteryGuardOn)
            ?? fallback.isBatteryGuardOn
        isThermalGuardOn = try container.decodeIfPresent(Bool.self, forKey: .isThermalGuardOn)
            ?? fallback.isThermalGuardOn
        sustainedHeatSecond = try container.decodeIfPresent(Int.self, forKey: .sustainedHeatSecond)
            ?? fallback.sustainedHeatSecond
        holdSecond = try container.decodeIfPresent(Int.self, forKey: .holdSecond)
            ?? fallback.holdSecond
    }

    /// Clamp anything a hand-edited config file could get wrong. A soft floor below
    /// the hard floor would silently disable the soft stop, so it is raised, not trusted.
    public func normalized() -> Setting {
        var copy = self
        copy.hardBatteryPercent = hardBatteryPercent.clamped(to: Setting.hardBatteryRange)
        copy.softBatteryPercent = softBatteryPercent.clamped(to: Setting.softBatteryRange)
        if copy.softBatteryPercent <= copy.hardBatteryPercent {
            copy.softBatteryPercent = Setting.softBatteryRange.lowerBound
        }
        copy.idleReleaseSecond = max(30, idleReleaseSecond)
        // Clamped here rather than in the picker so the CLI and a hand-edited
        // setting.json get the same protection — `lidcode set --thermal-ceiling nominal`
        // could otherwise wedge the app into never holding again.
        if copy.thermalCeiling < .fair { copy.thermalCeiling = .fair }
        copy.sustainedHeatSecond = sustainedHeatSecond.clamped(to: Setting.sustainedHeatRange)
        // Snapped *before* clamping would let 100s round to 0 and then clamp up to the
        // minimum, which is fine, but snapping after keeps every reachable value a real
        // multiple of the step — the slider and a hand-edited file agree on the grid.
        copy.holdSecond = Self.snappedHold(holdSecond)
        return copy
    }

    /// Nearest half-hour inside `holdRange`. Rounded, not truncated: a slider that
    /// reports 3h29m should read as 3h30m rather than silently losing 29 minutes.
    static func snappedHold(_ second: Int) -> Int {
        let clamped = second.clamped(to: Setting.holdRange)
        let step = Double(Setting.holdStepSecond)
        let snapped = Int((Double(clamped) / step).rounded()) * Setting.holdStepSecond
        return snapped.clamped(to: Setting.holdRange)
    }
}

extension Setting {
    public static var storeUrl: URL {
        LidCodePath.supportDirectory.appendingPathComponent("setting.json")
    }

    public static func load() -> Setting {
        guard let data = try? Data(contentsOf: storeUrl),
              let decoded = try? JSONDecoder().decode(Setting.self, from: data)
        else { return .default }
        return decoded.normalized()
    }

    public func save() throws {
        try LidCodePath.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(normalized()).write(to: Setting.storeUrl, options: .atomic)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Every on-disk path LidCode owns, in one place.
public enum LidCodePath {
    public static var supportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".lidcode", isDirectory: true)
    }

    /// App ↔ CLI socket. User-owned, mode 0600.
    public static var appSocket: URL {
        supportDirectory.appendingPathComponent("lidcode.sock")
    }

    /// App ↔ root helper socket. Created by the helper, chowned to the install user.
    public static let helperSocketPath = "/var/run/lidcode-helper.sock"

    public static var activityLog: URL {
        supportDirectory.appendingPathComponent("activity.jsonl")
    }

    /// Helper-side record of whether *we* are the one holding disablesleep, so a
    /// helper restart can tell "LidCode left this on" from "the user set it by hand".
    public static let helperStatePath = "/var/db/lidcode/helper-state.json"

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
