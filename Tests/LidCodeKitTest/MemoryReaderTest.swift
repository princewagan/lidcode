import XCTest
@testable import LidCodeKit

// MARK: - Swap line parsing

final class SwapLineParsingTest: XCTestCase {

    func testExtractsTotalMegabyte() {
        let line = "total = 2048.00M  used = 998.56M  free = 1049.44M  (encrypted)"
        XCTAssertEqual(MemoryReader.extractMegabyte(label: "total", from: line), 2048.0)
    }

    func testExtractsUsedMegabyte() throws {
        let line = "total = 2048.00M  used = 998.56M  free = 1049.44M  (encrypted)"
        let value = try XCTUnwrap(MemoryReader.extractMegabyte(label: "used", from: line))
        XCTAssertEqual(value, 998.56, accuracy: 0.001)
    }

    func testExtractsFreeMegabyte() throws {
        let line = "total = 2048.00M  used = 998.56M  free = 1049.44M  (encrypted)"
        let value = try XCTUnwrap(MemoryReader.extractMegabyte(label: "free", from: line))
        XCTAssertEqual(value, 1049.44, accuracy: 0.001)
    }

    func testReturnsNilForMissingLabel() {
        let line = "total = 2048.00M  used = 998.56M"
        XCTAssertNil(MemoryReader.extractMegabyte(label: "free", from: line))
    }

    func testReturnsNilForGarbageInput() {
        XCTAssertNil(MemoryReader.extractMegabyte(label: "total", from: "not a swap line"))
    }

    func testHandlesIntegerMegabyteValue() {
        // Machines with exactly round swap sizes sometimes omit the decimal.
        let line = "total = 1024M  used = 512M  free = 512M"
        XCTAssertEqual(MemoryReader.extractMegabyte(label: "total", from: line), 1024.0)
    }
}

// MARK: - Pressure mapping and swap override

final class MemoryPressureLevelTest: XCTestCase {

    // displayLevel returns the kernel pressure when swap is below both thresholds.
    func testKernelNormalAndSwapBelowWarn() {
        let reading = MemoryReading(
            pressure: .normal,
            usedPercent: 30,
            swapUsedMegabyte: 300,
            swapTotalMegabyte: 1000,
            app: [],
            readAt: Date()
        )
        XCTAssertEqual(reading.displayLevel(warnSwapPercent: 50, criticalSwapPercent: 85), .normal)
    }

    // Swap at the warn threshold escalates even when the kernel says normal.
    func testSwapAtWarnThresholdEscalates() {
        let reading = MemoryReading(
            pressure: .normal,
            usedPercent: 50,
            swapUsedMegabyte: 500,
            swapTotalMegabyte: 1000,
            app: [],
            readAt: Date()
        )
        XCTAssertEqual(reading.displayLevel(warnSwapPercent: 50, criticalSwapPercent: 85), .warn)
    }

    // Swap at the critical threshold escalates to critical.
    func testSwapAtCriticalThresholdEscalates() {
        let reading = MemoryReading(
            pressure: .normal,
            usedPercent: 85,
            swapUsedMegabyte: 850,
            swapTotalMegabyte: 1000,
            app: [],
            readAt: Date()
        )
        XCTAssertEqual(reading.displayLevel(warnSwapPercent: 50, criticalSwapPercent: 85), .critical)
    }

    // Kernel already at warn + swap below warn → warn (from kernel).
    func testKernelWarnIsPreservedWhenSwapBelowWarn() {
        let reading = MemoryReading(
            pressure: .warn,
            usedPercent: 20,
            swapUsedMegabyte: 200,
            swapTotalMegabyte: 1000,
            app: [],
            readAt: Date()
        )
        XCTAssertEqual(reading.displayLevel(warnSwapPercent: 50, criticalSwapPercent: 85), .warn)
    }

    // Kernel at warn, swap at critical → critical wins (max).
    func testSwapCriticalBeatsKernelWarn() {
        let reading = MemoryReading(
            pressure: .warn,
            usedPercent: 90,
            swapUsedMegabyte: 900,
            swapTotalMegabyte: 1000,
            app: [],
            readAt: Date()
        )
        XCTAssertEqual(reading.displayLevel(warnSwapPercent: 50, criticalSwapPercent: 85), .critical)
    }

