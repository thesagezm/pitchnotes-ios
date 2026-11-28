import XCTest
import EngineCore
@testable import PitchLogic

// J-401 · the timing and gating paths: the onset grace (C-19's 80–120 ms),
// the breath gate (a breath is silence, not a sung pitch), the uncovered-span
// exclusion (`notAssessableReason: "noLiveFrames"`), and the C-20 latency
// offset's effect on the comparison window.
final class SessionGraderTimingTests: XCTestCase {

    // MARK: The onset grace (C-19, default 100 ms inside [80, 120])

    func testOnsetWithinGraceIsFullTiming() throws {
        let fixture = try SessionFixtures.load("late_onset_grace")
        let result = try SessionFixtures.grade(fixture)
        let perNote = try XCTUnwrap(result.perNote)
        // Note 0 starts +90 ms late — inside the grace, so its timing is full
        // and the note grades as sung in tune.
        XCTAssertEqual(perNote[0].hit, true)
        XCTAssertEqual(perNote[0].centsDeviation ?? 99, 0, accuracy: 0.01)
        // And the pure component, pinned exactly: 90 ms ≤ 100 ms grace.
        XCTAssertEqual(SessionGrader.timingScore(onsetLatency_s: 0.09, grace_s: 0.1,
                                                 noteDuration_s: 1.0), 1.0, accuracy: 1e-12)
    }

    func testOnsetBeyondGraceDocksTheTiming() throws {
        let fixture = try SessionFixtures.load("late_onset_grace")
        let result = try SessionFixtures.grade(fixture)
        let perNote = try XCTUnwrap(result.perNote)
        // Note 1 starts +150 ms late — beyond the grace. Still a hit (the
        // note was sung in tune), but the timing component is docked.
        XCTAssertEqual(perNote[1].hit, true)
        XCTAssertEqual(perNote[1].centsDeviation ?? 99, 0, accuracy: 0.01)
        let late = SessionGrader.timingScore(onsetLatency_s: 0.16, grace_s: 0.1,
                                             noteDuration_s: 1.0)
        XCTAssertEqual(late, 0.94, accuracy: 1e-9)
        XCTAssertLessThan(late, 1.0)
        // On time: the grace never docks an on-time onset.
        XCTAssertEqual(SessionGrader.timingScore(onsetLatency_s: 0.0, grace_s: 0.1,
                                                 noteDuration_s: 1.0), 1.0, accuracy: 1e-12)
    }

