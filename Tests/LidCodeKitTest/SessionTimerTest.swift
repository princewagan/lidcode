import XCTest
@testable import LidCodeKit

/// The session timer, which is the one promise in this app with a wall clock attached.
///
/// It used to be checked near the bottom of `tick`, below two things that can return
/// first: the `guard isHeld || isClamshellActive`, and the governor's `switch` (whose
/// `.release` and `.forceSleep` arms both `return`). So on any tick where a guard also
/// fired, the deadline was simply not looked at — and a hold that had already been
/// released left `expiresAt` set, which the guard then skipped past forever.
///
/// It is checked first now, against `expiresAt` alone, so nothing else can suppress it.
final class SessionTimerTest: XCTestCase {

    private final class Power: @unchecked Sendable {
        var battery = BatteryReading(percent: 90, isCharging: true, isOnMain: true)
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
        let runtime = LidCodeRuntime(
            setting: .default,
            log: ActivityLog(url: logUrl),
            battery: { power.battery },
            thermal: { power.thermal })
        // Never let a test rewrite the settings of whoever is running it.
        runtime.disablePersistenceForTest()
        return runtime
    }

    /// A zero-second hold is already expired the moment it starts, which is the cheapest
    /// way to drive the deadline branch without waiting out a real timer.
    func testAnExpiredDeadlineStopsTheHold() {
        let runtime = makeRuntime(Power())
        defer { runtime.shutdown() }

        runtime.beginHold(second: 0, mode: .manual)
        runtime.drainForTest()
        XCTAssertNotNil(runtime.snapshot.expiresAt, "precondition: a deadline was set")

        runtime.tickForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
        XCTAssertEqual(runtime.snapshot.lastStopReason, .timerExpired)
    }

    /// The deadline is cleared by the stop, so the branch cannot re-fire.
    ///
    /// This is the bug that made an expired timer keep acting: `stopLocked` cleared
    /// `expiresAt` *below* its `guard isHeld`, so a stop arriving with nothing held
    /// returned early and left the deadline in place. `tick` then re-ran the expiry
    /// branch against it every five seconds — re-arming the 24-hour cooldown each time
    /// and, with the lid shut, asking the helper to sleep the Mac again on every pass.
    func testAnExpiredDeadlineIsClearedAndDoesNotFireTwice() {
        let runtime = makeRuntime(Power())
        defer { runtime.shutdown() }

        runtime.beginHold(second: 0, mode: .manual)
        runtime.drainForTest()
        runtime.tickForTest()
        XCTAssertNil(runtime.snapshot.expiresAt, "the deadline is spent, so it must be cleared")

        // Several more passes. A deadline left behind would stop something on each one.
        for _ in 0..<3 { runtime.tickForTest() }
        XCTAssertNil(runtime.snapshot.expiresAt)
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
    }

    /// Stopping by hand clears the deadline too, for the same reason: any path that ends
    /// a session must not leave a clock running behind it.
    func testStoppingByHandClearsTheDeadline() {
        let runtime = makeRuntime(Power())
        defer { runtime.shutdown() }

        runtime.beginHold(second: 3600, mode: .manual)
        runtime.drainForTest()
        XCTAssertNotNil(runtime.snapshot.expiresAt)

        runtime.endHold(reason: .userStopped)
        runtime.drainForTest()
        XCTAssertNil(runtime.snapshot.expiresAt)
    }

    /// A stop that arrives with nothing held is the exact shape of the orphan bug, so it
    /// gets its own case rather than being implied by the one above.
    func testStoppingWithNothingHeldStillClearsTheDeadline() {
        let runtime = makeRuntime(Power())
        defer { runtime.shutdown() }

        runtime.beginHold(second: 3600, mode: .manual)
        runtime.drainForTest()
        runtime.endHold(reason: .userStopped)   // now nothing is held
        runtime.drainForTest()
        runtime.endHold(reason: .userStopped)   // ...and this one arrives anyway
        runtime.drainForTest()

        XCTAssertNil(runtime.snapshot.expiresAt)
    }

    /// A live deadline is left alone. The point of checking the timer first is that it
    /// always gets looked at, not that it fires eagerly.
    func testALiveDeadlineSurvivesTheTick() {
        let runtime = makeRuntime(Power())
        defer { runtime.shutdown() }

        runtime.beginHold(second: 3600, mode: .manual)
        runtime.drainForTest()
        runtime.tickForTest()

        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
        XCTAssertNotNil(runtime.snapshot.expiresAt)
        XCTAssertNotEqual(runtime.snapshot.lastStopReason, .timerExpired)
    }

    /// The timer outranks a guard warning. A warm Mac produces a governor `.warn`, which
    /// falls through the `switch` — but a `.release` or `.forceSleep` would have returned
    /// before the old bottom-of-tick expiry check ever ran. Checking first removes the
    /// whole class of interaction.
    func testTheTimerFiresEvenWhileTheGovernorIsWarning() {
        let power = Power()
        power.thermal = ThermalReading(level: .serious)   // warn band, not a stop
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.beginHold(second: 0, mode: .manual)
        runtime.drainForTest()
        runtime.tickForTest()

        XCTAssertEqual(runtime.snapshot.lastStopReason, .timerExpired)
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
    }

    /// The countdown the panel draws. A timer nobody can see is indistinguishable from a
    /// timer that is not running, which is most of why this was reported as broken.
    func testTheSnapshotCarriesARemainingCountdown() {
        let runtime = makeRuntime(Power())
        defer { runtime.shutdown() }

        runtime.beginHold(second: 7200, mode: .manual)
        runtime.drainForTest()

        let remaining = runtime.snapshot.remainingSecond
        XCTAssertNotNil(remaining)
        XCTAssertGreaterThan(remaining ?? 0, 7100)
        XCTAssertLessThanOrEqual(remaining ?? 0, 7200)
        XCTAssertEqual(runtime.snapshot.remainingDisplay?.caption, "2h 00m left")
    }
}
