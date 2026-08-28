import XCTest
@testable import LidCodeKit

/// The exact shape Warp writes today. Copied verbatim from a live `warp.log` rather
/// than hand-typed, because every part of it is a parsing hazard: the timestamp is not
/// full ISO8601, the title carries a Rust `Some(...)` wrapper with its own quotes and a
/// `//`, and the JSON body is unquoted and runs to end of line.
private let liveLine = """
2026-08-26T16:57:42Z [INFO] Received OSC 777 notification: title=Some("warp://cli-agent"), \
body={"v":1,"agent":"claude","event":"tool_complete",\
"session_id":"9fafee7e-8769-462b-9ad9-67be152d2df0",\
"cwd":"/Users/princewagan/liddy-0.1.0","project":"liddy-0.1.0","tool_name":"Bash"}
"""

final class AgentLogLineTest: XCTestCase {
    func testLiveLineParsesEveryField() throws {
        let parsed = try XCTUnwrap(AgentSessionReader.parse(line: liveLine))
        XCTAssertEqual(parsed.sessionId, "9fafee7e-8769-462b-9ad9-67be152d2df0")
        XCTAssertEqual(parsed.agent, "claude")
        XCTAssertEqual(parsed.event, "tool_complete")
        XCTAssertEqual(parsed.project, "liddy-0.1.0")
        XCTAssertEqual(parsed.cwd, "/Users/princewagan/liddy-0.1.0")
        XCTAssertEqual(parsed.toolName, "Bash")
    }

    /// The stamp has no offset and no fractional part, so it must be read as UTC
    /// explicitly — a formatter left on the device timezone would place this event
    /// hours away and silently change what counts as stale.
    func testTimestampIsReadAsUtc() throws {
        let parsed = try XCTUnwrap(AgentSessionReader.parse(line: liveLine))
        XCTAssertEqual(parsed.at, Date(timeIntervalSince1970: 1_787_763_462))
    }

    /// The body contains `"` and `,` and `}` inside string values, so anything that
    /// splits on punctuation instead of handing the whole tail to JSON will truncate.
    func testBodyIsTakenToEndOfLineNotToTheFirstBrace() throws {
        let line = #"2026-08-26T16:57:42Z [INFO] Received OSC 777 notification: title=Some("warp://cli-agent"), body={"agent":"claude","event":"permission_request","session_id":"abc","cwd":"/tmp/a","project":"a","summary":"Run {rm -rf}, then, stop"}"#
        let parsed = try XCTUnwrap(AgentSessionReader.parse(line: line))
        XCTAssertEqual(parsed.event, "permission_request")
        XCTAssertEqual(parsed.project, "a")
    }

    func testUnrelatedLogLineIsIgnored() {
        XCTAssertNil(AgentSessionReader.parse(line: "2026-08-26T16:57:42Z [INFO] starting up"))
    }

    func testMalformedJsonIsIgnoredRatherThanCrashing() {
        let line = "2026-08-26T16:57:42Z [INFO] Received OSC 777 notification: body={not json"
        XCTAssertNil(AgentSessionReader.parse(line: line))
    }

    /// A line with no session cannot be keyed, so it is not half-recorded.
    func testMissingSessionIdIsIgnored() {
        let line = #"2026-08-26T16:57:42Z [INFO] Received OSC 777 notification: body={"event":"stop"}"#
        XCTAssertNil(AgentSessionReader.parse(line: line))
    }

    func testUnparseableTimestampIsIgnored() {
        let line = #"garbage [INFO] Received OSC 777 notification: body={"event":"stop","session_id":"a"}"#
        XCTAssertNil(AgentSessionReader.parse(line: line))
    }

    /// Observed in the wild on some events. The folder name is the same string the
    /// emitter would have put in `project`, so it is a substitution, not a guess.
    func testMissingProjectFallsBackToTheFolderName() throws {
        let line = #"2026-08-26T16:57:42Z [INFO] Received OSC 777 notification: body={"event":"stop","session_id":"a","cwd":"/Users/x/my-repo"}"#
        let parsed = try XCTUnwrap(AgentSessionReader.parse(line: line))
        XCTAssertEqual(parsed.project, "my-repo")
    }
}

