import XCTest
@testable import LidCodeKit

/// Copied verbatim from a live `/tmp/warp-monitor-usage.json`.
private let livePayload = Data("""
{
  "fetched_at": "2026-08-26T16:57:25Z",
  "five_hour": {
    "utilization": 38.0,
    "resets_at": "2026-08-26T19:30:00.127765+00:00"
  },
  "seven_day": {
    "utilization": 88.0,
    "resets_at": "2026-08-26T17:00:00.127793+00:00"
  },
  "severity": "warning"
}
""".utf8)

/// 2026-08-26T16:57:25Z, the `fetched_at` above.
private let fetchedAt = Date(timeIntervalSince1970: 1_787_763_445)

/// The reason this reader does not use a single formatter: one JSON object carries two
/// different ISO8601 dialects, and each formatter configuration rejects the other's
/// format outright rather than degrading gracefully.
final class UsageDateFormatTest: XCTestCase {
    func testPlainZuluStampParses() {
        XCTAssertEqual(
            ClaudeUsageReader.date(fromIso: "2026-08-26T16:57:25Z"),
            Date(timeIntervalSince1970: 1_787_763_445))
    }

    /// Six fractional digits and a `+00:00` offset — the `resets_at` dialect.
    ///
    /// The fraction survives into the `Date` (truncated to milliseconds), so this is
    /// deliberately not an equality check against a whole second: a countdown built on
    /// `==` against a rounded value would never match.
    func testFractionalOffsetStampParses() throws {
        let parsed = try XCTUnwrap(ClaudeUsageReader.date(fromIso: "2026-08-26T19:30:00.127765+00:00"))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_787_772_600.127, accuracy: 0.001)
    }

    /// Proves the retry is load-bearing rather than defensive padding: neither dialect
    /// is a superset of the other, so a single formatter would drop half the file.
    func testNeitherFormatterAcceptsTheOtherFormat() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNil(fractional.date(from: "2026-08-26T16:57:25Z"))

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        XCTAssertNil(plain.date(from: "2026-08-26T19:30:00.127765+00:00"))
    }

    func testGarbageStampIsNil() {
        XCTAssertNil(ClaudeUsageReader.date(fromIso: "not a date"))
        XCTAssertNil(ClaudeUsageReader.date(fromIso: ""))
    }
}

final class ClaudeUsageParseTest: XCTestCase {
    private func usage(asOf now: Date) -> ClaudeUsage? {
        ClaudeUsageReader.parse(livePayload, asOf: now)
    }

    func testLivePayloadParses() throws {
        let usage = try XCTUnwrap(usage(asOf: fetchedAt.addingTimeInterval(60)))
        XCTAssertEqual(usage.fiveHour.utilization, 38)
        XCTAssertEqual(usage.sevenDay.utilization, 88)
        XCTAssertEqual(usage.severity, "warning")
        XCTAssertEqual(usage.fetchedAt, fetchedAt)
    }

    /// `utilization` arrives as a percentage; the ring wants a fraction. Getting this
    /// backwards would draw a 38% window as a full circle.
    func testFractionIsThePercentageOverOneHundred() throws {
        let usage = try XCTUnwrap(usage(asOf: fetchedAt))
        XCTAssertEqual(usage.fiveHour.fraction, 0.38, accuracy: 0.0001)
        XCTAssertEqual(usage.sevenDay.fraction, 0.88, accuracy: 0.0001)
    }

    func testFractionIsClampedToTheRingsRange() {
        XCTAssertEqual(UsageWindow(utilization: 140, resetsAt: nil).fraction, 1)
        XCTAssertEqual(UsageWindow(utilization: -5, resetsAt: nil).fraction, 0)
    }

    func testResetsAtUsesTheFractionalDialect() throws {
        let usage = try XCTUnwrap(usage(asOf: fetchedAt))
        let resetsAt = try XCTUnwrap(usage.fiveHour.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, 1_787_772_600.127, accuracy: 0.001)
    }

    func testResetDisplayCountsDownInHoursAndMinutes() throws {
        let usage = try XCTUnwrap(usage(asOf: fetchedAt))
        XCTAssertEqual(usage.fiveHour.resetDisplay, "2h 32m")
    }