    // swapTotal == 0 must not divide by zero; swap-derived level stays .normal.
    func testSwapTotalZeroGuard() {
        let reading = MemoryReading(
            pressure: .normal,
            usedPercent: 0,
            swapUsedMegabyte: 0,
            swapTotalMegabyte: 0,
            app: [],
            readAt: Date()
        )
        XCTAssertEqual(reading.displayLevel(warnSwapPercent: 50, criticalSwapPercent: 85), .normal)
    }

    // swapTotal == 0 with kernel critical still returns critical.
    func testSwapTotalZeroWithKernelCritical() {
        let reading = MemoryReading(
            pressure: .critical,
            usedPercent: 0,
            swapUsedMegabyte: 0,
            swapTotalMegabyte: 0,
            app: [],
            readAt: Date()
        )
        XCTAssertEqual(reading.displayLevel(warnSwapPercent: 50, criticalSwapPercent: 85), .critical)
    }
}

// MARK: - App name parsing and claude/claude.exe merge

final class AppNameParsingTest: XCTestCase {

    func testClaudeLowercaseMapsToCanonical() {
        XCTAssertEqual(MemoryReader.appName(from: "claude"), "Claude")
    }

    func testClaudeExeMapsToCanonical() {
        XCTAssertEqual(MemoryReader.appName(from: "claude.exe"), "Claude")
    }

    func testClaudeUppercaseMapsToCanonical() {
        // Not expected in practice but defensive.
        XCTAssertEqual(MemoryReader.appName(from: "Claude"), "Claude")
    }

    func testBraveBrowserFullPath() {
        let path = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        XCTAssertEqual(MemoryReader.appName(from: path), "Brave Browser")
    }

    func testXcodeFullPath() {
        XCTAssertEqual(MemoryReader.appName(from: "/Applications/Xcode.app/Contents/MacOS/Xcode"), "Xcode")
    }

    func testBareBinaryName() {
        XCTAssertEqual(MemoryReader.appName(from: "launchd"), "launchd")
    }

    func testAbsoluteBareBinaryPath() {
        XCTAssertEqual(MemoryReader.appName(from: "/usr/bin/swift"), "swift")
    }

    /// `claude` and `claude.exe` processes must collapse into a single row.
    func testClaudeAndClaudeExeMerge() {
        let psOutput = """
        RSS COMM
        102400 claude
        51200 claude.exe
        """
        let apps = MemoryReader.parseApps(from: psOutput)
        let claude = apps.first { $0.name == "Claude" }
        XCTAssertNotNil(claude)
        // 102400 + 51200 KB = 150 MB
        XCTAssertEqual(claude?.megabyte ?? 0, 150, accuracy: 0.1)
        XCTAssertEqual(claude?.count, 2)
        // No separate "claude" or "claude.exe" row.
        XCTAssertNil(apps.first { $0.name == "claude" })
        XCTAssertNil(apps.first { $0.name == "claude.exe" })
    }

    /// App rows must be sorted descending by megabyte.
    func testAppsAreSortedDescending() {
        let psOutput = """
        10240 small
        102400 large
        51200 medium
        """
        let apps = MemoryReader.parseApps(from: psOutput)
        XCTAssertEqual(apps.map(\.name), ["large", "medium", "small"])
    }

    func testHeaderLineIsSkipped() {
        // ps always starts with a header; it must not parse as a process.
        let psOutput = "  RSS COMM\n102400 launchd"
        let apps = MemoryReader.parseApps(from: psOutput)
        // "launchd" should appear but not "COMM".
        XCTAssertNil(apps.first { $0.name == "COMM" })
    }
}

// MARK: - Setting normalization: critical > warn

final class MemorySettingNormalizationTest: XCTestCase {