final class AgentEventClassificationTest: XCTestCase {
    /// `permission_request` is the one that looks idle and is not: the agent is blocked
    /// on a human, but the run is live and letting the Mac sleep through the prompt
    /// would strand it.
    func testRunningEventsCountAsWorking() {
        for event in ["session_start", "prompt_submit", "tool_complete", "permission_request"] {
            XCTAssertTrue(AgentSessionReader.isWorking(event: event), "\(event) should be working")
        }
    }

    /// `idle_prompt` belongs here: control is back with the user, who may never return.
    func testFinishedEventsDoNotCountAsWorking() {
        for event in ["stop", "stop_failure", "idle_prompt"] {
            XCTAssertFalse(AgentSessionReader.isWorking(event: event), "\(event) should be idle")
        }
    }

    /// The emitter is a separate app that can add event names without telling us. An
    /// unknown name must fail closed, or a future release would pin the Mac awake.
    func testUnknownEventFailsClosed() {
        XCTAssertFalse(AgentSessionReader.isWorking(event: "compacting"))
        XCTAssertFalse(AgentSessionReader.isWorking(event: ""))
    }

    func testTheTwoSetsDoNotOverlap() {
        XCTAssertTrue(AgentSessionReader.workingEvent.isDisjoint(with: AgentSessionReader.idleEvent))
    }
}

final class AgentSessionTailTest: XCTestCase {
    private func line(_ stamp: String, _ session: String, _ event: String, project: String = "p") -> String {
        "\(stamp) [INFO] Received OSC 777 notification: title=Some(\"warp://cli-agent\"), "
            + #"body={"v":1,"agent":"claude","event":"\#(event)","session_id":"\#(session)","#
            + #""cwd":"/tmp/\#(project)","project":"\#(project)"}"#
    }

    private func sessions(_ text: String, dropsPartialFirstLine: Bool = false) -> [String: AgentSession] {
        AgentSessionReader.sessions(
            fromTail: Data(text.utf8), dropsPartialFirstLine: dropsPartialFirstLine)
    }

    /// The whole point of keying by session: one run emits hundreds of lines and the
    /// menu shows one row whose state is the newest of them.
    func testLastEventWins() {
        let store = sessions([
            line("2026-08-26T16:00:00Z", "a", "prompt_submit"),
            line("2026-08-26T16:00:10Z", "a", "tool_complete"),
            line("2026-08-26T16:00:20Z", "a", "stop"),
        ].joined(separator: "\n"))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store["a"]?.lastEvent, "stop")
        XCTAssertFalse(store["a"]?.isWorking ?? true)
    }

    /// The tail can interleave two agents; neither may overwrite the other.
    func testSessionsAreTrackedIndependently() {
        let store = sessions([
            line("2026-08-26T16:00:00Z", "a", "tool_complete", project: "alpha"),
            line("2026-08-26T16:00:01Z", "b", "stop", project: "beta"),
            line("2026-08-26T16:00:02Z", "a", "tool_complete", project: "alpha"),
        ].joined(separator: "\n"))
        XCTAssertEqual(store["a"]?.project, "alpha")
        XCTAssertEqual(store["b"]?.project, "beta")
    }

    /// A byte-offset seek lands mid-line far more often than not, and the fragment left
    /// behind is not valid JSON — but if it happened to be, it would be an *older*
    /// event resurrected out of order.
    func testPartialFirstLineIsDropped() {
        let text = #"session_id":"ghost","event":"tool_complete"}"# + "\n"
            + line("2026-08-26T16:00:00Z", "a", "tool_complete")
        let store = sessions(text, dropsPartialFirstLine: true)
        XCTAssertEqual(Set(store.keys), ["a"])
    }

    func testFirstLineIsKeptWhenTheWholeFileFitsInTheWindow() {
        let text = line("2026-08-26T16:00:00Z", "a", "tool_complete")
        XCTAssertEqual(Set(sessions(text, dropsPartialFirstLine: false).keys), ["a"])
    }

    /// Warp writes plenty of unrelated lines between agent events.
    func testNoiseBetweenEventsIsSkipped() {
        let text = [
            "2026-08-26T16:00:00Z [INFO] some other warp log line",
            line("2026-08-26T16:00:01Z", "a", "tool_complete"),
            "2026-08-26T16:00:02Z [WARN] unrelated",
        ].joined(separator: "\n")
        XCTAssertEqual(Set(sessions(text).keys), ["a"])
    }

    func testEmptyTailIsEmpty() {
        XCTAssertTrue(sessions("").isEmpty)
    }
}

