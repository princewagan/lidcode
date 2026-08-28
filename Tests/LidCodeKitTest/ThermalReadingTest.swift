import XCTest
@testable import LidCodeKit

/// The die temperature exists to make the governor responsive on Apple silicon, where
/// `ProcessInfo.thermalState` sits at `.nominal` almost permanently. That only works if
/// the celsius→level mapping is exact at its boundaries and if a machine with no
/// readable sensor still behaves the way it did before the sensor existed.
final class ThermalReadingTest: XCTestCase {

    // MARK: - Threshold boundaries

    /// Each band is closed at the bottom: exactly 65 °C is already `.fair`. Testing the
    /// boundary and the value one ulp below it pins the comparison direction, which is
    /// the half of this that a refactor can silently invert.
    func testBoundariesAreInclusiveAtTheLowerEdge() {
        let case_: [(Double, ThermalLevel)] = [
            (ThermalThreshold.fairCelsius, .fair),
            (ThermalThreshold.fairCelsius.nextDown, .nominal),
            (ThermalThreshold.seriousCelsius, .serious),
            (ThermalThreshold.seriousCelsius.nextDown, .fair),
            (ThermalThreshold.criticalCelsius, .critical),
            (ThermalThreshold.criticalCelsius.nextDown, .serious),
        ]
        for (celsius, expected) in case_ {
            XCTAssertEqual(
                ThermalThreshold.level(forCelsius: celsius), expected,
                "\(celsius)°C should map to \(expected)")
        }
    }

    func testTypicalReadingsMapToTheExpectedBand() {
        XCTAssertEqual(ThermalThreshold.level(forCelsius: 35), .nominal)
        XCTAssertEqual(ThermalThreshold.level(forCelsius: 52), .nominal)
        XCTAssertEqual(ThermalThreshold.level(forCelsius: 72), .fair)
        XCTAssertEqual(ThermalThreshold.level(forCelsius: 88), .serious)
        XCTAssertEqual(ThermalThreshold.level(forCelsius: 101), .critical)
    }

    /// A sensor that reports nonsense must not read as cold. `readCelsius` filters
    /// implausible values out, but if one ever reached the mapping, freezing must not
    /// be the answer that unblocks a run.
    func testExtremeValuesStaySaturatedRatherThanWrappingAround() {
        XCTAssertEqual(ThermalThreshold.level(forCelsius: -40), .nominal)
        XCTAssertEqual(ThermalThreshold.level(forCelsius: 500), .critical)
    }

    func testThresholdsAreOrdered() {
        XCTAssertLessThan(ThermalThreshold.fairCelsius, ThermalThreshold.seriousCelsius)
        XCTAssertLessThan(ThermalThreshold.seriousCelsius, ThermalThreshold.criticalCelsius)
    }

    // MARK: - Reading

    /// The whole point of the change: a `.nominal` OS state plus a hot die must not
    /// read as normal.
    func testEffectiveLevelTakesTheWorseOfOsStateAndTemperature() {
        XCTAssertEqual(max(ThermalLevel.nominal, ThermalThreshold.level(forCelsius: 96)), .critical)
        XCTAssertEqual(max(ThermalLevel.nominal, ThermalThreshold.level(forCelsius: 70)), .fair)
        // ...and the reverse: a cool die must never talk the OS down out of a state it
        // has already declared, because the OS knows about throttling the sensors do not.
        XCTAssertEqual(max(ThermalLevel.serious, ThermalThreshold.level(forCelsius: 40)), .serious)
    }

    func testDisplayPrefersDegreesAndFallsBackToTheLevelWord() {
        XCTAssertEqual(ThermalReading(level: .nominal, celsius: 52.4).display, "52°")
        XCTAssertEqual(ThermalReading(level: .nominal, celsius: 52.6).display, "53°")
        XCTAssertEqual(ThermalReading(level: .serious).display, "Hot")
    }

    /// Existing call sites construct `ThermalReading(level:)` with no temperature. That
    /// must keep meaning "unknown", not "0 °C", or every one of them would read as an
    /// ice-cold machine.
    func testNilCelsiusFallsBackToTheOsLevelAlone() {
        let reading = ThermalReading(level: .fair)
        XCTAssertNil(reading.celsius)
        XCTAssertEqual(reading.level, .fair)
        XCTAssertEqual(reading.display, "Fair")

        // And the governor still sees exactly what it saw before the field existed.
        let verdict = SafetyGovernor(setting: .default).evaluate(
            battery: BatteryReading(percent: 90, isCharging: false, isOnMain: true),
            thermal: ThermalReading(level: .critical),
            isClamshellActive: true)
        XCTAssertEqual(verdict, .forceSleep(.thermalCritical))
    }

    /// `state.json` written before this field existed must still decode.
    func testDecodesLegacyReadingWithoutACelsiusKey() throws {
        let legacy = Data(#"{"level":"serious"}"#.utf8)
        let decoded = try JSONDecoder().decode(ThermalReading.self, from: legacy)
        XCTAssertEqual(decoded.level, .serious)
        XCTAssertNil(decoded.celsius)
    }

    func testRoundTripsThroughCodableWithACelsiusValue() throws {
        let original = ThermalReading(level: .fair, celsius: 71.5)
        let decoded = try JSONDecoder().decode(
            ThermalReading.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Sensor

    /// Runs on whatever hardware CI or a developer has. It cannot assert a number, so
    /// it asserts the contract: never crash, never return an implausible value, and be
    /// consistent about whether the sensor exists.
    func testSensorEitherReportsAPlausibleTemperatureOrNothingAtAll() {
        let sensor = TemperatureSensor(cacheWindow: 0)
        let first = sensor.readCelsius()
        if let first {
            XCTAssertGreaterThan(first, 0)
            XCTAssertLessThanOrEqual(first, 130)
        }
        // Availability must latch, not flap: a caller polling every 5 s should never
        // see the sensor appear and vanish.
        for _ in 0..<3 {
            XCTAssertEqual(sensor.readCelsius() == nil, first == nil)
        }
        sensor.rescan()
        XCTAssertEqual(sensor.readCelsius() == nil, first == nil)
    }

    /// It is read from the runtime's background queue while the UI reads the published
    /// snapshot, so concurrent reads must not tear the cached state.
    func testConcurrentReadsAreSafe() {
        let sensor = TemperatureSensor()
        let done = expectation(description: "concurrent reads")
        done.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            DispatchQueue.global().async {
                for _ in 0..<25 { _ = sensor.readCelsius() }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 30)
    }

    func testReaderProducesAConsistentReading() {
        let reading = ThermalReader.read()
        if let celsius = reading.celsius {
            XCTAssertGreaterThanOrEqual(
                reading.level, ThermalThreshold.level(forCelsius: celsius),
                "the effective level must never be cooler than the die temperature implies")
            XCTAssertEqual(reading.display, "\(Int(celsius.rounded()))°")
        } else {
            XCTAssertEqual(reading.display, reading.level.display)
        }
    }
}
