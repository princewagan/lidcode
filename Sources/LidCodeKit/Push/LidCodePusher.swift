import Foundation
import CryptoKit

// MARK: - Payload types
//
// These are the exact JSON keys the television API validates with Zod.
// All fields are snake_case. Optional fields are omitted when nil.

public struct LidCodePushPayload: Codable, Sendable {
    public var schema_version: Int                     // always 1
    public var pushed_at: String                       // ISO8601 UTC
    public var mac_hostname: String
    public var awake_held: Bool
    public var physical_lid: String                    // "open" | "closed" | "unknown"
    public var hold_expires_at: String?                // ISO8601 or nil
    public var hold_elapsed_fraction: Double?          // 0...1, nil when no timed hold
    public var battery_percent: Int?                   // nil on desktop with no battery
    public var battery_on_main: Bool
    public var temperature_celsius: Double?
    public var temperature_stale: Bool
    public var claude_five_hour_utilization: Double?
    public var claude_seven_day_utilization: Double?
    public var foreign_blocker_count: Int
    public var sessions: [LidCodeSessionPayload]

    public init(
        schema_version: Int,
        pushed_at: String,
        mac_hostname: String,
        awake_held: Bool,
        physical_lid: String,
        hold_expires_at: String?,
        hold_elapsed_fraction: Double?,
        battery_percent: Int?,
        battery_on_main: Bool,
        temperature_celsius: Double?,
        temperature_stale: Bool,
        claude_five_hour_utilization: Double?,
        claude_seven_day_utilization: Double?,
        foreign_blocker_count: Int,
        sessions: [LidCodeSessionPayload]
    ) {
        self.schema_version = schema_version
        self.pushed_at = pushed_at
        self.mac_hostname = mac_hostname
        self.awake_held = awake_held
        self.physical_lid = physical_lid
        self.hold_expires_at = hold_expires_at
        self.hold_elapsed_fraction = hold_elapsed_fraction
        self.battery_percent = battery_percent
        self.battery_on_main = battery_on_main
        self.temperature_celsius = temperature_celsius
        self.temperature_stale = temperature_stale
        self.claude_five_hour_utilization = claude_five_hour_utilization
        self.claude_seven_day_utilization = claude_seven_day_utilization
        self.foreign_blocker_count = foreign_blocker_count
        self.sessions = sessions
    }
}

public struct LidCodeSessionPayload: Codable, Sendable {
    public var id: String
    public var agent: String
    public var project: String
    public var title: String
    public var status: String                          // AgentStatus.rawValue
    public var status_changed_at: String               // ISO8601 UTC
    public var last_seen_at: String                    // ISO8601 UTC
    public var cwd: String

    public init(
        id: String,
        agent: String,
        project: String,
        title: String,
        status: String,
        status_changed_at: String,
        last_seen_at: String,
        cwd: String
    ) {
        self.id = id
        self.agent = agent
        self.project = project
        self.title = title
        self.status = status
        self.status_changed_at = status_changed_at
        self.last_seen_at = last_seen_at
        self.cwd = cwd
    }
}

// MARK: - LidCodePusher

/// Pushes `RuntimeSnapshot` to the television dashboard (see `resolvePushURL`)
/// whenever the meaningful state changes, plus a heartbeat every 60 s.
///
/// Design constraints (from the freeze-history of LidCode):
/// - `pushIfChanged` never blocks the caller's thread.
/// - Every error is logged to stderr and swallowed — no throws, no alerts.
/// - At most one in-flight HTTP request at a time (skip push if already running).
/// - Config missing / PUSH_SECRET absent → disable quietly, no crash.
public final class LidCodePusher: @unchecked Sendable {

    // MARK: - Config

    private struct Config {
        let pushURL: URL
        let pushSecret: String
    }

    // MARK: - Transport injection (for tests)

    /// Signature matches URLSession.dataTask callback.
    public typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

    // MARK: - State

    private let configPath: String
    private var config: Config?                    // nil → disabled
    private let transport: Transport

    private let queue = DispatchQueue(
        label: "ph.advo.lidcode.pusher",
        qos: .utility
    )

