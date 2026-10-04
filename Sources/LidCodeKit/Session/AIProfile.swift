import Foundation

/// Public configuration contains paths and labels only, never credentials.
public struct AIProfile: Codable, Identifiable, Equatable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case claude, codex
        public var title: String { self == .claude ? "Claude" : "Codex" }
        public var defaultDirectory: String { self == .claude ? "~/.claude" : "~/.codex" }
    }
    public var id: String
    public var provider: Provider
    public var name: String
    /// Empty uses the provider's default credentials and profile directory.
    public var directory: String
    public var menuBarShow5h: Bool?
    public var menuBarShow1w: Bool?
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, provider: Provider, name: String, directory: String = "", isEnabled: Bool = true) {
        self.id = id; self.provider = provider; self.name = name
        self.directory = directory; self.isEnabled = isEnabled
    }
    public var expandedDirectory: String {
        NSString(string: directory.isEmpty ? provider.defaultDirectory : directory).expandingTildeInPath
    }
    public var claudeStorageDirectory: String? {
        guard provider == .claude, !directory.isEmpty,
              expandedDirectory != NSString(string: "~/.claude").expandingTildeInPath else { return nil }
        return expandedDirectory
    }
}

public enum AIProfileStore {
    public static func separatingDuplicates(_ profiles: [AIProfile]) -> [AIProfile] {
        var seen = Set<String>()
        return profiles.map { profile in
            var profile = profile
            let key = profile.provider.rawValue + ":" + URL(fileURLWithPath: profile.expandedDirectory).standardizedFileURL.path
            if !seen.insert(key).inserted {
                profile.directory = "~/.lidcode/profiles/\(profile.provider.rawValue)/\(profile.id)"
            }
            return profile
        }
    }

    public static func columns(for count: Int) -> Int {
        count == 4 ? 2 : min(3, max(1, count))
    }

    /// Keep the first default login; additional accounts get independent CLI homes.
    public static func prepared(_ profile: AIProfile, alongside profiles: [AIProfile]) throws -> AIProfile {
        var result = profile
        let others = profiles.filter { $0.id != profile.id && $0.provider == profile.provider }
        if result.directory.isEmpty && !others.isEmpty {
            result.directory = "~/.lidcode/profiles/\(profile.provider.rawValue)/\(profile.id)"
        }
        guard !others.contains(where: { URL(fileURLWithPath: $0.expandedDirectory).standardizedFileURL ==
            URL(fileURLWithPath: result.expandedDirectory).standardizedFileURL }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(atPath: result.expandedDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return result
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func signInCommand(for profile: AIProfile) -> String {
        let variable = profile.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let command = profile.provider == .claude ? "claude auth login" : "codex login"
        return "export \(variable)=\(shellQuote(profile.expandedDirectory)); \(command) && \(profile.provider.rawValue)"
    }

    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lidcode/ai-profiles.json")
    }
    public static func load(from url: URL = url) throws -> [AIProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([AIProfile].self, from: Data(contentsOf: url))
    }
    public static func save(_ profiles: [AIProfile], to url: URL = url) throws {
        let ids = profiles.map(\.id)
        guard Set(ids).count == ids.count,
              profiles.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  ($0.directory.isEmpty || NSString(string: $0.directory).expandingTildeInPath.hasPrefix("/")) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Detect installed tools once; a saved empty list stays empty on future launches.
    public static func detectedDefaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AIProfile] {
        AIProfile.Provider.allCases.compactMap { provider in
            let path = home.appendingPathComponent(provider == .claude ? ".claude" : ".codex")
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return AIProfile(id: "default-\(provider.rawValue)", provider: provider, name: provider.title)
        }
    }
}
