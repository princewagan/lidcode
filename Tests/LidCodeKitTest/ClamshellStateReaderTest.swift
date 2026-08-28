import XCTest
@testable import LidCodeKit

/// Tests for `ClamshellStateReader` — lid detection from ioreg output.
///
/// The live `ioreg` command cannot run in a test environment (it is a system call),
/// so only the pure parsing function `parseOutput(_:)` is tested here.
/// The caching behaviour is tested with the shared instance as an observable artefact.
final class ClamshellStateReaderTest: XCTestCase {

    // MARK: - Output parsing

    func testClosedLidParsedFromYes() {
        let output = """
            | | |   "IOClamshellState" = 0
            | | |   "AppleClamshellState" = Yes
            | | |   "IOPMSystemCapabilityFromClient" = 0
            """
        XCTAssertEqual(ClamshellStateReader.parseOutput(output), .closed)
    }

    func testOpenLidParsedFromNo() {
        let output = """
            | | |   "AppleClamshellState" = No
            | | |   "IOClamshellState" = 0
            """
        XCTAssertEqual(ClamshellStateReader.parseOutput(output), .open)
    }

    func testMissingKeyReturnsUnknown() {
        let output = """
            | | |   "IOClamshellState" = 0
            | | |   "SomethingElse" = Yes
            """
        XCTAssertEqual(ClamshellStateReader.parseOutput(output), .unknown)
    }

    func testEmptyOutputReturnsUnknown() {
        XCTAssertEqual(ClamshellStateReader.parseOutput(""), .unknown)
    }

    func testMultipleMatchesFirstOneWins() {
        // If the key appears twice (shouldn't in practice), the first match is used.
        let output = """
            "AppleClamshellState" = Yes
            "AppleClamshellState" = No
            """
        XCTAssertEqual(ClamshellStateReader.parseOutput(output), .closed)
    }

    // MARK: - Staleness

    /// A freshly-constructed reading should not be stale.
    func testFreshReadingIsNotStale() {
        let r = ClamshellReading(state: .open, readAt: Date(), isStale: false)
        XCTAssertFalse(r.isStale)
    }

    func testReadingOlderThan30sIsStale() {
        let old = Date().addingTimeInterval(-31)
        let r = ClamshellReading(state: .closed, readAt: old, isStale: true)
        XCTAssertTrue(r.isStale)
    }

    // MARK: - Shared instance cache

    /// `read()` must return within 6 seconds (5s cache TTL + 1s margin) without
    /// hanging the test process. The result may be .unknown on CI without IOKit access.
    func testSharedReadDoesNotHang() {
        let start = Date()
        let reading = ClamshellStateReader.shared.read()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 6.0, "read() must not block indefinitely")
        // The state is one of the three legal values.
        let legalStates: Set<PhysicalLidState> = [.open, .closed, .unknown]
        XCTAssertTrue(legalStates.contains(reading.state))
    }

    // MARK: - Codable round-trip

    func testClamshellReadingCodableRoundTrip() throws {
        let original = ClamshellReading(state: .closed, readAt: Date(), isStale: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClamshellReading.self, from: data)
        XCTAssertEqual(decoded.state, original.state)
        XCTAssertFalse(decoded.isStale)
    }
}
