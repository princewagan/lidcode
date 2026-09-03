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
    /// caller's sort to treat this row as the oldest so any valid row wins over it.
    func testMalformedEtimeReturnsIntMax() {
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime(""), Int.max)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("notadate"), Int.max)
        XCTAssertEqual(ActiveClaudeAccountReader.parseEtime("1:2:3:4"), Int.max)
    }
}

// ---------------------------------------------------------------------------
// ps row parsing — 4-column format: pid  etime  pcpu  comm
// ---------------------------------------------------------------------------

final class ClaudeRowParseTest: XCTestCase {

    func testNonClaudeRowIsIgnored() {
        let row = ActiveClaudeAccountReader.parseClaudeRow(
            from: "  123  01:30  0.0  /usr/bin/python3")
        XCTAssertNil(row)
    }

    func testClaudeRowByFullPath() {
        let row = ActiveClaudeAccountReader.parseClaudeRow(
            from: "  456  00:45  12.5  /Users/princewagan/.nvm/versions/node/v22.17.0/bin/claude")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.pid, 456)
        XCTAssertEqual(row?.elapsedSecond, 45)
        XCTAssertEqual(row?.cpuPercent, 12.5)
    }

    func testClaudeRowBareExecutable() {
        let row = ActiveClaudeAccountReader.parseClaudeRow(
            from: "789  1:02:03  3.2  claude")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.pid, 789)
        XCTAssertEqual(row?.elapsedSecond, 3723)
        XCTAssertEqual(row?.cpuPercent, 3.2)
    }

    func testUnparseableCpuDefaultsToZero() {
        // A malformed pcpu field must not drop the row — it stores 0 instead.
        let row = ActiveClaudeAccountReader.parseClaudeRow(
            from: "  999  00:10  -  claude")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.cpuPercent, 0.0)
    }

    func testPartialRowIsIgnored() {
        // Too few whitespace-separated fields to extract all four components.
        XCTAssertNil(ActiveClaudeAccountReader.parseClaudeRow(from: "123 01:30 0.0"))
        XCTAssertNil(ActiveClaudeAccountReader.parseClaudeRow(from: ""))
    }

    /// The "clauded" daemon or "claude-thing" must not match — only the executable
    /// named exactly "claude" qualifies.
    func testNearMatchesAreRejected() {
        XCTAssertNil(ActiveClaudeAccountReader.parseClaudeRow(from: "100 00:01 0.0 /bin/clauded"))
        XCTAssertNil(ActiveClaudeAccountReader.parseClaudeRow(from: "101 00:01 0.0 /bin/claude-helper"))
    }
}

// ---------------------------------------------------------------------------
// Picking the active row — busiest wins, ties broken by newer (smaller etime)
// ---------------------------------------------------------------------------

final class PickActiveRowTest: XCTestCase {

    func testBusiestRowWinsOverNewest() {
        // pid 1003 is the newest (30s) but pid 1002 is busiest (15.0%).
        // Busiest must win.
        let rows = [
            ClaudeRow(pid: 1001, elapsedSecond: 630, cpuPercent: 1.0),
            ClaudeRow(pid: 1002, elapsedSecond: 65,  cpuPercent: 15.0),
            ClaudeRow(pid: 1003, elapsedSecond: 30,  cpuPercent: 0.5),
        ]
        let result = ActiveClaudeAccountReader.pickActiveRow(from: rows)
        XCTAssertEqual(result?.row.pid, 1002)
        XCTAssertEqual(result?.isBusy, true)
    }

    func testAllBelowThresholdGivesIsBusyFalse() {
        // All sessions are idle — none reaches busyCpuPercent (2.0).
        let rows = [
            ClaudeRow(pid: 2001, elapsedSecond: 500, cpuPercent: 0.0),
            ClaudeRow(pid: 2002, elapsedSecond: 100, cpuPercent: 1.5),
            ClaudeRow(pid: 2003, elapsedSecond: 20,  cpuPercent: 0.8),
        ]
        let result = ActiveClaudeAccountReader.pickActiveRow(from: rows)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.isBusy, false)
        // The highest-cpu row still wins among the idle ones (pid 2002 at 1.5%).
        XCTAssertEqual(result?.row.pid, 2002)
    }

    func testTieOnCpuPicksNewer() {
        // Two rows with identical CPU — the one with smaller elapsedSecond (newer) wins.
        let rows = [
            ClaudeRow(pid: 3001, elapsedSecond: 200, cpuPercent: 8.0),
            ClaudeRow(pid: 3002, elapsedSecond: 50,  cpuPercent: 8.0),
        ]
        let result = ActiveClaudeAccountReader.pickActiveRow(from: rows)
        XCTAssertEqual(result?.row.pid, 3002,
            "tie on CPU must be broken by newer process (smaller elapsedSecond)")
        XCTAssertEqual(result?.isBusy, true)
    }

    func testEmptyTableReturnsNil() {
        XCTAssertNil(ActiveClaudeAccountReader.pickActiveRow(from: []))
    }

    func testSingleRowAlwaysWins() {
        let rows = [ClaudeRow(pid: 4001, elapsedSecond: 300, cpuPercent: 0.1)]
        let result = ActiveClaudeAccountReader.pickActiveRow(from: rows)
        XCTAssertEqual(result?.row.pid, 4001)
        XCTAssertEqual(result?.isBusy, false)  // 0.1 < busyCpuPercent
    }

    func testExactlyAtThresholdIsBusy() {
        // A row at exactly busyCpuPercent must be considered busy.
        let rows = [ClaudeRow(pid: 5001, elapsedSecond: 60,
                              cpuPercent: ActiveClaudeAccountReader.busyCpuPercent)]
        let result = ActiveClaudeAccountReader.pickActiveRow(from: rows)
        XCTAssertEqual(result?.isBusy, true)
    }
}

// ---------------------------------------------------------------------------
// Picking the newest process from the full ps table (4-column format)
// ---------------------------------------------------------------------------

final class NewestClaudeRowTest: XCTestCase {

    private let psTable = """
      1001  10:30  1.0  /path/to/claude
      1002  01:05  0.5  /path/to/claude
      1003  00:30  0.2  /path/to/claude
      1004  05:00  0.0  /path/to/node
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
        let rows = ActiveClaudeAccountReader.parseClaudeRows(
            from: "  99  00:01  0.0  /usr/bin/vim")
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
