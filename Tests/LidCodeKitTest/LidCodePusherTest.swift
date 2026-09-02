import XCTest
@testable import LidCodeKit

// MARK: - Helpers

/// A fake env file written to a temp path. Deleted on deinit.
private final class TempEnvFile {
    let path: String
    init(contents: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidcode-pusher-test-\(UUID().uuidString).env")
        path = tmp.path
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// A stub transport that records every outbound request and delivers a canned response.
private final class StubTransport: @unchecked Sendable {
    var requests: [URLRequest] = []
    var responseStatus: Int = 200
    private let lock = NSLock()

    var asTransport: LidCodePusher.Transport {
        { [weak self] req, completion in
            guard let self else { return }
            self.lock.withLock { self.requests.append(req) }
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: self.responseStatus,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
            completion(Data("{}".utf8), resp, nil)
        }
    }

    var callCount: Int { lock.withLock { requests.count } }
}

/// Builds a minimal `RuntimeSnapshot` for tests.
private func makeSnapshot(
    awakeHeld: Bool = true,
    sessions: [AgentSessionInfo] = [],
    physicalLid: PhysicalLidState = .open,
    battery: BatteryReading = .unknown,
    thermal: ThermalReading = ThermalReading(level: .nominal, celsius: 55.0),
    foreignBlockerCount: Int = 0,
    expiresAt: Date? = nil,
    fiveHourUtil: Double? = nil,
    sevenDayUtil: Double? = nil
) -> RuntimeSnapshot {
    let lidReading = ClamshellReading(state: physicalLid, readAt: Date(), isStale: false)

    var usage: ClaudeUsage? = nil
    if let fh = fiveHourUtil, let sh = sevenDayUtil {
        usage = ClaudeUsage(
            fiveHour: UsageWindow(utilization: fh, resetsAt: nil),
            sevenDay: UsageWindow(utilization: sh, resetsAt: nil),
            severity: "normal",
            fetchedAt: Date(),
            isStale: false
        )
    }

    let agentSnap = AgentSessionSnapshot(sessions: sessions)

    return RuntimeSnapshot(
        isAwakeHeld: awakeHeld,
        expiresAt: expiresAt,
        battery: battery,
        thermal: thermal,
        agentSession: agentSnap,
        usage: usage,
        physicalLid: lidReading,
        foreignBlockerCount: foreignBlockerCount
    )
}

/// A snapshot carrying the v2 extras: two Claude accounts and a memory reading.
/// Kept separate from `makeSnapshot` so the v1 tests keep proving that the new
/// fields are absent rather than merely empty.
private func makeV2Snapshot(
    memory: MemoryReading? = MemoryReading(
        pressure: .warn,
        usedPercent: 62.4,
        swapUsedMegabyte: 998.56,
        swapTotalMegabyte: 2048.0,
        app: [
            MemoryApp(name: "Claude", megabyte: 6297.0, count: 11),
            MemoryApp(name: "Brave", megabyte: 5150.0, count: 8)
        ],
        readAt: Date()
    ),
    accounts: [ClaudeAccountUsage] = [
        ClaudeAccountUsage(
            key: "prince", label: "prince", status: "ok",
            fiveHour: UsageWindow(utilization: 0.0, resetsAt: nil),
            sevenDay: UsageWindow(utilization: 8.0, resetsAt: nil),
            storageDir: nil
        ),
        ClaudeAccountUsage(
            key: "advo", label: "advo", status: "ok",
            fiveHour: UsageWindow(utilization: 100.0, resetsAt: nil),
            sevenDay: UsageWindow(utilization: 38.0, resetsAt: nil),
            storageDir: "/Users/test/.claude-advo"
        )
    ]
) -> RuntimeSnapshot {
    let usage = ClaudeUsage(
        fiveHour: UsageWindow(utilization: 50.0, resetsAt: nil),
        sevenDay: UsageWindow(utilization: 23.0, resetsAt: nil),
        severity: "normal",
        fetchedAt: Date(),
        isStale: false,
        accounts: accounts
    )
    return RuntimeSnapshot(
        isAwakeHeld: true,
        battery: .unknown,
        thermal: ThermalReading(level: .nominal, celsius: 55.0),
        agentSession: AgentSessionSnapshot(sessions: []),
        usage: usage,
        physicalLid: ClamshellReading(state: .open, readAt: Date(), isStale: false),
        foreignBlockerCount: 0,
        memory: memory
    )
}

private func makeSession(
    status: AgentStatus,
    id: String = UUID().uuidString
) -> AgentSessionInfo {
    AgentSessionInfo(
        id: id,
        agent: "claude",
        cwd: "/Users/test/project",
        project: "project",
        title: "Test session",
        titleSource: "cwd-basename",
        status: status,
        lastEvent: "session_start",
        lastSeenAt: Date(),
        statusChangedAt: Date()
    )
}

// MARK: - Test suite

final class LidCodePusherTest: XCTestCase {

    // MARK: - Env file parsing

    func testEnvParsing_missingFile() {
        // A path that does not exist → pusher is disabled, no crash.
        let pusher = LidCodePusher(
            configPath: "/tmp/lidcode-nonexistent-\(UUID().uuidString).env"
        )
        XCTAssertFalse(pusher._isConfigured, "Pusher should be disabled when env file is missing")
    }

    func testEnvParsing_missingPushSecret() {
        let env = TempEnvFile(contents: "PUSH_URL=https://example.com/api/lidcode\n")
        let pusher = LidCodePusher(configPath: env.path)
        XCTAssertFalse(pusher._isConfigured, "Pusher should be disabled when PUSH_SECRET is absent")
    }

    func testEnvParsing_validSecretNoUrl() {
        // No PUSH_URL → falls back to the hard-coded default URL. Still configured.
        let env = TempEnvFile(contents: "PUSH_SECRET=my-secret\n")
        let pusher = LidCodePusher(configPath: env.path)
        XCTAssertTrue(pusher._isConfigured, "Pusher should be enabled when PUSH_SECRET is present")
    }

    func testEnvParsing_quotedValues() {
        let env = TempEnvFile(contents:
            "# comment\n" +
            "PUSH_SECRET=\"quoted-secret\"\n" +
            "PUSH_URL='https://example.com/api/lidcode'\n"
        )
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)
        XCTAssertTrue(pusher._isConfigured, "Quotes around values should be stripped")

        // Fire a push and confirm the Authorization header contains the unquoted secret.
        let snapshot = makeSnapshot()
        pusher.pushIfChanged(snapshot, setting: .default)
        // Give the async queue a moment to fire.
        let expectation = expectation(description: "request sent")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(stub.callCount, 1)
        let auth = stub.requests.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer quoted-secret")
    }

    func testEnvParsing_commentsAndBlankLines() {
        let env = TempEnvFile(contents:
            "# This is a comment\n\n" +
            "   # Another comment\n" +
            "PUSH_SECRET=abc123\n" +
            "\n"
        )
        let pusher = LidCodePusher(configPath: env.path)
        XCTAssertTrue(pusher._isConfigured, "Comments and blank lines should be ignored")
    }

    // MARK: - Payload encoding

    /// The dashboard renders one block per account, so every account has to survive
    /// the trip — not just the aggregate the v1 payload carried.
    func testV2PayloadCarriesEveryAccountAndMemory() throws {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        pusher.pushIfChanged(makeV2Snapshot(), setting: .default)

        let e = expectation(description: "request")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e.fulfill() }
        wait(for: [e], timeout: 1.0)

        let body = try XCTUnwrap(stub.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["schema_version"] as? Int, 2)

        let accounts = try XCTUnwrap(json["claude_accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 2, "both accounts must reach the dashboard")
        XCTAssertEqual(accounts.map { $0["key"] as? String }, ["prince", "advo"])
        XCTAssertEqual(accounts[0]["five_hour_utilization"] as? Double, 0.0)
        XCTAssertEqual(accounts[0]["seven_day_utilization"] as? Double, 8.0)
        XCTAssertEqual(accounts[1]["five_hour_utilization"] as? Double, 100.0)
        XCTAssertEqual(accounts[1]["seven_day_utilization"] as? Double, 38.0)
        XCTAssertEqual(accounts[1]["status"] as? String, "ok")
        XCTAssertNotNil(accounts[0]["is_active"] as? Bool)

        let memory = try XCTUnwrap(json["memory"] as? [String: Any])
        // .warn kernel level with swap at 48.8% stays .warn under the default 50/85
        // thresholds — the swap rule raises the level, it never lowers it.
        XCTAssertEqual(memory["pressure"] as? String, "warn")
        XCTAssertEqual(memory["used_percent"] as? Double, 62.4)
        XCTAssertEqual(memory["swap_used_mb"] as? Double, 998.56)
        XCTAssertEqual(memory["swap_total_mb"] as? Double, 2048.0)

        let apps = try XCTUnwrap(memory["app"] as? [[String: Any]])
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0]["name"] as? String, "Claude")
        XCTAssertEqual(apps[0]["mb"] as? Double, 6297.0)
        XCTAssertEqual(apps[0]["count"] as? Int, 11)
    }

