import XCTest
@testable import LidCodeKit

/// Derived rather than hardcoded: these tests are about the bands either side of the
/// soft battery floor, not about any particular percentage, and hardcoding the number is
/// what broke them when the shipped default moved.
///
/// The bands are the governor's own, from `SafetyGovernor.evaluate`: below `floor` is a
/// release, `floor` through `floor + 9` is the warn band, and `floor + 10` upwards is
/// `.proceed` — the only verdict that lifts the safety lock.
private let floor = Setting.default.softBatteryPercent

/// Regression coverage for the flap: the soft battery floor released the hold, and
/// auto-watch re-acquired it ~10s later because the watched processes were obviously
/// still running — so the floor never actually let the Mac sleep. Observed live as the
/// lease count oscillating 0 ↔ 5 with "Battery crossed the floor after 4s" repeating in
/// the log every few seconds.
///
/// The rule that fixes it lives in the governor's own output, so it can be tested
/// there: a release must not be followed by a `.proceed` until conditions have
/// genuinely recovered, or the lock would lift straight back into the same release.
final class SafetyHysteresisTest: XCTestCase {
    private let setting = Setting.default          // soft floor, hard 4
    private var governor: SafetyGovernor { SafetyGovernor(setting: setting) }

    private func battery(_ percent: Int, isOnMain: Bool = false) -> BatteryReading {
        BatteryReading(percent: percent, isCharging: isOnMain, isOnMain: isOnMain)
    }

    private func verdict(_ percent: Int, isOnMain: Bool = false) -> SafetyVerdict {
        governor.evaluate(
            battery: battery(percent, isOnMain: isOnMain),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: false)
    }

    func testBelowSoftFloorReleases() {
        XCTAssertEqual(verdict(floor - 5), .release(.batteryFloor))
    }

    /// The load-bearing assertion. One point above the floor is *not* `.proceed`, so a
    /// lock cleared only on `.proceed` cannot re-arm at 21% and drop again at 19%.
    func testJustAboveTheFloorDoesNotReadAsRecovered() {
        for percent in floor...(floor + 9) {
            XCTAssertNotEqual(
                verdict(percent), .proceed,
                "\(percent)% is inside the warn band; treating it as recovered re-creates the flap")
        }
    }

    /// Ten points of clearance is what the governor's warn band already gives us, and
    /// it is where the lock is allowed to lift.
    func testWellClearOfTheFloorRecovers() {
        XCTAssertEqual(verdict(floor + 10), .proceed)
        XCTAssertEqual(verdict(80), .proceed)
    }

    /// Plugging in is the other recovery path, and it must work at any charge.
    func testMainsPowerRecoversImmediately() {
        XCTAssertEqual(verdict(5, isOnMain: true), .proceed)
        XCTAssertEqual(verdict(floor - 1, isOnMain: true), .proceed)
    }

    /// The hard floor is a forced sleep, never a plain release — releasing only drops
    /// LidCode's own assertion and anything else holding one rides the battery to a hard
    /// shutdown.
    func testHardFloorForcesSleep() {
        XCTAssertEqual(verdict(3), .forceSleep(.batteryFloor))
    }

    func testHotMachineIsNotRecovered() {
        let hot = governor.evaluate(
            battery: battery(90, isOnMain: true),
            thermal: ThermalReading(level: .serious),
            isClamshellActive: false)
        XCTAssertNotEqual(hot, .proceed, "still hot — a lock must not lift here")
    }

    func testCoolMachineOnMainsIsRecovered() {
        let cool = governor.evaluate(
            battery: battery(90, isOnMain: true),
            thermal: ThermalReading(level: .fair),
            isClamshellActive: false)
        XCTAssertEqual(cool, .proceed)
    }
}

