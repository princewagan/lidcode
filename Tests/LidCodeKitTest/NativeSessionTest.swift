import XCTest
@testable import LidCodeKit

final class NativeSessionTest: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ records: [[String: Any]], at path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in records { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return url
    }
    private func stamp(_ offset: Double = 0) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    private func reader(_ provider: AIProfile.Provider) -> AgentSessionReader {
        AgentSessionReader(logURL: root.appendingPathComponent("missing.log"),
                           databaseURL: root.appendingPathComponent("missing.sqlite"),
                           nativeProfiles: [AIProfile(provider: provider, name: "Test", directory: root.path)])
    }
    private func claude(_ type: String, stop: String? = nil, offset: Double = 0) -> [String: Any] {
        var row: [String: Any] = ["type": type, "sessionId": "session-a", "cwd": "/tmp/my.project",
                                  "timestamp": stamp(offset)]
        if let stop { row["message"] = ["stop_reason": stop] }
        return row
    }
    func testClaudeDetectedWithoutWarpAndWithCustomProfile() throws {
        try write([claude("user")], at: "projects/-tmp-my-project/session-a.jsonl")
        let snapshot = reader(.claude).readAgentSession(asOf: now, isWarpEnabled: false)
        XCTAssertEqual(snapshot.activeCount, 1)
        XCTAssertEqual(snapshot.sessions.first?.title, "my.project")
        XCTAssertEqual(snapshot.sessions.first?.agent, "claude")
    }
    func testCompletedClaudeIsNotRevivedByFreshMetadataWrite() throws {
        try write([claude("user", offset: -10), claude("assistant", stop: "end_turn", offset: -5),
                   ["type": "ai-title", "aiTitle": "Finished task", "sessionId": "session-a"]],
                  at: "projects/p/session-a.jsonl")
        let snapshot = reader(.claude).readAgentSession(asOf: now)
        XCTAssertEqual(snapshot.activeCount, 0)
        XCTAssertEqual(snapshot.sessions.first?.status, .finished)
        XCTAssertEqual(snapshot.sessions.first?.title, "Finished task")
    }
    func testNativeRunningTimeoutUsesEventAgeEvenWhenFileIsFresh() throws {
        try write([claude("user", offset: -601)], at: "projects/p/session-a.jsonl")
        XCTAssertEqual(reader(.claude).readAgentSession(asOf: now).activeCount, 0)
    }
    func testCodexStartCompleteAndNewTurn() throws {
        let meta: [String: Any] = ["type": "session_meta", "timestamp": stamp(-10),
                                   "payload": ["id": "codex-a", "cwd": "/tmp/codex-project"]]
        func event(_ type: String, _ offset: Double) -> [String: Any] {
            ["type": "event_msg", "timestamp": stamp(offset), "payload": ["type": type]]
        }
        let path = "sessions/2027/01/15/rollout.jsonl"
        try write([meta, event("task_started", -9), event("task_complete", -5)], at: path)
        let r = reader(.codex)
        XCTAssertEqual(r.readAgentSession(asOf: now).activeCount, 0)
        try write([meta, event("task_started", -9), event("task_complete", -5), event("task_started", 0)], at: path)
        let snapshot = r.readAgentSession(asOf: now)
        XCTAssertEqual(snapshot.activeCount, 1)
        XCTAssertEqual(snapshot.sessions.first?.agent, "codex")
        XCTAssertEqual(snapshot.sessions.first?.title, "codex-project")
    }
    func testUnknownAndMalformedRecordsDoNotInventActivity() throws {
        try write([["type": "something-new", "sessionId": "session-a", "cwd": "/tmp/p", "timestamp": stamp()]],
                  at: "projects/p/session-a.jsonl")
        XCTAssertTrue(reader(.claude).readAgentSession(asOf: now).sessions.isEmpty)
    }
    func testWarpAndNativeSessionAreDeduplicatedAndNewerStopWins() throws {
        try write([claude("user", offset: -10), claude("assistant", stop: "end_turn", offset: -1)],
                  at: "projects/p/session-a.jsonl")
        let log = root.appendingPathComponent("warp.log")
        let line = "\(stamp(-5)) [INFO] Received OSC 777 notification: body={\"agent\":\"claude\",\"event\":\"tool_complete\",\"session_id\":\"session-a\",\"cwd\":\"/tmp/my.project\",\"project\":\"my.project\"}"
        try line.write(to: log, atomically: true, encoding: .utf8)
        let r = AgentSessionReader(logURL: log, databaseURL: root.appendingPathComponent("missing.sqlite"),
                                   nativeProfiles: [AIProfile(provider: .claude, name: "Test", directory: root.path)])
        let snapshot = r.readAgentSession(asOf: now)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.activeCount, 0)
    }
    func testWarpPermissionStateWinsTimestampTieWithNativeActivity() throws {
        try write([claude("assistant", stop: "tool_use")], at: "projects/p/session-a.jsonl")
        let log = root.appendingPathComponent("warp.log")
        let line = "\(stamp()) [INFO] Received OSC 777 notification: body={\"agent\":\"claude\",\"event\":\"permission_request\",\"session_id\":\"session-a\",\"cwd\":\"/tmp/my.project\",\"project\":\"my.project\"}"
        try line.write(to: log, atomically: true, encoding: .utf8)
        let r = AgentSessionReader(logURL: log, databaseURL: root.appendingPathComponent("missing.sqlite"),
                                   nativeProfiles: [AIProfile(provider: .claude, name: "Test", directory: root.path)])
        let snapshot = r.readAgentSession(asOf: now)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.status, .blocked)
        XCTAssertEqual(snapshot.activeCount, 0)
    }
    func testWarpCanBeDisabledAndReenabledWithoutRestart() throws {
        let log = root.appendingPathComponent("warp.log")
        let line = "\(stamp()) [INFO] Received OSC 777 notification: body={\"agent\":\"claude\",\"event\":\"tool_complete\",\"session_id\":\"warp-only\",\"cwd\":\"/tmp/p\",\"project\":\"p\"}"
        try line.write(to: log, atomically: true, encoding: .utf8)
        let r = AgentSessionReader(logURL: log, databaseURL: root.appendingPathComponent("missing.sqlite"))
        XCTAssertEqual(r.readAgentSession(asOf: now).activeCount, 1)
        XCTAssertTrue(r.readAgentSession(asOf: now, isWarpEnabled: false).sessions.isEmpty)
        XCTAssertEqual(r.readAgentSession(asOf: now).activeCount, 1)
    }
    func testIncompleteWriteAndNestedSubagentsAreIgnored() throws {
        let url = try write([claude("user")], at: "projects/p/session-a.jsonl")
        var data = try Data(contentsOf: url)
        data.append(try JSONSerialization.data(withJSONObject: claude("assistant", stop: "end_turn")))
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        try write([claude("user")], at: "projects/p/session-a/subagents/agent-worker.jsonl")
        let snapshot = reader(.claude).readAgentSession(asOf: now)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.activeCount, 1)
    }
    func testLargeCodexTranscriptRetainsHeaderAndCompletionInTail() throws {
        let url = try write([["type": "session_meta", "timestamp": stamp(-10),
                              "payload": ["id": "large-codex", "cwd": "/tmp/large"]]],
                            at: "sessions/rollout.jsonl")
        var data = try Data(contentsOf: url)
        data.append(Data(repeating: 32, count: Int(AgentSessionReader.tailByteLimit) + 100))
        data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": stamp(),
                                                                 "payload": ["type": "task_complete"]]))
        data.append(10)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        let snapshot = reader(.codex).readAgentSession(asOf: now)
        XCTAssertEqual(snapshot.sessions.first?.id, "large-codex")
        XCTAssertEqual(snapshot.sessions.first?.status, .finished)
    }
    func testWarpToggleDefaultsOnForExistingSettingsAndPatchesIndependently() throws {
        let setting = try JSONDecoder().decode(Setting.self, from: Data("{}".utf8))
        XCTAssertTrue(setting.isWarpIntegrationOn)
        let patch = SettingPatch(isWarpIntegrationOn: false)
        XCTAssertFalse(patch.isEmpty)
        let changed = patch.applied(to: setting)
        XCTAssertFalse(changed.isWarpIntegrationOn)
        XCTAssertEqual(changed.softBatteryPercent, setting.softBatteryPercent)
        XCTAssertFalse(try JSONDecoder().decode(Setting.self, from: JSONEncoder().encode(changed)).isWarpIntegrationOn)
    }
}