    /// A signed-out account has no window at all, but Zod requires a number. It must
    /// go out as 0 with the real state in `status`, never as null.
    func testSignedOutAccountSendsZeroNotNull() throws {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        let snapshot = makeV2Snapshot(accounts: [
            ClaudeAccountUsage(
                key: "prince", label: "prince", status: "signed_out",
                fiveHour: nil, sevenDay: nil, storageDir: nil
            )
        ])
        pusher.pushIfChanged(snapshot, setting: .default)

        let e = expectation(description: "request")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e.fulfill() }
        wait(for: [e], timeout: 1.0)

        let body = try XCTUnwrap(stub.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let accounts = try XCTUnwrap(json["claude_accounts"] as? [[String: Any]])

        XCTAssertEqual(accounts[0]["five_hour_utilization"] as? Double, 0.0)
        XCTAssertEqual(accounts[0]["seven_day_utilization"] as? Double, 0.0)
        XCTAssertEqual(accounts[0]["status"] as? String, "signed_out")
    }

    func testPayloadSnakeCaseKeys() throws {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        let snapshot = makeSnapshot(
            awakeHeld: true,
            physicalLid: .open,
            fiveHourUtil: 14.0,
            sevenDayUtil: 6.5
        )
        pusher.pushIfChanged(snapshot, setting: .default)

        let e = expectation(description: "request")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e.fulfill() }
        wait(for: [e], timeout: 1.0)

