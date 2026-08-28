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

    private var lastPushedHash: String = ""
    private var lastPushAt: Date = .distantPast
    private let heartbeatInterval: TimeInterval = 60

    private var isInflight: Bool = false           // rate-limit: one request at a time

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
            fputs("[lidcode-pusher] Cannot read \(configPath): \(error)\n", stderr)
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
            fputs("[lidcode-pusher] No usable push URL — pusher disabled.\n", stderr)
            return
        }

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
        guard let config else { return }   // disabled: no config / no secret

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

        isInflight = true
        lastPushedHash = comparableHash
        lastPushAt = now

        performRequest(body: body, config: config, attempt: 0)
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
    private func hashPayload(_ payload: LidCodePushPayload) -> String {
        // Build a comparable struct that omits pushed_at.
        struct Comparable: Encodable {
            var schema_version: Int
            var mac_hostname: String
            var awake_held: Bool
            var physical_lid: String
            var hold_expires_at: String?
            var hold_elapsed_fraction: Double?
            var battery_percent: Int?
            var battery_on_main: Bool
            var temperature_celsius: Double?
            var temperature_stale: Bool
            var claude_five_hour_utilization: Double?
            var claude_seven_day_utilization: Double?
            var foreign_blocker_count: Int
            var sessions: [LidCodeSessionPayload]
        }

        let c = Comparable(
            schema_version: payload.schema_version,
            mac_hostname: payload.mac_hostname,
            awake_held: payload.awake_held,
            physical_lid: payload.physical_lid,
            hold_expires_at: payload.hold_expires_at,
            hold_elapsed_fraction: payload.hold_elapsed_fraction,
            battery_percent: payload.battery_percent,
            battery_on_main: payload.battery_on_main,
            temperature_celsius: payload.temperature_celsius,
            temperature_stale: payload.temperature_stale,
            claude_five_hour_utilization: payload.claude_five_hour_utilization,
            claude_seven_day_utilization: payload.claude_seven_day_utilization,
            foreign_blocker_count: payload.foreign_blocker_count,
            sessions: payload.sessions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(c) else { return UUID().uuidString }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func encode(_ payload: LidCodePushPayload) -> Data? {
        let encoder = JSONEncoder()
        // Omit nil fields from JSON so the payload stays compact.
        do {
            return try encoder.encode(payload)
        } catch {
            fputs("[lidcode-pusher] Encoding failed: \(error)\n", stderr)
            return nil
        }
    }

    private func performRequest(body: Data, config: Config, attempt: Int) {
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
                    fputs("[lidcode-pusher] Network error (attempt \(attempt)): \(error.localizedDescription)\n", stderr)
                    if attempt < maxAttempt {
                        let delay = pow(2.0, Double(attempt + 1))   // 2s, 4s, 8s
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            self.performRequest(body: body, config: config, attempt: attempt + 1)
                        }
                    } else {
                        self.isInflight = false
                    }
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    self.isInflight = false
                    return
                }

                switch http.statusCode {
                case 200, 201:
                    break   // success — nothing to do
                case 400...499:
                    // 4xx: not retryable (client-side problem).
                    fputs("[lidcode-pusher] HTTP \(http.statusCode) — not retrying.\n", stderr)
                default:
                    // 5xx / unexpected: retry with backoff.
                    fputs("[lidcode-pusher] HTTP \(http.statusCode) (attempt \(attempt)) — retrying.\n", stderr)
                    if attempt < maxAttempt {
                        let delay = pow(2.0, Double(attempt + 1))
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            self.performRequest(body: body, config: config, attempt: attempt + 1)
                        }
                        return
                    }
                }
                self.isInflight = false
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
    var _isConfigured: Bool { config != nil }
}
