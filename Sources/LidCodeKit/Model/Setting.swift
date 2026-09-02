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
    /// The deadline of the most-recently started timed hold, persisted so that
    /// an app restart mid-hold continues from the original expiry rather than
    /// giving the user a fresh 6-hour window. Cleared when the hold ends.
    ///
    /// `LidCodeRuntime.start()` reads this on launch; `stopLocked` clears it;
    /// `beginHoldLocked` writes it whenever a new expiry is computed.
    public var activeHoldExpiresAt: Date?

    // ── Menu bar icon visibility toggles (I1, I2) ──────────────────────────────
    // All default to true. Each hides its corresponding element from the menu bar.
    // Persisted with decodeIfPresent so existing settings files continue to load.

    /// Show the main state icon (bolt/slash/laptop) in the menu bar.
    public var menuBarShowStateIcon: Bool
    /// Show the active-sessions count badge (blue circle) in the menu bar.
    public var menuBarShowActiveBadge: Bool
    /// Show the blocked-sessions count badge (yellow circle) in the menu bar.
    public var menuBarShowBlockedBadge: Bool
    /// Show the errored-sessions count badge (red circle) in the menu bar.
    public var menuBarShowErrorBadge: Bool
    /// Show the non-blocking temperature warning icon (orange thermometer) in the menu bar.
    public var menuBarShowTempWarnIcon: Bool
    /// Show the blocking guard alert icon (red thermometer / red battery) in the menu bar.
    public var menuBarShowAlertIcon: Bool

    /// Whether the user has closed-lid protection armed. Restored on launch only
    /// alongside a still-live `activeHoldExpiresAt`, so it can never outlive the
    /// session the user actually asked for.
    public var isClamshellArmed: Bool

    /// Dim the built-in display to minimum while the lid is shut and closed-lid
    /// protection is armed. Restored to the previous level when the lid opens.
    public var isDimOnLidCloseOn: Bool

    /// Which generation of defaults this file was written against.
    ///
    /// Every other field here is read with `decodeIfPresent` so a *new* setting picks up
    /// its default without disturbing anything the user tuned. That rule is right, and it
    /// has one gap: it cannot change a default that is already on disk. When a shipped
    /// default turns out to be wrong rather than merely different — the thermal ceiling
    /// at `.critical`, which made the heat guard unreachable — leaving it alone means
    /// every existing install keeps the broken value forever.
    ///
    /// So a version number, bumped only when a default must be corrected in place, and a
    /// migration in `load()` that runs once. See `migrated()`.
    public var settingVersion: Int

    /// Bump this, and add a case to `migrated()`, when a shipped default has to change
    /// for people who already have a settings file.
    public static let currentVersion = 2

    public static let softBatteryRange = 15...50
    public static let hardBatteryRange = 4...8
    /// Changed from 8h to 6h so the slider's intervals are better spaced (J6).
    public static let maxSessionSecond = 6 * 3600
    /// Half an hour to six hours (J6). The lower bound is not a UI nicety — a hold
    /// shorter than the health sweep's own cadence would expire before the panel had
    /// anything true to say about it.
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
        // 15%, the bottom of `softBatteryRange`. Higher floors end overnight runs that
        // would have finished, and the hard floor at 4% is the one that exists to protect
        // the work — this one only decides how much headroom is left on top of it.
        softBatteryPercent: 15,
        hardBatteryPercent: 4,
        // `.serious`, not `.critical`.
        //
        // A ceiling of `.critical` combined with the fifteen-minute sustained rule made
        // the heat guard unreachable in practice: macOS reports `critical` thermal
        // pressure only when it is already throttling hard, and almost never holds it
        // there for a quarter of an hour. So the toggle said "Stop when hot" and, on a
        // machine that was genuinely hot for an hour, did nothing — which is the worst
        // possible state for a safety control, because it reads as protection.
        // `.serious` sustained for fifteen minutes is a real condition with a real stop
        // behind it, and a brief all-core burst still cannot trip it.
        thermalCeiling: .serious,
        idleReleaseSecond: 600,
        isChargingOnly: false,
        // Only task-shaped processes — things that start, do work, and exit.
        //
        // Server-shaped tools are deliberately absent: `ollama serve`, the Docker
        // Desktop backend, colima and a `vite` dev server all run for as long as
        // they are installed and open, so watching them by name would hold the Mac
        // awake permanently on an idle machine. Those cases belong to `lidcode claim`,
        // where the thing doing the work says when it starts and stops.
        // Narrowed to agent-shaped binaries only (plan step 1.2 / BUG 5).
        // Process presence alone no longer satisfies the keep-awake predicate —
        // that role belongs to the session state machine in AgentSessionReader.
        // The remaining six entries are genuine AI-agent binaries that start,
        // do real work, and exit — they have no daemon/idle form.
        watchPattern: [
            "claude", "codex", "cursor-agent", "aider",
            "xcodebuild", "swift-frontend",
        ],
        isNetworkProbeOn: true,
        // Both guards ship on. The whole safety argument collapses if the guardrail is
        // the part you have to remember to switch on.
        isBatteryGuardOn: true,
        isThermalGuardOn: true,
        sustainedHeatSecond: 900,
        holdSecond: 6 * 3600,
        // All menu bar icons default to visible (I2).
        menuBarShowStateIcon: true,
        menuBarShowActiveBadge: true,
        menuBarShowBlockedBadge: true,
        menuBarShowErrorBadge: true,
        menuBarShowTempWarnIcon: true,
        menuBarShowAlertIcon: true,
        isClamshellArmed: false,
        isDimOnLidCloseOn: true,
        settingVersion: currentVersion
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
        holdSecond: Int = 6 * 3600,
        activeHoldExpiresAt: Date? = nil,
        menuBarShowStateIcon: Bool = true,
        menuBarShowActiveBadge: Bool = true,
        menuBarShowBlockedBadge: Bool = true,
        menuBarShowErrorBadge: Bool = true,
        menuBarShowTempWarnIcon: Bool = true,
        menuBarShowAlertIcon: Bool = true,
        isClamshellArmed: Bool = false,
        isDimOnLidCloseOn: Bool = true,
        settingVersion: Int = Setting.currentVersion
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
        self.activeHoldExpiresAt = activeHoldExpiresAt
        self.menuBarShowStateIcon = menuBarShowStateIcon
        self.menuBarShowActiveBadge = menuBarShowActiveBadge
        self.menuBarShowBlockedBadge = menuBarShowBlockedBadge
        self.menuBarShowErrorBadge = menuBarShowErrorBadge
        self.menuBarShowTempWarnIcon = menuBarShowTempWarnIcon
        self.menuBarShowAlertIcon = menuBarShowAlertIcon
        self.isClamshellArmed = isClamshellArmed
        self.isDimOnLidCloseOn = isDimOnLidCloseOn
        self.settingVersion = settingVersion
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
        activeHoldExpiresAt = try container.decodeIfPresent(Date.self, forKey: .activeHoldExpiresAt)
        menuBarShowStateIcon = try container.decodeIfPresent(Bool.self, forKey: .menuBarShowStateIcon)
            ?? fallback.menuBarShowStateIcon
        menuBarShowActiveBadge = try container.decodeIfPresent(Bool.self, forKey: .menuBarShowActiveBadge)
            ?? fallback.menuBarShowActiveBadge
        menuBarShowBlockedBadge = try container.decodeIfPresent(Bool.self, forKey: .menuBarShowBlockedBadge)
            ?? fallback.menuBarShowBlockedBadge
        menuBarShowErrorBadge = try container.decodeIfPresent(Bool.self, forKey: .menuBarShowErrorBadge)
            ?? fallback.menuBarShowErrorBadge
        menuBarShowTempWarnIcon = try container.decodeIfPresent(Bool.self, forKey: .menuBarShowTempWarnIcon)
            ?? fallback.menuBarShowTempWarnIcon
        menuBarShowAlertIcon = try container.decodeIfPresent(Bool.self, forKey: .menuBarShowAlertIcon)
            ?? fallback.menuBarShowAlertIcon
        isClamshellArmed = try container.decodeIfPresent(Bool.self, forKey: .isClamshellArmed)
            ?? fallback.isClamshellArmed
        isDimOnLidCloseOn = try container.decodeIfPresent(Bool.self, forKey: .isDimOnLidCloseOn)
            ?? fallback.isDimOnLidCloseOn
        // Absent means version 1 — the format before the field existed. Not `currentVersion`:
        // defaulting an unversioned file to "already current" would skip every migration.
        settingVersion = try container.decodeIfPresent(Int.self, forKey: .settingVersion) ?? 1
    }

    /// Bring an older settings file up to the current generation of defaults.
    ///
    /// Applied once, in `load()`, before `normalized()`. Each step is deliberately narrow:
    /// it corrects the specific value that shipped wrong and touches nothing else, so a
    /// user who tuned a threshold keeps it.
    func migrated() -> Setting {
        var copy = self
        if copy.settingVersion < 2 {
            // v1 shipped `thermalCeiling = .critical`, which the fifteen-minute sustained
            // rule made effectively unreachable — the heat guard could not fire. Only the
            // old default is moved; anyone who had picked `.fair` deliberately keeps it.
            if copy.thermalCeiling == .critical { copy.thermalCeiling = .serious }
        }
        copy.settingVersion = Setting.currentVersion
        return copy
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
        // Clamp to 6h max (J6): any persisted value above 6h is brought down.
        copy.holdSecond = Self.snappedHold(holdSecond)
        // Anything that has been through here is, by definition, in the current shape.
        copy.settingVersion = Setting.currentVersion
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
        // Migrate before normalising: `normalized()` stamps the current version, so
        // running it first would erase the evidence that a migration was owed.
        return decoded.migrated().normalized()
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

/// Written atomically when we dim the built-in display, deleted when we restore.
///
/// If the app crashes or is force-quit between dim and restore, `LidCodeRuntime.start()`
/// reads this on the next launch and puts brightness back immediately — before any tick
/// can dim again. Without this, a crash strands the user with a black screen that
/// survives reboots until they manually raise brightness.
public struct BrightnessRestorePoint: Codable, Sendable {
    /// The brightness level to restore, 0.0–1.0.
    public var level: Float
    /// When the dimming happened, for diagnostic logging.
    public var savedAt: Date

    public init(level: Float, savedAt: Date) {
        self.level = level
        self.savedAt = savedAt
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

    /// Crash-safe brightness restore record. Written atomically the moment we dim,
    /// deleted the moment we restore. If it exists at launch, a previous run was
    /// interrupted before it could put brightness back — we restore immediately.
    public static var brightnessRestore: URL {
        supportDirectory.appendingPathComponent("brightness-restore.json")
    }

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