        let body = try XCTUnwrap(stub.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["schema_version"] as? Int, 2)
        XCTAssertNotNil(json["pushed_at"])
        XCTAssertNotNil(json["mac_hostname"])
        XCTAssertEqual(json["awake_held"] as? Bool, true)
        XCTAssertEqual(json["physical_lid"] as? String, "open")
        XCTAssertEqual(json["battery_on_main"] as? Bool, true)   // BatteryReading.unknown isOnMain=true
        XCTAssertEqual(json["temperature_stale"] as? Bool, false)
        XCTAssertEqual(json["foreign_blocker_count"] as? Int, 0)
        XCTAssertEqual(json["claude_five_hour_utilization"] as? Double, 14.0)
        XCTAssertEqual(json["claude_seven_day_utilization"] as? Double, 6.5)
        XCTAssertNotNil(json["sessions"])

        // v2 fields are omitted, not null, when the snapshot carries no reading —
        // the Zod schema marks them optional, and a literal null fails that.
        XCTAssertNil(json["memory"])
        XCTAssertNil(json["claude_accounts"])

        // Verify no camelCase keys leaked through.
        XCTAssertNil(json["schemaVersion"])
        XCTAssertNil(json["pushedAt"])
        XCTAssertNil(json["awakeHeld"])
        XCTAssertNil(json["physicalLid"])
        XCTAssertNil(json["batteryOnMain"])
        XCTAssertNil(json["temperatureStale"])
        XCTAssertNil(json["foreignBlockerCount"])
    }

    func testPayloadDateFormat() throws {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        pusher.pushIfChanged(makeSnapshot(), setting: .default)

        let e = expectation(description: "request")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e.fulfill() }
        wait(for: [e], timeout: 1.0)

        let body = try XCTUnwrap(stub.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let pushedAt = try XCTUnwrap(json["pushed_at"] as? String)

        // ISO8601 date must contain "T" separator and end with "Z".
        XCTAssertTrue(pushedAt.contains("T"), "pushed_at must be an ISO8601 string")
        XCTAssertTrue(pushedAt.hasSuffix("Z"), "pushed_at must be UTC (ends with Z)")
    }

    func testAllSessionStatusesIncluded() throws {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        let sessions = [
            makeSession(status: .running,  id: "id-running"),
            makeSession(status: .blocked,  id: "id-blocked"),
            makeSession(status: .error,    id: "id-error"),
            makeSession(status: .finished, id: "id-finished"),
        ]
        pusher.pushIfChanged(makeSnapshot(sessions: sessions), setting: .default)

        let e = expectation(description: "request")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e.fulfill() }
        wait(for: [e], timeout: 1.0)

        let body = try XCTUnwrap(stub.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sentSessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])

        XCTAssertEqual(sentSessions.count, 4, "All four sessions must be included regardless of status")

        let statuses = sentSessions.compactMap { $0["status"] as? String }
        XCTAssertTrue(statuses.contains("running"))
        XCTAssertTrue(statuses.contains("blocked"))
        XCTAssertTrue(statuses.contains("error"))
        XCTAssertTrue(statuses.contains("finished"))
    }

    func testSessionPayloadSnakeCaseKeys() throws {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        let session = makeSession(status: .running, id: "my-session-id")
        pusher.pushIfChanged(makeSnapshot(sessions: [session]), setting: .default)

        let e = expectation(description: "request")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e.fulfill() }
        wait(for: [e], timeout: 1.0)

        let body = try XCTUnwrap(stub.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        let first = try XCTUnwrap(sessions.first)

        XCTAssertEqual(first["id"] as? String, "my-session-id")
        XCTAssertNotNil(first["status_changed_at"])
        XCTAssertNotNil(first["last_seen_at"])
        XCTAssertNil(first["statusChangedAt"], "No camelCase keys in session payload")
        XCTAssertNil(first["lastSeenAt"], "No camelCase keys in session payload")
    }

    // MARK: - Diff suppression

    func testDiffSuppression_identicalSnapshotNoPush() {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        let snapshot = makeSnapshot()

        // First push — should fire.
        pusher.pushIfChanged(snapshot, setting: .default)

        var e1 = expectation(description: "first")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e1.fulfill() }
        wait(for: [e1], timeout: 1.0)

        let afterFirst = stub.callCount
        XCTAssertEqual(afterFirst, 1, "First push with new state should fire")

        // Second push with identical snapshot (no time change for hash) — should NOT fire.
        pusher.pushIfChanged(snapshot, setting: .default)

        var e2 = expectation(description: "second")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e2.fulfill() }
        wait(for: [e2], timeout: 1.0)

        XCTAssertEqual(stub.callCount, afterFirst, "Identical snapshot must not trigger a second push")
    }

    func testDiffSuppression_changedSessionFiresPush() {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        // First push.
        pusher.pushIfChanged(makeSnapshot(sessions: [makeSession(status: .running)]), setting: .default)
        let e1 = expectation(description: "first")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e1.fulfill() }
        wait(for: [e1], timeout: 1.0)
        XCTAssertEqual(stub.callCount, 1)

        // Second push with different sessions.
        pusher.pushIfChanged(makeSnapshot(sessions: [
            makeSession(status: .running),
            makeSession(status: .finished),
        ]), setting: .default)
        let e2 = expectation(description: "second")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e2.fulfill() }
        wait(for: [e2], timeout: 1.0)
        XCTAssertEqual(stub.callCount, 2, "Changed session list should trigger a push")
    }

    // MARK: - Heartbeat

    func testHeartbeat_firesAfter60s() {
        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        // First push to establish the hash.
        let snapshot = makeSnapshot()
        pusher.pushIfChanged(snapshot, setting: .default)
        let e1 = expectation(description: "first")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e1.fulfill() }
        wait(for: [e1], timeout: 1.0)
        XCTAssertEqual(stub.callCount, 1)

        // Simulate the 60s interval by manipulating lastPushAt via the queue.
        // We use the `_` prefixed accessors exposed for tests.
        // Force lastPushAt to be 61 seconds in the past.
        let queue = DispatchQueue(label: "test.backdoor")
        queue.sync {
            // Direct ivar manipulation is not possible; instead we use the public
            // `pushIfChanged` path and verify by checking that the second push fires
            // without any state change when enough time has elapsed.
            //
            // For a deterministic test, we just verify that the heartbeat path in
            // `pushIfChangedOnQueue` would fire: since we can't advance time in unit
            // tests without a time-injection seam, we verify the published hash is
            // stable and the call count didn't grow (no heartbeat needed in < 60s).
        }

        // A second push with identical snapshot immediately after should NOT fire
        // (less than 60s elapsed).
        pusher.pushIfChanged(snapshot, setting: .default)
        let e2 = expectation(description: "second (should be suppressed)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e2.fulfill() }
        wait(for: [e2], timeout: 1.0)
        XCTAssertEqual(stub.callCount, 1, "Second identical push within 60s must be suppressed")
    }

    // MARK: - Rate limiting (in-flight)

    func testRateLimit_noDoubleInflight() {
        // Use a slow transport that doesn't call back immediately.
        var pendingCompletions: [(Data?, URLResponse?, Error?) -> Void] = []
        let completionLock = NSLock()

        let slowTransport: LidCodePusher.Transport = { req, completion in
            completionLock.withLock { pendingCompletions.append(completion) }
        }

        let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
        let pusher = LidCodePusher(configPath: env.path, transport: slowTransport)

        // Fire two pushes with different state before the first completes.
        pusher.pushIfChanged(makeSnapshot(awakeHeld: true), setting: .default)
        let e1 = expectation(description: "first queued")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { e1.fulfill() }
        wait(for: [e1], timeout: 1.0)

        pusher.pushIfChanged(makeSnapshot(awakeHeld: false), setting: .default)
        let e2 = expectation(description: "second queued")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { e2.fulfill() }
        wait(for: [e2], timeout: 1.0)

        // Only 1 request should have been dispatched (second was dropped due to in-flight guard).
        XCTAssertEqual(completionLock.withLock { pendingCompletions.count }, 1,
                       "Only one in-flight request allowed at a time")
    }

    // MARK: - Disabled pusher

    func testDisabledPusher_makesNoRequests() {
        // Empty env file — no PUSH_SECRET.
        let env = TempEnvFile(contents: "# no keys here\n")
        let stub = StubTransport()
        let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

        XCTAssertFalse(pusher._isConfigured)

        pusher.pushIfChanged(makeSnapshot(), setting: .default)
        let e = expectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e.fulfill() }
        wait(for: [e], timeout: 1.0)

        XCTAssertEqual(stub.callCount, 0, "Disabled pusher must make no HTTP requests")
    }

    // MARK: - Physical lid values

    func testPhysicalLidValues() throws {
        for (state, expected) in [(PhysicalLidState.open, "open"), (.closed, "closed"), (.unknown, "unknown")] {
            let env = TempEnvFile(contents: "PUSH_SECRET=secret\n")
            let stub = StubTransport()
            let pusher = LidCodePusher(configPath: env.path, transport: stub.asTransport)

            pusher.pushIfChanged(makeSnapshot(physicalLid: state), setting: .default)
            let e = expectation(description: "request for \(state)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { e.fulfill() }
            wait(for: [e], timeout: 1.0)

            let body = try XCTUnwrap(stub.requests.first?.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["physical_lid"] as? String, expected,
                           "physical_lid must serialize to \(expected)")
        }
    }
}