/// The bug itself, at the level it actually lived: the interaction between the
/// governor, the process watcher and the hold. None of the three is wrong on its own,
/// which is why this needed the whole loop to reproduce.
final class SafetyLockTest: XCTestCase {
    /// Mutable so a test can move the battery under a running runtime.
    private final class Power: @unchecked Sendable {
        let lock = NSLock()
        private var _battery = BatteryReading(percent: 50, isCharging: false, isOnMain: false)
        var battery: BatteryReading {
            get { lock.lock(); defer { lock.unlock() }; return _battery }
            set { lock.lock(); _battery = newValue; lock.unlock() }
        }
        var thermal = ThermalReading(level: .nominal)
    }

    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidcode-test-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    private func makeRuntime(_ power: Power) -> LidCodeRuntime {
        LidCodeRuntime(
            setting: .default,                       // soft floor, hard 4
            log: ActivityLog(url: logUrl),
            battery: { power.battery },
            thermal: { power.thermal })
    }

    /// Helper: make a synthetic AgentSessionSnapshot with one running session for tests
    /// that need to establish a hold (since the new predicate requires activeCount > 0).
    private func runningSession() -> AgentSessionSnapshot {
        let info = AgentSessionInfo(
            id: "test-session", agent: "claude", cwd: "/tmp/test",
            project: "test", title: "Test session", titleSource: "cwd-basename",
            status: .running, lastEvent: "tool_complete",
            lastSeenAt: Date(), statusChangedAt: Date())
        return AgentSessionSnapshot(sessions: [info])
    }

    /// The exact sequence seen live: hold, drop below the floor, release — and then the
    /// watcher reports the same still-running processes and must **not** re-acquire.
    func testAutoWatchDoesNotReArmAfterASafetyRelease() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        // The new predicate requires an active session (activeCount > 0) to hold.
        // Inject a running session alongside the process scan.
        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["claude", "npm"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "a healthy battery should hold normally")