    func testCriticalIsKeptAboveWarnWhenValid() {
        var s = Setting.default
        s.memoryWarnSwapPercent = 50
        s.memoryCriticalSwapPercent = 85
        let n = s.normalized()
        XCTAssertGreaterThan(n.memoryCriticalSwapPercent, n.memoryWarnSwapPercent)
    }

    func testCriticalEqualToWarnIsFixed() {
        var s = Setting.default
        s.memoryWarnSwapPercent = 60
        s.memoryCriticalSwapPercent = 60
        let n = s.normalized()
        XCTAssertGreaterThan(n.memoryCriticalSwapPercent, n.memoryWarnSwapPercent)
    }

    func testCriticalBelowWarnIsFixed() {
        var s = Setting.default
        s.memoryWarnSwapPercent = 80
        s.memoryCriticalSwapPercent = 30   // invalid: below warn
        let n = s.normalized()
        XCTAssertGreaterThan(n.memoryCriticalSwapPercent, n.memoryWarnSwapPercent)
    }

    func testWarnClampedToRange() {
        var s = Setting.default
        s.memoryWarnSwapPercent = 0   // below minimum of 10
        let n = s.normalized()
        XCTAssertGreaterThanOrEqual(n.memoryWarnSwapPercent, Setting.memoryWarnSwapRange.lowerBound)
    }

    func testCriticalClampedToRange() {
        var s = Setting.default
        s.memoryCriticalSwapPercent = 100   // above maximum of 99
        let n = s.normalized()
        XCTAssertLessThanOrEqual(n.memoryCriticalSwapPercent, Setting.memoryCriticalSwapRange.upperBound)
    }

    func testAppRowCountClampedToRange() {
        var s = Setting.default
        s.memoryAppRowCount = 0   // below minimum of 3
        let n = s.normalized()
        XCTAssertGreaterThanOrEqual(n.memoryAppRowCount, Setting.memoryAppRowRange.lowerBound)
        s.memoryAppRowCount = 99
        XCTAssertLessThanOrEqual(s.normalized().memoryAppRowCount, Setting.memoryAppRowRange.upperBound)
    }
}

// MARK: - SettingPatch round-trip

final class MemorySettingPatchTest: XCTestCase {

    func testPatchAppliesMemoryFields() {
        let base = Setting.default
        let patch = SettingPatch(
            isMemoryWarningOn: false,
            memoryWarnSwapPercent: 40,
            memoryCriticalSwapPercent: 80,
            memoryAppRowCount: 7
        )
        let result = patch.applied(to: base)
        XCTAssertFalse(result.isMemoryWarningOn)
        XCTAssertEqual(result.memoryWarnSwapPercent, 40)
        XCTAssertEqual(result.memoryCriticalSwapPercent, 80)
        XCTAssertEqual(result.memoryAppRowCount, 7)
    }

    func testPatchIsEmptyWhenNoMemoryFields() {
        let patch = SettingPatch()
        XCTAssertTrue(patch.isEmpty)
    }

    func testPatchIsNotEmptyWhenMemoryFieldSet() {
        let patch = SettingPatch(isMemoryWarningOn: false)
        XCTAssertFalse(patch.isEmpty)
    }

    func testPartialPatchLeavesOtherFieldsUntouched() {
        var base = Setting.default
        base.memoryWarnSwapPercent = 55
        let patch = SettingPatch(memoryCriticalSwapPercent: 90)
        let result = patch.applied(to: base)
        // Warn percent must survive unchanged (90 > 55 so no normalization clash).
        XCTAssertEqual(result.memoryWarnSwapPercent, 55)
        XCTAssertEqual(result.memoryCriticalSwapPercent, 90)
    }

    func testPatchRoundTrip() throws {
        let patch = SettingPatch(
            isMemoryWarningOn: true,
            memoryWarnSwapPercent: 45,
            memoryCriticalSwapPercent: 88,
            memoryAppRowCount: 6
        )
        let data = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(SettingPatch.self, from: data)
        XCTAssertEqual(decoded.isMemoryWarningOn, true)
        XCTAssertEqual(decoded.memoryWarnSwapPercent, 45)
        XCTAssertEqual(decoded.memoryCriticalSwapPercent, 88)
        XCTAssertEqual(decoded.memoryAppRowCount, 6)
    }
}