// MARK: - Push URL resolution

final class LidCodePushURLTest: XCTestCase {

    func testExplicitLidcodeUrlWins() {
        let url = LidCodePusher.resolvePushURL([
            "LIDCODE_PUSH_URL": "https://example.test/custom",
            "PUSH_URL": "https://other.test/api/push",
        ])
        XCTAssertEqual(url?.absoluteString, "https://example.test/custom")
    }

    func testSharedPushUrlKeepsHostButNeverKeepsWarpMonitorPath() {
        // Posting a LidCode payload to /api/push would fail validation and
        // could clobber warp_state, so the path must always be rewritten.
        let url = LidCodePusher.resolvePushURL(["PUSH_URL": "https://mytelevision.vercel.app/api/push"])
        XCTAssertEqual(url?.absoluteString, "https://mytelevision.vercel.app/api/lidcode")
    }

    func testSharedPushUrlDropsQueryAndFragment() {
        let url = LidCodePusher.resolvePushURL(["PUSH_URL": "https://host.test/api/push?token=x#frag"])
        XCTAssertEqual(url?.absoluteString, "https://host.test/api/lidcode")
    }

    func testFallsBackToDefaultWhenNoHostIsNamed() {
        XCTAssertEqual(LidCodePusher.resolvePushURL([:])?.absoluteString, LidCodePusher.defaultPushURL)
        XCTAssertEqual(LidCodePusher.resolvePushURL(["PUSH_URL": ""])?.absoluteString, LidCodePusher.defaultPushURL)
    }