        power.battery = BatteryReading(percent: floor - 5, isCharging: false, isOnMain: false)
        runtime.tickForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "below the soft floor, the hold must drop")
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)

        // The processes are obviously still running — releasing the Mac did not kill
        // them. This scan is what used to re-acquire the hold ~10s after every stop.
        runtime.applyScanForTest(["claude", "npm"])
        XCTAssertFalse(
            runtime.snapshot.isAwakeHeld,
            "re-arming here is the 0↔5 flap: release, re-acquire, release, forever")
    }

    /// Repeated scans must stay refused, not just the first one.
    func testRepeatedScanStayRefused() {
        let power = Power()
        power.battery = BatteryReading(percent: floor - 5, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        for _ in 0..<5 {
            runtime.applyScanForTest(["claude"])
            runtime.tickForTest()
        }
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
    }

    /// An agent hook firing every turn must not walk through the floor either.
    func testClaimDoesNotOverrideTheLock() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        power.battery = BatteryReading(percent: floor - 5, isCharging: false, isOnMain: false)
        runtime.tickForTest()
        XCTAssertNotNil(runtime.snapshot.blockedBy)

        _ = runtime.claim(label: "Claude Code · lidcode", ttlSecond: 300, key: "session-1")
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "a claim is not an override of a safety stop")
    }

    /// The lease is still recorded while blocked — the work is real, and the panel has
    /// to be able to say "five things want this Mac awake and I am not allowing it".
    func testLeaseIsStillRecordedWhileBlocked() {
        let power = Power()
        power.battery = BatteryReading(percent: floor - 5, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.tickForTest()
        _ = runtime.claim(label: "overnight migration", ttlSecond: 300, key: "k")
        XCTAssertEqual(runtime.snapshot.activeLease.count, 1)
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
    }

    /// Plugging in recovers, and the next scan is allowed to hold again.
    func testRecoveryOnMainsPowerLiftsTheLock() {
        let power = Power()
        power.battery = BatteryReading(percent: floor - 5, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        XCTAssertNotNil(runtime.snapshot.blockedBy)

        power.battery = BatteryReading(percent: floor - 4, isCharging: true, isOnMain: true)
        runtime.tickForTest()
        XCTAssertNil(runtime.snapshot.blockedBy, "on mains, the floor no longer applies")

        runtime.applyScanForTest(["claude"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
    }

    /// Recovering by charge needs real clearance, not one point over the line.
    func testOnePointAboveTheFloorDoesNotLiftTheLock() {
        let power = Power()
        power.battery = BatteryReading(percent: floor - 5, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()

        power.battery = BatteryReading(percent: floor + 1, isCharging: false, isOnMain: false)
        runtime.tickForTest()
        XCTAssertEqual(
            runtime.snapshot.blockedBy, .batteryFloor,
            "one point above the floor is still inside the warn band")

        power.battery = BatteryReading(percent: floor + 15, isCharging: false, isOnMain: false)
        runtime.tickForTest()
        XCTAssertNil(runtime.snapshot.blockedBy, "well clear of the floor — allowed again")
    }

    /// An explicit hold is an override, and it is allowed to be. The governor still
    /// gets the next word, so this costs one cycle rather than looping.
    func testExplicitHoldOverridesTheLockOnce() {
        let power = Power()
        power.battery = BatteryReading(percent: floor - 5, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        XCTAssertNotNil(runtime.snapshot.blockedBy)

        runtime.beginHold(second: nil, mode: .manual)
        runtime.tickForTest()   // the governor's next word
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "still below the floor, so it stops again")
        XCTAssertNotNil(runtime.snapshot.blockedBy, "and the lock is back on, so it stops looping")
    }
}

/// Turning the hold off by hand has to stay off. With auto-watch on and any watched
/// process running — which is the normal case, since that is *why* the Mac was awake —
/// the next scan re-acquired within ten seconds and the switch flipped itself back on.
final class UserPauseTest: XCTestCase {
    private final class Power: @unchecked Sendable {
        var battery = BatteryReading(percent: 80, isCharging: true, isOnMain: true)
        var thermal = ThermalReading(level: .nominal)
    }

    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidcode-pause-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    private func makeRuntime(_ power: Power) -> LidCodeRuntime {
        LidCodeRuntime(
            setting: .default,
            log: ActivityLog(url: logUrl),
            battery: { power.battery },
            thermal: { power.thermal })
    }

    /// Synthetic running session for tests that need activeCount > 0 to establish a hold.
    private func runningSession() -> AgentSessionSnapshot {
        let info = AgentSessionInfo(
            id: "test-session", agent: "claude", cwd: "/tmp/test",
            project: "test", title: "Test session", titleSource: "cwd-basename",
            status: .running, lastEvent: "tool_complete",
            lastSeenAt: Date(), statusChangedAt: Date())
        return AgentSessionSnapshot(sessions: [info])
    }

    func testManualStopSurvivesTheNextProcessScan() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        // Inject running session so the initial scan establishes a hold.
        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["npm", "esbuild", "uv"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)

        runtime.endHold(reason: .userStopped)
        runtime.drainForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
        XCTAssertTrue(runtime.snapshot.isUserPaused)

        // The watcher's next scan — the processes never stopped.
        runtime.applyScanForTest(["npm", "esbuild", "uv"])
        XCTAssertFalse(
            runtime.snapshot.isAwakeHeld,
            "off has to mean off; this is the switch flipping itself back on")
    }

    func testPauseSurvivesManyScan() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["npm"])
        runtime.endHold(reason: .userStopped)
        runtime.drainForTest()
        for _ in 0..<10 {
            runtime.applyScanForTest(["npm"])
            runtime.tickForTest()
        }
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
    }

    func testTurningItBackOnClearsThePause() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["npm"])
        runtime.endHold(reason: .userStopped)
        runtime.drainForTest()
        runtime.beginHold(second: nil, mode: .smart)
        runtime.drainForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
        XCTAssertFalse(runtime.snapshot.isUserPaused)
    }

    /// A script saying "I am working now" is somebody asking out loud, so it lifts the
    /// pause. Otherwise a pause set days ago silently costs an overnight run.
    func testAnExplicitClaimLiftsThePause() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["npm"])
        runtime.endHold(reason: .userStopped)
        runtime.drainForTest()
        XCTAssertTrue(runtime.snapshot.isUserPaused)

        _ = runtime.claim(label: "overnight migration", ttlSecond: 300, key: "k")
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
        XCTAssertFalse(runtime.snapshot.isUserPaused)
    }

    /// Only a *hand-made* stop pauses. Work finishing is the system doing its job, and
    /// the next real workload must hold normally — otherwise one completed build would
    /// quietly disable LidCode until someone noticed.
    func testWorkFinishingDoesNotPause() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        // Inject a running session to satisfy the new predicate.
        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["npm"])
        runtime.endHold(reason: .workFinished)
        runtime.drainForTest()
        XCTAssertFalse(runtime.snapshot.isUserPaused)

        // Work finishing is not a pause; a new hold with an active session should arm.
        runtime.applyScanForTest(["npm"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "a new workload should hold again")
    }

    func testTimerExpiryDoesNotPause() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["cargo"])
        runtime.endHold(reason: .timerExpired)
        runtime.drainForTest()
        XCTAssertFalse(runtime.snapshot.isUserPaused)
    }
}

