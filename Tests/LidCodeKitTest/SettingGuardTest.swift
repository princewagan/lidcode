import XCTest
@testable import LidCodeKit

/// The fields that back the two guard buttons and the duration slider.
///
/// The decoding half is the one with a bug waiting in it: synthesized `Codable` fails
/// the whole decode when one key is missing, and `Setting.load()` swallows that into
/// `.default` — so adding a field the naive way silently resets every threshold the
/// user had tuned. Every field added from here on is read with `decodeIfPresent`, and
/// these tests are what says so out loud.
final class SettingGuardTest: XCTestCase {
    // MARK: - Defaults

    func testBothGuardsShipOn() {
        XCTAssertTrue(Setting.default.isBatteryGuardOn)
        XCTAssertTrue(Setting.default.isThermalGuardOn)
    }

    func testDefaultsMatchTheContract() {
        XCTAssertEqual(Setting.default.sustainedHeatSecond, 900)
        // J6: max changed from 8h to 3h — default holdSecond is now 3h.
        XCTAssertEqual(Setting.default.holdSecond, 3 * 3600)
    }

    func testDefaultIsAlreadyNormalized() {
        XCTAssertEqual(Setting.default.normalized(), Setting.default)
    }

    // MARK: - Decoding an older file

    /// A settings file written before these fields existed. Every tuned threshold in it
    /// has to survive, and the new fields have to arrive at their defaults.
    func testOlderFileKeepsItsTunedValues() throws {
        let data = Data("""
        {
          "softBatteryPercent": 35,
          "hardBatteryPercent": 6,
          "thermalCeiling": "serious",
          "idleReleaseSecond": 1200,
          "isChargingOnly": true,
          "isNetworkProbeOn": false,
          "watchPattern": ["claude", "cargo"]
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)

        XCTAssertEqual(decoded.softBatteryPercent, 35, "a missing new key must not reset an old one")
        XCTAssertEqual(decoded.hardBatteryPercent, 6)
        XCTAssertEqual(decoded.thermalCeiling, .serious)
        XCTAssertEqual(decoded.idleReleaseSecond, 1200)
        XCTAssertTrue(decoded.isChargingOnly)
        XCTAssertFalse(decoded.isNetworkProbeOn)
        XCTAssertEqual(decoded.watchPattern, ["claude", "cargo"])

        XCTAssertTrue(decoded.isBatteryGuardOn)
        XCTAssertTrue(decoded.isThermalGuardOn)
        XCTAssertEqual(decoded.sustainedHeatSecond, 900)
        // J6: max changed to 3h — an older file without holdSecond gets the new default.
        XCTAssertEqual(decoded.holdSecond, 3 * 3600)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(Setting.self, from: Data("{}".utf8))
        // Every field falls back to its default — except `settingVersion`, which reads a
        // file with no version key as the pre-versioning format so `migrated()` still
        // runs. Expressed as an expected value rather than by dropping the field from
        // the comparison, so the other twenty stay under full equality.
        var expected = Setting.default
        expected.settingVersion = 1
        XCTAssertEqual(decoded, expected)
    }

    func testRoundTripsThroughJson() throws {
        var setting = Setting.default
        setting.isBatteryGuardOn = false
        setting.isThermalGuardOn = false
        setting.sustainedHeatSecond = 300
        setting.holdSecond = 5400

        let data = try JSONEncoder().encode(setting)
        XCTAssertEqual(try JSONDecoder().decode(Setting.self, from: data), setting)
    }

    // MARK: - Clamping

    func testHoldSecondIsClampedToTheRange() {
        XCTAssertEqual(clampedHold(0), Setting.holdRange.lowerBound)
        XCTAssertEqual(clampedHold(60), Setting.holdRange.lowerBound)
        XCTAssertEqual(clampedHold(-5000), Setting.holdRange.lowerBound)
        XCTAssertEqual(clampedHold(99 * 3600), Setting.holdRange.upperBound)
    }

    func testHoldSecondSnapsToHalfHours() {
        XCTAssertEqual(clampedHold(3600), 3600)
        XCTAssertEqual(clampedHold(3700), 3600, "rounds down to the nearer step")
        XCTAssertEqual(clampedHold(5340), 5400, "rounds up to the nearer step")
        // Range updated to 3h max (J6).
        for second in stride(from: 1800, through: 10800, by: 137) {
            XCTAssertEqual(
                clampedHold(second) % Setting.holdStepSecond, 0,
                "\(second) did not land on the grid")
        }
    }

    func testSustainedHeatIsClamped() {
        XCTAssertEqual(clampedHeat(0), Setting.sustainedHeatRange.lowerBound)
        XCTAssertEqual(clampedHeat(30), Setting.sustainedHeatRange.lowerBound)
        XCTAssertEqual(clampedHeat(99_999), Setting.sustainedHeatRange.upperBound)
        XCTAssertEqual(clampedHeat(900), 900, "the default is inside the range untouched")
    }

    /// A hand-edited file gets the same protection as the UI, which is the reason the
    /// clamp lives in `normalized()` rather than in a picker.
    func testHandEditedFileIsClampedOnDecode() throws {
        let data = Data(#"{"holdSecond": 99999999, "sustainedHeatSecond": 1}"#.utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data).normalized()
        XCTAssertEqual(decoded.holdSecond, Setting.holdRange.upperBound)
        XCTAssertEqual(decoded.sustainedHeatSecond, Setting.sustainedHeatRange.lowerBound)
    }

    // MARK: - Patching

    func testPatchCarriesEveryNewField() {
        let patched = SettingPatch(
            isBatteryGuardOn: false,
            isThermalGuardOn: false,
            sustainedHeatSecond: 120,
            holdSecond: 3600
        ).applied(to: .default)

        XCTAssertFalse(patched.isBatteryGuardOn)
        XCTAssertFalse(patched.isThermalGuardOn)
        XCTAssertEqual(patched.sustainedHeatSecond, 120)
        XCTAssertEqual(patched.holdSecond, 3600)
    }

    /// The whole reason `SettingPatch` exists: one flag must not reset the rest.
    func testPatchingOneGuardLeavesEverythingElseAlone() {
        var base = Setting.default
        base.softBatteryPercent = 35
        base.holdSecond = 3600

        let patched = SettingPatch(isThermalGuardOn: false).applied(to: base)
        XCTAssertFalse(patched.isThermalGuardOn)
        XCTAssertTrue(patched.isBatteryGuardOn)
        XCTAssertEqual(patched.softBatteryPercent, 35)
        XCTAssertEqual(patched.holdSecond, 3600)
    }

    func testEmptyPatchIsStillReportedEmpty() {
        XCTAssertTrue(SettingPatch().isEmpty)
        XCTAssertFalse(SettingPatch(holdSecond: 3600).isEmpty)
        XCTAssertFalse(SettingPatch(isBatteryGuardOn: false).isEmpty)
        XCTAssertFalse(SettingPatch(isThermalGuardOn: false).isEmpty)
        XCTAssertFalse(SettingPatch(sustainedHeatSecond: 60).isEmpty)
    }

    private func clampedHold(_ second: Int) -> Int {
        var setting = Setting.default
        setting.holdSecond = second
        return setting.normalized().holdSecond
    }

    private func clampedHeat(_ second: Int) -> Int {
        var setting = Setting.default
        setting.sustainedHeatSecond = second
        return setting.normalized().sustainedHeatSecond
    }
}
