import Foundation

// MARK: - AITitleReader
//
// Reads Claude Code per-session transcript files to extract the AI-generated
// session title. Claude Code writes JSONL transcripts to:
//
//   ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
//
// Encoding: each forward slash in the absolute cwd path is replaced by a dash.
//   /Users/princewagan/television  →  -Users-princewagan-television
// Other characters (dots, hyphens, underscores) are kept as-is.
//
// Each JSONL file contains one JSON object per line. Lines with
//   `"type":"ai-title"` carry the AI-generated title:
//   {"type":"ai-title","aiTitle":"Fix sleep policy error","sessionId":"..."}
//
// A file accumulates MANY ai-title lines as the session evolves — the LAST one
// wins. This reader tails the last 256 KB and scans backward to find it.
//
// Safety:
//   - Read-only. Never writes, truncates, or locks any file.
//   - Handles: missing dir, missing file, empty file, malformed JSON,
//     non-UTF-8 bytes, no ai-title in window. Always degrades gracefully.
//   - Cache by (path, mtime, size): unchanged files are never re-read.
//   - Per-poll cost: cold ~1–3 ms per new file; warm ~0 ms (cache hit).

public final class AITitleReader: @unchecked Sendable {

    // MARK: - Cache

    private struct CacheEntry {
        let mtime: Date
        let size: Int64
        let aiTitle: String?
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheLock = NSLock()

    // Maximum bytes read from the END of a transcript per lookup.
    // 256 KB covers thousands of lines and is read in one syscall.
    private static let tailBytes: Int64 = 256 * 1024

    // MARK: - Project directory root

    private static var claudeProjectsDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.claude/projects"
    }

    // MARK: - CWD encoding
    //
    // Claude Code encodes the cwd by replacing every "/" with "-".
    // e.g. /Users/princewagan/television → -Users-princewagan-television
    //
    // Verified live on this machine:
    //   /Users/princewagan/television         → -Users-princewagan-television
    //   /Users/princewagan/advopark           → -Users-princewagan-advopark
    //   /Users/princewagan/easymed-1          → -Users-princewagan-easymed-1
    //   /Users/princewagan/fourlinq-management → -Users-princewagan-fourlinq-management
    // Dots and hyphens in path components are kept as-is.

    public static func encodeProjectDir(cwd: String) -> String {
        // Replace every "/" with "-". The leading "/" becomes the leading "-".
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Project directory for a given cwd

    public static func projectDir(for cwd: String) -> String {
        let encoded = encodeProjectDir(cwd: cwd)
        return claudeProjectsDir + "/" + encoded
    }

    // MARK: - Resolve transcript path

    /// Returns the transcript path for a given (cwd, sessionId) pair.
    /// Preferred — exact, uses the session ID directly.
    public static func transcriptPath(cwd: String, sessionId: String) -> String {
        return projectDir(for: cwd) + "/" + sessionId + ".jsonl"
    }

    // NOTE: there is deliberately no "pick the Nth transcript in this folder"
    // lookup here any more.
    //
    // A previous version listed every .jsonl in the project directory, sorted by
    // mtime descending, and handed the Nth file to the Nth Warp tab. That was the
    // source of a long-standing status bug: the mtime order re-sorts every time
    // any session writes a line, so a tab's "own" transcript changed identity
    // every few seconds. Statuses swapped between tabs and a single error
    // appeared to spread across every tab in the folder.
    //
    // The list was also mostly dead sessions — one observed folder held 43
    // transcripts for 3 open tabs — so the index rarely pointed at live work.
    //
    // A transcript is now only ever addressed by its session id, which is exact.

    // MARK: - Read AI title (primary interface)

    /// Read the AI title for a specific session transcript at the given path.
    /// Returns nil when: file missing, no ai-title found, or any error occurs.
    ///
    /// - Parameter path: absolute path to the .jsonl file
    /// - Returns: the last ai-title value in the file, or nil
    public func aiTitle(at path: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return aiTitleLocked(at: path)
    }

    private func aiTitleLocked(at path: String) -> String? {
        // Stat the file to check if it has changed since last read.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int64 else {
            // File missing or inaccessible — return cached value if we have one,
            // otherwise nil.
            return cache[path]?.aiTitle
        }

        // Cache hit: same mtime and size — no re-read needed.
        if let entry = cache[path], entry.mtime == mtime, entry.size == size {
            return entry.aiTitle
        }

        // Cache miss: read the tail of the file.
        let title = readLastAITitle(at: path, fileSize: size)

        // Store in cache.
        cache[path] = CacheEntry(mtime: mtime, size: size, aiTitle: title)

        return title
    }

    // MARK: - Read last ai-title from file tail