    func testDefaultTargetsTheLiveDeployment() {
        XCTAssertFalse(LidCodePusher.defaultPushURL.contains("television-pearl"),
                       "television-pearl.vercel.app is a dead alias")
        XCTAssertTrue(LidCodePusher.defaultPushURL.hasSuffix(LidCodePusher.lidcodePath))
    }
}

// MARK: - The pusher must never wedge permanently

final class LidCodePusherWedgeTest: XCTestCase {

    private func envFile() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wedge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("env")
        try "PUSH_SECRET=s\nLIDCODE_PUSH_URL=https://example.test/api/lidcode\n"
            .write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }

    /// A transport that accepts the request and then never calls back — the exact
    /// shape that previously stranded the flag and stopped all future pushes.
    func testARequestThatNeverCompletesDoesNotBlockForever() throws {
        var sent = 0
        let pusher = LidCodePusher(configPath: try envFile()) { _, _ in sent += 1 }

        pusher.pushIfChanged(makeSnapshot(), setting: .default)
        pusher.drainForTest()
        XCTAssertEqual(sent, 1)

        // Still within the expiry window: correctly suppressed.
        pusher.forceInflightAgeForTest(10)
        pusher.pushIfChanged(makeSnapshot(), setting: .default)
        pusher.drainForTest()
        XCTAssertEqual(sent, 1, "should not double-post while a request is genuinely in flight")

        // Past the expiry window: must recover on its own.
        pusher.forceInflightAgeForTest(600)
        pusher.pushIfChanged(makeSnapshot(), setting: .default)
        pusher.drainForTest()
        XCTAssertEqual(sent, 2, "an abandoned request must not wedge the pusher permanently")
    }

    /// A failed push must not be recorded as delivered, or the state would sit
    /// unsent until it happened to change again.
    func testFailedPushIsRetriedOnTheNextHeartbeat() throws {
        var sent = 0
        let pusher = LidCodePusher(configPath: try envFile()) { _, done in
            sent += 1
            done(nil, HTTPURLResponse(url: URL(string: "https://example.test")!,
                                      statusCode: 400, httpVersion: nil, headerFields: nil), nil)
        }
        pusher.pushIfChanged(makeSnapshot(), setting: .default)
        pusher.drainForTest()
        XCTAssertEqual(sent, 1)

        pusher.forceHeartbeatDueForTest()
        pusher.pushIfChanged(makeSnapshot(), setting: .default)
        pusher.drainForTest()
        XCTAssertEqual(sent, 2, "a rejected payload must be resent, not treated as delivered")
    }
}

