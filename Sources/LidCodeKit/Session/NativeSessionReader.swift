import Foundation

/// Terminal-independent activity from the current user's Claude and Codex transcripts.
/// Reads bounded file tails, caches unchanged files, and never treats a file write alone
/// as a new turn. Explicit completion always wins over transcript freshness.
final class NativeSessionReader {
    private struct Entry {
        var modified: Date
        var size: UInt64
        var session: AgentSessionInfo?
    }
    private let profiles: [AIProfile]?
    private var candidates: [(URL, AIProfile)] = []
    private var discoveredAt: Date?
    private var discoveredProfiles: [AIProfile] = []
    private var cache: [URL: Entry] = [:]

    init(profiles: [AIProfile]? = nil) { self.profiles = profiles }

    func read(asOf now: Date) -> [AgentSessionInfo] {
        let profiles = self.profiles ?? currentProfiles()
        if discoveredAt == nil || now.timeIntervalSince(discoveredAt!) >= 30 || profiles != discoveredProfiles {
            discover(profiles: profiles, asOf: now)
        }
        var sessions: [AgentSessionInfo] = []
        for (url, profile) in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else {
                cache.removeValue(forKey: url)
                continue
            }
            if cache[url]?.modified != modified || cache[url]?.size != size {
                let parsed = parse(url: url, profile: profile, size: size)
                cache[url] = Entry(modified: modified, size: size, session: parsed)
            }
            guard var session = cache[url]?.session else { continue }
            let age = now.timeIntervalSince(session.lastSeenAt)
            guard age >= -60, age <= 1800 else { continue }
            if session.status == .running && age > AgentSessionReader.staleAfterSecond {
                session.status = .finished
                session.lastEvent = "stop"
                session.statusChangedAt = session.lastSeenAt.addingTimeInterval(AgentSessionReader.staleAfterSecond)
            }
            sessions.append(session)
        }
        return sessions
    }

    private func currentProfiles() -> [AIProfile] {
        // Defaults remain discoverable even if usage cards are hidden. Add configured
        // CLI homes so accounts with CLAUDE_CONFIG_DIR or CODEX_HOME work as well.
        var profiles = AIProfile.Provider.allCases.map { AIProfile(id: "native-" + $0.rawValue, provider: $0, name: $0.title) }
        profiles += (try? AIProfileStore.load()) ?? []
        for (provider, variable) in [(AIProfile.Provider.claude, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME")] {
            if let directory = ProcessInfo.processInfo.environment[variable], directory.hasPrefix("/") {
                profiles.append(AIProfile(id: "environment-" + provider.rawValue, provider: provider, name: provider.title, directory: directory))
            }
        }
        var seen = Set<String>()
        return profiles.filter { $0.isEnabled && seen.insert($0.provider.rawValue + ":" + $0.expandedDirectory).inserted }
    }

    private func discover(profiles: [AIProfile], asOf now: Date) {
        var found: [(URL, AIProfile, Date)] = []
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        for profile in profiles {
            let root = URL(fileURLWithPath: profile.expandedDirectory)
                .appendingPathComponent(profile.provider == .claude ? "projects" : "sessions")
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                // Nested Claude subagents belong to the parent turn; counting each
                // tool worker separately inflates the badge and duplicates work.
                if url.lastPathComponent == "subagents" { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true, let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) <= 1800 else { continue }
                found.append((url, profile, modified))
                if found.count > 128 { found.sort { $0.2 > $1.2 }; found = Array(found.prefix(64)) }
            }
        }
        found.sort { $0.2 > $1.2 }
        candidates = found.prefix(64).map { ($0.0, $0.1) }
        let retained = Set(candidates.map { $0.0 })
        cache = cache.filter { retained.contains($0.key) }
        discoveredAt = now
        discoveredProfiles = profiles
    }

    private func parse(url: URL, profile: AIProfile, size: UInt64) -> AgentSessionInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = AgentSessionReader.tailByteLimit
        var records: [Substring] = []
        if size > limit {
            // Codex session_meta (id/cwd) is at the beginning, outside a long tail.
            if let head = try? handle.read(upToCount: 64 * 1024) {
                var rows = String(decoding: head, as: UTF8.self).split(separator: "\n")
                rows = Array(rows.dropLast()) // last record may be incomplete
                records += rows
            }
            guard (try? handle.seek(toOffset: size - limit)) != nil else { return nil }
        }
        guard let tail = try? handle.readToEnd() else { return nil }
        let text = String(decoding: tail, as: UTF8.self)
        var rows = text.split(separator: "\n")
        if size > limit, !rows.isEmpty { rows.removeFirst() }
        // Ignore an in-progress JSONL write until the newline is committed.
        if !text.hasSuffix("\n"), !rows.isEmpty { rows.removeLast() }
        records += rows

        var id: String?, cwd: String?, title: String?
        var status: AgentStatus?, lastSeen: Date?, changedAt: Date?
        var lastEvent = ""
        for row in records {
            guard let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                  object["isSidechain"] as? Bool != true, let type = object["type"] as? String else { continue }
            var next: AgentStatus?
            var event: String?
            if profile.provider == .claude {
                id = object["sessionId"] as? String ?? id
                cwd = object["cwd"] as? String ?? cwd
                if type == "ai-title" { title = object["aiTitle"] as? String ?? title }
                if type == "custom-title" { title = object["customTitle"] as? String ?? title }
                if type == "user" { next = .running; event = "prompt_submit" }
                if type == "assistant" {
                    let message = object["message"] as? [String: Any]
                    let reason = message?["stop_reason"] as? String
                    next = ["end_turn", "stop_sequence", "max_tokens"].contains(reason ?? "") ? .finished : .running
                    event = next == .finished ? "stop" : "tool_complete"
                }
                if type == "system", object["subtype"] as? String == "turn_duration" { next = .finished; event = "stop" }
            } else {
                let payload = object["payload"] as? [String: Any] ?? [:]
                if type == "session_meta" { id = payload["id"] as? String ?? id; cwd = payload["cwd"] as? String ?? cwd }
                if type == "turn_context" { cwd = payload["cwd"] as? String ?? cwd }
                if type == "event_msg" {
                    switch payload["type"] as? String {
                    case "task_started", "user_message": next = .running; event = "prompt_submit"
                    case "task_complete", "turn_complete", "turn_aborted": next = .finished; event = "stop"
                    default: break
                    }
                }
                if type == "response_item" {
                    switch payload["type"] as? String {
                    case "reasoning", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output":
                        next = .running; event = "tool_complete"
                    case "message":
                        if payload["role"] as? String == "assistant" {
                            next = payload["phase"] as? String == "final_answer" || payload["channel"] as? String == "final" ? .finished : .running
                            event = next == .finished ? "stop" : "tool_complete"
                        }
                    default: break
                    }
                }
            }
            guard let next, let event, let timestamp = object["timestamp"] as? String,
                  let at = ClaudeUsageReader.date(fromIso: timestamp), at >= (lastSeen ?? .distantPast) else { continue }
            if status != next { changedAt = at }
            status = next; lastSeen = at; lastEvent = event
        }
        guard let id, !id.isEmpty, let cwd, cwd.hasPrefix("/"), let status, let lastSeen else { return nil }
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let validTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentSessionInfo(id: id, agent: profile.provider.rawValue, cwd: cwd, project: project,
                                title: validTitle?.isEmpty == false ? validTitle! : project,
                                titleSource: validTitle?.isEmpty == false ? "ai-title" : "cwd-basename",
                                status: status, lastEvent: lastEvent, lastSeenAt: lastSeen,
                                statusChangedAt: changedAt ?? lastSeen)
    }
}
