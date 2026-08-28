import XCTest
@testable import LidCodeKit

/// The structural half of the freeze fix.
///
/// Every one of these reads used to be a `queue.sync` onto the runtime's serial queue,
/// called from the main thread. If anything ever blocked that queue — a wedged `pmset`,
/// a hung root helper, a `ps` stuck on a busy filesystem — the next read from the main
/// thread never returned, and the menu bar icon stayed drawn but stopped responding.
///
/// The property tested here is the one that makes that impossible: these accessors do
/// not touch the runtime queue at all. A queue that is busy for a full second must not
/// delay them by any measurable amount.
final class RuntimeCacheTest: XCTestCase {
    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidcode-cache-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    private func makeRuntime(setting: Setting = .default) -> LidCodeRuntime {
        let runtime = LidCodeRuntime(
            setting: setting,
            log: ActivityLog(url: logUrl),
            battery: { BatteryReading(percent: 80, isCharging: true, isOnMain: true) },
            thermal: { ThermalReading(level: .nominal) })
        // These tests drive the settings path on purpose, and the settings path writes
        // to `~/.lidcode/setting.json`. A test suite must not rewrite the settings of
        // whoever ran it.
        runtime.disablePersistenceForTest()
        return runtime
    }

    /// Helper: synthetic running session for tests that need activeCount > 0 to hold.
    private func runningSession() -> AgentSessionSnapshot {
        let info = AgentSessionInfo(
            id: "test-session", agent: "claude", cwd: "/tmp/test",
            project: "test", title: "Test session", titleSource: "cwd-basename",
            status: .running, lastEvent: "tool_complete",
            lastSeenAt: Date(), statusChangedAt: Date())
        return AgentSessionSnapshot(sessions: [info])
    }

