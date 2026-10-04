import XCTest
@testable import LidCodeKit

final class AIUsageCollectorTest: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptyDefaultLoginFindsSingleAuthenticatedCustomAccount() {
        let profile = AIProfile(id: "default-claude", provider: .claude, name: "Claude")
        let result = AIUsageCollector.resolveClaudeCredential(profile, activeDirectory: nil,
            customDirectories: ["/tmp/work", "/tmp/unused"]) { candidate in
                ["claudeAiOauth": ["accessToken": candidate.directory == "/tmp/work" ? "fixture" : ""]]
            }
        XCTAssertEqual(result.0.directory, "/tmp/work")
        XCTAssertEqual(result.0.id, profile.id)
    }

    func testAmbiguousAccountsRequireActiveAccountAndExplicitProfilesNeverSwitch() {
        let profile = AIProfile(provider: .claude, name: "Claude")
        let read: (AIProfile) -> [String: Any]? = { candidate in
            ["claudeAiOauth": ["accessToken": candidate.directory.isEmpty ? "" : "fixture"]]
        }
        let ambiguous = AIUsageCollector.resolveClaudeCredential(profile, activeDirectory: nil,
            customDirectories: ["/tmp/a", "/tmp/b"], read: read)
        XCTAssertEqual(ambiguous.0.directory, "")
        let active = AIUsageCollector.resolveClaudeCredential(profile, activeDirectory: "/tmp/b",
            customDirectories: ["/tmp/a", "/tmp/b"], read: read)
        XCTAssertEqual(active.0.directory, "/tmp/b")
        let explicit = AIProfile(provider: .claude, name: "Work", directory: "/tmp/work")
        let unchanged = AIUsageCollector.resolveClaudeCredential(explicit, activeDirectory: "/tmp/b",
            customDirectories: ["/tmp/b"]) { _ in nil }
        XCTAssertEqual(unchanged.0, explicit)
    }

    func testClaudeMissingWindowDoesNotBecomeZeroUsage() throws {
        let profile = AIProfile(provider: .claude, name: "Work")
        let data = Data(#"{"five_hour":{"utilization":37,"resets_at":"2027-01-15T12:00:00Z"},"seven_day":null}"#.utf8)
        let account = try XCTUnwrap(AIUsageCollector.parseClaude(data, profile: profile, now: now))
        XCTAssertEqual(account.fiveHour?.utilization, 37)
        XCTAssertNil(account.sevenDay)
        XCTAssertEqual(account.key, profile.id)
        XCTAssertNil(AIUsageCollector.parseClaude(Data("{}".utf8), profile: profile))
    }

    func testCodexTailSkipsPartialRecordAndRetainsOriginalAge() throws {
        let profile = AIProfile(provider: .codex, name: "Personal")
        let data = Data("""
        partial head
        {"timestamp":"2027-01-01T00:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":120,"resets_at":1800001000},"secondary":{"used_percent":23,"resets_at":1800100000}}}}
        {"payload":
        """.utf8)
        let account = try XCTUnwrap(AIUsageCollector.parseCodexTail(data, profile: profile, fallbackDate: now, now: now))
        XCTAssertEqual(account.fiveHour?.utilization, 100)
        XCTAssertEqual(account.sevenDay?.utilization, 23)
        XCTAssertEqual(account.asOf, ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        XCTAssertTrue(account.isCarried)
        XCTAssertEqual(account.provider, "codex")
    }

    func testCodexUnknownAndMalformedEventsDoNotCreateReadings() {
        let profile = AIProfile(provider: .codex, name: "Codex")
        for value in ["broken", #"{"payload":{"type":"token_count","rate_limits":{"primary":{}}}}"#, #"{"payload":{"type":"other","rate_limits":{"primary":{"used_percent":12}}}}"#] {
            XCTAssertNil(AIUsageCollector.parseCodexTail(Data(value.utf8), profile: profile, fallbackDate: now))
        }
    }

    func testNativeSnapshotRoundTripsThroughRuntimeReaderWithoutCredentials() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let account = ClaudeAccountUsage(key: "work", label: "Work", provider: "codex", status: "ok",
                                        fiveHour: UsageWindow(utilization: 21, resetsAt: now.addingTimeInterval(3600)),
                                        asOf: now.addingTimeInterval(-2000), isCarried: true)
        let usage = ClaudeUsage(fiveHour: account.fiveHour!, sevenDay: UsageWindow(utilization: 0, resetsAt: nil),
                                severity: "normal", fetchedAt: now, isStale: false, accounts: [account])
        try AIUsageCollector.write(usage, to: url)
        let data = try Data(contentsOf: url)
        let parsed = try XCTUnwrap(ClaudeUsageReader.parse(data, asOf: now))
        XCTAssertEqual(parsed.accounts.first?.fiveHour?.utilization, 21)
        XCTAssertNil(parsed.accounts.first?.sevenDay)
        XCTAssertEqual(parsed.accounts.first?.asOf, account.asOf)
        XCTAssertTrue(parsed.accounts.first?.isCarried == true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["fetched_at", "accounts", "five_hour", "seven_day", "severity"])
        let serialized = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(serialized.contains("accessToken"))
        XCTAssertFalse(serialized.contains("refreshToken"))
    }

    func testDisabledAndEmptyProfilesDoNotReadOrReappear() async {
        let disabled = AIProfile(provider: .claude, name: "Disabled", isEnabled: false)
        let usage = await AIUsageCollector.collect([disabled], previous: nil, now: now)
        XCTAssertTrue(usage.accounts.isEmpty)
    }
}
