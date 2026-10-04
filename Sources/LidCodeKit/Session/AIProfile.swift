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
