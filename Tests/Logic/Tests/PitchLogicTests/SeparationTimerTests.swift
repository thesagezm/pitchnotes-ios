import XCTest
import EngineCore
@testable import PitchLogic

// SeparationTimerTests (J-206, session 7) — the separation pass, measured
// from the C-8 stage stream.
//
// The clock is INJECTED, so these tests are deterministic: no sleeping, no
// wall-clock tolerance. The dates below are fixed points on a synthetic
// timeline (the 1970 epoch + N seconds), which is exactly why the timer
// takes the timestamp as a parameter instead of calling Date().

final class SeparationTimerTests: XCTestCase {

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: - The band opens and closes on the right events

    func testBandOpensOnTheFirstSeparatingEvent() {
        var timer = SeparationTimer()
        XCTAssertEqual(timer.observe(stage: .decoding, at: at(0)), .none)
        XCTAssertEqual(timer.observe(stage: .separating, at: at(10)), .opened)
        XCTAssertEqual(timer.separationStartedAt, at(10))
        XCTAssertNil(timer.separationEndedAt)
    }

    func testBandClosesOnTheFirstAssemblingEvent() {
        var timer = SeparationTimer()
        timer.observe(stage: .separating, at: at(10))
        XCTAssertEqual(timer.observe(stage: .assembling, at: at(25)), .closed)
        XCTAssertEqual(timer.separationEndedAt, at(25))
    }

    func testWallTimeIsTheSeparationBandOnly() {
        var timer = SeparationTimer()
        timer.observe(stage: .decoding, at: at(0))
        timer.observe(stage: .separating, at: at(10))
        timer.observe(stage: .separating, at: at(18))
        timer.observe(stage: .assembling, at: at(25))
        timer.observe(stage: .assembling, at: at(30))
        // 10 s → 25 s. The decode before it and the assembly after it are
        // NOT separation time — the whole point of the band.
        XCTAssertEqual(timer.separationWallTime_s, 15)
        XCTAssertTrue(timer.isMeasured)
    }

    // MARK: - Honesty: no band, no number

    func testWallTimeIsNilBeforeTheBandCloses() {
        var timer = SeparationTimer()
        timer.observe(stage: .separating, at: at(10))
        // The separation is still running: no number yet — never a 0.0,
        // which would read as "infinitely fast" in the RTF line.
        XCTAssertNil(timer.separationWallTime_s)
        XCTAssertFalse(timer.isMeasured)
    }

    func testWallTimeIsNilWhenNoSeparatingEventWasEverSeen() {
        var timer = SeparationTimer()
        timer.observe(stage: .decoding, at: at(0))
        timer.observe(stage: .assembling, at: at(5))
        // An engine that broke C-8: the assembling event must NOT open a
        // band (there was no separation to measure).
        XCTAssertEqual(timer.observe(stage: .assembling, at: at(5)), .none)
        XCTAssertNil(timer.separationWallTime_s)
        XCTAssertNil(timer.separationStartedAt)
        XCTAssertNil(timer.separationEndedAt)
    }

    func testDecodingEventsNeverTouchTheBand() {
        var timer = SeparationTimer()
        XCTAssertEqual(timer.observe(stage: .decoding, at: at(0)), .none)
        XCTAssertEqual(timer.observe(stage: .decoding, at: at(3)), .none)
        XCTAssertNil(timer.separationStartedAt)
        XCTAssertNil(timer.separationEndedAt)
    }

    // MARK: - The band opens once and closes once

    func testTheBandOpensOnlyOnce() {
        var timer = SeparationTimer()
        XCTAssertEqual(timer.observe(stage: .separating, at: at(10)), .opened)
        XCTAssertEqual(timer.observe(stage: .separating, at: at(12)), .none)
        XCTAssertEqual(timer.observe(stage: .separating, at: at(14)), .none)
        XCTAssertEqual(timer.separationStartedAt, at(10))
    }

    func testTheBandClosesOnlyOnce() {
        var timer = SeparationTimer()
        timer.observe(stage: .separating, at: at(10))
        XCTAssertEqual(timer.observe(stage: .assembling, at: at(25)), .closed)
        XCTAssertEqual(timer.observe(stage: .assembling, at: at(27)), .none)
        XCTAssertEqual(timer.separationEndedAt, at(25))
    }

    // MARK: - Degenerate clocks

    func testAZeroLengthBandIsZeroNotNegative() {
        var timer = SeparationTimer()
        timer.observe(stage: .separating, at: at(10))
        timer.observe(stage: .assembling, at: at(10))
        XCTAssertEqual(timer.separationWallTime_s, 0)
    }

    func testABackwardsClockIsRefusedRatherThanReported() {
        var timer = SeparationTimer()
        timer.observe(stage: .separating, at: at(10))
        timer.observe(stage: .assembling, at: at(5)) // the clock went backwards
        XCTAssertNil(timer.separationWallTime_s)
        XCTAssertFalse(timer.isMeasured)
    }

    // MARK: - The mock's real event order still measures

    /// The mock's own shape: decode → separating ticks → assembling. The
    /// timer must produce a positive number for it — the mock path is what
    /// the UI regression runs on, so a broken band would silently blank the
    /// metrics line.
    func testTheMockEventOrderMeasures() {
        var timer = SeparationTimer()
        timer.observe(stage: .decoding, at: at(0))
        for i in 1...5 {
            timer.observe(stage: .separating, at: at(Double(i)))
        }
        timer.observe(stage: .assembling, at: at(6))
        XCTAssertEqual(timer.separationWallTime_s, 5)
    }
}
