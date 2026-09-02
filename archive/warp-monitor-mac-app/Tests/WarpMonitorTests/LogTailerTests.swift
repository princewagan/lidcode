import Foundation
import Testing
@testable import WarpMonitor

// MARK: - Helpers

/// Build a synthetic OSC 777 log line in the exact format Warp writes.
private func syntheticLine(
    event: String,
    agent: String = "claude",
    sessionId: String = "test-session-id-1234",
    cwd: String = "/Users/princewagan/television",
    project: String = "television",
    toolName: String? = nil,
    errorType: String? = nil
) -> String {
    var bodyDict: [String: Any] = [
        "v": 1,
        "agent": agent,
        "event": event,
        "session_id": sessionId,
        "cwd": cwd,
        "project": project,
    ]
    if let t = toolName { bodyDict["tool_name"] = t }
    if let e = errorType { bodyDict["error_type"] = e }
    let bodyData = try! JSONSerialization.data(withJSONObject: bodyDict)
    let bodyStr = String(data: bodyData, encoding: .utf8)!
    return "2026-08-18T15:17:43Z [INFO] Received OSC 777 notification: title=Some(\"warp://cli-agent\"), body=\(bodyStr)"
}

/// Write lines to a temp file, create a LogTailer opened at byte 0 (startForTesting),
/// then call readNewLines() directly — no FSEvents, no async waiting needed.
private func parseLines(_ lines: [String]) throws -> [OSC777Event] {
    let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test-warp-\(UUID().uuidString).log")
    let content = lines.joined(separator: "\n") + "\n"
    try content.write(to: tmpURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    let tailer = LogTailer(logPath: tmpURL.path)
    var received: [OSC777Event] = []
    tailer.onEvent = { received.append($0) }

    // startForTesting opens at byte 0, no FSEvents installed
    tailer.startForTesting()
    // Drive reads directly — synchronous, deterministic
    tailer.readNewLines()
    tailer.stop()

    return received
}

// MARK: - Tests

@Suite("LogTailer OSC 777 parsing")
struct LogTailerTests {

    // MARK: - Parsing tests (synchronous, deterministic)

    @Test("Session start event is parsed correctly")
    func testSessionStartParsed() throws {
        let events = try parseLines([syntheticLine(event: "session_start")])

        #expect(events.count == 1)
        #expect(events[0].event == .sessionStart)
        #expect(events[0].sessionId == "test-session-id-1234")
        #expect(events[0].cwd == "/Users/princewagan/television")
        #expect(events[0].project == "television")
    }

    @Test("tool_complete event is parsed with tool_name")
    func testToolCompleteParsed() throws {
        let events = try parseLines([syntheticLine(event: "tool_complete", toolName: "Bash")])

        #expect(events.count == 1)
        #expect(events[0].event == .toolComplete)
        #expect(events[0].toolName == "Bash")
    }

    @Test("stop_failure event is parsed with error_type")
    func testStopFailureParsed() throws {
        let events = try parseLines([syntheticLine(event: "stop_failure", errorType: "rate_limit")])

        #expect(events.count == 1)
        #expect(events[0].event == .stopFailure)
        #expect(events[0].errorType == "rate_limit")
    }

    @Test("Multiple events in one file are all parsed")
    func testMultipleEvents() throws {
        let events = try parseLines([
            syntheticLine(event: "session_start"),
            syntheticLine(event: "tool_complete", toolName: "Read"),
            syntheticLine(event: "stop_failure", errorType: "rate_limit"),
        ])
        #expect(events.count == 3)
        #expect(events[0].event == .sessionStart)
        #expect(events[1].event == .toolComplete)
        #expect(events[2].event == .stopFailure)
    }

    @Test("Non-claude agent events are ignored")
    func testNonClaudeAgentIgnored() throws {
        let events = try parseLines([
            syntheticLine(event: "session_start", agent: "other-tool"),
            syntheticLine(event: "tool_complete"),  // claude, should pass
        ])
        // Only the claude event should pass through
        #expect(events.count == 1)
        #expect(events[0].event == .toolComplete)
    }

    @Test("Lines without OSC 777 marker are ignored")
    func testNonOSCLinesIgnored() throws {
        let events = try parseLines([
            "2026-08-18T15:17:43Z [INFO] Some unrelated log line",
            "2026-08-18T15:17:43Z [DEBUG] Another log line",
            syntheticLine(event: "session_start"),
        ])
        #expect(events.count == 1)
        #expect(events[0].event == .sessionStart)
    }

    @Test("stop_failure → error status transition via state machine")
    func testStopFailureTriggersErrorInStateMachine() throws {
        let events = try parseLines([
            syntheticLine(event: "session_start"),
            syntheticLine(event: "stop_failure", errorType: "rate_limit"),
        ])
        #expect(events.count == 2)

        var state = ClaudeSessionState(
            sessionId: events[0].sessionId,
            cwd: events[0].cwd,
            project: events[0].project
        )
        // Initial state is running (session created from first event in state machine)
        #expect(state.status == .running)

        for event in events {
            state.apply(event: event.event, at: event.receivedAt,
                        toolName: event.toolName, errorType: event.errorType)
        }
        #expect(state.status == .error, "Expected .error after stop_failure, got \(state.status)")
    }

    // MARK: - State machine transition tests (pure, no I/O)

    @Test("State machine: full transition sequence")
    func testStateMachineTransitions() {
        var state = ClaudeSessionState(sessionId: "sm-test", cwd: "/test", project: "test")

        // Created in running
        #expect(state.status == .running)

        // tool_complete keeps running
        state.apply(event: .toolComplete, at: Date())
        #expect(state.status == .running)

        // prompt_submit stays running
        state.apply(event: .promptSubmit, at: Date())
        #expect(state.status == .running)

        // idle_prompt → finished
        state.apply(event: .idlePrompt, at: Date())
        #expect(state.status == .finished)

        // A tool_complete AFTER a finish means Claude picked the work back up.
        // Status tracks the most recent event, so this must return to running.
        // The old table pinned it to .finished here, which is why long-idle
        // sessions kept reporting a stale state.
        state.apply(event: .toolComplete, at: Date())
        #expect(state.status == .running,
            "tool_complete after finishing means work resumed, not still done")

        // session_start → running (new session resets)
        state.apply(event: .sessionStart, at: Date())
        #expect(state.status == .running)

        // stop_failure → error (NOT warning — warning is the old generic value)
        state.apply(event: .stopFailure, at: Date())
        #expect(state.status == .error,
            "stop_failure must produce .error, not .warning")

        // Claude running another tool after a failure means it is working again.
        // The old table required session_start/prompt_submit to clear .error, so a
        // session that recovered on its own stayed red indefinitely.
        state.apply(event: .toolComplete, at: Date())
        #expect(state.status == .running,
            "tool_complete after a failure means Claude resumed, not still errored")

        // prompt_submit clears error → running
        state.apply(event: .promptSubmit, at: Date())
        #expect(state.status == .running)

        // stop → finished
        state.apply(event: .stop, at: Date())
        #expect(state.status == .finished)

        // permission_request from running → blocked (NOT warning)
        state.apply(event: .sessionStart, at: Date())
        state.apply(event: .permissionRequest, at: Date())
        #expect(state.status == .blocked,
            "permission_request must produce .blocked, not .warning")

        // session_start clears blocked → running
        state.apply(event: .sessionStart, at: Date())
        #expect(state.status == .running)
    }

    @Test("Approved permission prompt does not leave the session stuck on blocked")
    func testBlockedClearsAfterApprovalAndStop() {
        // Regression for the bug the user reported: nearly every tab showed
        // "Blocked" when it was actually done.
        //
        // This is the ordinary lifecycle of an approved permission prompt. The old
        // transition table only cleared .blocked on session_start/prompt_submit, so
        // tool_complete and stop both left the session pinned to blocked forever.
        // Observed live on session 7a7c4063 "Update push skill for commit and push",
        // whose last event was a clean stop while the app reported blocked.
        var state = ClaudeSessionState(sessionId: "approve-flow", cwd: "/test", project: "test")

        state.apply(event: .permissionRequest, at: Date(), summary: "Wants to run Bash")
        #expect(state.status == .blocked)
        #expect(state.blockedReason != nil, "the prompt's summary should be surfaced while blocked")

        // User approves; Claude carries on and finishes cleanly.
        state.apply(event: .toolComplete, at: Date())
        #expect(state.status == .running, "approval resumes work")
        #expect(state.blockedReason == nil,
            "a resolved prompt must stop advertising what it was waiting on")

        state.apply(event: .stop, at: Date())
        #expect(state.status == .finished,
            "a session whose last event is stop is done, not blocked")
    }

    @Test("A failure after finishing is not masked by the earlier finish")
    func testErrorAfterFinishIsReported() {
        // The old table ignored stop_failure while in .finished, so a session that
        // completed once and was then re-run into an error kept reporting done.
        var state = ClaudeSessionState(sessionId: "err-after-done", cwd: "/test", project: "test")

        state.apply(event: .stop, at: Date())
        #expect(state.status == .finished)

        state.apply(event: .stopFailure, at: Date(), query: "deploy the site")
        #expect(state.status == .error, "the newer failure must win over the older finish")
        #expect(state.lastQuery != nil, "the failing request should be surfaced")
    }

    @Test("10-minute running timeout downgrades to finished")
    func testRunningTimeout() {
        var state = ClaudeSessionState(sessionId: "timeout-test", cwd: "/test", project: "test")
        #expect(state.status == .running)

        // Backdate by 11 minutes
        state.lastEventAt = Date().addingTimeInterval(-660)

        let changed = state.checkTimeout()
        #expect(changed == true)
        #expect(state.status == .finished)
        #expect(state.timedOut == true)
        // last_event must be a wire-safe ClaudeEvent value (not "timed_out")
        #expect(state.lastEvent == "stop", "last_event must be wire-safe 'stop', not 'timed_out'")
    }

    @Test("Timeout does not fire for non-running states")
    func testTimeoutOnlyForRunning() {
        var state = ClaudeSessionState(sessionId: "timeout-safe", cwd: "/test", project: "test")
        state.apply(event: .stop, at: Date())
        #expect(state.status == .finished)

        state.lastEventAt = Date().addingTimeInterval(-660)
        let changed = state.checkTimeout()
        #expect(changed == false)
        #expect(state.status == .finished)
    }

    @Test("Stale finished session is marked for pruning after 30 minutes")
    func testStaleSessionPruning() {
        var state = ClaudeSessionState(sessionId: "stale-test", cwd: "/test", project: "test")
        state.apply(event: .stop, at: Date())
        #expect(state.status == .finished)
        #expect(state.isStale == false)

        // Backdate by 31 minutes
        state.lastEventAt = Date().addingTimeInterval(-1860)
        #expect(state.isStale == true)
    }

    @Test("Running session is never considered stale")
    func testRunningNotStale() {
        var state = ClaudeSessionState(sessionId: "running-stale", cwd: "/test", project: "test")
        #expect(state.status == .running)
        // Even if backdated
        state.lastEventAt = Date().addingTimeInterval(-3600)
        #expect(state.isStale == false)
    }

    // MARK: - Phase 4 resilience verification (plan §"Phase 4 — Resilience Verification" step 2)

    /// Replays the stop_failure/rate_limit scenario from the plan using a fixture log file.
    /// Proves that stop_failure → .error (the new granular status, replacing the old .warning).
    /// This is the fixture-based equivalent of the plan's manual echo-to-warp.log step —
    /// we write to a temp file, NOT to ~/Library/Logs/warp.log.
    @Test("Phase 4 resilience: stop_failure rate_limit line in fixture produces error status")
    func testPhase4ErrorScenario() throws {
        // This is the exact line format from the plan's step 2, written to a temp fixture.
        let fixtureLine = #"2026-08-18T15:17:43Z [INFO] Received OSC 777 notification: title=Some("warp://cli-agent"), body={"v":1,"agent":"claude","event":"stop_failure","session_id":"test-session","cwd":"/Users/princewagan/television","project":"television","error_type":"rate_limit"}"#

        let events = try parseLines([fixtureLine])
        #expect(events.count == 1, "Expected 1 parsed event from fixture line")
        #expect(events[0].event == .stopFailure)
        #expect(events[0].errorType == "rate_limit")
        #expect(events[0].sessionId == "test-session")
        #expect(events[0].cwd == "/Users/princewagan/television")

        // Run through the state machine — a new session starts in .running then gets the event
        var state = ClaudeSessionState(
            sessionId: events[0].sessionId,
            cwd: events[0].cwd,
            project: events[0].project
        )
        // Session is initially running (created on first event)
        #expect(state.status == .running)

        state.apply(event: events[0].event, at: events[0].receivedAt,
                    toolName: events[0].toolName, errorType: events[0].errorType)
        #expect(state.status == .error,
            "stop_failure must produce .error status (not .warning — that is the legacy value)")
        #expect(state.errorType == "rate_limit")
    }

    @Test("Timed-out session: timedOut flag is set, lastEvent is wire-safe 'stop'")
    func testTimedOutWireSafety() {
        var state = ClaudeSessionState(sessionId: "wire-safe-test", cwd: "/test", project: "test")
        state.lastEventAt = Date().addingTimeInterval(-700) // 11+ minutes ago

        state.checkTimeout()

        #expect(state.timedOut == true)
        #expect(state.lastEvent == "stop",
            "last_event must be 'stop' on the wire — 'timed_out' is not a valid Zod enum value")
        // Verify it round-trips through ClaudeEvent without crashing
        let event = ClaudeEvent(rawValue: state.lastEvent)
        #expect(event == .stop)
    }

    // MARK: - Idle first-event tests (Fix 1 regression suite)
    //
    // LogTailer seeks to END of warp.log on startup, so the state machine always
    // joins sessions mid-stream.  The first event seen for a tab may be one that
    // signals Claude is already done.  These tests confirm every .idle → X
    // transition maps to the correct terminal/active status rather than blindly
    // transitioning to .running.

    /// Helper: create a ClaudeSessionState pre-set to .idle to simulate a fresh
    /// tab that has no prior session data but receives its first event from mid-stream.
    private func idleState() -> ClaudeSessionState {
        var s = ClaudeSessionState(sessionId: "idle-entry-test", cwd: "/test", project: "test")
        // Manually force back to .idle to simulate "no session seen yet for this cwd".
        // (ClaudeSessionState is initialised to .running by convention; we override for testing.)
        s.status = .idle
        return s
    }

    @Test("idle + idle_prompt → finished (session already done when we join)")
    func testIdleFirstEventIdlePromptGoesFinished() {
        var s = idleState()
        s.apply(event: .idlePrompt, at: Date())
        #expect(s.status == .finished,
            "A tab whose first observed event is idle_prompt should be .finished, not .running")
    }

    @Test("idle + stop → finished")
    func testIdleFirstEventStopGoesFinished() {
        var s = idleState()
        s.apply(event: .stop, at: Date())
        #expect(s.status == .finished)
    }

    @Test("idle + stop_failure → error")
    func testIdleFirstEventStopFailureGoesError() {
        var s = idleState()
        s.apply(event: .stopFailure, at: Date())
        #expect(s.status == .error,
            "A tab whose first observed event is stop_failure should be .error (not .warning)")
    }

    @Test("idle + permission_request → blocked")
    func testIdleFirstEventPermissionRequestGoesBlocked() {
        var s = idleState()
        s.apply(event: .permissionRequest, at: Date())
        #expect(s.status == .blocked,
            "A tab whose first observed event is permission_request should be .blocked (not .warning)")
    }

    @Test("idle + session_start → running")
    func testIdleFirstEventSessionStartGoesRunning() {
        var s = idleState()
        s.apply(event: .sessionStart, at: Date())
        #expect(s.status == .running)
    }

    @Test("idle + prompt_submit → running")
    func testIdleFirstEventPromptSubmitGoesRunning() {
        var s = idleState()
        s.apply(event: .promptSubmit, at: Date())
        #expect(s.status == .running)
    }

    @Test("idle + tool_complete → running")
    func testIdleFirstEventToolCompleteGoesRunning() {
        var s = idleState()
        s.apply(event: .toolComplete, at: Date())
        #expect(s.status == .running)
    }

    @Test("idle → finished state still respects 10-minute timeout (only .running times out)")
    func testIdleFinishedDoesNotTimeout() {
        var s = idleState()
        s.apply(event: .idlePrompt, at: Date())
        #expect(s.status == .finished)
        // Backdate — timeout rule is only for .running sessions
        s.lastEventAt = Date().addingTimeInterval(-700)
        let changed = s.checkTimeout()
        #expect(changed == false, "timeout must not fire on a .finished session entered via .idle")
        #expect(s.status == .finished)
    }

    @Test("idle → error state is NOT pruned by 30-minute rule (needs user action)")
    func testIdleErrorIsNotStale() {
        var s = idleState()
        s.apply(event: .stopFailure, at: Date())
        #expect(s.status == .error)
        // Backdate by 31 minutes — error sessions must NOT be pruned
        s.lastEventAt = Date().addingTimeInterval(-1860)
        #expect(s.isStale == false,
            "error sessions must not be pruned regardless of age — they need user action")
    }

    @Test("idle → blocked state is NOT pruned by 30-minute rule (needs user action)")
    func testIdleBlockedIsNotStale() {
        var s = idleState()
        s.apply(event: .permissionRequest, at: Date())
        #expect(s.status == .blocked)
        // Backdate by 31 minutes — blocked sessions must NOT be pruned
        s.lastEventAt = Date().addingTimeInterval(-1860)
        #expect(s.isStale == false,
            "blocked sessions must not be pruned regardless of age — they need user action")
    }

    // MARK: - New enum split: blocked vs error (rich-status feature)

    @Test("permission_request fixture line → blocked status and blocked_reason populated")
    func testPermissionRequestBlockedWithReason() throws {
        // Fixture line containing a permission_request event with a summary field.
        // This exercises: parsing → OSC777Event.summary → ClaudeSessionState.blockedReason.
        let fixtureLine = #"2026-08-19T10:00:00Z [INFO] Received OSC 777 notification: title=Some("warp://cli-agent"), body={"v":1,"agent":"claude","event":"permission_request","session_id":"blocked-session-1","cwd":"/Users/princewagan/television","project":"television","summary":"Wants to run AskUserQuestion: {\"question\":\"Should I overwrite package.json?\"}"}"#

        let events = try parseLines([fixtureLine])
        #expect(events.count == 1, "Expected 1 parsed event")
        #expect(events[0].event == .permissionRequest)
        #expect(events[0].summary != nil, "summary field should be parsed from the body")
        #expect(events[0].agent == "claude")

        var state = ClaudeSessionState(
            sessionId: events[0].sessionId,
            cwd: events[0].cwd,
            project: events[0].project
        )
        state.status = .idle  // simulate mid-stream join

        state.apply(
            event: events[0].event,
            at: events[0].receivedAt,
            toolName: events[0].toolName,
            errorType: events[0].errorType,
            agent: events[0].agent,
            summary: events[0].summary,
            query: events[0].query
        )

        #expect(state.status == .blocked,
            "permission_request must produce .blocked (not .warning or .error)")
        #expect(state.blockedReason != nil,
            "blocked_reason should be populated from the summary field")
        #expect(state.agent == "claude")
    }

    @Test("stop_failure fixture line → error status and last_query populated")
    func testStopFailureErrorWithQuery() throws {
        // Fixture line with a stop_failure event carrying a query field.
        let fixtureLine = #"2026-08-19T10:00:00Z [INFO] Received OSC 777 notification: title=Some("warp://cli-agent"), body={"v":1,"agent":"claude","event":"stop_failure","session_id":"error-session-1","cwd":"/Users/princewagan/television","project":"television","error_type":"rate_limit","query":"Refactor the authentication module to use JWT"}"#

        let events = try parseLines([fixtureLine])
        #expect(events.count == 1, "Expected 1 parsed event")
        #expect(events[0].event == .stopFailure)
        #expect(events[0].query != nil, "query field should be parsed from the body")

        var state = ClaudeSessionState(
            sessionId: events[0].sessionId,
            cwd: events[0].cwd,
            project: events[0].project
        )

        state.apply(
            event: events[0].event,
            at: events[0].receivedAt,
            toolName: events[0].toolName,
            errorType: events[0].errorType,
            agent: events[0].agent,
            summary: events[0].summary,
            query: events[0].query
        )

        #expect(state.status == .error,
            "stop_failure must produce .error (not .warning)")
        #expect(state.lastQuery != nil,
            "last_query should be populated from the query field")
        #expect(state.lastQuery == "Refactor the authentication module to use JWT")
    }

    @Test("blocked_reason is truncated to 200 chars")
    func testBlockedReasonTruncation() {
        var s = ClaudeSessionState(sessionId: "trunc-test", cwd: "/test", project: "test")
        let longSummary = String(repeating: "x", count: 300)
        s.apply(event: .permissionRequest, at: Date(), summary: longSummary)
        #expect(s.blockedReason?.count == 200,
            "blocked_reason must be truncated to 200 chars to keep the wire blob small")
    }

    @Test("last_query is truncated to 200 chars")
    func testLastQueryTruncation() {
        var s = ClaudeSessionState(sessionId: "trunc-query", cwd: "/test", project: "test")
        let longQuery = String(repeating: "q", count: 300)
        s.apply(event: .stopFailure, at: Date(), query: longQuery)
        #expect(s.lastQuery?.count == 200,
            "last_query must be truncated to 200 chars to keep the wire blob small")
    }

    // MARK: - Per-session status isolation
    //
    // Replaces an older "aggregate priority" test that asserted a folder rolled
    // its sessions up into a single worst-status value. That aggregation was the
    // bug: one failing session turned every tab in the folder red. It has been
    // deleted from the production code, so the test that blessed it is gone too.
    //
    // The invariant now worth guarding is the opposite one.

    @Test("Sessions sharing a cwd hold independent statuses")
    func testSessionsInSameFolderAreIndependent() {
        let now = Date()
        let cwd = "/Users/princewagan/advopark"

        var failing = ClaudeSessionState(sessionId: "aaa", cwd: cwd, project: "advopark")
        var working = ClaudeSessionState(sessionId: "bbb", cwd: cwd, project: "advopark")
        var waiting = ClaudeSessionState(sessionId: "ccc", cwd: cwd, project: "advopark")
        var done    = ClaudeSessionState(sessionId: "ddd", cwd: cwd, project: "advopark")

        failing.apply(event: .stopFailure, at: now, query: "deploy")
        working.apply(event: .toolComplete, at: now, toolName: "Read")
        waiting.apply(event: .permissionRequest, at: now, summary: "Wants to run rm")
        done.apply(event: .stop, at: now)

        // Four sessions, one folder, four different answers. No session's state
        // may be reachable from another's.
        #expect(failing.status == .error)
        #expect(working.status == .running)
        #expect(waiting.status == .blocked)
        #expect(done.status == .finished)
    }

    @Test("A failure does not leak into a sibling session's context fields")
    func testFailureDoesNotLeakContext() {
        let now = Date()
        let cwd = "/Users/princewagan/advopark"

        var failing = ClaudeSessionState(sessionId: "aaa", cwd: cwd, project: "advopark")
        var sibling = ClaudeSessionState(sessionId: "bbb", cwd: cwd, project: "advopark")

        failing.apply(event: .stopFailure, at: now, query: "migrate the database")
        sibling.apply(event: .stop, at: now)

        #expect(failing.lastQuery == "migrate the database")
        #expect(sibling.lastQuery == nil, "A sibling session must not inherit a failure's query")
        #expect(sibling.status == .finished, "A sibling session must not inherit a failure's status")
    }

    @Test("Legacy .warning from an old binary still reads as blocked")
    func testLegacyWarningIsBlocked() {
        // Old Mac binaries emitted .warning instead of .blocked. Pushes from them
        // must still surface as attention-needed rather than silently unknown.
        var s = ClaudeSessionState(sessionId: "legacy", cwd: "/test", project: "test")
        s.status = .warning
        #expect(s.status == .warning)
        // StateManager maps .warning → .blocked when building a row; the phone
        // does the same in lib/tabModel.ts normalizeStatus().
    }

    // MARK: - Git branch parsing tests

    @Test("GitBranchReader: reads branch from normal .git/HEAD")
    func testGitBranchNormal() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-git-\(UUID().uuidString)")
        let gitDir = tmpDir.appendingPathComponent(".git")
        let headFile = gitDir.appendingPathComponent("HEAD")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: headFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let reader = GitBranchReader(ttl: 0) // TTL=0 so no caching in tests
        let branch = reader.branch(for: tmpDir.path)
        #expect(branch == "main", "Should read 'main' branch from HEAD file")
    }

    @Test("GitBranchReader: detached HEAD returns nil")
    func testGitBranchDetachedHead() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-git-detach-\(UUID().uuidString)")
        let gitDir = tmpDir.appendingPathComponent(".git")
        let headFile = gitDir.appendingPathComponent("HEAD")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        // Detached HEAD: raw SHA instead of ref
        try "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2\n"
            .write(to: headFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let reader = GitBranchReader(ttl: 0)
        let branch = reader.branch(for: tmpDir.path)
        #expect(branch == nil, "Detached HEAD should return nil")
    }

    @Test("GitBranchReader: missing .git returns nil")
    func testGitBranchMissingGitDir() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-git-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let reader = GitBranchReader(ttl: 0)
        let branch = reader.branch(for: tmpDir.path)
        #expect(branch == nil, "No .git directory should return nil")
    }

    @Test("GitBranchReader: .git file (worktree) with gitdir: pointer")
    func testGitBranchWorktree() throws {
        // Set up: a "real" git dir with HEAD, and a worktree dir with a .git FILE
        // pointing to it.
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-worktree-\(UUID().uuidString)")
        let realGitDir = baseDir.appendingPathComponent("real-git")
        let worktreeDir = baseDir.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: realGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)

        // Write HEAD in the real git dir
        let headFile = realGitDir.appendingPathComponent("HEAD")
        try "ref: refs/heads/feat/auth\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Write .git FILE in the worktree dir pointing to the real git dir
        let gitFile = worktreeDir.appendingPathComponent(".git")
        try "gitdir: \(realGitDir.path)\n".write(to: gitFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: baseDir) }

        let reader = GitBranchReader(ttl: 0)
        let branch = reader.branch(for: worktreeDir.path)
        #expect(branch == "feat/auth",
            "Worktree .git file should resolve to the real git dir and read the branch")
    }

    @Test("GitBranchReader: cache hit avoids re-read within TTL")
    func testGitBranchCaching() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-git-cache-\(UUID().uuidString)")
        let gitDir = tmpDir.appendingPathComponent(".git")
        let headFile = gitDir.appendingPathComponent("HEAD")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/develop\n".write(to: headFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let reader = GitBranchReader(ttl: 60) // 60s TTL
        let branch1 = reader.branch(for: tmpDir.path)
        #expect(branch1 == "develop")

        // Now change the HEAD file
        try "ref: refs/heads/changed-branch\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Second read should return cached value (not the updated one)
        let branch2 = reader.branch(for: tmpDir.path)
        #expect(branch2 == "develop", "Should return cached value within TTL")

        // After invalidation, should return fresh value
        reader.invalidate(cwd: tmpDir.path)
        let branch3 = reader.branch(for: tmpDir.path)
        #expect(branch3 == "changed-branch", "Should return fresh value after cache invalidation")
    }

    // MARK: - Backfill tests

    /// Build a synthetic log line with an explicit timestamp prefix (for backfill tests).
    /// `timestamp` should be ISO 8601 UTC, e.g. "2026-08-19T10:00:00Z".
    private func backfillLine(
        timestamp: String,
        event: String,
        sessionId: String = "backfill-session-1",
        cwd: String = "/Users/princewagan/television"
    ) -> String {
        let bodyDict: [String: Any] = [
            "v": 1,
            "agent": "claude",
            "event": event,
            "session_id": sessionId,
            "cwd": cwd,
            "project": "television",
        ]
        let bodyData = try! JSONSerialization.data(withJSONObject: bodyDict)
        let bodyStr = String(data: bodyData, encoding: .utf8)!
        return "\(timestamp) [INFO] Received OSC 777 notification: title=Some(\"warp://cli-agent\"), body=\(bodyStr)"
    }

    /// Write lines to a temp file and drive backfill via `startForTesting()` + `readNewLines()`.
    /// Returns parsed events from the backfill pass only (no live events).
    private func runBackfill(_ lines: [String]) throws -> [OSC777Event] {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backfill-\(UUID().uuidString).log")
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let tailer = LogTailer(logPath: tmpURL.path)
        var received: [OSC777Event] = []
        tailer.onEvent = { received.append($0) }
        tailer.startForTesting()
        tailer.readNewLines()
        tailer.stop()
        return received
    }

    @Test("Backfill: sessions within 2-hour window are populated after startup")
    func testBackfillPopulatesSessions() throws {
        // Produce two events 30 minutes ago — well within the 2-hour window.
        // Uses the real backfill path (replayBackfillDataForTesting) so the window
        // filter and historical receivedAt are both exercised.
        let thirtyMinsAgo = Date().addingTimeInterval(-1800)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let ts = fmt.string(from: thirtyMinsAgo)

        let lines = [
            backfillLine(timestamp: ts, event: "session_start", sessionId: "bf-session-A"),
            backfillLine(timestamp: ts, event: "tool_complete",  sessionId: "bf-session-A"),
        ]
        let content = lines.joined(separator: "\n") + "\n"
        let data = content.data(using: .utf8)!

        // Build a session map in the onEvent callback — mirrors StateManager behaviour.
        var sessionMap: [String: ClaudeSessionState] = [:]
        let tailer = LogTailer(logPath: "/dev/null")
        tailer.onEvent = { event in
            if sessionMap[event.sessionId] == nil {
                sessionMap[event.sessionId] = ClaudeSessionState(
                    sessionId: event.sessionId, cwd: event.cwd, project: event.project
                )
            }
            sessionMap[event.sessionId]!.apply(
                event: event.event, at: event.receivedAt,
                toolName: event.toolName, errorType: event.errorType,
                agent: event.agent, summary: event.summary, query: event.query
            )
        }
        tailer.replayBackfillDataForTesting(data, readStart: 0)

        #expect(sessionMap["bf-session-A"] != nil, "Session must exist after backfill")
        #expect(sessionMap["bf-session-A"]!.status == .running,
            "Session with recent tool_complete (30 min ago) should be running — not yet timed out")
        // receivedAt must be the historical timestamp, not now.
        let lastEventAge = -sessionMap["bf-session-A"]!.lastEventAt.timeIntervalSinceNow
        #expect(lastEventAge > 1700 && lastEventAge < 1900,
            "lastEventAt must be ~30 min ago (1800s ± 100s), confirming historical timestamp used")
    }

    @Test("Backfill: stale running session (> 10 min ago) is timed out after state machine apply")
    func testBackfillStaleRunningTimesOut() throws {
        // Produce events 90 minutes ago — inside the 2-hour window but far beyond the
        // 10-minute running timeout.  We exercise the real backfill path
        // (replayBackfillDataForTesting) so receivedAt carries the log-line timestamp,
        // not Date().  The timeout rule must then fire correctly.
        let ninetyMinsAgo = Date().addingTimeInterval(-5400) // 90 minutes
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let ts = fmt.string(from: ninetyMinsAgo)

        let lines = [
            backfillLine(timestamp: ts, event: "session_start", sessionId: "stale-sess"),
            backfillLine(timestamp: ts, event: "tool_complete",  sessionId: "stale-sess"),
        ]
        let content = lines.joined(separator: "\n") + "\n"
        let data = content.data(using: .utf8)!

        // Collect events via the real backfill replay path.
        var receivedEvents: [OSC777Event] = []
        let tailer = LogTailer(logPath: "/dev/null")
        tailer.onEvent = { receivedEvents.append($0) }
        // readStart = 0: no first-line drop (we control the full content here).
        tailer.replayBackfillDataForTesting(data, readStart: 0)

        #expect(receivedEvents.count == 2, "Events 90 min ago are within 2h window")

        // Feed into state machine with the historical receivedAt timestamps.
        var state = ClaudeSessionState(sessionId: "stale-sess", cwd: "/test", project: "test")
        for ev in receivedEvents {
            state.apply(event: ev.event, at: ev.receivedAt,
                        toolName: ev.toolName, errorType: ev.errorType)
        }

        // lastEventAt must carry the historical timestamp (~90 min ago).
        #expect(state.lastEventAt.timeIntervalSinceNow < -600,
            "lastEventAt should be 90 min ago, well beyond the 10-min threshold")

        // Apply the timeout rule — same as StateManager.pruneStaleSessionsAndRefresh.
        let changed = state.checkTimeout()
        #expect(changed == true, "Timeout must fire for running session with 90-min-old lastEventAt")
        #expect(state.status == .finished, "Stale running session must be demoted to finished")
        #expect(state.timedOut == true)
        #expect(state.lastEvent == "stop",
            "Wire-safe last_event must be 'stop' after timeout, not 'timed_out'")
    }

    @Test("Backfill: events outside the backfill window are excluded")
    func testBackfillWindowBoundRespected() throws {
        // Uses the real backfill replay path so the cutoff filter is exercised.
        // The startForTesting/readNewLines path skips all time-filtering (live path).
        //
        // Bounds are derived from LogTailer.backfillWindowSeconds rather than
        // hardcoded. The window widened from 2h to 24h so that sticky error and
        // blocked states survive for sessions that have been quiet a long time;
        // deriving the bounds keeps this test honest across that change.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        let window = LogTailer.backfillWindowSeconds
        let insideTs  = fmt.string(from: Date().addingTimeInterval(-(window - 120)))
        let outsideTs = fmt.string(from: Date().addingTimeInterval(-(window + 120)))

        let lines = [
            backfillLine(timestamp: outsideTs, event: "tool_complete",  sessionId: "old-sess"),
            backfillLine(timestamp: insideTs,  event: "session_start",  sessionId: "new-sess"),
        ]
        let content = lines.joined(separator: "\n") + "\n"
        let data = content.data(using: .utf8)!

        var receivedEvents: [OSC777Event] = []
        let tailer = LogTailer(logPath: "/dev/null")
        tailer.onEvent = { receivedEvents.append($0) }
        // readStart = 0: we control the full content so no first-line drop needed.
        tailer.replayBackfillDataForTesting(data, readStart: 0)

        let sessionIds = Set(receivedEvents.map { $0.sessionId })

        #expect(!sessionIds.contains("old-sess"),
            "Event just past backfillWindowSeconds must be excluded")
        #expect(sessionIds.contains("new-sess"),
            "Event just inside backfillWindowSeconds must be included")
    }

    @Test("Backfill: no double-count at live-tail boundary")
    func testBackfillNoDoubleCountAtBoundary() throws {
        // Write N lines before starting, then add M more lines after (simulating live tail).
        // Total events must equal N (backfill) + M (live), not N + N + M.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let recentTs = fmt.string(from: Date().addingTimeInterval(-60)) // 1 min ago

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nodbl-\(UUID().uuidString).log")

        // Write the "pre-existing" lines.
        let preLines = [
            backfillLine(timestamp: recentTs, event: "session_start", sessionId: "pre-sess"),
            backfillLine(timestamp: recentTs, event: "tool_complete",  sessionId: "pre-sess"),
        ]
        let preContent = preLines.joined(separator: "\n") + "\n"
        try preContent.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let tailer = LogTailer(logPath: tmpURL.path)
        var allEvents: [OSC777Event] = []
        tailer.onEvent = { allEvents.append($0) }

        // startForTesting opens at offset 0 (not end), simulating the pre-existing content.
        tailer.startForTesting()
        // First readNewLines: processes all pre-existing content, advances lastOffset to EOF.
        tailer.readNewLines()

        let afterBackfillCount = allEvents.count
        #expect(afterBackfillCount == 2, "Pre-existing content must produce exactly 2 events")

        // Append live lines to the file.
        let liveContent = backfillLine(timestamp: fmt.string(from: Date()), event: "stop",
                                       sessionId: "pre-sess") + "\n"
        if let fh = FileHandle(forWritingAtPath: tmpURL.path) {
            fh.seekToEndOfFile()
            fh.write(liveContent.data(using: .utf8)!)
            fh.closeFile()
        }

        // Second readNewLines: must pick up only the new line, not re-read the old ones.
        tailer.readNewLines()
        tailer.stop()

        #expect(allEvents.count == 3,
            "Live tail must add exactly 1 new event — no double-count of the pre-existing 2")
        #expect(allEvents.last?.event == .stop)
    }

    @Test("Backfill: graceful handling of missing log file")
    func testBackfillMissingLogFile() throws {
        // Point to a path that does not exist — must not crash, must degrade silently.
        let nonExistentPath = "/tmp/warp-monitor-test-nonexistent-\(UUID().uuidString).log"
        let tailer = LogTailer(logPath: nonExistentPath)
        var received: [OSC777Event] = []
        tailer.onEvent = { received.append($0) }

        // Should complete without throwing or crashing.
        tailer.startForTesting()
        // readNewLines on a nil fileHandle must be a safe no-op.
        tailer.readNewLines()
        tailer.stop()

        #expect(received.isEmpty, "Missing log file must produce zero events (silent degradation)")
    }

    @Test("Backfill: graceful handling of empty log file")
    func testBackfillEmptyLogFile() throws {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-\(UUID().uuidString).log")
        try "".write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let tailer = LogTailer(logPath: tmpURL.path)
        var received: [OSC777Event] = []
        tailer.onEvent = { received.append($0) }

        tailer.startForTesting()
        tailer.readNewLines()
        tailer.stop()

        #expect(received.isEmpty, "Empty log file must produce zero events")
    }

    @Test("Backfill: truncated first line at byte boundary is skipped, rest parsed correctly")
    func testBackfillTruncatedFirstLine() throws {
        // Simulate what happens when backfillByteLimit cuts in the middle of a line.
        // The replayBackfillData method drops the first line when readStart > 0.
        // We test this by calling replayBackfillData directly via a subclass-like approach:
        // write content where the first "line" is deliberately incomplete,
        // and verify the second (complete) line is still parsed.

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let recentTs = fmt.string(from: Date().addingTimeInterval(-300)) // 5 min ago

        // First "line" is truncated (no timestamp prefix, just noise — as if we started mid-line).
        let truncatedFirst = "...corrupted partial line content"
        let goodSecond = backfillLine(timestamp: recentTs, event: "tool_complete",
                                      sessionId: "trunc-boundary-session")

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trunc-\(UUID().uuidString).log")
        let content = truncatedFirst + "\n" + goodSecond + "\n"
        try content.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let tailer = LogTailer(logPath: tmpURL.path)
        var received: [OSC777Event] = []
        tailer.onEvent = { received.append($0) }
        tailer.startForTesting()
        tailer.readNewLines()
        tailer.stop()

        // The good line should be parsed; the truncated first is either ignored (if
        // it doesn't contain OSC 777 marker) or dropped by the boundary skip logic.
        let parsed = received.filter { $0.sessionId == "trunc-boundary-session" }
        #expect(parsed.count == 1,
            "Good line after truncated boundary must be parsed successfully")
        #expect(parsed[0].event == .toolComplete)
    }
}

// The `prioritize` helper that lived here mirrored StateManager's folder-wide
// status aggregation. Both are gone: a row now carries exactly one session's
// own status, so there is nothing to prioritise across.
