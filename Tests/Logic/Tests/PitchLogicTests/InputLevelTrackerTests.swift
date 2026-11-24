import XCTest
@testable import PitchLogic

/// InputLevelTrackerTests (J-102) — the meter's arithmetic, pinned.
///
/// The meter used to render a MOCK wobble at the M1 device demo, so the
/// "Input level" reading was never the singer's. These tests pin the
/// replacement: the engine's real per-frame loudness (C-2.4 `loudness_db`)
/// becomes a 0…1 meter value with fixed anchors and fixed smoothing.
///
/// No sleeping, no wall-clock tolerance: the tracker is a pure value type and
/// the smoothing is per frame, so every expectation is exact.
final class InputLevelTrackerTests: XCTestCase {

    // MARK: - The mapping (dBFS → 0…1)

    func testFloorReadsZero() {
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: -60), 0)
    }

    func testCeilingReadsOne() {
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: 0), 1)
    }

    func testMidpointReadsHalf() {
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: -30), 0.5, accuracy: 1e-12)
    }

    func testBelowFloorClampsToZero() {
        // The MockEngine reports −95 dBFS — the demo singer's "silence".
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: -95), 0)
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: -120), 0)
    }

    func testAboveCeilingClampsToOne() {
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: 6), 1)
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: 120), 1)
    }

    func testNonFiniteLoudnessReadsZero() {
        // Never fabricate a level (D-12 honesty).
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: .nan), 0)
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: .infinity), 0)
        XCTAssertEqual(InputLevelTracker.normalized(loudnessDB: -.infinity), 0)
    }

    func testMappingIsMonotonicInLoudness() {
        let samples: [Double] = [-95, -60, -45, -30, -15, -6, 0, 6]
        let mapped = samples.map(InputLevelTracker.normalized(loudnessDB:))
        for (lower, higher) in zip(mapped, mapped.dropFirst()) {
            XCTAssertLessThanOrEqual(lower, higher)
        }
    }

    // MARK: - The smoothing (attack / release per frame)

    func testAttackReachesHalfTheTargetInOneFrame() {
        var tracker = InputLevelTracker()
        XCTAssertEqual(tracker.ingest(loudnessDB: 0), 0.5, accuracy: 1e-12)
    }

    func testReleaseFallsByTheReleaseCoefficientInOneFrame() {
        var tracker = InputLevelTracker()
        // The attack is exponential: the level approaches the target
        // (1 − 0.5ⁿ), so 40 frames is full scale to within 1e-12.
        for _ in 0..<40 { tracker.ingest(loudnessDB: 0) }
        let before = tracker.level
        XCTAssertEqual(before, 1, accuracy: 1e-12)
        // Silence arrives → the level falls by the RELEASE coefficient, not
        // the attack one (the meter must not snap to zero between syllables).
        XCTAssertEqual(tracker.ingest(loudnessDB: -60),
                       before * (1 - InputLevelTracker.release),
                       accuracy: 1e-12)
    }

    func testAttackIsUsedWhenTheLevelRises() {
        var tracker = InputLevelTracker()
        tracker.ingest(loudnessDB: -60) // 0
        tracker.ingest(loudnessDB: -60)
        let before = tracker.level
        let after = tracker.ingest(loudnessDB: 0)
        XCTAssertEqual(after - before, (1 - before) * InputLevelTracker.attack, accuracy: 1e-12)
    }

    func testLevelRisesMonotonicallyTowardTheTarget() {
        var tracker = InputLevelTracker()
        var previous = tracker.level
        for _ in 0..<20 {
            let current = tracker.ingest(loudnessDB: -10)
            XCTAssertGreaterThan(current, previous)
            previous = current
        }
    }

    func testLevelStaysWithinZeroAndOne() {
        var tracker = InputLevelTracker()
        for db in [0.0, -60, 12, -120, -3, 0] {
            let level = tracker.ingest(loudnessDB: db)
            XCTAssertGreaterThanOrEqual(level, 0)
            XCTAssertLessThanOrEqual(level, 1)
        }
    }

    func testSilenceDecaysToZeroOverFrames() {
        var tracker = InputLevelTracker()
        for _ in 0..<40 { tracker.ingest(loudnessDB: 0) }
        XCTAssertEqual(tracker.level, 1, accuracy: 1e-12)
        // Release is exponential too: 200 frames of silence is silence.
        for _ in 0..<200 { tracker.ingest(loudnessDB: -60) }
        XCTAssertEqual(tracker.level, 0, accuracy: 1e-9)
    }

    // MARK: - Reset

    func testResetReturnsToSilence() {
        var tracker = InputLevelTracker()
        for _ in 0..<10 { tracker.ingest(loudnessDB: 0) }
        XCTAssertGreaterThan(tracker.level, 0)
        tracker.reset()
        XCTAssertEqual(tracker.level, 0)
    }

    func testAFreshTrackerStartsAtZero() {
        XCTAssertEqual(InputLevelTracker().level, 0)
    }
}
