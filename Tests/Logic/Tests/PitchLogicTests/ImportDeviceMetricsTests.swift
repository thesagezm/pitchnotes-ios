import XCTest
@testable import PitchLogic

// ImportDeviceMetrics tests (J-206) — the arithmetic and the honest
// formatting of the import-pass numbers the M2 gate records (separation
// wall-time ÷ source duration = RTF, peak resident footprint, thermal
// start→end).
//
// The HONESTY rules are the point of these tests: a value that was not
// measured must read as "not measured", never as 0.

final class ImportDeviceMetricsTests: XCTestCase {

    private func metrics(
        wall: Double = 42,
        source: Double = 180,
        peak: UInt64? = 512 * 1024 * 1024,
        start: ThermalLevel = .nominal,
        end: ThermalLevel = .fair
    ) -> ImportDeviceMetrics {
        ImportDeviceMetrics(
            separationWallTime_s: wall,
            sourceDuration_s: source,
            peakResidentBytes: peak,
            thermalAtStart: start,
            thermalAtEnd: end)
    }

    // MARK: - RTF arithmetic

    func testRealtimeFactorIsWallTimeOverSourceDuration() {
        XCTAssertEqual(metrics(wall: 42, source: 180).realtimeFactor ?? 0, 42.0 / 180.0, accuracy: 1e-9)
    }

    func testRealtimeFactorIsNilWithoutAKnownDuration() {
        XCTAssertNil(metrics(source: 0).realtimeFactor,
                     "a zero-length source has no RTF — never 0.00×")
        XCTAssertNil(metrics(source: -5).realtimeFactor)
    }

    func testFasterThanRealtimeIsBelowOne() {
        XCTAssertLessThan(metrics(wall: 30, source: 180).realtimeFactor ?? 99, 1.0)
    }

    // MARK: - Peak tracking

    func testPeakTrackerKeepsTheMaximum() {
        var tracker = PeakResidentTracker()
        XCTAssertNil(tracker.peakBytes, "no sample yet means no peak — not zero")
        tracker.sample(100)
        tracker.sample(300)
        tracker.sample(200)
        XCTAssertEqual(tracker.peakBytes, 300)
    }

    func testPeakTrackerIgnoresUnusableSamples() {
        var tracker = PeakResidentTracker()
        tracker.sample(nil)
        XCTAssertNil(tracker.peakBytes)
        tracker.sample(42)
        tracker.sample(nil)
        XCTAssertEqual(tracker.peakBytes, 42, "a failed sample must not erase the peak")
    }

    // MARK: - Honest formatting

    func testRealtimeFactorFormatting() {
        XCTAssertEqual(ImportMetricsFormatter.realtimeFactor(0.4567), "0.46×")
        XCTAssertEqual(ImportMetricsFormatter.realtimeFactor(nil), "—",
                       "an unmeasured RTF must not read as 0.00×")
        XCTAssertEqual(ImportMetricsFormatter.realtimeFactor(.nan), "—")
        XCTAssertEqual(ImportMetricsFormatter.realtimeFactor(-1), "—")
    }

    func testResidentBytesFormatting() {
        XCTAssertEqual(ImportMetricsFormatter.residentBytes(512 * 1024 * 1024), "512 MB")
        XCTAssertEqual(ImportMetricsFormatter.residentBytes(2 * 1024 * 1024 * 1024), "2.00 GB")
        XCTAssertEqual(ImportMetricsFormatter.residentBytes(nil), "not sampled",
                       "an unsampled footprint must not read as 0 MB")
        XCTAssertEqual(ImportMetricsFormatter.residentBytes(0), "0 MB",
                       "a measured zero is a real zero — say it")
    }

    func testDurationFormatting() {
        XCTAssertEqual(ImportMetricsFormatter.duration(0), "0:00")
        XCTAssertEqual(ImportMetricsFormatter.duration(83), "1:23")
        XCTAssertEqual(ImportMetricsFormatter.duration(3600), "60:00")
        XCTAssertEqual(ImportMetricsFormatter.duration(.nan), "—")
    }

    func testSummaryCarriesEveryNumberTheGateRecords() {
        let text = ImportMetricsFormatter.summary(metrics())
        XCTAssertTrue(text.contains("RTF 0.23×"), text)
        XCTAssertTrue(text.contains("peak RSS 512 MB"), text)
        XCTAssertTrue(text.contains("thermal nominal→fair"), text)
        XCTAssertTrue(text.contains("0:42"), text)
        XCTAssertTrue(text.contains("3:00"), text)
    }

    func testSummaryMarksAnEstimatedSourceDuration() {
        var m = metrics()
        m.sourceDurationIsEstimate = true
        let text = ImportMetricsFormatter.summary(m)
        XCTAssertTrue(text.contains("(estimated)"),
                      "the mock engine's size-based duration must be marked: \(text)")
    }

    func testSummaryStaysHonestWhenNothingWasSampled() {
        let text = ImportMetricsFormatter.summary(metrics(peak: nil))
        XCTAssertTrue(text.contains("peak RSS not sampled"), text)
        // The RTF is still known (wall time ÷ duration were both measured) —
        // only the unsampled value reads as "not sampled".
        XCTAssertTrue(text.contains("RTF 0.23×"), text)
    }

    func testSummaryShowsNoRTFWhenTheDurationIsUnknown() {
        let text = ImportMetricsFormatter.summary(metrics(source: 0, peak: nil))
        XCTAssertTrue(text.contains("RTF —"), text)
        XCTAssertTrue(text.contains("peak RSS not sampled"), text)
    }

    // MARK: - Thermal labels

    func testThermalLabels() {
        XCTAssertEqual(ThermalLevel.nominal.label, "nominal")
        XCTAssertEqual(ThermalLevel.fair.label, "fair")
        XCTAssertEqual(ThermalLevel.serious.label, "serious")
        XCTAssertEqual(ThermalLevel.critical.label, "critical")
    }
}