    func testMissingWindowsDegradeToZeroRatherThanNil() throws {
        let data = Data(#"{"fetched_at":"2026-08-26T16:57:25Z"}"#.utf8)
        let usage = try XCTUnwrap(ClaudeUsageReader.parse(data, asOf: fetchedAt))
        XCTAssertEqual(usage.fiveHour.utilization, 0)
        XCTAssertNil(usage.fiveHour.resetsAt)
        XCTAssertEqual(usage.severity, "normal")
    }

    /// A reading that cannot be aged is worse than no reading, because the UI would
    /// present it as current forever.
    func testPayloadWithoutFetchedAtIsRejected() {
        XCTAssertNil(ClaudeUsageReader.parse(Data(#"{"five_hour":{"utilization":38}}"#.utf8)))
    }

    func testGarbageIsNilRatherThanThrowing() {
        XCTAssertNil(ClaudeUsageReader.parse(Data("not json".utf8)))
        XCTAssertNil(ClaudeUsageReader.parse(Data()))
    }

    func testRoundTripsThroughCodable() throws {
        let usage = try XCTUnwrap(usage(asOf: fetchedAt))
        let data = try JSONEncoder().encode(usage)
        XCTAssertEqual(try JSONDecoder().decode(ClaudeUsage.self, from: data), usage)
    }
}

final class ClaudeUsageStalenessTest: XCTestCase {
    private func usage(secondAfterFetch: TimeInterval) throws -> ClaudeUsage {
        try XCTUnwrap(ClaudeUsageReader.parse(
            livePayload, asOf: fetchedAt.addingTimeInterval(secondAfterFetch)))
    }

    func testCutoffIsFifteenMinutes() {
        XCTAssertEqual(ClaudeUsageReader.staleAfterSecond, 900)
    }

    /// One missed refresh of a five-minute job is a blip, not a fault.
    func testAFreshReadingIsNotStale() throws {
        XCTAssertFalse(try usage(secondAfterFetch: 0).isStale)
        XCTAssertFalse(try usage(secondAfterFetch: 899).isStale)
    }

    func testAReadingPastTheCutoffIsStale() throws {
        XCTAssertTrue(try usage(secondAfterFetch: 901).isStale)
        XCTAssertTrue(try usage(secondAfterFetch: 86_400).isStale)
    }

    /// Staleness is a function of the clock, not of the file, so it has to be
    /// recomputed on reads that hit the mtime cache.
    func testRefreshedRecomputesAgainstTheCurrentTime() throws {
        let fresh = try usage(secondAfterFetch: 0)
        XCTAssertFalse(fresh.isStale)
        let later = ClaudeUsageReader.refreshed(fresh, asOf: fetchedAt.addingTimeInterval(3600))
        XCTAssertTrue(later.isStale)
    }
}

final class UsageResetDisplayTest: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_763_445)

    private func display(inSecond: TimeInterval) -> String? {
        UsageWindow.display(until: now.addingTimeInterval(inSecond), asOf: now)
    }

    func testHoursAreZeroPaddedSoTheLabelDoesNotJump() {
        XCTAssertEqual(display(inSecond: 2 * 3600 + 30 * 60), "2h 30m")
        XCTAssertEqual(display(inSecond: 2 * 3600 + 5 * 60), "2h 05m")
        XCTAssertEqual(display(inSecond: 3600), "1h 00m")
    }

    func testUnderAnHourDropsTheHourComponent() {
        XCTAssertEqual(display(inSecond: 45 * 60), "45m")
        XCTAssertEqual(display(inSecond: 60), "1m")
    }

    func testTheLastMinuteIsSpelledOut() {
        XCTAssertEqual(display(inSecond: 30), "under a minute")
    }

    /// The file is only rewritten every five minutes, so a just-past reset means "not
    /// known yet" — counting into negatives would be a worse answer than none.
    func testAPastResetIsNilRatherThanNegative() {
        XCTAssertNil(display(inSecond: -1))
        XCTAssertNil(display(inSecond: -3600))
        XCTAssertNil(display(inSecond: 0))
    }

    func testUnknownResetIsNil() {
        XCTAssertNil(UsageWindow.display(until: nil, asOf: now))
        XCTAssertNil(UsageWindow(utilization: 10, resetsAt: nil).resetDisplay)
    }

    /// A seven-day window legitimately reads in the hundreds of hours.
    func testMultiDayWindowStillReadsInHours() {
        XCTAssertEqual(display(inSecond: 7 * 24 * 3600), "168h 00m")
    }
}

final class ClaudeUsageReaderFileTest: XCTestCase {
    /// The reader points at a fixed `/tmp` path it does not own, so the only contract
    /// testable without touching it is that it never throws and never fabricates.
    func testReadIsSafeToCallRegardlessOfWhatIsOnDisk() {
        let usage = ClaudeUsageReader.read()
        if let usage {
            XCTAssertGreaterThanOrEqual(usage.fiveHour.fraction, 0)
            XCTAssertLessThanOrEqual(usage.fiveHour.fraction, 1)
            XCTAssertLessThanOrEqual(usage.sevenDay.fraction, 1)
        }
    }

    /// Repeated calls go through the mtime cache; they must agree with each other.
    func testRepeatedReadsAreConsistent() {
        let now = Date()
        XCTAssertEqual(ClaudeUsageReader.read(asOf: now), ClaudeUsageReader.read(asOf: now))
    }
}
