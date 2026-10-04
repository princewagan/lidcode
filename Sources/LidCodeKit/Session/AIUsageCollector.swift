import Foundation
import CryptoKit
import Security

/// Runs inside the downloaded app. Reads existing CLI logins without installing a runtime,
/// copying credentials, or changing either tool's authentication state.
public enum AIUsageCollector {
    public static func collect(_ profiles: [AIProfile], previous: ClaudeUsage?, now: Date = Date()) async -> ClaudeUsage {
        var accounts: [ClaudeAccountUsage] = []
        for profile in profiles where profile.isEnabled {
            var account: ClaudeAccountUsage
            switch profile.provider {
            case .claude: account = await claude(profile, now: now)
            case .codex: account = codex(profile, now: now)
            }
            if account.status == "error" || account.status == "expired",
               var old = previous?.accounts.first(where: { $0.key == profile.id && $0.status == "ok" }),
               let asOf = old.asOf, now.timeIntervalSince(asOf) < 6 * 3600 {
                old.label = profile.name; old.isCarried = true; old.degraded = account.status
                account = old
            }
            accounts.append(account)
        }
        let activeCodex = accounts.filter { $0.provider == "codex" }.max {
            ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast)
        }?.key
        for index in accounts.indices where accounts[index].provider == "codex" {
            accounts[index].isActive = accounts[index].key == activeCodex && accounts[index].lastUsedAt != nil
        }
        let summary = accounts.first(where: { $0.status == "ok" && $0.provider == "claude" })
            ?? accounts.first(where: { $0.status == "ok" })
        return ClaudeUsage(fiveHour: summary?.fiveHour ?? UsageWindow(utilization: 0, resetsAt: nil),
                           sevenDay: summary?.sevenDay ?? UsageWindow(utilization: 0, resetsAt: nil),
                           severity: summary?.severity ?? "normal", fetchedAt: now, isStale: false, accounts: accounts)
    }

    public static func write(_ usage: ClaudeUsage, to url: URL = ClaudeUsageReader.usageURL) throws {
        func window(_ value: UsageWindow?) -> Any {
            guard let value else { return NSNull() }
            return ["utilization": value.utilization,
                    "resets_at": value.resetsAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()] as [String: Any]
        }
        let formatter = ISO8601DateFormatter()
        let accounts: [[String: Any]] = usage.accounts.map { account in
            ["key": account.key, "label": account.label, "provider": account.provider,
             "status": account.status, "is_active": account.isActive,
             "storage_dir": account.storageDir as Any? ?? NSNull(),
             "last_used_at": account.lastUsedAt.map { formatter.string(from: $0) } as Any? ?? NSNull(),
             "as_of": account.asOf.map { formatter.string(from: $0) } as Any? ?? NSNull(),
             "carried": account.isCarried, "degraded": account.degraded as Any? ?? NSNull(),
             "severity": account.severity as Any? ?? NSNull(),
             "five_hour": window(account.fiveHour), "seven_day": window(account.sevenDay)]
        }
        let payload: [String: Any] = ["fetched_at": formatter.string(from: usage.fetchedAt),
                                      "accounts": accounts, "five_hour": window(usage.fiveHour),
                                      "seven_day": window(usage.sevenDay), "severity": usage.severity]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func base(_ profile: AIProfile, status: String) -> ClaudeAccountUsage {
        ClaudeAccountUsage(key: profile.id, label: profile.name, provider: profile.provider.rawValue,
                           status: status, storageDir: profile.claudeStorageDirectory)
    }

    private static func claude(_ profile: AIProfile, now: Date) async -> ClaudeAccountUsage {
        // Keychain access stays off the main actor. Never launches a login flow or refreshes tokens.
        let credential = await Task.detached(priority: .utility) { () -> [String: Any]? in
            var service = "Claude Code-credentials"
            if let directory = profile.claudeStorageDirectory {
                let hash = SHA256.hash(data: Data(directory.precomposedStringWithCanonicalMapping.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                service += "-" + hash.prefix(8)
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
                                             kSecAttrService: service, kSecReturnData: true,
                                             kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
            // Linux-style credentials are also used by some macOS CLI installations.
            let url = URL(fileURLWithPath: profile.expandedDirectory).appendingPathComponent(".credentials.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.value
        guard let oauth = credential?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return base(profile, status: "signed_out") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return base(profile, status: "error") }
            guard response.statusCode == 200 else { return base(profile, status: response.statusCode == 401 ? "expired" : "error") }
            guard let account = parseClaude(data, profile: profile, now: now) else { return base(profile, status: "error") }
            return account
        } catch { return base(profile, status: "error") }
    }

    public static func parseClaude(_ data: Data, profile: AIProfile, now: Date = Date()) -> ClaudeAccountUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let raw = object[key] as? [String: Any], let used = raw["utilization"] as? Double,
                  used.isFinite else { return nil }
            return UsageWindow(utilization: min(100, max(0, used)),
                               resetsAt: (raw["resets_at"] as? String).flatMap(ClaudeUsageReader.date(fromIso:)), asOf: now)
        }
        let session = window("five_hour"), weekly = window("seven_day")
        guard session != nil || weekly != nil else { return nil }
        var account = base(profile, status: "ok")
        account.fiveHour = session; account.sevenDay = weekly; account.asOf = now
        account.severity = severity(max(session?.utilization ?? 0, weekly?.utilization ?? 0))
        return account
    }

    private static func codex(_ profile: AIProfile, now: Date) -> ClaudeAccountUsage {
        let root = URL(fileURLWithPath: profile.expandedDirectory).appendingPathComponent("sessions")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return base(profile, status: "no_data") }
        var recent: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            recent.append((url, values.contentModificationDate ?? .distantPast))
            // Retain only the newest candidates; histories can contain years of logs.
            if recent.count > 64 { recent.sort { $0.1 > $1.1 }; recent = Array(recent.prefix(32)) }
        }
        recent.sort { $0.1 > $1.1 }
        var newest: ClaudeAccountUsage?
        for (url, modified) in recent.prefix(32) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd(),
                  (try? handle.seek(toOffset: size > 1_048_576 ? size - 1_048_576 : 0)) != nil,
                  let data = try? handle.readToEnd(),
                  let candidate = parseCodexTail(data, profile: profile, fallbackDate: modified, now: now) else { continue }
            if newest == nil || (candidate.asOf ?? .distantPast) > (newest?.asOf ?? .distantPast) { newest = candidate }
        }
        return newest ?? base(profile, status: "no_data")
    }

    public static func parseCodexTail(_ data: Data, profile: AIProfile, fallbackDate: Date, now: Date = Date()) -> ClaudeAccountUsage? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            func window(_ key: String) -> UsageWindow? {
                guard let raw = limits[key] as? [String: Any], let used = raw["used_percent"] as? Double,
                      used.isFinite else { return nil }
                return UsageWindow(utilization: min(100, max(0, used)),
                                   resetsAt: (raw["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }, asOf: now)
            }
            let session = window("primary"), weekly = window("secondary")
            guard session != nil || weekly != nil else { continue }
            var account = base(profile, status: "ok")
            account.fiveHour = session; account.sevenDay = weekly
            // A local log retains its original timestamp; opening Lidcode cannot make it fresh.
            account.asOf = (object["timestamp"] as? String).flatMap(ClaudeUsageReader.date(fromIso:)) ?? fallbackDate
            account.lastUsedAt = account.asOf
            account.isCarried = now.timeIntervalSince(account.asOf!) > ClaudeUsageReader.staleAfterSecond
            account.severity = severity(max(session?.utilization ?? 0, weekly?.utilization ?? 0))
            return account
        }
        return nil
    }

    private static func severity(_ used: Double) -> String { used >= 90 ? "critical" : used >= 70 ? "warning" : "normal" }
}