/// The two persistent guard toggles that replaced the timed "keep going anyway"
/// override. The line they must hold is the same one the override held: a guard waives
/// the rules that exist out of courtesy, and cannot reach the ones that exist to stop
/// work being lost or hardware cooked.
final class GuardTest: XCTestCase {
    private func governor(battery isBatteryGuardOn: Bool = true,
                          thermal isThermalGuardOn: Bool = true,
                          isChargingOnly: Bool = false) -> SafetyGovernor {
        var setting = Setting.default          // soft floor, hard 4, shipped ceiling
        setting.isBatteryGuardOn = isBatteryGuardOn
        setting.isThermalGuardOn = isThermalGuardOn
        setting.isChargingOnly = isChargingOnly
        return SafetyGovernor(setting: setting)
    }

    private func verdict(percent: Int, thermal: ThermalLevel = .nominal,
                         isClamshellActive: Bool = false,
                         hotForSecond: Int = 100_000,
                         batteryGuard: Bool = true, thermalGuard: Bool = true) -> SafetyVerdict {
        governor(battery: batteryGuard, thermal: thermalGuard).evaluate(
            battery: BatteryReading(percent: percent, isCharging: false, isOnMain: false),
            thermal: ThermalReading(level: thermal),
            isClamshellActive: isClamshellActive,
            hotForSecond: hotForSecond)
    }

    // MARK: - Battery guard

    func testSoftFloorFiresWithTheGuardOn() {
        XCTAssertEqual(verdict(percent: floor - 5), .release(.batteryFloor))
    }

    func testBatteryGuardOffSkipsTheSoftFloor() {
        let overridden = verdict(percent: floor - 5, batteryGuard: false)
        XCTAssertFalse(overridden.isStop, "the soft floor is the user's call to waive")
    }

    /// The one that must never be waivable: below the hard floor the Mac is forced to
    /// sleep so the run ends resumable instead of at a hard shutdown.
    func testBatteryGuardOffDoesNotReachTheHardFloor() {
        XCTAssertEqual(
            verdict(percent: 3, batteryGuard: false),
            .forceSleep(.batteryFloor))
    }

    /// Both guards off is the state a user leaves the app in overnight after pressing
    /// two buttons, so the hard floor has to survive that combination specifically.
    func testHardFloorSurvivesBothGuardsOff() {
        XCTAssertEqual(
            verdict(percent: 3, batteryGuard: false, thermalGuard: false),
            .forceSleep(.batteryFloor))
    }

    // MARK: - Thermal guard

    func testThermalGuardOffSkipsTheCeiling() {
        // Critical with the lid open is a plain release, which is courtesy — waivable.
        XCTAssertEqual(verdict(percent: 90, thermal: .critical), .release(.thermalCritical))
        XCTAssertFalse(verdict(percent: 90, thermal: .critical, thermalGuard: false).isStop)
    }

    /// No airflow behind a shut lid, so releasing is not enough and consent is not the
    /// missing ingredient.
    func testThermalGuardOffDoesNotReachCriticalHeatBehindAShutLid() {
        XCTAssertEqual(
            verdict(percent: 90, thermal: .critical, isClamshellActive: true, thermalGuard: false),
            .forceSleep(.thermalCritical))
    }

