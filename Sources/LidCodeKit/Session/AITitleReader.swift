import Foundation

// MARK: - AITitleReader
//
// Ported from /Users/princewagan/television/mac-app/Sources/WarpMonitor/AITitleReader.swift
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

final class AITitleReader: @unchecked Sendable {

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
    // Verified live on this machine.

    static func encodeProjectDir(cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Resolve transcript path

    /// Returns the transcript path for a given (cwd, sessionId) pair.
    static func transcriptPath(cwd: String, sessionId: String) -> String {
        let encoded = encodeProjectDir(cwd: cwd)
        return claudeProjectsDir + "/" + encoded + "/" + sessionId + ".jsonl"
    }

    // MARK: - Read AI title (primary interface)

    /// Read the AI title for a specific session transcript at the given path.
    /// Returns nil when: file missing, no ai-title found, or any error occurs.
    func aiTitle(at path: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return aiTitleLocked(at: path)
    }

    private func aiTitleLocked(at path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int64 else {
            return cache[path]?.aiTitle
        }

        if let entry = cache[path], entry.mtime == mtime, entry.size == size {
            return entry.aiTitle
        }

        let title = readLastAITitle(at: path, fileSize: size)
        cache[path] = CacheEntry(mtime: mtime, size: size, aiTitle: title)
        return title
    }

    // MARK: - Read last ai-title from file tail

    private func readLastAITitle(at path: String, fileSize: Int64) -> String? {
        guard fileSize > 0 else { return nil }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }

        let readBytes = min(fileSize, AITitleReader.tailBytes)
        let startOffset = fileSize - readBytes
        fh.seek(toFileOffset: UInt64(startOffset))
        let data = fh.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8)
               ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            if let title = extractAITitle(from: line) {
                return title
            }
        }

        return nil
    }

    // MARK: - JSON extraction

    private func extractAITitle(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
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

    /// Returns the most-recent modification date of the transcript at `path`, or nil.
    ///
    /// This is essentially free: `aiTitleLocked` already calls
    /// `FileManager.attributesOfItem` to populate the cache. Because callers
    /// always call `resolve()` (which calls `aiTitle(at:)`) before this, the
    /// stat result is already in the cache entry and no extra syscall is needed.
    func transcriptMtime(at path: String) -> Date? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        // Check cache first (populated by aiTitleLocked).
        if let entry = cache[path] {
            return entry.mtime
        }

        // Cache miss: stat the file to get mtime without reading its content.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int64 else {
            return nil
        }

        // Populate cache entry with no title (avoids an unnecessary full read just for mtime).
        // The next call to aiTitle(at:) will still do a full read if the file has changed.
        if cache[path] == nil {
            cache[path] = CacheEntry(mtime: mtime, size: size, aiTitle: nil)
        }

        return mtime
    }

    // MARK: - Title resolution

    /// Result of resolving an AI title and mtime for one session.
    struct TitleResult {
        /// The AI-generated title, or nil if none found.
        let aiTitle: String?
        /// Which rule produced this result.
        /// One of: "ai-title" | "no-ai-title" | "no-transcript"
        let source: String
        /// mtime of the transcript file, or nil when no transcript was found.
        let transcriptMtime: Date?
    }

    /// Resolve the AI title for one Claude/Codex session.
    ///
    /// - Parameters:
    ///   - cwd: absolute path to the session's working directory
    ///   - sessionId: session UUID from OSC 777
    /// - Returns: TitleResult with aiTitle (may be nil), source, and transcriptMtime.
    func resolve(cwd: String, sessionId: String) -> TitleResult {
        guard !cwd.isEmpty else {
            return TitleResult(aiTitle: nil, source: "no-cwd", transcriptMtime: nil)
        }
        guard !sessionId.isEmpty else {
            return TitleResult(aiTitle: nil, source: "no-session-id", transcriptMtime: nil)
        }

        let path = AITitleReader.transcriptPath(cwd: cwd, sessionId: sessionId)
        let title = aiTitle(at: path)
        let mtime = transcriptMtime(at: path)
        return TitleResult(
            aiTitle: title,
            source: title != nil ? "ai-title" : (mtime != nil ? "no-ai-title" : "no-transcript"),
            transcriptMtime: mtime
        )
    }
}