    /// Reads up to `tailBytes` from the end of the file and returns the value of
    /// the last `{"type":"ai-title","aiTitle":"..."}` line found, or nil.
    ///
    /// Reads from the END — does not parse the whole file. The last occurrence
    /// wins, so scanning backward is correct.
    private func readLastAITitle(at path: String, fileSize: Int64) -> String? {
        guard fileSize > 0 else { return nil }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }

        // Determine read start: last min(fileSize, tailBytes) bytes.
        let readBytes = min(fileSize, AITitleReader.tailBytes)
        let startOffset = fileSize - readBytes
        fh.seek(toFileOffset: UInt64(startOffset))
        let data = fh.readDataToEndOfFile()

        // Tolerate non-UTF-8 bytes by replacing them — we prefer partial data
        // over a total miss.
        guard let text = String(data: data, encoding: .utf8)
               ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        // Split into lines and scan BACKWARD for the last ai-title entry.
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            if let title = extractAITitle(from: line) {
                return title
            }
        }

        return nil
    }

    // MARK: - JSON extraction

    /// Parse a single JSONL line and return the aiTitle value if this is an
    /// ai-title record. Returns nil for any other line type or malformed JSON.
    private func extractAITitle(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Quick guard: must contain the type key before we allocate a Data.
        guard trimmed.contains("\"ai-title\"") || trimmed.contains("ai-title") else { return nil }

        guard let data = trimmed.data(using: .utf8) else { return nil }

        struct AITitleLine: Codable {
            let type: String
            let aiTitle: String?
        }

        guard let parsed = try? JSONDecoder().decode(AITitleLine.self, from: data),
              parsed.type == "ai-title",
              let title = parsed.aiTitle,
              !title.isEmpty else {
            return nil
        }

        return title
    }

    // MARK: - Transcript mtime (activity signal)

    /// Returns the most-recent modification date of the transcript at `path`,
    /// or nil when the file is missing or inaccessible.
    ///
    /// This is essentially free: `aiTitleLocked` already calls
    /// `FileManager.attributesOfItem` to populate the cache. Because callers
    /// always call `resolve()` (which calls `aiTitle(at:)`) before this, the
    /// stat result is already in the cache entry and no extra syscall is needed.
    public func transcriptMtime(at path: String) -> Date? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[path]?.mtime
    }

    // MARK: - Bulk resolution (used by StateManager during correlation)

    /// Result of resolving an AI title for one tab.
    public struct TitleResult {
        public let aiTitle: String?
        /// Which rule produced this result.
        public let source: String  // "ai-title-exact" | "ai-title-fallback" | nil
        /// mtime of the transcript file, or nil when no transcript was found.
        /// Used by StateManager to determine whether this session is actively
        /// running (transcript recently modified) or done (transcript is quiet).
        public let transcriptMtime: Date?
        /// Session UUID of the transcript this title came from.
        ///
        /// A transcript filename IS the session id, so resolving a title also tells
        /// us exactly which Claude session this tab belongs to. StateManager uses it
        /// to give each tab its OWN status instead of a folder-wide aggregate — the
        /// bug where one failing session in a folder turned every tab in it red.
        /// It also keeps title and status consistent: both describe the same session.
        public let sessionId: String?
        public init(aiTitle: String?, source: String, transcriptMtime: Date? = nil, sessionId: String? = nil) {
            self.aiTitle = aiTitle
            self.source = source
            self.transcriptMtime = transcriptMtime
            self.sessionId = sessionId
        }
    }

    /// Resolve the AI title for one Claude session.
    ///
    /// The session id IS the transcript filename, so this lookup is exact: the
    /// title and the mtime returned here always describe the same session the
    /// caller asked about. There is no positional fallback by design — guessing
    /// which transcript belongs to a caller is what produced wrong-tab statuses.
    ///
    /// - Parameters:
    ///   - cwd: normalised absolute path to the session's working directory
    ///   - sessionId: session UUID from OSC 777 / ClaudeSessionState
    /// - Returns: TitleResult with aiTitle (may be nil), source, and transcriptMtime.
    public func resolve(cwd: String, sessionId: String) -> TitleResult {
        guard !cwd.isEmpty else {
            return TitleResult(aiTitle: nil, source: "no-cwd", transcriptMtime: nil)
        }
        guard !sessionId.isEmpty else {
            return TitleResult(aiTitle: nil, source: "no-session-id", transcriptMtime: nil)
        }

        let exactPath = AITitleReader.transcriptPath(cwd: cwd, sessionId: sessionId)
        let title = aiTitle(at: exactPath)
        let mtime = transcriptMtime(at: exactPath)
        return TitleResult(
            aiTitle: title,
            source: title != nil ? "ai-title-exact"
                                 : (mtime != nil ? "no-ai-title" : "no-transcript"),
            transcriptMtime: mtime,
            sessionId: sessionId
        )
    }
}