    /// Where push activity is recorded.
    ///
    /// stderr is invisible when the app is launched by LaunchServices (double-click
    /// or `open`), which is how it normally runs — so a push failure in real use
    /// left no trace anywhere. This file is the only way to tell a working pusher
    /// from a silent one.
    public static let logPath = NSHomeDirectory() + "/Library/Logs/lidcode-push.log"

    /// Reused, because building an ISO8601DateFormatter per log line drags in ICU
    /// locale setup every time — expensive, and on the launch path it showed up
    /// prominently in a crash trace.
    private static let logStamp = ISO8601DateFormatter()

    public static func log(_ message: String) {
        let line = "[\(logStamp.string(from: Date()))] \(message)\n"
        // NB: this writes to stderr directly and must never call back into log().
        line.withCString { _ = fputs($0, stderr) }
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // Keep the file small; this runs for the lifetime of the app.
            if (try? handle.seekToEnd()).map({ $0 > 256 * 1024 }) == true {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private var lastPushedHash: String = ""
    private var lastPushAt: Date = .distantPast
    private let heartbeatInterval: TimeInterval = 60

    /// When the current request started, or nil when idle.
    ///
    /// A plain Bool here is a trap: any path that fails to clear it wedges the
    /// pusher permanently and the dashboard silently goes stale forever, with the
    /// app otherwise looking healthy. Storing the start time instead makes the
    /// rate-limit self-healing — a request older than `inflightExpiry` is treated
    /// as abandoned. Worst case we double-post one payload, which is idempotent.
    private var inflightSince: Date?

    /// Longer than the worst-case attempt chain (10s request timeout x3 plus
    /// 2s + 4s backoff), so a live retry sequence is never cut short.
    private let inflightExpiry: TimeInterval = 120

    private var isInflight: Bool {
        guard let since = inflightSince else { return false }
        if Date().timeIntervalSince(since) > inflightExpiry {
            Self.log("Previous request abandoned after \(Int(inflightExpiry))s — unblocking.")
            inflightSince = nil
            return false
        }
        return true
    }

    // MARK: - ISO8601 formatter

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Init

    public init(configPath: String = "~/.warp-monitor.env") {
        // Expand leading tilde.
        let expanded: String
        if configPath.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expanded = home + String(configPath.dropFirst())
        } else {
            expanded = configPath
        }
        self.configPath = expanded
        // Default transport: URLSession with a 10-second timeout.
        let session: URLSession = {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 10
            return URLSession(configuration: cfg)
        }()
        self.transport = { req, completion in
            session.dataTask(with: req, completionHandler: completion).resume()
        }
        loadConfig()
    }

    /// Designated initialiser for tests — inject a custom transport so no real
    /// network calls are made.
    public init(configPath: String = "~/.warp-monitor.env", transport: @escaping Transport) {
        let expanded: String
        if configPath.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expanded = home + String(configPath.dropFirst())
        } else {
            expanded = configPath
        }
        self.configPath = expanded
        self.transport = transport
        loadConfig()
    }

    // MARK: - Config loading