    /// A lower ceiling is still just a ceiling — waivable, and still unable to reach
    /// the forced-sleep rule above it.
    func testLoweredCeilingIsWaivableButCriticalStillIsNot() {
        var setting = Setting.default
        setting.thermalCeiling = .fair
        setting.isThermalGuardOn = false
        let governor = SafetyGovernor(setting: setting)
        let battery = BatteryReading(percent: 90, isCharging: true, isOnMain: true)

        XCTAssertFalse(
            governor.evaluate(battery: battery, thermal: ThermalReading(level: .fair),
                              isClamshellActive: false, hotForSecond: 100_000).isStop)
        XCTAssertEqual(
            governor.evaluate(battery: battery, thermal: ThermalReading(level: .critical),
                              isClamshellActive: true, hotForSecond: 0),
            .forceSleep(.thermalCritical))
    }

    // MARK: - Sustained heat

    /// The rule that stopped the thermal ceiling being twitchy: a few seconds of
    /// all-core compile touches the ceiling and used to end an eight-hour run.
    func testCeilingDoesNotTripBelowTheSustainedWindow() {
        var setting = Setting.default
        setting.thermalCeiling = .serious
        setting.sustainedHeatSecond = 900
        let governor = SafetyGovernor(setting: setting)
        let hot = ThermalReading(level: .serious)
        let battery = BatteryReading(percent: 90, isCharging: true, isOnMain: true)

        for second in [0, 1, 60, 899] {
            let verdict = governor.evaluate(
                battery: battery, thermal: hot, isClamshellActive: false, hotForSecond: second)
            XCTAssertFalse(
                verdict.isStop,
                "\(second)s at the ceiling is a burst, not sustained heat")
        }
    }

    func testCeilingTripsAtAndAboveTheSustainedWindow() {
        var setting = Setting.default
        setting.thermalCeiling = .serious
        setting.sustainedHeatSecond = 900
        let governor = SafetyGovernor(setting: setting)
        let hot = ThermalReading(level: .serious)
        let battery = BatteryReading(percent: 90, isCharging: true, isOnMain: true)

        for second in [900, 901, 100_000] {
            XCTAssertEqual(
                governor.evaluate(battery: battery, thermal: hot,
                                  isClamshellActive: false, hotForSecond: second),
                .release(.thermalCritical),
                "\(second)s at the ceiling is sustained heat")
        }
    }

    /// Sustained heat is a condition on the *ceiling*, not on the forced-sleep rule.
    /// A shut lid at critical does not get fifteen minutes of grace.
    func testCriticalBehindAShutLidIgnoresTheSustainedWindow() {
        XCTAssertEqual(
            verdict(percent: 90, thermal: .critical, isClamshellActive: true, hotForSecond: 0),
            .forceSleep(.thermalCritical))
    }

    // MARK: - What the guards do not cover

    /// Charging-only is not reachable by either guard, and that is deliberate. It is
    /// not a safety floor the app imposes — it is a preference the user typed, and the
    /// way to stop it applying is to turn it off, not to override it from elsewhere.
    func testChargingOnlyIsNotWaivableByTheGuards() {
        let strict = governor(battery: false, thermal: false, isChargingOnly: true)
        XCTAssertTrue(
            strict.evaluate(
                battery: BatteryReading(percent: 90, isCharging: false, isOnMain: false),
                thermal: .init(level: .nominal),
                isClamshellActive: false).isStop)
    }

    /// Guards off changes nothing when nothing was wrong.
    func testGuardsAreInertWhenHealthy() {
        XCTAssertEqual(
            governor(battery: false, thermal: false).evaluate(
                battery: BatteryReading(percent: 90, isCharging: true, isOnMain: true),
                thermal: .init(level: .nominal),
                isClamshellActive: false),
            .proceed)
    }
}

/// The runtime half: a guard turned off has to actually resume the hold, persist, and
/// still be overruled by the rules it was never allowed to touch.
final class GuardRuntimeTest: XCTestCase {
    private final class Power: @unchecked Sendable {
        let lock = NSLock()
        private var _battery = BatteryReading(percent: floor - 5, isCharging: false, isOnMain: false)
        var battery: BatteryReading {
            get { lock.lock(); defer { lock.unlock() }; return _battery }
            set { lock.lock(); _battery = newValue; lock.unlock() }
        }
        private var _thermal = ThermalReading(level: .nominal)
        var thermal: ThermalReading {
            get { lock.lock(); defer { lock.unlock() }; return _thermal }
            set { lock.lock(); _thermal = newValue; lock.unlock() }
        }
    }

    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidcode-guard-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    private func makeRuntime(_ power: Power, setting: Setting = .default) -> LidCodeRuntime {
        let runtime = LidCodeRuntime(
            setting: setting,
            log: ActivityLog(url: logUrl),
            battery: { power.battery },
            thermal: { power.thermal })
        // The guard toggles persist, and a test must not rewrite the settings file of
        // whoever ran it.
        runtime.disablePersistenceForTest()
        return runtime
    }

