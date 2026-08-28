import Foundation

public enum SafetyVerdict: Equatable, Sendable {
    /// Nothing to do.
    case proceed
    /// Still safe, but worth surfacing.
    case warn(String)
    /// Drop the hold and let macOS sleep normally.
    case release(StopReason)
    /// Force `pmset sleepnow`. Used only where a normal release is not enough —
    /// a closed lid at critical heat, or the last-resort battery floor.
    case forceSleep(StopReason)

    public var isStop: Bool {
        switch self {
        case .proceed, .warn: return false
        case .release, .forceSleep: return true
        }
    }

    public var reason: StopReason? {
        switch self {
        case .release(let r), .forceSleep(let r): return r
        case .proceed, .warn: return nil
        }
    }
}

/// Pure decision layer: readings in, verdict out. No IOKit, no side effects, so the
/// rules that decide whether an overnight run survives are directly testable.
public struct SafetyGovernor: Sendable {
    public var setting: Setting

    public init(setting: Setting) {
        self.setting = setting.normalized()
    }

    /// Evaluated most-severe first — a hard floor must win over every softer rule.
    ///
    /// - Parameter hotForSecond: how long the machine has been continuously at or above
    ///   `setting.thermalCeiling`, or 0 when it is below it. The accumulator lives in
    ///   `LidCodeRuntime.tick`, not here: this type stays a pure function of its
    ///   arguments, which is the only reason the rules that decide whether an overnight
    ///   run survives are directly testable.
    ///
    /// The two guard flags in `setting` waive rules, and which rules they can reach is
    /// the whole design. The split is the one already encoded in the return type:
    ///
    /// `.release` rules are *courtesy*: sleep while there is still headroom, back off
    /// when warm, stay off battery if asked. Those are the user's call to waive — it is
    /// their Mac and their unfinished job.
    ///
    /// `.forceSleep` rules are not courtesy. The hard battery floor exists so a run
    /// ends in a resumable sleep instead of a hard shutdown, and critical heat behind a
    /// shut lid has no airflow to recover through. Waiving those does not express a
    /// preference, it loses work or cooks hardware — so no toggle reaches them at any
    /// setting. This held for the old timed override and it holds for the guards that
    /// replaced it; the timer was never what made those rules safe.
    public func evaluate(
        battery: BatteryReading,
        thermal: ThermalReading,
        isClamshellActive: Bool,
        hotForSecond: Int = 0
    ) -> SafetyVerdict {
        // 1. Hard battery floor. Forced sleep, not a release: releasing only removes
        //    *our* assertion, and anything else holding one would ride the battery to
        //    a hard shutdown, which is exactly the lost-work case being prevented.
        //
        //    Not reachable by `isBatteryGuardOn`. Deliberately checked before the flag
        //    is ever consulted, so no future edit can accidentally fold it in.
        if battery.isBelow(setting.hardBatteryPercent), !battery.isOnMain {
            return .forceSleep(.batteryFloor)
        }

        // 2. Critical heat with the lid shut: no airflow, so do not merely release.
        //    The forced half is not reachable by `isThermalGuardOn` either, and it is
        //    checked here — above the guard — for the same reason.
        //
        //    Critical heat with the lid *open* is a plain release, which is a courtesy
        //    rule, so it goes through the guard along with the rest of the ceiling.
        if thermal.level >= .critical, isClamshellActive {
            return .forceSleep(.thermalCritical)
        }

        // 3. Soft battery floor — sleep normally while there is still headroom to
        //    write everything out and resume from where the work left off. This is the
        //    one "Override battery health" turns off.
        if setting.isBatteryGuardOn,
           battery.isBelow(setting.softBatteryPercent), !battery.isOnMain {
            return .release(.batteryFloor)
        }

        // 4. Thermal ceiling the user chose, and only once the machine has *stayed*
        //    there for `sustainedHeatSecond`. An instantaneous check ended eight-hour
        //    runs over a few seconds of all-core compile; heat that matters is heat
        //    that persists. Turned off entirely by "Override temperature".
        if setting.isThermalGuardOn,
           thermal.level >= setting.thermalCeiling,
           hotForSecond >= setting.sustainedHeatSecond {
            return .release(.thermalCritical)
        }

        // 5. Charging-only mode.
        if setting.isChargingOnly, !battery.isOnMain {
            return .release(.userStopped)
        }

        // Warnings — the run continues, but the menu bar should say something.
        if thermal.level >= .serious {
            return .warn("Thermal pressure \(thermal.level.display). Check airflow")
        }
        if let percent = battery.percent, !battery.isOnMain,
           percent < setting.softBatteryPercent + 10 {
            return .warn("Battery \(percent)%, will sleep at \(setting.softBatteryPercent)%")
        }
        return .proceed
    }
}