    private func loadConfig() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else {
            // Missing env file: silent disable.
            return
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: configPath, encoding: .utf8)
        } catch {
            Self.log("Cannot read \(configPath): \(error)")
            return
        }

        var parsed: [String: String] = [:]
        for raw in contents.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes (single or double).
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            parsed[key] = value
        }

        guard let secret = parsed["PUSH_SECRET"], !secret.isEmpty else {
            // No PUSH_SECRET → disabled quietly.
            return
        }

        // PUSH_URL is WarpMonitor's endpoint (/api/push) and must not be used verbatim —
        // posting a LidCode payload there would fail validation and could clobber warp_state.
        // Prefer an explicit LIDCODE_PUSH_URL, else reuse PUSH_URL's host with our own path.
        guard let url = Self.resolvePushURL(parsed) else {
            Self.log("No usable push URL — pusher disabled.")
            return
        }

        Self.log("Enabled — target \(url.absoluteString)")
        config = Config(pushURL: url, pushSecret: secret)
    }

    /// Path this pusher always posts to, regardless of which host it resolves.
    static let lidcodePath = "/api/lidcode"

    /// Used only when the env file names no host at all.
    static let defaultPushURL = "https://mytelevision.vercel.app/api/lidcode"

    /// Resolution order:
    ///   1. `LIDCODE_PUSH_URL` — used verbatim.
    ///   2. `PUSH_URL` — host reused, path forced to `/api/lidcode`.
    ///   3. the built-in default.
    static func resolvePushURL(_ env: [String: String]) -> URL? {
        if let explicit = env["LIDCODE_PUSH_URL"], !explicit.isEmpty {
            return URL(string: explicit)
        }
        if let shared = env["PUSH_URL"], !shared.isEmpty,
           var parts = URLComponents(string: shared), parts.host != nil {
            parts.path = lidcodePath
            parts.query = nil
            parts.fragment = nil
            if let derived = parts.url { return derived }
        }
        return URL(string: defaultPushURL)
    }

    // MARK: - Public API

    /// Non-blocking. Schedules the push on a background queue and returns immediately.
    /// Never throws. Errors are written to stderr only.
    public func pushIfChanged(_ snapshot: RuntimeSnapshot) {
        queue.async { [weak self] in
            self?.pushIfChangedOnQueue(snapshot)
        }
    }

    // MARK: - Private — all called on `queue`

    private func pushIfChangedOnQueue(_ snapshot: RuntimeSnapshot) {
        guard let config else { return }

        let payload = buildPayload(snapshot: snapshot, pushedAt: Date())
        let comparableHash = hashPayload(payload)
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPushAt)

        let stateChanged = comparableHash != lastPushedHash
        let heartbeatDue = elapsed >= heartbeatInterval

        guard stateChanged || heartbeatDue else { return }

        // Rate-limit: skip if a previous request is still running.
        guard !isInflight else { return }

        // Update pushed_at to current time for the actual HTTP body.
        let finalPayload = buildPayload(snapshot: snapshot, pushedAt: now)
        guard let body = encode(finalPayload) else { return }

        inflightSince = now
        lastPushAt = now
        // lastPushedHash is deliberately NOT set here. Recording it before the
        // server accepts the payload would mark a failed push as delivered, and
        // the state would not be retried until it happened to change again.
        Self.log("POST \(config.pushURL.absoluteString) — \(finalPayload.sessions.count) session(s), \(body.count) bytes")
        performRequest(body: body, config: config, attempt: 0, hash: comparableHash)
    }

    private func buildPayload(snapshot: RuntimeSnapshot, pushedAt: Date) -> LidCodePushPayload {
        let iso = Self.iso8601

        let sessionPayloads = snapshot.agentSession.sessions.map { s in
            LidCodeSessionPayload(
                id: s.id,
                agent: s.agent,
                project: s.project,
                title: s.title,
                status: s.status.rawValue,
                status_changed_at: iso.string(from: s.statusChangedAt),
                last_seen_at: iso.string(from: s.lastSeenAt),
                cwd: s.cwd
            )
        }

        return LidCodePushPayload(
            schema_version: 1,
            pushed_at: iso.string(from: pushedAt),
            mac_hostname: hostName(),
            awake_held: snapshot.isAwakeHeld,
            physical_lid: snapshot.physicalLid.state.rawValue,
            hold_expires_at: snapshot.expiresAt.map { iso.string(from: $0) },
            hold_elapsed_fraction: snapshot.timerFraction,
            battery_percent: snapshot.battery.percent,
            battery_on_main: snapshot.battery.isOnMain,
            temperature_celsius: snapshot.thermal.celsius,
            temperature_stale: snapshot.thermal.isCelsiusStale,
            claude_five_hour_utilization: snapshot.usage?.fiveHour.utilization,
            claude_seven_day_utilization: snapshot.usage?.sevenDay.utilization,
            foreign_blocker_count: snapshot.foreignBlockerCount,
            sessions: sessionPayloads
        )
    }

    /// Hash the payload with `pushed_at` excluded so identical state with only a
    /// timestamp difference does not trigger a push.
    /// Hash of the fields worth waking the network for.
    ///
    /// The full payload changes on every single tick, because the temperature
    /// sensor moves by fractions of a degree constantly. Hashing all of it meant a
    /// POST every 5 seconds — roughly 700 an hour, which is precisely the kind of
    /// idle chatter that exhausted the previous database's egress allowance.
    ///
    /// So only genuinely meaningful state forces an immediate push: whether the Mac
    /// is being held awake, the lid, and each session's identity and status.
    ///
    /// Deliberately excluded: the foreign-blocker count, which oscillates constantly
    /// because Claude Code spawns a short-lived `caffeinate` per session; the hold
    /// deadline, which moves whenever a hold re-arms; and every sensor reading. All
    /// of those still reach the dashboard, just on the 60-second heartbeat.
    private func hashPayload(_ payload: LidCodePushPayload) -> String {
        struct Significant: Encodable {
            var schema_version: Int
            var mac_hostname: String
            var awake_held: Bool
            var physical_lid: String
            var temperature_stale: Bool
            var sessions: [String]      // "id:status" — a status flip must go out at once
        }

        let c = Significant(
            schema_version: payload.schema_version,
            mac_hostname: payload.mac_hostname,
            awake_held: payload.awake_held,
            physical_lid: payload.physical_lid,
            temperature_stale: payload.temperature_stale,
            sessions: payload.sessions.map { "\($0.id):\($0.status)" }.sorted()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(c) else { return UUID().uuidString }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func encode(_ payload: LidCodePushPayload) -> Data? {
        let encoder = JSONEncoder()
        // Omit nil fields from JSON so the payload stays compact.
        do {
            return try encoder.encode(payload)
        } catch {
            Self.log("Encoding failed: \(error)")
            return nil
        }
    }

    private func performRequest(body: Data, config: Config, attempt: Int, hash: String) {
        // Max 3 retries (attempts 0, 1, 2 → delays 2s, 4s, 8s before giving up).
        let maxAttempt = 3

        var req = URLRequest(url: config.pushURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.pushSecret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        transport(req) { [weak self] _, response, error in
            guard let self else { return }

            self.queue.async {
                if let error {
                    Self.log("Network error (attempt \(attempt)): \(error.localizedDescription)")
                    if attempt < maxAttempt {
                        let delay = pow(2.0, Double(attempt + 1))   // 2s, 4s, 8s
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            self.performRequest(body: body, config: config, attempt: attempt + 1, hash: hash)
                        }
                    } else {
                        self.inflightSince = nil
                    }
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    self.inflightSince = nil
                    return
                }

                switch http.statusCode {
                case 200, 201:
                    Self.log("HTTP \(http.statusCode) — accepted")
                    self.lastPushedHash = hash   // accepted — safe to suppress identical resends
                case 400...499:
                    // 4xx: not retryable (client-side problem).
                    Self.log("HTTP \(http.statusCode) — not retrying.")
                default:
                    // 5xx / unexpected: retry with backoff.
                    Self.log("HTTP \(http.statusCode) (attempt \(attempt)) — retrying.")
                    if attempt < maxAttempt {
                        let delay = pow(2.0, Double(attempt + 1))
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            self.performRequest(body: body, config: config, attempt: attempt + 1, hash: hash)
                        }
                        return
                    }
                }
                self.inflightSince = nil
            }
        }
    }

    // MARK: - Helpers

    private func hostName() -> String {
        ProcessInfo.processInfo.hostName
    }
}

// MARK: - Test helpers

extension LidCodePusher {
    /// Expose internal state for unit tests only.
    var _lastPushedHash: String { lastPushedHash }
    var _lastPushAt: Date { lastPushAt }
    var _isInflight: Bool { isInflight }
    var _inflightSince: Date? { inflightSince }
    var _isConfigured: Bool { config != nil }
}

#if DEBUG
extension LidCodePusher {
    /// Blocks until every queued push operation has run. Test-only.
    func drainForTest() { queue.sync { } }

    /// Backdates the in-flight marker so expiry can be exercised without waiting.
    func forceInflightAgeForTest(_ seconds: TimeInterval) {
        queue.sync { if inflightSince != nil { inflightSince = Date().addingTimeInterval(-seconds) } }
    }

    /// Backdates the last-push time so the heartbeat is due immediately.
    func forceHeartbeatDueForTest() {
        queue.sync { lastPushAt = Date().addingTimeInterval(-(heartbeatInterval + 1)) }
    }
}
#endif
