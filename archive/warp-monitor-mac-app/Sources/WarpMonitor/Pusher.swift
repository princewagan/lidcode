import Foundation

// MARK: - Pusher
// Reads config from ~/.warp-monitor.env and POSTs WarpMonitorState to /api/push.
// Required keys in the env file:
//   PUSH_SECRET=<bearer token>
//   PUSH_URL=<full endpoint URL, e.g. https://your-project.vercel.app/api/push>
//
// Missing/unreadable config → reports "not configured" state, does NOT crash.
// Network failure → exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s (capped at 32s).
// 401 → surfaces a clear auth error.
// 400 → surfaces a validation error with the response body.

public final class Pusher: @unchecked Sendable {

    // MARK: - Config

    public struct Config: Sendable {
        public let pushURL: URL
        public let pushSecret: String
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case fileNotFound(String)
        case fileUnreadable(String, Error)
        case missingKey(String)
        case invalidURL(String)

        public var description: String {
            switch self {
            case .fileNotFound(let path):
                return "Config file not found at \(path). Create it with: PUSH_SECRET=... and PUSH_URL=..."
            case .fileUnreadable(let path, let err):
                return "Config file at \(path) could not be read: \(err.localizedDescription)"
            case .missingKey(let key):
                return "Config file is missing required key: \(key)"
            case .invalidURL(let raw):
                return "PUSH_URL is not a valid URL: \(raw)"
            }
        }
    }

    public enum PushResult: Sendable {
        case ok
        case notConfigured(String)
        case authError
        case validationError(String)
        case networkError(Error)
        case httpError(Int, String)
    }

    // MARK: - State

    private let configPath: String
    private var cachedConfig: Config?
    private var configLoadError: ConfigError?
    private let session: URLSession
    private var retryDelay: TimeInterval = 1.0
    private let maxRetryDelay: TimeInterval = 32.0
    // QoS .userInitiated: retry callbacks must fire promptly even when the app has no window.
    // .utility is subject to App Nap timer coalescing on backgrounded apps.
    private let retryQueue = DispatchQueue(label: "ph.advo.warp-monitor.pusher.retry", qos: .userInitiated)

    /// Called on each push result (for UI feedback, logging, etc.)
    public var onResult: ((PushResult) -> Void)?

    // MARK: - Init

    public init(configPath: String = "~/.warp-monitor.env") {
        // Expand tilde
        let expanded: String
        if configPath.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expanded = home + String(configPath.dropFirst())
        } else {
            expanded = configPath
        }
        self.configPath = expanded
        self.session = URLSession(configuration: .default)
        // Load config eagerly so errors are surfaced early
        loadConfig()
    }

    // MARK: - Config loading

    @discardableResult
    public func loadConfig() -> Result<Config, ConfigError> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else {
            let err = ConfigError.fileNotFound(configPath)
            configLoadError = err
            cachedConfig = nil
            return .failure(err)
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: configPath, encoding: .utf8)
        } catch {
            let err = ConfigError.fileUnreadable(configPath, error)
            configLoadError = err
            cachedConfig = nil
            return .failure(err)
        }

        var parsed: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip blank lines and comments
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // Split on first "=" only
            if let eqRange = trimmed.range(of: "=") {
                let key = String(trimmed[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                parsed[key] = value
            }
        }

        guard let secret = parsed["PUSH_SECRET"], !secret.isEmpty else {
            let err = ConfigError.missingKey("PUSH_SECRET")
            configLoadError = err
            cachedConfig = nil
            return .failure(err)
        }

        guard let urlString = parsed["PUSH_URL"], !urlString.isEmpty else {
            let err = ConfigError.missingKey("PUSH_URL")
            configLoadError = err
            cachedConfig = nil
            return .failure(err)
        }

        guard let url = URL(string: urlString) else {
            let err = ConfigError.invalidURL(urlString)
            configLoadError = err
            cachedConfig = nil
            return .failure(err)
        }

        let config = Config(pushURL: url, pushSecret: secret)
        cachedConfig = config
        configLoadError = nil
        return .success(config)
    }

    // MARK: - Push

    /// Encode and POST state. Calls onResult on the calling queue or retry queue.
    public func push(state: WarpMonitorState) {
        guard let config = cachedConfig else {
            let msg = configLoadError?.description ?? "Config not loaded"
            onResult?(.notConfigured(msg))
            return
        }

        let encoder = JSONEncoder()
        guard let body = try? encoder.encode(state) else {
            onResult?(.validationError("Failed to encode WarpMonitorState to JSON"))
            return
        }

        performRequest(body: body, config: config, attempt: 0)
    }

    // MARK: - HTTP request with exponential backoff

    private func performRequest(body: Data, config: Config, attempt: Int) {
        var request = URLRequest(url: config.pushURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.pushSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                // Network failure: apply exponential backoff
                let delay = min(self.retryDelay * pow(2.0, Double(attempt)), self.maxRetryDelay)
                self.onResult?(.networkError(error))
                self.retryQueue.asyncAfter(deadline: .now() + delay) {
                    self.performRequest(body: body, config: config, attempt: attempt + 1)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.onResult?(.networkError(URLError(.badServerResponse)))
                return
            }

            // Reset retry delay on any HTTP response (connection succeeded)
            self.retryDelay = 1.0

            switch httpResponse.statusCode {
            case 200:
                self.onResult?(.ok)

            case 401:
                self.onResult?(.authError)
                // Do NOT retry 401 — it won't help without a config change
                fputs("[warp-monitor] Push auth error (401): check PUSH_SECRET in ~/.warp-monitor.env\n", stderr)

            case 400:
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                self.onResult?(.validationError(body))
                fputs("[warp-monitor] Push validation error (400): \(body)\n", stderr)
                // Do NOT retry 400 — payload is invalid, retrying won't help

            default:
                let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self.onResult?(.httpError(httpResponse.statusCode, responseBody))
                // Retry server errors (5xx) with backoff
                if httpResponse.statusCode >= 500 {
                    let delay = min(self.retryDelay * pow(2.0, Double(attempt)), self.maxRetryDelay)
                    self.retryQueue.asyncAfter(deadline: .now() + delay) {
                        self.performRequest(body: body, config: config, attempt: attempt + 1)
                    }
                }
            }
        }
        task.resume()
    }

    // MARK: - Config status

    public var isConfigured: Bool { cachedConfig != nil }
    public var configurationError: String? { configLoadError?.description }
}
