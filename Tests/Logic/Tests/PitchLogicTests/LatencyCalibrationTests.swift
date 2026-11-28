import XCTest
import EngineCore
@testable import PitchLogic

// J-403 — the latency compensation: the loopback measurement core, the
// resolver's rules (manual wins; loopback is route-bound; staleness applies
// the honest zero), the device-local persistence, and the end-to-end tie to
// the grader (the resolved offset feeds SessionEnvironment).
final class LatencyCalibrationTests: XCTestCase {

    // MARK: The loopback core (AC: a synthetic loopback within ±10 ms)

    func testSyntheticLoopbackRecoversThePlantedOffsetWithin10ms() throws {
        // Five clean rounds planted at 150 ms with ±2 ms of detection jitter
        // (grid-quantized onsets) — the median must land within ±10 ms.
        let planted = 0.150
        let jitter: [Double] = [0.000, 0.002, -0.001, 0.001, -0.002]
        let rounds = jitter.map {
            LoopbackMeasurement(emittedAt_s: 1.000,
                                detectedAt_s: 1.000 + planted + $0)
        }
        let calibration = try LoopbackCalibrator.calibrate(rounds,
                                                           routeID: "headphones_bt",
                                                           updatedAt: "2026-11-28T00:00:00Z")
        XCTAssertEqual(calibration.offset_ms, 150)
        XCTAssertLessThanOrEqual(abs(calibration.offset_ms - Int(planted * 1000)), 10)
        XCTAssertEqual(calibration.source, .loopback)
        XCTAssertEqual(calibration.routeID, "headphones_bt")
    }

    func testTheMedianSurvivesAnOutlierRound() throws {
        // A double-triggered round (400 ms) must not shift the result.
        let offsets = [150, 150, 400, 150, 150]
        let rounds = offsets.map { LoopbackMeasurement(emittedAt_s: 0, detectedAt_s: Double($0) / 1000) }
        let calibration = try LoopbackCalibrator.calibrate(rounds, routeID: "r", updatedAt: nil)
        XCTAssertEqual(calibration.offset_ms, 150)
        let report = LoopbackCalibrator.outliers(in: rounds)
        XCTAssertEqual(report.excluded, [400])
        XCTAssertEqual(report.kept.count, 4)
    }

    func testNoRoundsIsAnErrorNotACalibration() {
        XCTAssertThrowsError(try LoopbackCalibrator.calibrate([], routeID: nil, updatedAt: nil)) {
            error in
            XCTAssertEqual(error as? LoopbackCalibrator.CalibrationError,
                           .notEnoughCleanRounds(got: 0, need: 1))
        }
    }

    func testAnImplausibleMedianIsRefused() throws {
        // Four seconds is not a latency — it is a bug wearing a calibration.
        let rounds = (0..<5).map {
            LoopbackMeasurement(emittedAt_s: 0, detectedAt_s: 4.0 + Double($0) * 0.001)
        }
        XCTAssertThrowsError(try LoopbackCalibrator.calibrate(rounds, routeID: nil, updatedAt: nil)) {
            error in
            XCTAssertEqual(error as? LoopbackCalibrator.CalibrationError,
                           .implausibleMedian(4002))
        }
    }

    func testAnEarlyLivePathIsANegativeOffsetInsideTheWindow() throws {
        // Negative = the live path reads EARLY (a DSP pre-roll): inside the
        // plausible window, so it is accepted — C-20 §4's sign carries it.
        let rounds = (0..<5).map { _ in LoopbackMeasurement(emittedAt_s: 1, detectedAt_s: 1 - 0.030) }
        let calibration = try LoopbackCalibrator.calibrate(rounds, routeID: nil, updatedAt: nil)
        XCTAssertEqual(calibration.offset_ms, -30)
    }

    // MARK: The resolver (what the session APPLIES)

    func testManualWinsAndPersistsAcrossRoutes() {
        let stored = LatencyCalibration(offset_ms: 120, source: .manual,
                                        routeID: "speaker", updatedAt: nil)
        let resolved = LatencyResolver.resolve(stored: stored, currentRouteID: "headphones")
        XCTAssertEqual(resolved.badge, .manual(120))
        XCTAssertEqual(resolved.offset_ms, 120) // the user set it, the user owns it
    }

    func testLoopbackAppliesOnItsOwnRoute() {
        let stored = LatencyCalibration(offset_ms: 150, source: .loopback,
                                        routeID: "headphones", updatedAt: nil)
        let resolved = LatencyResolver.resolve(stored: stored, currentRouteID: "headphones")
        XCTAssertEqual(resolved.badge, .calibrated(150))
        XCTAssertEqual(resolved.offset_ms, 150)
    }

    func testARouteChangeStalesTheLoopbackToTheHonestZero() {
        let stored = LatencyCalibration(offset_ms: 150, source: .loopback,
                                        routeID: "headphones", updatedAt: nil)
        let resolved = LatencyResolver.resolve(stored: stored, currentRouteID: "speaker")
        // The measurement described ANOTHER hardware path: 0 is applied and
        // the user is told why — never a stale number silently used.
        XCTAssertEqual(resolved.badge, .routeChanged(150))
        XCTAssertEqual(resolved.offset_ms, 0)
        XCTAssertEqual(resolved.badge.appliedOffset_ms, 0)
    }

    func testUncalibratedIsTheHonestZero() {
        let resolved = LatencyResolver.resolve(stored: nil, currentRouteID: "speaker")
        XCTAssertEqual(resolved.badge, .uncalibrated)
        XCTAssertEqual(resolved.offset_ms, 0)
    }

    // MARK: Persistence (per device, never in the bundle)

    private var defaults: UserDefaults {
        UserDefaults(suiteName: "latency-calibration-tests")!
    }

    override func tearDown() {
        LatencyCalibration.clear(from: defaults)
        super.tearDown()
    }

    func testPersistenceRoundTrip() {
        let stored = LatencyCalibration(offset_ms: 145, source: .manual,
                                        routeID: "bt", updatedAt: "2026-11-28T00:00:00Z")
        stored.save(to: defaults)
        let loaded = LatencyCalibration.load(from: defaults)
        XCTAssertEqual(loaded, stored)
    }

    func testPersistenceAbsenceIsUncalibratedNeverACrash() {
        LatencyCalibration.clear(from: defaults)
        XCTAssertNil(LatencyCalibration.load(from: defaults))
        defaults.set(Data([0xFF]), forKey: LatencyCalibration.defaultsKey) // corrupt
        XCTAssertNil(LatencyCalibration.load(from: defaults))
    }

    // MARK: The end-to-end tie (the resolved offset drives the GRADER)

    func testTheResolvedOffsetFeedsTheGrader() throws {
        // The session flow's wiring, one call each: resolver → environment →
        // grader. A 200 ms-late capture with a calibrated 200 ms offset on
        // the SAME route grades as sung.
        let stored = LatencyCalibration(offset_ms: 200, source: .loopback,
                                        routeID: "bt", updatedAt: nil)
        let (offset, badge) = LatencyResolver.resolve(stored: stored, currentRouteID: "bt")
        XCTAssertEqual(badge, .calibrated(200))

        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(1.0, 2.0, 48)])
        let live = SessionFixtures.stream(notes: [(1.2, 2.2, 4800)])
        let result = try SessionFixtures.grade(
            reference: reference, live: live,
            environment: SessionEnvironment(latencyOffset_ms: offset))
        XCTAssertEqual(result.perNote?.first?.hit, true)
        XCTAssertEqual(result.latencyOffset_ms, 200) // the session records what applied
    }
}
