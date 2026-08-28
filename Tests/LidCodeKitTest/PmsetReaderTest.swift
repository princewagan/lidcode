import XCTest
@testable import LidCodeKit

/// `isDisableSleepOn` returned `false` for the entire life of the app.
///
/// It searched for a row containing `"disablesleep"`. The row macOS actually prints is
/// `SleepDisabled`, which lowercases to `"sleepdisabled"` — a different string, so the
/// loop never matched and the function always fell through to `return false`.
///
/// The user-visible symptom was the health panel's Sleep policy row: `HealthProbe`
/// reaches `case (false, true)` whenever closed-lid is on and the reading says sleep is
/// not disabled, so every closed-lid session showed a permanent red
/// "closed-lid on but disablesleep is 0" while closed-lid was working perfectly.
final class PmsetReaderTest: XCTestCase {
    /// Real `pmset -g` output, copied verbatim including the tabs. The `SleepDisabled`
    /// row is tab-separated and the `sleep` row carries a parenthetical that mentions
    /// sleep three more times — both details are what the parser has to survive.
    private func realOutput(sleepDisabled: String) -> String {
        """
        System-wide power settings:
         SleepDisabled\t\t\(sleepDisabled)
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
         networkoversleep     0
         disksleep            10
         sleep                1 (sleep prevented by caffeinate, powerd, coreaudiod, WindowServer)
         hibernatemode        3
         displaysleep         10
         tcpkeepalive         1
        """
    }

    func testRealOutputWithSleepDisabledZero() {
        XCTAssertFalse(PmsetReader.isDisableSleepOn(realOutput(sleepDisabled: "0")))
    }

    func testRealOutputWithSleepDisabledOne() {
        XCTAssertTrue(PmsetReader.isDisableSleepOn(realOutput(sleepDisabled: "1")))
    }

    /// `pmset -g` omits the row entirely when the value is 0, so absent is a complete
    /// answer — normal sleep — rather than an inconclusive reading.
    func testAbsentRowMeansNormalSleep() {
        let text = """
        Currently in use:
         standby              1
         sleep                1 (sleep prevented by caffeinate)
         displaysleep         10
        """
        XCTAssertFalse(PmsetReader.isDisableSleepOn(text))
        XCTAssertFalse(PmsetReader.isDisableSleepOn(""))
    }

    /// The write spelling still has to work: it is what older macOS echoed back, and it
    /// is what every existing fixture and doc uses.
    func testWriteSpellingIsStillMatched() {
        XCTAssertTrue(PmsetReader.isDisableSleepOn(" disablesleep         1\n"))
        XCTAssertFalse(PmsetReader.isDisableSleepOn(" disablesleep         0\n"))
    }

    /// The row that must never be mistaken for the disable-sleep row. It is called
    /// `sleep`, its value is 1, and its parenthetical is full of the word — a substring
    /// search of any kind gets this wrong.
    func testSleepAssertionRowIsNotTheDisableSleepRow() {
        let text = " sleep                1 (sleep prevented by caffeinate, powerd, coreaudiod)\n"
        XCTAssertFalse(PmsetReader.isDisableSleepOn(text))
    }

    func testDisplaySleepAndDiskSleepAreNotMatched() {
        XCTAssertFalse(PmsetReader.isDisableSleepOn(" displaysleep        1\n"))
        XCTAssertFalse(PmsetReader.isDisableSleepOn(" disksleep           1\n"))
    }

    /// `hasSuffix("1")` was the old value test. It says yes to 11, and to any row that
    /// happens to end in a 1 — including a `sleepimage` path or a timestamp.
    func testValueIsComparedExactlyNotBySuffix() {
        XCTAssertFalse(PmsetReader.isDisableSleepOn(" SleepDisabled\t\t11\n"))
        XCTAssertFalse(PmsetReader.isDisableSleepOn(" SleepDisabled\t\t01\n"))
        XCTAssertTrue(PmsetReader.isDisableSleepOn(" SleepDisabled\t\t1\n"))
    }

    /// A section header has a key and no value. Treating it as a setting would read the
    /// header's own last word as the value.
    func testSectionHeaderIsIgnored() {
        XCTAssertFalse(PmsetReader.isDisableSleepOn("System-wide power settings:\n"))
    }

    func testCaseIsIgnored() {
        XCTAssertTrue(PmsetReader.isDisableSleepOn(" SLEEPDISABLED 1\n"))
        XCTAssertTrue(PmsetReader.isDisableSleepOn(" sleepDisabled 1\n"))
    }

    /// The health panel's own arm, driven by the fixture rather than by the parser in
    /// isolation — this is the row the user was actually looking at.
    func testHealthPanelAgreesWithClosedLidOnRealOutput() {
        var context = HealthContext()
        context.isClamshellActive = true
        let check = HealthProbe.lidcodeCheck(
            context: context, pmsetText: realOutput(sleepDisabled: "1"))
        let sleep = check.first { $0.id == "lidcode.sleep" }
        XCTAssertEqual(sleep?.state, .ok, "closed-lid on and SleepDisabled 1 is the healthy pair")
    }

    /// And it still reports the genuine mismatch, which is the whole reason the check
    /// exists — a broken parser that always says "ok" would be no better.
    func testHealthPanelStillCatchesTheRealMismatch() {
        var context = HealthContext()
        context.isClamshellActive = true
        let check = HealthProbe.lidcodeCheck(
            context: context, pmsetText: realOutput(sleepDisabled: "0"))
        XCTAssertEqual(check.first { $0.id == "lidcode.sleep" }?.state, .down)
    }

    /// `assertionHolder` reads the same output and must keep working — it is the other
    /// half of "why is my Mac still awake?".
    func testAssertionHolderStillParsesTheSleepRow() {
        let holder = PmsetReader.assertionHolder(realOutput(sleepDisabled: "0"))
        XCTAssertEqual(holder, "caffeinate, powerd, coreaudiod, WindowServer")
    }
}