    /// The load-bearing test. A block is parked on the runtime queue for a full second;
    /// every public read has to come back immediately anyway.
    func testReadsDoNotWaitOnABlockedRuntimeQueue() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        // Establish a snapshot first, so there is something real in the mirror.
        // The new predicate requires activeCount > 0 (a running session) to hold.
        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["claude"])

        let occupied = expectation(description: "queue occupied")
        runtime.blockQueueForTest(second: 1.0, started: { occupied.fulfill() })
        wait(for: [occupied], timeout: 2)

        let start = Date()
        let snapshot = runtime.snapshot
        let setting = runtime.currentSetting
        let pattern = runtime.currentPattern
        let lease = runtime.activeLease
        let health = runtime.currentHealth
        let sample = runtime.recentSample(limit: 48)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 0.25,
            "a read that waits on the runtime queue is the freeze; it must be a lock read")
        // And the answers are real, not empty placeholders.
        XCTAssertTrue(snapshot.isAwakeHeld)
        XCTAssertEqual(snapshot.activeLease, ["claude"])
        XCTAssertEqual(setting.softBatteryPercent, Setting.default.softBatteryPercent)
        XCTAssertFalse(pattern.isEmpty)
        XCTAssertEqual(lease.count, 1)
        XCTAssertNil(health, "no sweep has run yet")
        XCTAssertNotNil(sample)
    }

    /// `setClamshell` is the one that actually froze people: it did blocking socket I/O
    /// to a root daemon inside a `queue.sync` called from the main thread. The callback
    /// form must return to its caller straight away, whatever the helper is doing.
    func testSetClamshellReturnsImmediatelyEvenWithTheQueueBusy() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        let occupied = expectation(description: "queue occupied")
        runtime.blockQueueForTest(second: 0.75, started: { occupied.fulfill() })
        wait(for: [occupied], timeout: 2)

        let start = Date()
        runtime.setClamshell(true, second: nil, mode: .smart, completion: nil)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 0.25,
            "the UI must never block on the helper")
    }

    /// And the completion still arrives — on the main queue, so a caller can drive UI
    /// state from it without a hop of its own. No helper is installed in a test, so the
    /// expected outcome is a clean `helperMissing` rather than a hang.
    func testSetClamshellReportsFailureOnTheMainQueue() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        let delivered = expectation(description: "completion delivered")
        runtime.setClamshell(true, second: nil, mode: .smart) { result in
            XCTAssertTrue(Thread.isMainThread, "completions are delivered on the main queue")
            if case .success = result {
                XCTFail("no helper is installed in a test environment")
            }
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
    }

    // MARK: - The settings mirror

    /// `updateSetting` no longer waits on the queue, so the value it returns is computed
    /// from the mirror. It still has to be right, and it still has to be readable back
    /// immediately — a slider that snaps back for one frame is a bug report.
    func testUpdateSettingIsReadableImmediately() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        let occupied = expectation(description: "queue occupied")
        runtime.blockQueueForTest(second: 0.5, started: { occupied.fulfill() })
        wait(for: [occupied], timeout: 2)

        let returned = runtime.updateSetting(SettingPatch(softBatteryPercent: 35))
        XCTAssertEqual(returned.softBatteryPercent, 35)
        XCTAssertEqual(runtime.currentSetting.softBatteryPercent, 35,
                       "the mirror is written synchronously")
    }

    func testUpdateSettingNormalizesTheReturnedValue() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        // 99% is outside `softBatteryRange`, and 2h29m is not on the half-hour grid.
        let returned = runtime.updateSetting(
            SettingPatch(softBatteryPercent: 99, holdSecond: 3600 + 1740))
        XCTAssertEqual(returned.softBatteryPercent, Setting.softBatteryRange.upperBound)
        XCTAssertEqual(returned.holdSecond, 5400)
    }

    /// The patch is re-applied on the queue rather than assigned wholesale, so the live
    /// governor genuinely picks up the new floor.
    func testUpdateSettingReachesTheLiveGovernor() {
        let runtime = LidCodeRuntime(
            setting: .default,
            log: ActivityLog(url: logUrl),
            battery: { BatteryReading(percent: 30, isCharging: false, isOnMain: false) },
            thermal: { ThermalReading(level: .nominal) })
        runtime.disablePersistenceForTest()
        defer { runtime.shutdown() }

        // The new predicate requires activeCount > 0 to hold.
        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["claude"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "30% is comfortably above the 20% floor")

        _ = runtime.updateSetting(SettingPatch(softBatteryPercent: 40))
        runtime.drainForTest()
        runtime.tickForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "a floor you just raised protects this run")
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
    }

    func testGuardTogglesAreReadableImmediately() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.setBatteryGuard(false)
        XCTAssertFalse(runtime.currentSetting.isBatteryGuardOn)
        runtime.setThermalGuard(false)
        XCTAssertFalse(runtime.currentSetting.isThermalGuardOn)

        runtime.drainForTest()
        XCTAssertFalse(runtime.currentSetting.isBatteryGuardOn)
        XCTAssertFalse(runtime.currentSetting.isThermalGuardOn)
    }

    // MARK: - Watchdog

    /// A wedge has to be visible rather than silent. Nothing has ticked yet here, so
    /// there is no timestamp to be late — "unknown" must not read as "stalled", or the
    /// flag would be true for every app launch.
    func testNotStalledBeforeTheFirstTick() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }
        XCTAssertNil(runtime.lastTickAt)
        XCTAssertFalse(runtime.isStalled)
        XCTAssertFalse(runtime.snapshot.isStalled)
    }

    func testTickStampsTheWatchdog() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.tickForTest()
        guard let at = runtime.lastTickAt else { return XCTFail("no tick recorded") }
        XCTAssertLessThan(abs(at.timeIntervalSinceNow), 2)
        XCTAssertFalse(runtime.isStalled)
        XCTAssertFalse(runtime.snapshot.isStalled)
    }

    /// The flag is computed by the *reader* from a timestamp, precisely so it can become
    /// true while the queue that would otherwise set it is the thing that is stuck.
    func testStaleTickReadsAsStalled() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.tickForTest()
        runtime.backdateTickForTest(bySecond: LidCodeRuntime.stallAfterSecond + 5)
        XCTAssertTrue(runtime.isStalled)
        XCTAssertTrue(runtime.snapshot.isStalled, "and it rides out on the snapshot")

        runtime.tickForTest()
        XCTAssertFalse(runtime.isStalled, "a tick clears it")
    }

    // MARK: - Live data (Job D)

    /// Both readers run on the queue, once per tick, and their results ride out on the
    /// snapshot. Neither file exists in a test environment, so the assertion is that the
    /// fields are populated with the honest empty answer rather than left unset.
    func testSessionAndUsageArePublishedEveryTick() {
        let runtime = LidCodeRuntime(
            setting: .default,
            log: ActivityLog(url: logUrl),
            battery: { BatteryReading(percent: 80, isCharging: true, isOnMain: true) },
            thermal: { ThermalReading(level: .nominal) },
            sessionReader: AgentSessionReader(
                logURL: URL(fileURLWithPath: "/nonexistent/warp.log"),
                databaseURL: URL(fileURLWithPath: "/nonexistent/warp.sqlite")))
        runtime.disablePersistenceForTest()
        defer { runtime.shutdown() }

        runtime.tickForTest()
        let snapshot = runtime.snapshot
        XCTAssertEqual(snapshot.agentSession, .empty, "no log means no sessions, not a nil field")
        XCTAssertTrue(snapshot.agentSession.sessions.isEmpty)
    }
}