// MARK: - Decoding OLD JSON without memory fields

final class MemorySettingBackwardCompatTest: XCTestCase {

    /// A settings file written before memory monitoring existed must decode cleanly
    /// and pick up the shipped defaults for every new field.
    func testOldSettingsJsonLoadsWithDefaults() throws {
        let json = """
        {
          "softBatteryPercent": 20,
          "hardBatteryPercent": 5,
          "thermalCeiling": "serious",
          "idleReleaseSecond": 600,
          "isChargingOnly": false,
          "watchPattern": ["claude"],
          "settingVersion": 2
        }
        """.data(using: .utf8)!

        let setting = try JSONDecoder().decode(Setting.self, from: json)
        XCTAssertEqual(setting.isMemoryWarningOn, Setting.default.isMemoryWarningOn)
        XCTAssertEqual(setting.memoryWarnSwapPercent, Setting.default.memoryWarnSwapPercent)
        XCTAssertEqual(setting.memoryCriticalSwapPercent, Setting.default.memoryCriticalSwapPercent)
        XCTAssertEqual(setting.memoryAppRowCount, Setting.default.memoryAppRowCount)
    }

    /// A RuntimeSnapshot written before the `memory` field existed must decode cleanly
    /// with memory == nil.
    func testOldSnapshotJsonLoadsWithNilMemory() throws {
        let json = """
        {
          "isAwakeHeld": false,
          "isAssertionActive": false,
          "isClamshellActive": false,
          "mode": "smart",
          "activeLease": [],
          "battery": {"isCharging": false, "isOnMain": false},
          "thermal": {"level": "nominal"},
          "isAutoWatchOn": true,
          "isUserPaused": false,
          "agentSession": {"sessions": [], "activeCount": 0, "blockedCount": 0, "errorCount": 0},
          "physicalLid": {"state": "open", "readAt": "2024-01-01T00:00:00Z", "isStale": false},
          "foreignBlockerCount": 0,
          "isStalled": false,
          "isGuardOverrideOn": false,
          "isClamshellArmed": false
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RuntimeSnapshot.self, from: json)
        XCTAssertNil(snapshot.memory)
    }
}

/// Chromium browsers hide their real weight in helper processes. Naming a row the
/// user cannot act on is the same as not showing it.
final class MemoryHelperMergeTest: XCTestCase {
    func testRendererHelperFoldsIntoTheParentApp() {
        XCTAssertEqual(
            MemoryReader.appName(from: "Brave Browser Helper (Renderer)"),
            "Brave Browser")
    }

    func testGpuAndPluginHelpersFoldToo() {
        XCTAssertEqual(MemoryReader.appName(from: "Brave Browser Helper (GPU)"), "Brave Browser")
        XCTAssertEqual(MemoryReader.appName(from: "Google Chrome Helper"), "Google Chrome")
    }

    func testHelperInsideABundlePathAlsoFolds() {
        XCTAssertEqual(
            MemoryReader.appName(
                from: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"),
            "Brave Browser")
    }

    func testAnAppWhoseNameContainsHelperIsNotTruncatedWrongly() {
        // No " Helper" boundary, so nothing to fold.
        XCTAssertEqual(MemoryReader.appName(from: "Helperific"), "Helperific")
    }

    func testOrdinaryNamesAreUntouched() {
        XCTAssertEqual(MemoryReader.appName(from: "Brave Browser"), "Brave Browser")
        XCTAssertEqual(MemoryReader.appName(from: "claude.exe"), "Claude")
    }
}

final class PhysicalMemoryReadingTest: XCTestCase {
    func testReadsPhysicalMemoryWithoutDependingOnSwapCapacity() throws {
        let percent = try XCTUnwrap(MemoryReader.readMemoryPercent())
        XCTAssertTrue(percent.isFinite)
        XCTAssertGreaterThan(percent, 0)
        XCTAssertLessThanOrEqual(percent, 100)
    }
}
