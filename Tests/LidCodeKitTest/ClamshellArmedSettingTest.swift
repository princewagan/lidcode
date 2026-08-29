import XCTest
@testable import LidCodeKit

/// Tests for the two new `Setting` fields added in the clamshell-armed + dim-on-close
/// feature: `isClamshellArmed` and `isDimOnLidCloseOn`.
///
/// The critical invariant being guarded here is the same one that motivated the
/// `decodeIfPresent` rule in `Setting.init(from:)`: adding a field must never silently
/// reset every threshold a user had tuned. These tests say that out loud.
final class ClamshellArmedSettingTest: XCTestCase {

    // MARK: - Defaults

    func testClamshellArmedDefaultsToFalse() {
        XCTAssertFalse(Setting.default.isClamshellArmed,
            "armed intent must not survive a factory default — no session is in flight")
    }

    func testDimOnLidCloseDefaultsToTrue() {
        XCTAssertTrue(Setting.default.isDimOnLidCloseOn,
            "dim-on-close ships enabled so the feature works without a settings visit")
    }

    // MARK: - Decode from a file that predates these fields

    /// A settings file written before `isClamshellArmed` and `isDimOnLidCloseOn` existed.
    /// Every tuned threshold must survive; the two new fields must arrive at their defaults.
    func testOlderFileKeepsTunedValuesAndNewFieldsArrive() throws {
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

        // Existing fields are unchanged.
        XCTAssertEqual(decoded.softBatteryPercent, 35,
            "a missing new key must not reset an already-tuned threshold")
        XCTAssertEqual(decoded.hardBatteryPercent, 6)
        XCTAssertEqual(decoded.thermalCeiling, .serious)
        XCTAssertEqual(decoded.idleReleaseSecond, 1200)
        XCTAssertTrue(decoded.isChargingOnly)
        XCTAssertFalse(decoded.isNetworkProbeOn)

        // New fields arrive at their defaults.
        XCTAssertFalse(decoded.isClamshellArmed)
        XCTAssertTrue(decoded.isDimOnLidCloseOn)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(Setting.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.isClamshellArmed)
        XCTAssertTrue(decoded.isDimOnLidCloseOn)
    }

    // MARK: - Round-trip

    func testBothFieldsRoundTripThroughJson() throws {
        var setting = Setting.default
        setting.isClamshellArmed = true
        setting.isDimOnLidCloseOn = false

        let data = try JSONEncoder().encode(setting)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)

        XCTAssertTrue(decoded.isClamshellArmed)
        XCTAssertFalse(decoded.isDimOnLidCloseOn)
    }

    // MARK: - normalized() leaves the new fields alone

    func testNormalizedDoesNotTouchClamshellArmed() {
        var setting = Setting.default
        setting.isClamshellArmed = true
        XCTAssertTrue(setting.normalized().isClamshellArmed,
            "normalized() must not silently clear the armed flag")
    }

    func testNormalizedDoesNotTouchDimOnLidClose() {
        var setting = Setting.default
        setting.isDimOnLidCloseOn = false
        XCTAssertFalse(setting.normalized().isDimOnLidCloseOn,
            "normalized() must not flip the dim-on-close setting")
    }

    // MARK: - SettingPatch carries isDimOnLidCloseOn

    func testPatchCanSetDimOnLidClose() {
        let patched = SettingPatch(isDimOnLidCloseOn: false).applied(to: .default)
        XCTAssertFalse(patched.isDimOnLidCloseOn)
        // A patch for one field must leave everything else alone.
        XCTAssertEqual(patched.softBatteryPercent, Setting.default.softBatteryPercent)
    }

    func testPatchLeavingDimOnLidCloseNilChangesNothing() {
        let before = Setting.default
        let after = SettingPatch().applied(to: before)
        XCTAssertEqual(after.isDimOnLidCloseOn, before.isDimOnLidCloseOn)
    }

    func testEmptyPatchIsStillEmpty() {
        XCTAssertTrue(SettingPatch().isEmpty)
        XCTAssertFalse(SettingPatch(isDimOnLidCloseOn: true).isEmpty)
    }
}

// MARK: - Brightness-reconcile predicate unit tests

/// Tests the pure predicate that decides whether the display should be dimmed.
///
/// The actual DisplayBrightness calls touch real hardware and are never exercised here.
/// `LidCodeRuntime.shouldDimDisplay` is a public static func that `reconcileBrightnessLocked`
/// calls directly — so these tests exercise the real production decision path, not a copy.
final class BrightnessReconcilePredicateTest: XCTestCase {

    func testDimsOnlyWhenAllConditionsMet() {
        XCTAssertTrue(LidCodeRuntime.shouldDimDisplay(
            isDimOnLidCloseOn: true, isClamshellArmed: true, isHeld: true, lid: .closed))
    }

    func testDoesNotDimWhenSettingOff() {
        XCTAssertFalse(LidCodeRuntime.shouldDimDisplay(
            isDimOnLidCloseOn: false, isClamshellArmed: true, isHeld: true, lid: .closed))
    }

    func testDoesNotDimWhenNotArmed() {
        XCTAssertFalse(LidCodeRuntime.shouldDimDisplay(
            isDimOnLidCloseOn: true, isClamshellArmed: false, isHeld: true, lid: .closed))
    }

    func testDoesNotDimWhenNotHeld() {
        XCTAssertFalse(LidCodeRuntime.shouldDimDisplay(
            isDimOnLidCloseOn: true, isClamshellArmed: true, isHeld: false, lid: .closed))
    }

    func testDoesNotDimWhenLidOpen() {
        XCTAssertFalse(LidCodeRuntime.shouldDimDisplay(
            isDimOnLidCloseOn: true, isClamshellArmed: true, isHeld: true, lid: .open))
    }

    /// `.unknown` must NOT be treated as closed — that is the safety posture documented
    /// on `ClamshellStateReader`: a desktop Mac or an unreadable lid never accidentally
    /// dims the screen.
    func testDoesNotDimWhenLidUnknown() {
        XCTAssertFalse(LidCodeRuntime.shouldDimDisplay(
            isDimOnLidCloseOn: true, isClamshellArmed: true, isHeld: true, lid: .unknown))
    }
}
