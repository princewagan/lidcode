import XCTest
@testable import LidCodeKit

/// Tests for the new keep-awake predicate introduced in plan step 1.3 (W1).
///
/// Core contract:
///   Hold ONLY when:
///     (a) user has not paused, AND
///     (b) agentSession.activeCount > 0 OR a non-process lease exists, AND
///     (c) deadline not passed AND not in cooldown, AND
///     (d) safety guards OK.
///
/// The most critical behaviours: .blocked / .finished / .error sessions must NOT
/// hold the Mac awake, and a timer expiry must trigger a cooldown.
final class HoldPredicateTest: XCTestCase {

    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidcode-predicate-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRuntime(
        battery: BatteryReading = BatteryReading(percent: 80, isCharging: true, isOnMain: true),
        thermal: ThermalReading = ThermalReading(level: .nominal)
    ) -> LidCodeRuntime {
        let runtime = LidCodeRuntime(
            setting: .default,
            log: ActivityLog(url: logUrl),
            battery: { battery },
            thermal: { thermal })
        runtime.disablePersistenceForTest()
        return runtime
    }

    private func session(status: AgentStatus) -> AgentSessionSnapshot {
        let info = AgentSessionInfo(
            id: "test-\(status.rawValue)", agent: "claude", cwd: "/tmp/test",
            project: "test", title: "Test \(status.rawValue)", titleSource: "cwd-basename",
            status: status, lastEvent: "tool_complete",
            lastSeenAt: Date(), statusChangedAt: Date())
        return AgentSessionSnapshot(sessions: [info])
    }

    private func runningSession() -> AgentSessionSnapshot { session(status: .running) }
    private func blockedSession() -> AgentSessionSnapshot { session(status: .blocked) }
    private func errorSession() -> AgentSessionSnapshot { session(status: .error) }
    private func finishedSession() -> AgentSessionSnapshot { session(status: .finished) }

    // MARK: - Session status gates

