import XCTest
@testable import LidCodeKit

/// Coverage for the one thing `decodeIfPresent` cannot do.
///
/// Every field on `Setting` is decoded with a per-key fallback, so a *new* setting picks
/// up its default without disturbing anything the user has tuned. That rule is right, and
/// it has exactly one gap: it cannot correct a default that is already written to disk.
/// When a shipped default turns out to be wrong rather than merely different — the
/// thermal ceiling at `.critical`, which the fifteen-minute sustained rule made
/// unreachable, so the heat guard could never fire — every existing install would keep
/// the broken value forever.
///
/// `settingVersion` plus `migrated()` closes that gap. These tests pin both halves: that
/// the correction happens, and that it is narrow enough not to overwrite a deliberate choice.
final class SettingMigrationTest: XCTestCase {

    /// An unversioned file is the pre-migration format, so it must read as version 1.
    /// Defaulting it to `currentVersion` would be the one mistake that silently skips
    /// every migration there will ever be.
    func testAbsentVersionReadsAsOne() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)
        XCTAssertEqual(decoded.settingVersion, 1)
    }

    /// The correction itself: v1 shipped `.critical`, which could not fire.
    func testCriticalCeilingIsMigratedToSerious() throws {
        let data = Data(#"{"thermalCeiling":"critical"}"#.utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)
        XCTAssertEqual(decoded.thermalCeiling, .critical, "precondition: the old value is on disk")
        XCTAssertEqual(decoded.migrated().thermalCeiling, .serious)
    }

    /// The load-bearing limit on that correction. A user who picked `.fair` deliberately
    /// must keep it — a migration that rewrites every ceiling is not a migration, it is a
    /// reset, and it would throw away the setting on the run it was supposed to protect.
    func testADeliberatelyChosenCeilingSurvives() throws {
        let data = Data(#"{"thermalCeiling":"fair"}"#.utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)
        XCTAssertEqual(decoded.migrated().thermalCeiling, .fair)
    }

    /// Nothing else moves. The migration touches one field; every other value the user
    /// tuned has to come through untouched.
    func testMigrationLeavesEveryOtherFieldAlone() throws {
        let data = Data("""
        {"thermalCeiling":"critical","softBatteryPercent":40,"hardBatteryPercent":7,
         "idleReleaseSecond":1800,"isChargingOnly":true,"holdSecond":5400,
         "isNetworkProbeOn":false,"sustainedHeatSecond":600}
        """.utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)
        let migrated = decoded.migrated()

        XCTAssertEqual(migrated.softBatteryPercent, 40)
        XCTAssertEqual(migrated.hardBatteryPercent, 7)
        XCTAssertEqual(migrated.idleReleaseSecond, 1800)
        XCTAssertTrue(migrated.isChargingOnly)
        XCTAssertEqual(migrated.holdSecond, 5400)
        XCTAssertFalse(migrated.isNetworkProbeOn)
        XCTAssertEqual(migrated.sustainedHeatSecond, 600)
    }

    /// Migrating stamps the current version, which is what stops it running twice.
    func testMigrationStampsTheCurrentVersion() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)
        XCTAssertEqual(decoded.migrated().settingVersion, Setting.currentVersion)
    }

    /// And an already-current file is left completely alone, including a `.critical`
    /// ceiling — by version 2 that value can only be a deliberate choice, because the
    /// migration has already run once on this file.
    func testAnAlreadyMigratedFileIsNotMigratedAgain() throws {
        let data = Data(#"{"settingVersion":2,"thermalCeiling":"critical"}"#.utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)
        XCTAssertEqual(decoded.migrated().thermalCeiling, .critical)
    }

    /// `normalized()` is run on every save, so it has to agree that the file is current
    /// — otherwise a saved file would decode as version 1 and migrate on every launch.
    func testNormalizingStampsTheCurrentVersion() {
        var setting = Setting.default
        setting.settingVersion = 1
        XCTAssertEqual(setting.normalized().settingVersion, Setting.currentVersion)
    }

    // MARK: - The defaults these tests exist to protect

    /// The heat guard has to be reachable. `.critical` sustained for fifteen minutes is a
    /// condition macOS essentially never reports, so the guard read as protection while
    /// doing nothing — the worst possible state for a safety control.
    func testTheDefaultCeilingIsReachable() {
        XCTAssertEqual(Setting.default.thermalCeiling, .serious)
        XCTAssertLessThan(
            Setting.default.thermalCeiling, .critical,
            "a default ceiling at the top of the scale cannot fire before the forced-sleep rule does")
    }

    /// The soft floor sits at the bottom of its own range: it decides how much headroom
    /// is left on top of the hard floor, and a higher value only ends runs that would
    /// have finished.
    func testTheDefaultSoftFloorIsTheBottomOfItsRange() {
        XCTAssertEqual(Setting.default.softBatteryPercent, 15)
        XCTAssertEqual(Setting.default.softBatteryPercent, Setting.softBatteryRange.lowerBound)
        XCTAssertGreaterThan(
            Setting.default.softBatteryPercent, Setting.default.hardBatteryPercent,
            "a soft floor at or below the hard floor silently disables itself")
    }
}