    func testBatteryGuardOffResumesHoldingBelowTheSoftFloor() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)

        runtime.setBatteryGuard(false)
        runtime.drainForTest()
        XCTAssertTrue(
            runtime.snapshot.isAwakeHeld,
            "a guard toggle that does not unblock the thing it was blocking is decoration")
        XCTAssertNil(runtime.snapshot.blockedBy)

        // And it survives the governor's next word, which is the whole point.
        runtime.tickForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
    }

    /// Unlike the timed override it replaced, this does not lapse — so the assertion
    /// worth making is that it *keeps* holding rather than that it stops.
    func testBatteryGuardOffDoesNotExpire() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.setBatteryGuard(false)
        runtime.drainForTest()
        for _ in 0..<20 { runtime.tickForTest() }
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
        XCTAssertFalse(runtime.currentSetting.isBatteryGuardOn)
    }

    /// Crossing the hard floor with the guard off must force sleep anyway. The guard is
    /// not consulted on that rule at all, so unlike the old override there is nothing
    /// to void — the correct assertion is that the flag survives and the stop happens.
    func testHardFloorFiresWithTheBatteryGuardOff() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        runtime.setBatteryGuard(false)
        runtime.drainForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)

        power.battery = BatteryReading(percent: 3, isCharging: false, isOnMain: false)
        runtime.tickForTest()

        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "the hard floor is not waivable")
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
    }

    func testTurningTheGuardBackOnRestoresTheRules() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        runtime.setBatteryGuard(false)
        runtime.drainForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)

        runtime.setBatteryGuard(true)
        runtime.drainForTest()
        XCTAssertTrue(runtime.currentSetting.isBatteryGuardOn)

        runtime.tickForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "back under the floor once the guard is on")
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
    }

    /// The accumulator, end to end: the runtime has to start the clock when the machine
    /// reaches the ceiling, keep it running across ticks, and reset it on cooling.
    func testHotSinceAccumulatesAndResets() {
        let power = Power()
        power.battery = BatteryReading(percent: 90, isCharging: true, isOnMain: true)
        var setting = Setting.default
        setting.thermalCeiling = .serious
        let runtime = makeRuntime(power, setting: setting)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        XCTAssertNil(runtime.snapshot.hotSinceSecond, "a cool machine has no clock running")

        power.thermal = ThermalReading(level: .serious)
        runtime.tickForTest()
        XCTAssertNotNil(runtime.snapshot.hotSinceSecond)
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "a burst of heat is not a stop")

        power.thermal = ThermalReading(level: .nominal)
        runtime.tickForTest()
        XCTAssertNil(runtime.snapshot.hotSinceSecond, "cooling down resets the window")
    }

    func testSustainedHeatReleasesOnceTheWindowIsPassed() {
        let power = Power()
        power.battery = BatteryReading(percent: 90, isCharging: true, isOnMain: true)
        var setting = Setting.default
        setting.thermalCeiling = .serious
        setting.sustainedHeatSecond = 900
        let runtime = makeRuntime(power, setting: setting)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        power.thermal = ThermalReading(level: .serious)
        runtime.tickForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "fifteen minutes have not passed")

        runtime.backdateHotSinceForTest(bySecond: 901)
        runtime.tickForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
        XCTAssertEqual(runtime.snapshot.blockedBy, .thermalCritical)
    }

    /// With the thermal guard off, the same sustained heat must not stop anything —
    /// and the machine must still be held.
    func testThermalGuardOffSurvivesSustainedHeat() {
        let power = Power()
        power.battery = BatteryReading(percent: 90, isCharging: true, isOnMain: true)
        var setting = Setting.default
        setting.thermalCeiling = .serious
        setting.sustainedHeatSecond = 900
        setting.isThermalGuardOn = false
        let runtime = makeRuntime(power, setting: setting)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        power.thermal = ThermalReading(level: .serious)
        runtime.tickForTest()
        runtime.backdateHotSinceForTest(bySecond: 5000)
        runtime.tickForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "the ceiling is waived")
        XCTAssertNil(runtime.snapshot.blockedBy)
    }
}