    /// ONLY a .running session should satisfy the keep-awake predicate.
    func testRunningSessionHolds() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["claude"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, ".running session should hold the Mac awake")
    }

    /// A .blocked session (waiting for user response) must NOT hold.
    func testBlockedSessionDoesNotHold() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.setAgentSessionForTest(blockedSession())
        runtime.applyScanForTest(["claude"])
        XCTAssertFalse(runtime.snapshot.isAwakeHeld,
                       ".blocked session waiting on user must NOT hold the Mac awake")
    }

    /// A .error session must NOT hold.
    func testErrorSessionDoesNotHold() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.setAgentSessionForTest(errorSession())
        runtime.applyScanForTest(["claude"])
        XCTAssertFalse(runtime.snapshot.isAwakeHeld,
                       ".error session must NOT hold the Mac awake")
    }

    /// A .finished session must NOT hold.
    func testFinishedSessionDoesNotHold() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.setAgentSessionForTest(finishedSession())
        runtime.applyScanForTest(["claude"])
        XCTAssertFalse(runtime.snapshot.isAwakeHeld,
                       ".finished session must NOT hold the Mac awake")
    }

    /// Process presence alone (no active session) must NOT hold.
    func testProcessAloneDoesNotHold() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        // No session injected — agentSession stays at .empty (activeCount = 0).
        runtime.applyScanForTest(["claude", "codex"])
        XCTAssertFalse(runtime.snapshot.isAwakeHeld,
                       "process presence alone must not hold: BUG 5 fix")
    }

    /// A non-process lease (explicit claim) satisfies the predicate even without a session.
    func testExplicitClaimHoldsWithoutSession() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        // No session injected. An explicit claim should still hold.
        _ = runtime.claim(label: "overnight-migration", ttlSecond: 3600, key: "k")
        XCTAssertTrue(runtime.snapshot.isAwakeHeld,
                      "an explicit claim (non-process lease) must hold even with no running session")
    }

    // MARK: - Nil-second resolves to setting.holdSecond (BUG 1)

    /// A nil-second beginHold must use `setting.holdSecond`, never indefinite.
    func testNilSecondResolvesToSettingHoldSecond() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.setAgentSessionForTest(runningSession())
        runtime.beginHold(second: nil, mode: .smart)
        runtime.drainForTest()

        let snap = runtime.snapshot
        XCTAssertNotNil(snap.expiresAt, "nil second must produce a finite deadline, never nil")

        // The deadline should be approximately setting.holdSecond from now.
        let expected = Date().addingTimeInterval(TimeInterval(Setting.default.holdSecond))
        let actual = snap.expiresAt!
        let diff = abs(actual.timeIntervalSince(expected))
        XCTAssertLessThan(diff, 5, "deadline should match setting.holdSecond within 5s")
    }

    // MARK: - Deadline not clobbered while held (BUG 2)

    /// A second nil-second call while already held must not clear the live deadline.
    func testDeadlineNotClearedOnReacquire() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        // Start with an explicit 30-minute hold.
        let thirtyMin = 30 * 60
        runtime.setAgentSessionForTest(runningSession())
        runtime.beginHold(second: thirtyMin, mode: .smart)
        runtime.drainForTest()

        let firstExpiry = runtime.snapshot.expiresAt
        XCTAssertNotNil(firstExpiry)

        // A second nil-second call while already held must NOT clear the expiry.
        runtime.beginHold(second: nil, mode: .smart)
        runtime.drainForTest()

        let secondExpiry = runtime.snapshot.expiresAt
        XCTAssertNotNil(secondExpiry)

        // The expiry must still be close to the original 30-minute deadline.
        let diff = abs(secondExpiry!.timeIntervalSince(firstExpiry!))
        XCTAssertLessThan(diff, 5, "a nil-second re-arm must not clobber the live deadline (BUG 2)")
    }

    // MARK: - Cooldown after timer expiry (BUG 1)

    /// After a .timerExpired stop, the runtime must not re-arm until the user re-enables.
    func testTimerExpiredCooldown() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["claude"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "should hold initially")

        // Simulate timer expiry manually.
        runtime.endHold(reason: .timerExpired)
        runtime.drainForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "must release on timer expiry")

        // Now a process scan should NOT re-arm (cooldown is active).
        runtime.applyScanForTest(["claude"])
        XCTAssertFalse(runtime.snapshot.isAwakeHeld,
                       "must not re-arm after timer expiry until user re-enables (BUG 1)")
    }

    /// After cooldown, an explicit user beginHold clears the cooldown and arms normally.
    func testUserReenablesClearsCooldown() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["claude"])
        runtime.endHold(reason: .timerExpired)
        runtime.drainForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)

        // User explicitly re-enables.
        runtime.beginHold(second: nil, mode: .smart)
        runtime.drainForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "user explicit hold must clear the cooldown")
    }

    /// After cooldown, when all sessions finish and a new running session appears, the
    /// cooldown must clear on the next tick.
    func testNewSessionAfterAllFinishedClearsCooldown() {
        let runtime = makeRuntime()
        defer { runtime.shutdown() }

        // Start a hold and expire it.
        runtime.setAgentSessionForTest(runningSession())
        runtime.applyScanForTest(["claude"])
        runtime.endHold(reason: .timerExpired)
        runtime.drainForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "must not hold after expiry")

        // All sessions finish: set to empty (activeCount = 0).
        runtime.setAgentSessionForTest(.empty)
        runtime.tickForTest()  // tick to record previousActiveCount = 0

        // A brand-new running session appears.
        runtime.setAgentSessionForTest(runningSession())
        runtime.tickForTest()  // should clear cooldown on 0→nonzero transition
        runtime.applyScanForTest(["claude"])

        // Allow a tick to process the new scan with cleared cooldown.
        runtime.tickForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld,
                      "new session after all finished must clear cooldown and re-arm")
    }

    // MARK: - activeCount correctness

    func testActiveCountZeroForAllNonRunningStatuses() {
        // .blocked, .error, .finished all give activeCount == 0
        for s in [AgentStatus.blocked, .error, .finished] {
            let snap = session(status: s)
            XCTAssertEqual(snap.activeCount, 0, "\(s) must not contribute to activeCount")
        }
    }

    func testActiveCountOneForRunning() {
        XCTAssertEqual(runningSession().activeCount, 1)
    }

    func testActiveCountCountsMultipleRunning() {
        let infos = (0..<3).map { i in
            AgentSessionInfo(
                id: "s\(i)", agent: "claude", cwd: "/tmp", project: "p", title: "T\(i)",
                titleSource: "cwd-basename", status: .running, lastEvent: "tool_complete",
                lastSeenAt: Date(), statusChangedAt: Date())
        }
        let snap = AgentSessionSnapshot(sessions: infos)
        XCTAssertEqual(snap.activeCount, 3)
    }

    func testMixedSessionsActiveCountOnlyCountsRunning() {
        let running = AgentSessionInfo(
            id: "r", agent: "claude", cwd: "/tmp", project: "p", title: "Running",
            titleSource: "cwd-basename", status: .running, lastEvent: "tool_complete",
            lastSeenAt: Date(), statusChangedAt: Date())
        let blocked = AgentSessionInfo(
            id: "b", agent: "claude", cwd: "/tmp", project: "p", title: "Blocked",
            titleSource: "cwd-basename", status: .blocked, lastEvent: "permission_request",
            lastSeenAt: Date(), statusChangedAt: Date())
        let finished = AgentSessionInfo(
            id: "f", agent: "claude", cwd: "/tmp", project: "p", title: "Done",
            titleSource: "cwd-basename", status: .finished, lastEvent: "stop",
            lastSeenAt: Date(), statusChangedAt: Date())
        let snap = AgentSessionSnapshot(sessions: [running, blocked, finished])
        XCTAssertEqual(snap.activeCount, 1,
                       "only .running sessions count; .blocked and .finished do not")
    }

    // MARK: - foreignBlockerCount

    /// The field exists on RuntimeSnapshot with a safe default.
    func testForeignBlockerCountDefaultsToZero() {
        let snap = RuntimeSnapshot()
        XCTAssertEqual(snap.foreignBlockerCount, 0)
    }

    // MARK: - physicalLid

    /// The field exists on RuntimeSnapshot with a safe unknown default.
    func testPhysicalLidDefaultsToUnknown() {
        let snap = RuntimeSnapshot()
        XCTAssertEqual(snap.physicalLid.state, .unknown)
        XCTAssertTrue(snap.physicalLid.isStale)
    }

    // MARK: - shouldDisableSleep truth table

    /// disablesleep must be 1 exactly when armed && held && not safety-locked.
    /// This covers the pure predicate that the tick reconcile calls directly.
    func testShouldDisableSleepAllTrue() {
        XCTAssertTrue(LidCodeRuntime.shouldDisableSleep(isArmed: true, isHeld: true, isSafetyLocked: false),
            "armed + held + no safety lock must request disablesleep 1")
    }

    func testShouldDisableSleepNotArmed() {
        XCTAssertFalse(LidCodeRuntime.shouldDisableSleep(isArmed: false, isHeld: true, isSafetyLocked: false),
            "not armed: disablesleep must be 0 even while held")
    }

    func testShouldDisableSleepNotHeld() {
        XCTAssertFalse(LidCodeRuntime.shouldDisableSleep(isArmed: true, isHeld: false, isSafetyLocked: false),
            "not held: armed intent without a live hold must not set disablesleep")
    }

    func testShouldDisableSleepSafetyLocked() {
        XCTAssertFalse(LidCodeRuntime.shouldDisableSleep(isArmed: true, isHeld: true, isSafetyLocked: true),
            "safety lock engaged: disablesleep must be 0 even when armed and held")
    }

    func testShouldDisableSleepAllFalse() {
        XCTAssertFalse(LidCodeRuntime.shouldDisableSleep(isArmed: false, isHeld: false, isSafetyLocked: true),
            "nothing active: disablesleep must be 0")
    }
}