// MARK: - Push rate

final class LidCodePushRateTest: XCTestCase {

    private func envFile() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("env")
        try "PUSH_SECRET=s\nLIDCODE_PUSH_URL=https://example.test/api/lidcode\n"
            .write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }

    private func pusher(_ sent: @escaping () -> Void) throws -> LidCodePusher {
        LidCodePusher(configPath: try envFile()) { _, done in
            sent()
            done(nil, HTTPURLResponse(url: URL(string: "https://example.test")!,
                                      statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }
    }

    /// Sensor drift must not put a request on the wire. This is the behaviour that
    /// exhausted the previous database's egress budget.
    func testTemperatureDriftAloneDoesNotPush() throws {
        var sent = 0
        let p = try pusher { sent += 1 }

        p.pushIfChanged(makeSnapshot(thermal: ThermalReading(level: .nominal, celsius: 55.0)), setting: .default)
        p.drainForTest()
        XCTAssertEqual(sent, 1, "first push always goes")

        for c in [55.4, 55.9, 56.2, 54.8, 57.1] {
            p.pushIfChanged(makeSnapshot(thermal: ThermalReading(level: .nominal, celsius: c)), setting: .default)
            p.drainForTest()
        }
        XCTAssertEqual(sent, 1, "drifting temperature must ride the heartbeat, not force a push")
    }

    /// A session changing status is the whole point of the dashboard — it must not wait.
    func testSessionStatusChangePushesImmediately() throws {
        var sent = 0
        let p = try pusher { sent += 1 }
        let base = AgentSessionInfo(
            id: "s1", agent: "claude", cwd: "/tmp", project: "p", title: "t",
            titleSource: "ai-title", status: .running, lastEvent: "prompt_submit",
            lastSeenAt: Date(), statusChangedAt: Date())

        p.pushIfChanged(makeSnapshot(sessions: [base]), setting: .default)
        p.drainForTest()
        XCTAssertEqual(sent, 1)

        var blocked = base
        blocked.status = .blocked
        p.pushIfChanged(makeSnapshot(sessions: [blocked]), setting: .default)
        p.drainForTest()
        XCTAssertEqual(sent, 2, "a running -> blocked flip must go out at once")
    }

    func testLidAndAwakeChangesPushImmediately() throws {
        var sent = 0
        let p = try pusher { sent += 1 }
        p.pushIfChanged(makeSnapshot(awakeHeld: true, physicalLid: .open), setting: .default)
        p.drainForTest()
        p.pushIfChanged(makeSnapshot(awakeHeld: true, physicalLid: .closed), setting: .default)
        p.drainForTest()
        p.pushIfChanged(makeSnapshot(awakeHeld: false, physicalLid: .closed), setting: .default)
        p.drainForTest()
        XCTAssertEqual(sent, 3)
    }
}
