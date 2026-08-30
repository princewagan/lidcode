import XCTest
@testable import LidCodeKit

// ---------------------------------------------------------------------------
// etime parsing
// ---------------------------------------------------------------------------

final class EtimeParseTest: XCTestCase {

    func testMinuteSecondFormat() {
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("02:30"), 2 * 60 + 30)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("00:05"), 5)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("59:59"), 59 * 60 + 59)
    }

    func testHourMinuteSecondFormat() {
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("01:02:03"), 3723)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("00:00:01"), 1)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("23:59:59"), 23 * 3600 + 59 * 60 + 59)
    }

    func testDayHourMinuteSecondFormat() {
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("1-00:00:00"), 86_400)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("3-12:30:00"), 3 * 86_400 + 12 * 3600 + 30 * 60)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("10-00:00:01"), 10 * 86_400 + 1)
    }

    /// Malformed input should not crash; Int.max is the sentinel that causes the
    /// caller's min() to skip this row in favour of any valid one.
    func testMalformedEtimeReturnsIntMax() {
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime(""), Int.max)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("notadate"), Int.max)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("1:2:3:4"), Int.max)
    }
}

// ---------------------------------------------------------------------------
// ps row parsing
// ---------------------------------------------------------------------------

final class ClaudeRowParseTest: XCTestCase {

    func testNonClaudeRowIsIgnored() {
        let row = ActiveClaudeAccountReader.parseClaudeRow(from: "  123  01:30  /usr/bin/python3")
        XCTAssertNil(row)
    }

    func testClaudeRowByFullPath() {
        let row = ActiveClaudeAccountReader.parseClaudeRow(
            from: "  456  00:45  /Users/princewagan/.nvm/versions/node/v22.17.0/bin/claude")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.pid, 456)
        XCTAssertEqual(row?.elapsedSecond, 45)
    }

    func testClaudeRowBareExecutable() {
        let row = ActiveClaudeAccountReader.parseClaudeRow(from: "789  1:02:03  claude")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.pid, 789)
        XCTAssertEqual(row?.elapsedSecond, 3723)
    }

    func testPartialRowIsIgnored() {
        // Too few whitespace-separated fields to extract all three components.
        XCTAssertNil(ActiveClaudeAccountReader.parseClaudeRow(from: "123 01:30"))
        XCTAssertNil(ActiveClaudeAccountReader.parseClaudeRow(from: ""))
    }

    /// The "clauded" daemon or "claude-thing" must not match — only the executable
    /// named exactly "claude" qualifies.
    func testNearMatchesAreRejected() {
        XCTAssertNil(ActiveClaudeAccountReader.parseClaudeRow(from: "100 00:01 /bin/clauded"))
        XCTAssertNil(ActiveClaudeAccountReader.parseClaudeRow(from: "101 00:01 /bin/claude-helper"))
    }
}

// ---------------------------------------------------------------------------
// Picking the newest process from a table
// ---------------------------------------------------------------------------

final class NewestClaudeRowTest: XCTestCase {

    private let psTable = """
      1001  10:30  /path/to/claude
      1002  01:05  /path/to/claude
      1003  00:30  /path/to/claude
      1004  05:00  /path/to/node
    """

    func testSmallestElapsedTimeIsNewest() {
        let rows = ActiveClaudeAccountReader.parseClaudeRows(from: psTable)
        // Three claude rows: 630s, 65s, 30s. Newest is pid 1003 at 30s.
        XCTAssertEqual(rows.count, 3)
        let newest = rows.min(by: { $0.elapsedSecond < $1.elapsedSecond })
        XCTAssertEqual(newest?.pid, 1003)
        XCTAssertEqual(newest?.elapsedSecond, 30)
    }

    func testEmptyTableProducesEmptyArray() {
        let rows = ActiveClaudeAccountReader.parseClaudeRows(from: "")
        XCTAssertTrue(rows.isEmpty)
    }

    func testTableWithOnlyNonClaudeRowsIsEmpty() {
        let rows = ActiveClaudeAccountReader.parseClaudeRows(from: "  99  00:01  /usr/bin/vim")
        XCTAssertTrue(rows.isEmpty)
    }
}

// ---------------------------------------------------------------------------
// env token extraction
// ---------------------------------------------------------------------------

final class ExtractStorageDirTest: XCTestCase {

    func testEnvVarPresentReturnsPath() throws {
        let env = "claude arg1 arg2 HOME=/Users/princewagan CLAUDE_SECURESTORAGE_CONFIG_DIR=/Users/princewagan/.claude-advo TERM=xterm"
        let result = ActiveClaudeAccountReader.extractStorageDir(from: env)
        // Result is String??: .some(.some(path))
        let outer = try XCTUnwrap(result)    // outer: not nil → process was found
        let inner = try XCTUnwrap(outer)     // inner: not nil → env var present
        XCTAssertEqual(inner, "/Users/princewagan/.claude-advo")
    }

    func testEnvVarAbsentReturnsSomeNil() throws {
        // No CLAUDE_SECURESTORAGE_CONFIG_DIR token — this is the default (PRINCE) account.
        let env = "claude HOME=/Users/princewagan TERM=xterm"
        let result = ActiveClaudeAccountReader.extractStorageDir(from: env)
        // Result is String??: .some(nil) — process found, no env var.
        let outer = try XCTUnwrap(result)    // outer: not nil → process was found
        XCTAssertNil(outer)                  // inner nil → default account
    }

