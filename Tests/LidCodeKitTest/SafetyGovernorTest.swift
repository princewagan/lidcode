import XCTest
@testable import LidCodeKit

/// The governor decides whether an overnight run survives, so its rules are tested
/// directly rather than inferred from the app behaving plausibly.
final class SafetyGovernorTest: XCTestCase {
    private let governor = SafetyGovernor(setting: .default)

    private func battery(_ percent: Int?, onMain: Bool = false) -> BatteryReading {
        BatteryReading(percent: percent, isCharging: onMain, isOnMain: onMain)
    }

    func testProceedOnHealthyBatteryAndTemperature() {
        let verdict = governor.evaluate(
            battery: battery(80),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(verdict, .proceed)
    }

    func testSoftFloorReleasesBeforeHardFloorForcesSleep() {
        let soft = governor.evaluate(
            battery: battery(18),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(soft, .release(.batteryFloor))

        let hard = governor.evaluate(
            battery: battery(3),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(hard, .forceSleep(.batteryFloor))
    }

    /// A battery floor must never fire while the Mac is plugged in — that would end
    /// runs on a machine that is charging past the threshold.
    func testBatteryFloorIsIgnoredOnMainPower() {
        let verdict = governor.evaluate(
            battery: battery(3, onMain: true),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(verdict, .proceed)
    }

    /// Critical heat with the lid shut has no airflow, so releasing our own assertion
    /// is not enough — something else holding one would keep the machine cooking.
    ///
    /// Note the asymmetry, which is deliberate and is exactly where the sustained-heat
    /// rule draws its line. A shut lid forces sleep on the *instant* reading: there is
    /// no airflow to recover through, so "wait and see whether it settles" is not an
    /// option that exists. With the lid open there is airflow and the OS is already
    /// throttling, so the same reading goes through the ordinary ceiling — which now
    /// asks for sustained heat rather than a single sample.
    func testCriticalHeatForcesSleepImmediatelyWithLidClosed() {
        XCTAssertEqual(
            governor.evaluate(
                battery: battery(90), thermal: ThermalReading(level: .critical),
                isClamshellActive: true, hotForSecond: 0),
            .forceSleep(.thermalCritical)
        )
    }

    /// With the lid open the same reading is a courtesy release, and it waits out the
    /// sustained window first. An instantaneous check here is what used to end an
    /// eight-hour run over a few seconds of all-core compile.
    func testCriticalHeatWithLidOpenWaitsForSustainedHeat() {
        XCTAssertFalse(
            governor.evaluate(
                battery: battery(90), thermal: ThermalReading(level: .critical),
                isClamshellActive: false, hotForSecond: 10).isStop,
            "ten seconds at critical is a burst, not sustained heat")

        XCTAssertEqual(
            governor.evaluate(
                battery: battery(90), thermal: ThermalReading(level: .critical),
                isClamshellActive: false,
                hotForSecond: Setting.default.sustainedHeatSecond),
            .release(.thermalCritical)
        )
    }

    func testSeriousHeatWarnsWithoutStopping() {
        let verdict = governor.evaluate(
            battery: battery(90),
            thermal: ThermalReading(level: .serious),
            isClamshellActive: true
        )
        XCTAssertFalse(verdict.isStop)
        if case .warn = verdict {} else { XCTFail("expected a warning, got \(verdict)") }
    }

    /// A desktop with no battery reports nil, which must never read as 0%.
    func testMissingBatteryNeverTripsAFloor() {
        let verdict = governor.evaluate(
            battery: battery(nil, onMain: true),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(verdict, .proceed)
    }

    func testChargingOnlyReleasesOnBattery() {
        var setting = Setting.default
        setting.isChargingOnly = true
        let verdict = SafetyGovernor(setting: setting).evaluate(
            battery: battery(90),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: false
        )
        XCTAssertEqual(verdict, .release(.userStopped))
    }

    /// A hand-edited config must not be able to disable a floor by inverting it.
    func testSettingNormalizationKeepsSoftFloorAboveHardFloor() {
        let broken = Setting(
            softBatteryPercent: 2,
            hardBatteryPercent: 99,
            thermalCeiling: .critical,
            idleReleaseSecond: 1,
            isChargingOnly: false,
            watchPattern: []
        ).normalized()

        XCTAssertTrue(Setting.hardBatteryRange.contains(broken.hardBatteryPercent))
        XCTAssertTrue(Setting.softBatteryRange.contains(broken.softBatteryPercent))
        XCTAssertGreaterThan(broken.softBatteryPercent, broken.hardBatteryPercent)
        XCTAssertGreaterThanOrEqual(broken.idleReleaseSecond, 30)
    }
}