final class SessionSnapshotTest: XCTestCase {
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())
    private var logURL: URL { directory.appendingPathComponent("warp.log") }
    /// A path that cannot exist, so the fallback query is exercised as "unavailable"
    /// rather than reaching for the real Warp database from a unit test.
    private var absentDatabase: URL { directory.appendingPathComponent("no-such.sqlite") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidcode-session-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let base = Date(timeIntervalSince1970: 1_787_763_462)

    private func write(_ line: String...) throws {
        try line.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func line(_ offsetSecond: Int, _ session: String, _ event: String, project: String = "p") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let stamp = formatter.string(from: base.addingTimeInterval(TimeInterval(offsetSecond)))
        return "\(stamp) [INFO] Received OSC 777 notification: "
            + #"body={"agent":"claude","event":"\#(event)","session_id":"\#(session)","#
            + #""cwd":"/tmp/\#(project)","project":"\#(project)"}"#
    }

    private func reader() -> AgentSessionReader {
        AgentSessionReader(logURL: logURL, databaseURL: absentDatabase)
    }

    func testWorkingSessionBecomesPrimary() throws {
        try write(line(0, "a", "tool_complete", project: "liddy-0.1.0"))
        let snapshot = reader().read(asOf: base.addingTimeInterval(5))
        XCTAssertEqual(snapshot.active.count, 1)
        XCTAssertEqual(snapshot.primary?.project, "liddy-0.1.0")
        XCTAssertEqual(snapshot.otherCount, 0)
    }

    /// The rule the staleness cutoff exists for. Without it a crashed agent — which
    /// never emits `stop` — stays "working" in the menu until the log rotates.
    func testSessionOlderThanTheCutoffIsDropped() throws {
        try write(line(0, "a", "tool_complete"))
        let cutoff = AgentSessionReader.staleAfterSecond
        XCTAssertEqual(cutoff, 600)

        let justInside = reader().read(asOf: base.addingTimeInterval(cutoff - 1))
        XCTAssertEqual(justInside.active.count, 1, "9m59s old is still a live run")

        let justOutside = reader().read(asOf: base.addingTimeInterval(cutoff + 1))
        XCTAssertTrue(justOutside.active.isEmpty, "10m01s old must age out")
        XCTAssertNil(justOutside.primary)
    }

    func testTheCutoffItselfIsInclusive() throws {
        try write(line(0, "a", "tool_complete"))
        let snapshot = reader().read(asOf: base.addingTimeInterval(AgentSessionReader.staleAfterSecond))
        XCTAssertEqual(snapshot.active.count, 1)
    }

    /// Staleness has to be re-applied on cache hits too. A quiet log is precisely when
    /// sessions age out, and that is also precisely when nothing triggers a re-parse.
    func testStalenessStillAppliesWhenTheLogHasNotChanged() throws {
        try write(line(0, "a", "tool_complete"))
        let reader = reader()
        XCTAssertEqual(reader.read(asOf: base.addingTimeInterval(1)).active.count, 1)
        XCTAssertTrue(
            reader.read(asOf: base.addingTimeInterval(3600)).active.isEmpty,
            "the cached parse must not freeze the menu on a session that has since aged out")
    }

    func testStoppedSessionIsNotActiveEvenWhenFresh() throws {
        try write(line(0, "a", "stop"))
        let snapshot = reader().read(asOf: base.addingTimeInterval(1))
        XCTAssertTrue(snapshot.active.isEmpty)
    }

    /// The subtitle shows one name and a count, so the newest run has to sort first.
    func testActiveIsSortedMostRecentlySeenFirst() throws {
        try write(
            line(0, "a", "tool_complete", project: "old"),
            line(30, "b", "tool_complete", project: "new"))
        let snapshot = reader().read(asOf: base.addingTimeInterval(40))
        XCTAssertEqual(snapshot.active.map(\.project), ["new", "old"])
        XCTAssertEqual(snapshot.primary?.project, "new")
        XCTAssertEqual(snapshot.otherCount, 1)
    }

    func testOtherCountNeverGoesNegative() {
        XCTAssertEqual(SessionSnapshot.empty.otherCount, 0)
        XCTAssertNil(SessionSnapshot.empty.primary)
    }

    /// Warp not installed is a normal state on most Macs, not a failure.
    func testMissingLogReturnsAnEmptySnapshotRatherThanThrowing() {
        let snapshot = AgentSessionReader(
            logURL: directory.appendingPathComponent("absent.log"),
            databaseURL: absentDatabase).read()
        XCTAssertTrue(snapshot.active.isEmpty)
        XCTAssertNil(snapshot.primary)
        XCTAssertNil(snapshot.fallbackName)
    }

    /// A log that vanishes between ticks must clear the menu, not keep serving the
    /// last thing it saw.
    func testLogDisappearingClearsThePreviousResult() throws {
        try write(line(0, "a", "tool_complete"))
        let reader = reader()
        XCTAssertEqual(reader.read(asOf: base.addingTimeInterval(1)).active.count, 1)
        try FileManager.default.removeItem(at: logURL)
        XCTAssertTrue(reader.read(asOf: base.addingTimeInterval(2)).active.isEmpty)
    }

    func testGrowingLogIsPickedUp() throws {
        try write(line(0, "a", "tool_complete"))
        let reader = reader()
        XCTAssertEqual(reader.read(asOf: base.addingTimeInterval(1)).active.count, 1)
        try write(line(0, "a", "tool_complete"), line(5, "b", "tool_complete"))
        XCTAssertEqual(reader.read(asOf: base.addingTimeInterval(10)).active.count, 2)
    }

    /// Only the tail is read, so an 8 MB log costs the same as a small one.
    func testOnlyTheTailWindowIsRead() throws {
        let filler = String(repeating: "2026-08-26T15:00:00Z [INFO] filler\n", count: 40_000)
        let text = filler + line(0, "a", "tool_complete") + "\n"
        XCTAssertGreaterThan(text.utf8.count, Int(AgentSessionReader.tailByteLimit))
        try text.write(to: logURL, atomically: true, encoding: .utf8)
        let snapshot = reader().read(asOf: base.addingTimeInterval(1))
        XCTAssertEqual(snapshot.primary?.id, "a", "the newest events live at the end of the file")
    }

    func testSnapshotRoundTripsThroughCodable() throws {
        let snapshot = SessionSnapshot(
            active: [AgentSession(
                id: "a", agent: "claude", project: "p", cwd: "/tmp/p",
                lastEvent: "tool_complete", lastSeenAt: base, isWorking: true)],
            primary: nil,
            otherCount: 0,
            fallbackName: "fallback")
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: data), snapshot)
    }
}

