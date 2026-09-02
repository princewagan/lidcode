import Foundation
import Testing
@testable import WarpMonitor

// MARK: - ActivityDetectionTests
//
// Tests for the mtime-based activity detection logic in StateManager.
// The key bug: previously a live `claude` process → status = .running.
// After the fix: transcript mtime is the running/finished signal.
// Process liveness only establishes that a session EXISTS.
//
// Required by the activity-detection spec:
//   1. fresh transcript → running
//   2. stale transcript + live process → finished
//   3. no process (no mtime) → idle is handled upstream; activityStatus → .finished
//   4. recent permission_request → blocked overrides mtime
//   5. recent stop_failure → error overrides mtime
//   6. hysteresis behaviour

@Suite("Activity detection (mtime-based)")
struct ActivityDetectionTests {

    // Convenience: build a StateManager in test mode (no DB, no log, no Pusher).
    // We only call activityStatus(), which has no side effects.
    private func sm() -> StateManager {
        StateManager(dbPath: "/dev/null", logPath: "/dev/null")
    }

    // MARK: - 1. Fresh transcript → running

    @Test("Fresh transcript (within activityWindow) → running")
    func testFreshTranscriptIsRunning() {
        let manager = sm()
        // mtime = 10 seconds ago — well within the 60s window
        let mtime = Date(timeIntervalSinceNow: -10)
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: nil,
            logStatus: nil
        )
        #expect(status == .running,
            "A transcript written 10 s ago must produce 'running' status")
    }

    @Test("Transcript just inside the activity window → running")
    func testTranscriptAtBoundaryIsRunning() {
        let manager = sm()
        // Deliberately just *inside* the 60 s window rather than exactly on it.
        //
        // activityStatus reads Date() itself, so an mtime of exactly -60 s is
        // already older than 60 s by the time the comparison runs. Asserting on
        // the exact boundary made this test a race that passed or failed on
        // scheduling luck. The behaviour worth pinning is that a transcript
        // written within the window reads as running; the sub-millisecond edge
        // is not a real case.
        let mtime = Date(timeIntervalSinceNow: -(StateManager.activityWindow - 1))
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: nil,
            logStatus: nil
        )
        #expect(status == .running,
            "A transcript written inside the activity window must produce 'running'")
    }

    @Test("Transcript past the activity window → finished")
    func testTranscriptPastWindowIsFinished() {
        let manager = sm()
        let mtime = Date(timeIntervalSinceNow: -(StateManager.activityWindow + 1))
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: nil,
            logStatus: nil
        )
        #expect(status == .finished,
            "A transcript older than the activity window must produce 'finished'")
    }

    // MARK: - 2. Stale transcript + live process → finished

    @Test("Stale transcript (beyond activityWindow, not currently running) → finished")
    func testStaleTranscriptIsFinished() {
        let manager = sm()
        // mtime = 90 seconds ago — beyond the 60 s window; not currently running (no grace)
        let mtime = Date(timeIntervalSinceNow: -90)
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: .idle,  // was not running → no grace period
            logStatus: nil
        )
        #expect(status == .finished,
            "A stale transcript with a live process must produce 'finished', not 'running'")
    }

    @Test("Stale transcript (beyond activityWindow + grace) with currentStatus=running → finished")
    func testStaleTranscriptBeyondGraceIsFinished() {
        let manager = sm()
        // mtime = activityWindow + activityGrace + 5 s ago → beyond even the extended window
        let age = StateManager.activityWindow + StateManager.activityGrace + 5
        let mtime = Date(timeIntervalSinceNow: -age)
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: .running,  // was running → grace period applies
            logStatus: nil
        )
        #expect(status == .finished,
            "A transcript beyond activityWindow + grace must produce 'finished' even if was running")
    }

    // MARK: - 3. No transcript → finished (not idle, not running)
    //
    // When there is no transcript, activityStatus returns .finished.
    // (idle is set upstream when there is also no process.)

    @Test("No transcript (nil mtime) → finished")
    func testNoTranscriptIsFinished() {
        let manager = sm()
        let status = manager.activityStatus(
            transcriptMtime: nil,
            currentStatus: nil,
            logStatus: nil
        )
        #expect(status == .finished,
            "No transcript means we cannot confirm activity; must default to 'finished'")
    }

    // MARK: - 4. Recent permission_request (blocked) overrides mtime

    @Test("blocked logStatus overrides even a fresh transcript")
    func testBlockedOverridesFreshTranscript() {
        let manager = sm()
        // Transcript is fresh (10 s ago) — would normally say "running".
        // But the log says blocked → blocked wins.
        let mtime = Date(timeIntervalSinceNow: -10)
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: .running,
            logStatus: .blocked
        )
        #expect(status == .blocked,
            "blocked logStatus must override mtime-based running detection")
    }

    @Test("blocked logStatus overrides a stale transcript")
    func testBlockedOverridesStaleTranscript() {
        let manager = sm()
        let mtime = Date(timeIntervalSinceNow: -300)  // 5 minutes ago
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: .finished,
            logStatus: .blocked
        )
        #expect(status == .blocked,
            "blocked logStatus must override stale transcript")
    }

    // MARK: - 5. Recent stop_failure (error) overrides mtime

    @Test("error logStatus overrides even a fresh transcript")
    func testErrorOverridesFreshTranscript() {
        let manager = sm()
        let mtime = Date(timeIntervalSinceNow: -5)
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: .running,
            logStatus: .error
        )
        #expect(status == .error,
            "error logStatus must override mtime-based running detection")
    }

    @Test("error logStatus overrides nil transcript")
    func testErrorOverridesNilTranscript() {
        let manager = sm()
        let status = manager.activityStatus(
            transcriptMtime: nil,
            currentStatus: nil,
            logStatus: .error
        )
        #expect(status == .error,
            "error logStatus must override nil transcript (no transcript found)")
    }

    // MARK: - 6. Hysteresis behaviour

    @Test("Hysteresis: transcript just outside window but currentStatus=running → still running")
    func testHysteresisKeepsRunning() {
        let manager = sm()
        // mtime = activityWindow + 5 s ago → just beyond the 60 s window.
        // Without hysteresis this would flip to finished.
        // With hysteresis (grace = 15 s), the effective window becomes 75 s,
        // so it must still read as running.
        let age = StateManager.activityWindow + 5  // 65 s: inside window+grace
        let mtime = Date(timeIntervalSinceNow: -age)
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: .running,
            logStatus: nil
        )
        #expect(status == .running,
            "Hysteresis: transcript within window+grace and currentStatus=running must stay running")
    }

    @Test("Hysteresis: same age but currentStatus=idle (not running) → finished (no grace)")
    func testNoHysteresisWhenNotRunning() {
        let manager = sm()
        // Same age as above (65 s) but currentStatus is not running → no grace period.
        let age = StateManager.activityWindow + 5
        let mtime = Date(timeIntervalSinceNow: -age)
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: .idle,
            logStatus: nil
        )
        #expect(status == .finished,
            "Without running currentStatus, no grace period applies; must flip to 'finished'")
    }

    @Test("Hysteresis: running logStatus (not blocked/error) does not bypass mtime check")
    func testRunningLogStatusStillUseMtime() {
        let manager = sm()
        // logStatus = .running, but transcript is 5 minutes old → mtime wins.
        // (Only blocked/error bypass the mtime check.)
        let mtime = Date(timeIntervalSinceNow: -300)
        let status = manager.activityStatus(
            transcriptMtime: mtime,
            currentStatus: .finished,
            logStatus: .running
        )
        #expect(status == .finished,
            "logStatus=running does NOT override mtime; stale transcript must produce 'finished'")
    }
}
