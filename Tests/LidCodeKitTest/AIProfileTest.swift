import XCTest
@testable import LidCodeKit

final class AIProfileTest: XCTestCase {
    func testProfilesRoundTripIncludingEmptyListAndDisabledProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.json")
        XCTAssertEqual(try AIProfileStore.load(from: url), [])
        let profile = AIProfile(provider: .codex, name: "Work", directory: "~/work-codex", isEnabled: false)
        try AIProfileStore.save([profile], to: url)
        XCTAssertEqual(try AIProfileStore.load(from: url), [profile])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try AIProfileStore.save([], to: url)
        XCTAssertEqual(try AIProfileStore.load(from: url), [])
    }

    func testInvalidConfigurationDoesNotOverwriteExistingProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.json")
        let valid = AIProfile(provider: .claude, name: "Claude")
        try AIProfileStore.save([valid], to: url)
        XCTAssertThrowsError(try AIProfileStore.save([valid, valid], to: url))
        XCTAssertThrowsError(try AIProfileStore.save([AIProfile(provider: .codex, name: "Work", directory: "relative")], to: url))
        XCTAssertThrowsError(try AIProfileStore.save([AIProfile(provider: .codex, name: " ")], to: url))
        XCTAssertEqual(try AIProfileStore.load(from: url), [valid])
    }

    func testDetectionOnlyAddsInstalledProviders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(AIProfileStore.detectedDefaults(home: home).isEmpty)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let profiles = AIProfileStore.detectedDefaults(home: home)
        XCTAssertEqual(profiles.map(\.provider), [.codex])
        XCTAssertEqual(profiles.map(\.name), ["Codex"])
    }

    func testMalformedSavedConfigurationIsReported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{broken".utf8).write(to: url)
        XCTAssertThrowsError(try AIProfileStore.load(from: url))
    }
}