final class WarpDatabaseTest: XCTestCase {
    /// SQLite stops a URI path at `?` and reads `%` as an escape, so both have to be
    /// encoded — and `%` has to go first or it would double-encode the others.
    func testUriEscapesTheCharactersSqliteTreatsAsSyntax() {
        XCTAssertEqual(
            AgentSessionReader.uri(forPath: "/tmp/a?b#c"),
            "file:/tmp/a%3fb%23c?mode=ro")
        XCTAssertEqual(
            AgentSessionReader.uri(forPath: "/tmp/100%"),
            "file:/tmp/100%25?mode=ro")
    }

    /// The real path has spaces in it ("Group Containers", "Application Support") and
    /// SQLite accepts them raw, so they must not be mangled into "+" or "%20".
    func testUriLeavesSpacesAlone() {
        XCTAssertEqual(
            AgentSessionReader.uri(forPath: "/a b/c d.sqlite"),
            "file:/a b/c d.sqlite?mode=ro")
    }

    func testMissingDatabaseReturnsNilRatherThanThrowing() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidcode-absent-\(UUID().uuidString).sqlite")
        XCTAssertNil(AgentSessionReader.warpTabName(databaseURL: absent))
    }

    /// A file that exists but is not a database must fail the same quiet way.
    func testGarbageDatabaseReturnsNil() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidcode-garbage-\(UUID().uuidString).sqlite")
        try Data("this is not a database".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertNil(AgentSessionReader.warpTabName(databaseURL: path))
    }
}
