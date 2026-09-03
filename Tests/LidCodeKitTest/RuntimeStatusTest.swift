import XCTest
@testable import LidCodeKit

/// `RuntimeSnapshot.displayStatus` is the single source for the status line in
/// both the menu bar and the push payload. These tests pin the precedence, because
/// the ordering is the part that matters: reporting "Keeping awake" while the
/// engine is stalled is the one wrong answer that lets an overnight run die
/// without anyone noticing.
final class RuntimeStatusTest: XCTestCase {

    private func snapshot(
        isAwakeHeld: Bool = false,
        isClamshellActive: Bool = false,
        isStalled: Bool = false,
        blockedBy: StopReason? = nil,
        isAutoWatchOn: Bool = false,
        isUserPaused: Bool = false,
        activeLease: [String] = [],
        lastStopReason: StopReason? = nil,
        mode: HoldMode = .smart,
        sessions: [AgentSessionInfo] = []
    ) -> RuntimeSnapshot {
        var snap = RuntimeSnapshot(
            isAwakeHeld: isAwakeHeld,
            agentSession: AgentSessionSnapshot(sessions: sessions),
            physicalLid: ClamshellReading(state: .open, readAt: Date(), isStale: false),
            foreignBlockerCount: 0
        )
        snap.isClamshellActive = isClamshellActive
        snap.isStalled = isStalled
        snap.blockedBy = blockedBy
        snap.isAutoWatchOn = isAutoWatchOn
        snap.isUserPaused = isUserPaused
        snap.activeLease = activeLease
        snap.lastStopReason = lastStopReason
        snap.mode = mode
        return snap
    }

    private func runningSession(id: String) -> AgentSessionInfo {
        AgentSessionInfo(
            id: id,
            agent: "claude",
            cwd: "/tmp",
            project: "lidcode",
            title: "work",
            titleSource: "test",
            status: .running,
            lastEvent: "test",
            lastSeenAt: Date(),
            statusChangedAt: Date()
        )
    }

    // MARK: - Precedence

    func testStalledOutranksAHoldThatIsStillNominallyActive() {
        let s = snapshot(isAwakeHeld: true, isStalled: true, activeLease: ["claude"])
        XCTAssertEqual(s.displayStatus.kind, .stalled)
        XCTAssertEqual(s.displayStatus.title, "Not responding")
        XCTAssertEqual(
            s.displayStatus.detail,
            "The engine stopped ticking. Quit and reopen LidCode")
    }

    func testGuardBlockOutranksAHold() {
        let s = snapshot(isAwakeHeld: true, blockedBy: .thermalCritical)
        XCTAssertEqual(s.displayStatus.kind, .blocked)
        XCTAssertEqual(s.displayStatus.title, "Holding back")
        XCTAssertEqual(
            s.displayStatus.detail,
            "Thermal state critical. Won't re-arm until it recovers")
    }

    func testStalledOutranksAGuardBlock() {
        let s = snapshot(isStalled: true, blockedBy: .batteryFloor)
        XCTAssertEqual(s.displayStatus.kind, .stalled)
    }

    // MARK: - Holding

    func testHoldingCountsActiveSessionsAndSingularises() {
        let one = snapshot(isAwakeHeld: true, sessions: [runningSession(id: "a")])
        XCTAssertEqual(one.displayStatus.kind, .holding)
        XCTAssertEqual(one.displayStatus.title, "Keeping awake · 1 active session")

        let two = snapshot(
            isAwakeHeld: true,
            sessions: [runningSession(id: "a"), runningSession(id: "b")])
        XCTAssertEqual(two.displayStatus.title, "Keeping awake · 2 active sessions")
    }

    func testHoldingWithNoSessionsDropsTheCount() {
        let s = snapshot(isAwakeHeld: true)
        XCTAssertEqual(s.displayStatus.title, "Keeping awake")
    }

    /// A closed lid holds the Mac even when no timer or lease is running, so the
    /// clamshell path has to count as `holding` on its own.
    func testClamshellAloneCountsAsHolding() {
        let s = snapshot(isClamshellActive: true)
        XCTAssertEqual(s.displayStatus.kind, .holding)
    }

    func testHoldingDetailNamesUpToThreeLeases() {
        let s = snapshot(isAwakeHeld: true, activeLease: ["claude", "codex", "vite", "esbuild"])
        XCTAssertEqual(s.displayStatus.detail, "Held by claude, codex, vite")
    }

    func testHoldingDetailFallsBackToTheModeWhenNothingHoldsIt() {
        XCTAssertEqual(
            snapshot(isAwakeHeld: true, mode: .manual).displayStatus.detail,
            "Manual hold")
        XCTAssertEqual(
            snapshot(isAwakeHeld: true, mode: .smart).displayStatus.detail,
            "Releases when work stops")
    }

    // MARK: - Waiting / paused / idle

    func testAutoWatchArmedButUntriggeredIsWaiting() {
        let s = snapshot(isAutoWatchOn: true)
        XCTAssertEqual(s.displayStatus.kind, .waiting)
        XCTAssertEqual(s.displayStatus.title, "Waiting for a session")
    }

    /// A user pause has to win over auto-watch, otherwise the panel claims it is
    /// still watching something the user explicitly switched off.
    func testUserPauseBeatsAutoWatch() {
        let s = snapshot(isAutoWatchOn: true, isUserPaused: true)
        XCTAssertEqual(s.displayStatus.kind, .paused)
        XCTAssertEqual(s.displayStatus.title, "Paused by you")
        XCTAssertEqual(s.displayStatus.detail, "Auto-watch won't turn this back on")
    }

    func testPausedDetailCountsWhatIsStillRunning() {
        let s = snapshot(isUserPaused: true, activeLease: ["claude", "codex"])
        XCTAssertEqual(
            s.displayStatus.detail,
            "2 running. Auto-watch won't turn this back on")
    }

    func testIdleReportsTheLastStopReason() {
        let s = snapshot(lastStopReason: .timerExpired)
        XCTAssertEqual(s.displayStatus.kind, .idle)
        XCTAssertEqual(s.displayStatus.title, "Idle")
        XCTAssertEqual(s.displayStatus.detail, "Last stop: Session timer expired")
    }

    func testEveryKindProducesNonEmptyText() {
        let cases: [RuntimeSnapshot] = [
            snapshot(isStalled: true),
            snapshot(blockedBy: .heartbeatLost),
            snapshot(isAwakeHeld: true),
            snapshot(isAutoWatchOn: true),
            snapshot(isUserPaused: true),
            snapshot(),
        ]
        XCTAssertEqual(Set(cases.map { $0.displayStatus.kind }).count, RuntimeStatusKind.allCases.count)
        for c in cases {
            XCTAssertFalse(c.displayStatus.title.isEmpty)
            XCTAssertFalse(c.displayStatus.detail.isEmpty)
        }
    }
}
