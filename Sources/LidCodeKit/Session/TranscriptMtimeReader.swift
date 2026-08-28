import Foundation

// MARK: - TranscriptMtimeReader
//
// Thin wrapper around AITitleReader that answers a single question:
// "When was this session's JSONL transcript last modified?"
//
// Exists as a named type so AgentSessionReader can express its dependency
// explicitly rather than reaching into AITitleReader's internals directly.
// All actual I/O is delegated to AITitleReader, which caches by (path, mtime, size)
// and shares its cache across both callers.

final class TranscriptMtimeReader: @unchecked Sendable {
    private let ai: AITitleReader

    init(ai: AITitleReader = AITitleReader()) {
        self.ai = ai
    }

    /// Returns the mtime of `~/.claude/projects/<encodedCwd>/<sessionId>.jsonl`,
    /// or nil when the file does not exist or is inaccessible.
    func mtime(cwd: String, sessionId: String) -> Date? {
        let path = AITitleReader.transcriptPath(cwd: cwd, sessionId: sessionId)
        return ai.transcriptMtime(at: path)
    }
}