/// A thermal ceiling of `.nominal` is unsatisfiable: the governor asks
/// `thermal.level >= ceiling`, and every level is `>= .nominal`. Before the clamp that
/// was reachable from `lidcode set --thermal-ceiling nominal` and from the settings
/// picker, and it does not merely misbehave — combined with the safety lock it wedges
/// the app into a state that can never hold again, because the lock only lifts on a
/// verdict the governor can no longer produce.
final class ThermalCeilingClampTest: XCTestCase {
    func testNominalCeilingIsRaisedToFair() {
        var setting = Setting.default
        setting.thermalCeiling = .nominal
        XCTAssertEqual(setting.normalized().thermalCeiling, .fair)
    }

    func testTheCliCannotSetAnUnsatisfiableCeiling() {
        let patched = SettingPatch(thermalCeiling: .nominal).applied(to: .default)
        XCTAssertEqual(patched.thermalCeiling, .fair)
    }

    func testAHandEditedConfigIsClampedOnLoad() throws {
        let data = Data(#"{"thermalCeiling":"nominal"}"#.utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)
        XCTAssertEqual(decoded.normalized().thermalCeiling, .fair)
    }

    func testValidCeilingIsUntouched() {
        for level in Setting.thermalCeilingChoice {
            var setting = Setting.default
            setting.thermalCeiling = level
            XCTAssertEqual(setting.normalized().thermalCeiling, level)
        }
    }

    /// The property that matters: with any offered ceiling, a cool idle Mac can still
    /// reach `.proceed` — so a lock taken for heat is always liftable.
    func testEveryOfferedCeilingLeavesProceedReachable() {
        for level in Setting.thermalCeilingChoice {
            var setting = Setting.default
            setting.thermalCeiling = level
            let verdict = SafetyGovernor(setting: setting).evaluate(
                battery: BatteryReading(percent: 90, isCharging: true, isOnMain: true),
                thermal: ThermalReading(level: .nominal),
                isClamshellActive: false)
            XCTAssertEqual(verdict, .proceed, "ceiling \(level.rawValue) must leave a reachable healthy state")
        }
    }

    /// The picker must not offer the value the clamp exists to reject.
    func testPickerDoesNotOfferNominal() {
        XCTAssertFalse(Setting.thermalCeilingChoice.contains(.nominal))
    }
}

/// The registry half of the same story: a safety stop wipes every lease, and the next
/// process scan puts them all straight back. That is correct — the processes really are
/// still running — which is exactly why the *hold* has to be gated separately from the
/// *lease*, and why the fix could not live here.
final class LeaseAfterSafetyStopTest: XCTestCase {
    func testProcessLeaseComeBackAfterAReleaseAll() {
        let registry = LeaseRegistry()
        registry.replaceProcessLease(["claude", "npm", "python"])
        XCTAssertEqual(registry.active.count, 3)

        registry.releaseAll()
        XCTAssertTrue(registry.isEmpty)

        // The watcher's next scan, 10s later.
        registry.replaceProcessLease(["claude", "npm", "python"])
        XCTAssertEqual(registry.active.count, 3, "the work did not stop just because we let go")
    }

    /// Process leases never expire on their own — they are backed by something real,
    /// so a scan is the only thing that can retire them. Worth pinning: if these ever
    /// gained a TTL, the count would flap for a completely different reason.
    func testProcessLeaseDoesNotExpire() {
        let registry = LeaseRegistry()
        registry.replaceProcessLease(["cargo"])
        let lease = registry.active.first
        XCTAssertNotNil(lease)
        XCTAssertNil(lease?.expiresAt)
        XCTAssertFalse(lease?.isExpired(asOf: Date().addingTimeInterval(86_400)) ?? true)
    }
}
