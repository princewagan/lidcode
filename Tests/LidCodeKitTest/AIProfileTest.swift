import XCTest
@testable import LidCodeKit

final class AIProfileTest: XCTestCase {
    func testAccountGridBalancesFourAndCapsAtThreeColumns() {
        XCTAssertEqual((0...8).map(AIProfileStore.columns), [1, 1, 2, 3, 2, 3, 3, 3, 3])
    }

    func testOldProfilesDecodeWithoutMenuBarPreferences() throws {
        let data = Data("[{\"id\":\"old\",\"provider\":\"claude\",\"name\":\"Claude\",\"directory\":\"\",\"isEnabled\":true}]".utf8)
        let profiles = try JSONDecoder().decode([AIProfile].self, from: data)
        XCTAssertNil(profiles[0].menuBarShow5h)
        XCTAssertNil(profiles[0].menuBarShow1w)
    }

    func testDuplicateMigrationPreservesFirstLoginAndSeparatesProviders() {
        let profiles = [AIProfile(id: "first", provider: .claude, name: "Personal"),
                        AIProfile(id: "second", provider: .claude, name: "Work", directory: "~/.claude"),
                        AIProfile(id: "codex", provider: .codex, name: "Codex")]
        let separated = AIProfileStore.separatingDuplicates(profiles)
        XCTAssertEqual(separated[0], profiles[0])
        XCTAssertEqual(separated[1].directory, "~/.lidcode/profiles/claude/second")
        XCTAssertEqual(separated[2], profiles[2])
        XCTAssertEqual(AIProfileStore.separatingDuplicates(separated), separated)
    }

    func testPreparationRejectsDuplicateFolderAndSignInQuotesPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("profile ' \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = AIProfile(provider: .codex, name: "Work", directory: root.path)
        let prepared = try AIProfileStore.prepared(profile, alongside: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.expandedDirectory))
        XCTAssertThrowsError(try AIProfileStore.prepared(AIProfile(provider: .codex, name: "Duplicate", directory: root.path + "/."), alongside: [profile]))
        XCTAssertTrue(AIProfileStore.signInCommand(for: prepared).contains("CODEX_HOME="))
        XCTAssertTrue(AIProfileStore.signInCommand(for: prepared).contains("'\"'\"'"))
    }

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