    func testTheGraceWindowIsNotScoredAgainstPitch() {
        // A glide INTO the note inside the grace does not poison the center:
        // 50 ms of a +80c glide, then on-pitch — the scored frames start
        // after the 100 ms grace, so the center is the sung note, not the glide.
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(0.5, 1.5, 48)])
        var frames: [PitchFrame] = []
        var t = 0.512
        while t < 1.5 {
            let cents = t < 0.6 ? 4880.0 : 4800.0 // +80c glide for the first 50 ms
            frames.append(SessionFixtures.frame(t: t, cents: cents))
            t += 0.016
        }
        let result = try? SessionFixtures.grade(reference: reference, live: frames)
        let note = try? XCTUnwrap(result?.perNote?.first)
        XCTAssertEqual(note?.centsDeviation ?? 99, 0, accuracy: 0.01)
        XCTAssertEqual(note?.hit, true)
    }

    // MARK: The breath gate (C-19, default −60 dB)

    func testLeadingBreathThenOnPitchIsAHit() throws {
        let fixture = try SessionFixtures.load("breath_silence_dropout")
        let result = try SessionFixtures.grade(fixture)
        let perNote = try XCTUnwrap(result.perNote)
        // Note 0: 300 ms of breath (−75 dB, below the gate), then on-pitch.
        // The breath costs coverage and timing, not the pitch verdict.
        XCTAssertEqual(perNote[0].hit, true)
        XCTAssertEqual(perNote[0].centsDeviation ?? 99, 0, accuracy: 0.01)
        XCTAssertEqual(perNote[0].coverage ?? 0, 0.704, accuracy: 0.02)
    }

    func testASilentNoteIsAMissNotAPitchError() throws {
        let fixture = try SessionFixtures.load("breath_silence_dropout")
        let result = try SessionFixtures.grade(fixture)
        let note = try XCTUnwrap(result.perNote?[1])
        // Note 1: EVERY frame below the gate — nothing was sung. That is a
        // graded miss (coverage 0), not an exclusion: frames existed.
        XCTAssertEqual(note.hit, false)
        XCTAssertEqual(note.coverage, 0.0)
        XCTAssertEqual(note.sustain_ms, 0)
        XCTAssertEqual(note.centsDeviation, nil) // no voiced frames ⇒ no center to report
        XCTAssertEqual(note.notAssessable, false)
        XCTAssertEqual(note.notAssessableReason, nil)
    }

    func testAnUncoveredSpanIsNotAssessableNoLiveFrames() throws {
        let fixture = try SessionFixtures.load("breath_silence_dropout")
        let result = try SessionFixtures.grade(fixture)
        let note = try XCTUnwrap(result.perNote?[2])
        // Note 2: a GRID HOLE — no frames at all in its span. C-18's
        // "noLiveFrames" is the contract's answer, and the exclusion is
        // VISIBLE (D-54 §1).
        XCTAssertEqual(note.notAssessable, true)
        XCTAssertEqual(note.notAssessableReason, "noLiveFrames")
        XCTAssertEqual(note.hit, nil)
        XCTAssertEqual(note.centsDeviation, nil)
        let summary = try XCTUnwrap(result.notAssessable)
        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.byReason.noLiveFrames, 1)
        XCTAssertEqual(summary.byReason.unassigned, 0)
    }

    func testTheCleanNoteAfterTheHoleGradesNormally() throws {
        let fixture = try SessionFixtures.load("breath_silence_dropout")
        let result = try SessionFixtures.grade(fixture)
        let note = try XCTUnwrap(result.perNote?[3])
        XCTAssertEqual(note.hit, true)
        XCTAssertEqual(note.centsDeviation ?? 99, 0, accuracy: 0.01)
    }

    func testFramesBelowTheGateAreUnvoicedEvenWithAPitch() {
        // A frame carrying a pitch but −80 dB loudness is a breath, not a
        // note (C-19: frames below the gate are UNVOICED for grading).
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(0.5, 1.5, 48)])
        var frames: [PitchFrame] = []
        var t = 0.512
        while t < 1.5 {
            let loud = t >= 0.8 // the first 300 ms is "sung" but at −80 dB
            frames.append(PitchFrame(t: t,
                                     hz: SessionFixtures.hzOf(cents: 4800),
                                     confidence: 0.95,
                                     loudness_db: loud ? -30.0 : -80.0,
                                     engine_id: "SWIFTF0", lookahead_ms: 176))
            t += 0.016
        }
        let result = try? SessionFixtures.grade(reference: reference, live: frames)
        let note = try? XCTUnwrap(result?.perNote?.first)
        XCTAssertEqual(note?.coverage ?? 1, 0.704, accuracy: 0.02) // the quiet stretch was NOT coverage
        XCTAssertEqual(note?.hit, true)
    }

    // MARK: The C-20 latency offset moves the comparison window

    func testLatencyOffsetShiftsTheComparisonWindowByItsSign() {
        // The singer sang the note ON the reference timeline, but every frame
        // was CAPTURED 200 ms late (output → air → mic → processing). C-20 §4:
        // ≥ 0 = live is LATE, so the grader compares the frame at t against
        // the reference at t − 200 ms — the note grades as sung.
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(1.0, 2.0, 48)])
        let live = SessionFixtures.stream(notes: [(1.2, 2.2, 4800.0)])

        let withCompensation = try? SessionFixtures.grade(
            reference: reference, live: live,
            environment: SessionEnvironment(latencyOffset_ms: 200))
        XCTAssertEqual(withCompensation?.perNote?.first?.hit, true)
        XCTAssertEqual(withCompensation?.perNote?.first?.centsDeviation ?? 99, 0, accuracy: 0.01)

        // Without the compensation the same session looks late-started and
        // partially uncovered — exactly the distortion the calibration
        // removes (a LOWER score for the SAME singing).
        let without = try? SessionFixtures.grade(reference: reference, live: live)
        XCTAssertEqual(without?.perNote?.first?.coverage ?? 0, 0.8, accuracy: 0.01)
        XCTAssertGreaterThan(withCompensation?.accuracy?.overall ?? 0,
                             without?.accuracy?.overall ?? 1)
        XCTAssertEqual(without?.latencyOffset_ms, 0)
        XCTAssertEqual(withCompensation?.latencyOffset_ms, 200) // recorded per session
    }
}
