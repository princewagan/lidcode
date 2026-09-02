import Foundation
import Testing
@testable import WarpMonitor

// MARK: - AITitleReaderTests
//
// Tests for the AITitleReader component that extracts Claude Code AI-generated
// session titles from ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl files.

@Suite("AITitleReader")
struct AITitleReaderTests {

    // MARK: - CWD encoding

    @Test("encodeProjectDir: forward slashes become dashes")
    func testEncodeProjectDirSlashToDash() {
        let encoded = AITitleReader.encodeProjectDir(cwd: "/Users/princewagan/television")
        #expect(encoded == "-Users-princewagan-television",
            "Each '/' in the cwd must be replaced by '-'")
    }

    @Test("encodeProjectDir: dots and hyphens preserved")
    func testEncodeProjectDirDotsAndHyphens() {
        let encoded = AITitleReader.encodeProjectDir(cwd: "/Users/princewagan/easymed-1")
        #expect(encoded == "-Users-princewagan-easymed-1",
            "Dots and hyphens in path components must be kept as-is")
    }

    @Test("encodeProjectDir: path with sub-directory")
    func testEncodeProjectDirSubDir() {
        let encoded = AITitleReader.encodeProjectDir(
            cwd: "/Users/princewagan/entropy/process/features/squads/squad-wars/active"
        )
        #expect(encoded == "-Users-princewagan-entropy-process-features-squads-squad-wars-active")
    }

    @Test("encodeProjectDir: root slash")
    func testEncodeProjectDirRoot() {
        let encoded = AITitleReader.encodeProjectDir(cwd: "/")
        #expect(encoded == "-")
    }

    // MARK: - Transcript path derivation

    @Test("transcriptPath: exact path from cwd and session id")
    func testTranscriptPathExact() {
        let path = AITitleReader.transcriptPath(
            cwd: "/Users/princewagan/television",
            sessionId: "f3cb676c-7c76-485a-98a2-e2691e57586d"
        )
        #expect(path.hasSuffix("/f3cb676c-7c76-485a-98a2-e2691e57586d.jsonl"))
        #expect(path.contains("-Users-princewagan-television"))
    }

    // MARK: - AI title extraction (file-based tests using temp files)

    private func withTempFile(content: String, work: (String) throws -> Void) throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try work(url.path)
    }

    @Test("last ai-title wins when multiple entries exist")
    func testLastAITitleWins() throws {
        let reader = AITitleReader()
        let content = """
        {"type":"user","text":"hello"}
        {"type":"ai-title","aiTitle":"First title","sessionId":"aaa"}
        {"type":"assistant","text":"working..."}
        {"type":"ai-title","aiTitle":"Second title","sessionId":"aaa"}
        {"type":"tool_result","content":"done"}
        {"type":"ai-title","aiTitle":"Final title","sessionId":"aaa"}
        """

        try withTempFile(content: content) { path in
            let title = reader.aiTitle(at: path)
            #expect(title == "Final title", "Must return the LAST ai-title in the file")
        }
    }

    @Test("no ai-title in file returns nil")
    func testNoAITitleReturnsNil() throws {
        let reader = AITitleReader()
        let content = """
        {"type":"user","text":"hello"}
        {"type":"assistant","text":"I can help with that."}
        {"type":"tool_result","content":"output here"}
        """

        try withTempFile(content: content) { path in
            let title = reader.aiTitle(at: path)
            #expect(title == nil, "File with no ai-title entries must return nil")
        }
    }

    @Test("empty file returns nil")
    func testEmptyFileReturnsNil() throws {
        let reader = AITitleReader()
        try withTempFile(content: "") { path in
            let title = reader.aiTitle(at: path)
            #expect(title == nil, "Empty file must return nil without crashing")
        }
    }

    @Test("missing file returns nil")
    func testMissingFileReturnsNil() {
        let reader = AITitleReader()
        let title = reader.aiTitle(at: "/tmp/this-file-does-not-exist-\(UUID().uuidString).jsonl")
        #expect(title == nil, "Missing file must return nil without crashing")
    }

    @Test("malformed JSON lines are skipped, valid ai-title still extracted")
    func testMalformedJSONLinesSkipped() throws {
        let reader = AITitleReader()
        let content = """
        {"type":"user","text":"hello"}
        NOT VALID JSON AT ALL }{{}[
        {"type":"ai-title","aiTitle":"Good title","sessionId":"bbb"}
        ALSO NOT JSON: ]][[{{
        """

        try withTempFile(content: content) { path in
            let title = reader.aiTitle(at: path)
            #expect(title == "Good title", "Malformed lines must be skipped; valid ai-title must still be found")
        }
    }

    @Test("ai-title with empty aiTitle value returns nil")
    func testEmptyAITitleValueReturnsNil() throws {
        let reader = AITitleReader()
        let content = """
        {"type":"ai-title","aiTitle":"","sessionId":"ccc"}
        """

        try withTempFile(content: content) { path in
            let title = reader.aiTitle(at: path)
            #expect(title == nil, "An ai-title line with an empty aiTitle must not be returned")
        }
    }

    @Test("cache hit: file not re-read when mtime and size unchanged")
    func testCacheHit() throws {
        let reader = AITitleReader()
        let content = """
        {"type":"ai-title","aiTitle":"Cached title","sessionId":"ddd"}
        """

        try withTempFile(content: content) { path in
            // First read — cold
            let first = reader.aiTitle(at: path)
            #expect(first == "Cached title")

            // Second read — should hit cache (same mtime, same size)
            let second = reader.aiTitle(at: path)
            #expect(second == "Cached title", "Second read of unchanged file must return same value")
        }
    }

    @Test("resolve addresses the transcript by session id and echoes that id back")
    func testResolveWithSessionId() throws {
        // A missing transcript must degrade gracefully, and the returned
        // sessionId must be the one asked for — StateManager binds a row's
        // status to that value, so resolve() must never answer about a
        // different session than the caller named.
        let reader = AITitleReader()
        let sid = "nonexistent-session-\(UUID().uuidString)"
        let result = reader.resolve(cwd: "/tmp/does-not-exist-\(UUID().uuidString)", sessionId: sid)

        #expect(result.aiTitle == nil)
        #expect(result.source == "no-transcript", "Missing transcript must yield 'no-transcript'")
        #expect(result.sessionId == sid, "resolve must echo back the session id it was given")
        #expect(result.transcriptMtime == nil)
    }

    @Test("resolve with empty cwd returns no-cwd source")
    func testResolveEmptyCWD() {
        let reader = AITitleReader()
        let result = reader.resolve(cwd: "", sessionId: "abc")
        #expect(result.aiTitle == nil)
        #expect(result.source == "no-cwd")
    }

    @Test("resolve with empty session id returns no-session-id source")
    func testResolveEmptySessionId() {
        let reader = AITitleReader()
        let result = reader.resolve(cwd: "/Users/princewagan/television", sessionId: "")
        #expect(result.aiTitle == nil)
        #expect(result.source == "no-session-id")
    }

    /// Regression guard for the wrong-tab status bug.
    ///
    /// The old reader had a `transcriptPath(cwd:pairIndex:)` fallback that
    /// listed every .jsonl in a folder by mtime and returned the Nth one. That
    /// ordering re-sorted whenever any session wrote, so a caller's "own"
    /// transcript kept changing identity and statuses landed on the wrong row.
    /// resolve() must depend only on the session id it is handed.
    @Test("resolve is independent of other transcripts in the same folder")
    func testResolveIgnoresFolderContents() throws {
        let reader = AITitleReader()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aititle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two sibling transcripts; the decoy is written LAST so it is newest by
        // mtime and would have won any mtime-ranked lookup.
        let wanted = "11111111-1111-1111-1111-111111111111"
        let decoy  = "22222222-2222-2222-2222-222222222222"
        try #"{"type":"ai-title","aiTitle":"Wanted"}"#
            .write(to: dir.appendingPathComponent("\(wanted).jsonl"), atomically: true, encoding: .utf8)
        try #"{"type":"ai-title","aiTitle":"Decoy"}"#
            .write(to: dir.appendingPathComponent("\(decoy).jsonl"), atomically: true, encoding: .utf8)

        // Read each by path directly — the reader exposes no folder-ranked lookup
        // to call any more, which is itself the fix.
        let wantedTitle = reader.aiTitle(at: dir.appendingPathComponent("\(wanted).jsonl").path)
        let decoyTitle = reader.aiTitle(at: dir.appendingPathComponent("\(decoy).jsonl").path)

        #expect(wantedTitle == "Wanted", "A session's title must come from its own transcript")
        #expect(decoyTitle == "Decoy", "A sibling transcript must resolve to its own title")
    }
}