    func testEmptyInputReturnsNil() {
        // Empty output means the process exited between the two ps calls.
        let result = ActiveClaudeAccountReader.extractStorageDir(from: "")
        // Result is String??: nil → detection failed entirely.
        // Cast to Any? to silence the double-optional implicit coercion warning.
        XCTAssertNil(result as Any?)
    }

    func testWhitespaceOnlyInputReturnsNil() {
        let result = ActiveClaudeAccountReader.extractStorageDir(from: "   \n  ")
        XCTAssertNil(result as Any?)
    }

    /// Partial match must not fire — only the exact prefix should match.
    func testPrefixSubstringDoesNotMatch() throws {
        let env = "claude NOT_CLAUDE_SECURESTORAGE_CONFIG_DIR=/bad HOME=/Users/princewagan"
        let result = ActiveClaudeAccountReader.extractStorageDir(from: env)
        // No matching token — should be .some(nil) (default account, env var absent).
        let outer = try XCTUnwrap(result)
        XCTAssertNil(outer)
    }
}

// ---------------------------------------------------------------------------
// storageDir field in ClaudeAccountUsage
// ---------------------------------------------------------------------------

final class StorageDirParseTest: XCTestCase {

    private let payloadWithStorageDir = Data("""
    {
      "fetched_at": "2026-08-31T00:00:00Z",
      "severity": "normal",
      "five_hour": { "utilization": 8.0, "resets_at": "2026-08-31T05:00:00.000000+00:00" },
      "seven_day": { "utilization": 45.0, "resets_at": "2026-09-07T00:00:00.000000+00:00" },
      "accounts": [
        {
          "key": "advo",
          "label": "ADVO",
          "status": "ok",
          "severity": "normal",
          "storage_dir": "/Users/princewagan/.claude-advo",
          "five_hour": { "utilization": 8.0,  "resets_at": "2026-08-31T05:00:00.000000+00:00" },
          "seven_day": { "utilization": 45.0, "resets_at": "2026-09-07T00:00:00.000000+00:00" }
        },
        {
          "key": "prince",
          "label": "PRINCE",
          "status": "ok",
          "severity": "warning",
          "storage_dir": null,
          "five_hour": { "utilization": 72.0, "resets_at": "2026-08-31T05:00:00.000000+00:00" },
          "seven_day": { "utilization": 88.0, "resets_at": "2026-09-07T00:00:00.000000+00:00" }
        }
      ]
    }
    """.utf8)

    private let fetchedAt = Date(timeIntervalSince1970: 1_788_134_400)

    func testAdvStorageDirIsParsed() throws {
        let usage = try XCTUnwrap(ClaudeUsageReader.parse(payloadWithStorageDir, asOf: fetchedAt))
        let advo = try XCTUnwrap(usage.accounts.first { $0.key == "advo" })
        XCTAssertEqual(advo.storageDir, "/Users/princewagan/.claude-advo")
    }

    func testDefaultAccountStorageDirIsNil() throws {
        let usage = try XCTUnwrap(ClaudeUsageReader.parse(payloadWithStorageDir, asOf: fetchedAt))
        let prince = try XCTUnwrap(usage.accounts.first { $0.key == "prince" })
        XCTAssertNil(prince.storageDir)
    }

    func testAbsentStorageDirFieldIsNil() throws {
        // Old-format payload with no storage_dir field at all — must parse without error.
        let payload = Data("""
        {
          "fetched_at": "2026-08-31T00:00:00Z",
          "accounts": [
            { "key": "advo", "label": "ADVO", "status": "signed_out" }
          ]
        }
        """.utf8)
        let usage = try XCTUnwrap(ClaudeUsageReader.parse(payload, asOf: fetchedAt))
        let advo = try XCTUnwrap(usage.accounts.first { $0.key == "advo" })
        XCTAssertNil(advo.storageDir)
    }
}

// ---------------------------------------------------------------------------
// readStorageDir() is safe to call without live processes
// ---------------------------------------------------------------------------

final class ActiveClaudeAccountReaderLiveTest: XCTestCase {

    /// The reader must never crash regardless of what processes happen to be running
    /// in the test environment. It may return any String?? value.
    func testReadStorageDirIsSafeToCall() {
        // Does not throw or crash.
        let result: String?? = ActiveClaudeAccountReader.readStorageDir()
        // Three valid states — just assert it doesn't explode.
        switch result {
        case .none:
            break  // detection failed — acceptable
        case .some(.none):
            break  // default account active — acceptable
        case .some(.some(let path)):
            XCTAssertFalse(path.isEmpty, "non-default account must have a non-empty path")
        }
    }

    /// `readStorageDir()` must return immediately — it must never invoke `ps` on the
    /// calling thread. The ps timeout is 3 s per call, and there are two calls per
    /// refresh, so a synchronous implementation could block the caller for up to 6 s.
    /// A non-blocking implementation returns well under 1 s regardless of ps latency.
    ///
    /// This test is intentionally generous (1 s budget) so it stays green on a heavily
    /// loaded CI machine without being so tight that it becomes flaky.
    func testReadStorageDirReturnsPromptly() {
        let start = Date()
        _ = ActiveClaudeAccountReader.readStorageDir()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
            "readStorageDir() blocked for \(elapsed)s — ps must run on a background queue, not the caller's thread")
    }
}
