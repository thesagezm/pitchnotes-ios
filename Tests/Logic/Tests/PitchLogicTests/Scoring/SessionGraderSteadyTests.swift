import XCTest
import EngineCore
@testable import PitchLogic

// J-401 · the pitch path over the L-402 fixtures: steady singing, the D-22
// detuned-recording AC (a faithful singer is never marked flat), the octave
// fold (fold THEN measure), and the mean-centered vibrato model.
final class SessionGraderSteadyTests: XCTestCase {

    // MARK: steady_sung — on-pitch, both notes hit, grade A

    func testSteadySungEveryNoteIsAHitWithZeroDeviation() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("steady_sung"))
        let perNote = try XCTUnwrap(result.perNote)
        XCTAssertEqual(perNote.count, 2)
        for note in perNote {
            XCTAssertEqual(note.hit, true)
            XCTAssertEqual(note.centsDeviation ?? 99, 0, accuracy: 0.01)
            XCTAssertEqual(note.notAssessable, false)
        }
    }

    func testSteadySungGradesAWithNearPerfectAccuracy() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("steady_sung"))
        let accuracy = try XCTUnwrap(result.accuracy)
        XCTAssertEqual(accuracy.overall ?? 0, 1.0, accuracy: 0.005)
        XCTAssertEqual(accuracy.transition, nil) // gap 100 ms > 50 ms: no transition class
        XCTAssertEqual(result.grade, .a)
    }

    func testReferenceCentsRefFeedsTheReferencePitch() throws {
        // The fixture's notes carry cents_ref 12 / −30 and the frames sit at
        // midi·100 + cents_ref — proving the grader reads BOTH (the note's
        // own deviation, not just its MIDI number).
        let result = try SessionFixtures.grade(try SessionFixtures.load("steady_sung"))
        let perNote = try XCTUnwrap(result.perNote)
        XCTAssertEqual(perNote[0].centsDeviation ?? 99, 0, accuracy: 0.01) // +12c note
        XCTAssertEqual(perNote[1].centsDeviation ?? 99, 0, accuracy: 0.01) // −30c note
    }

    // MARK: D-22 — the detuned-recording AC (the headline honesty pin)

    func testDetunedSharp35FaithfulSingerIsNeverMarkedSharp() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("detuned_sharp_35"))
        for note in try XCTUnwrap(result.perNote) {
            XCTAssertEqual(note.centsDeviation ?? 99, 0, accuracy: 0.01) // NOT +35
            XCTAssertEqual(note.hit, true)
        }
        XCTAssertEqual(result.tuningCents, 35)
    }

    func testDetunedFlat35FaithfulSingerIsNeverMarkedFlat() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("detuned_flat_35"))
        for note in try XCTUnwrap(result.perNote) {
            XCTAssertEqual(note.centsDeviation ?? 99, 0, accuracy: 0.01) // NOT −35
            XCTAssertEqual(note.hit, true)
        }
        XCTAssertEqual(result.tuningCents, -35)
    }

    func testIgnoringTuningCentsIsExactlyTheFailureD22Forbids() throws {
        // The same faithful singer graded against unadjusted A440 IS marked
        // −35 — the contract forbids that, and this test pins why the
        // environment's tuningCents is consumed on every grading path.
        var fixture = try SessionFixtures.load("detuned_flat_35")
        fixture.environment = SessionEnvironment(tuningCents: 0) // the D-22 failure
        let result = try SessionFixtures.grade(fixture)
        let perNote = try XCTUnwrap(result.perNote)
        XCTAssertEqual(perNote[0].centsDeviation ?? 99, -35, accuracy: 0.01)
    }

    // MARK: octave_error — fold THEN measure (C-19)

    func testOctaveErrorFoldsByDefault() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("octave_error"))
        for note in try XCTUnwrap(result.perNote) {
            XCTAssertEqual(note.centsDeviation ?? 99, 0, accuracy: 0.01)
            XCTAssertEqual(note.hit, true)
        }
        XCTAssertTrue(GradingConfig.default.octaveEquivalence)
    }

    func testOctaveErrorMissesWhenTheFoldIsDisabled() throws {
        let fixture = try SessionFixtures.load("octave_error")
        var config = GradingConfig.default
        config.octaveEquivalence = false
        let result = try SessionFixtures.grade(fixture, config: config)
        let perNote = try XCTUnwrap(result.perNote)
        for note in perNote {
            XCTAssertEqual(note.centsDeviation ?? 99, 1200, accuracy: 0.01)
            XCTAssertEqual(note.hit, false)
        }
    }

    // MARK: vibrato_mean_centered — the swing is not an error (C-19)

    func testVibratoMeanCenteredIsNotAnError() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("vibrato_mean_centered"))
        let note = try XCTUnwrap(result.perNote?.first)
        XCTAssertEqual(note.centsDeviation ?? 99, 0, accuracy: 1.0) // the MEAN is the center
        XCTAssertEqual(note.hit, true)
        XCTAssertGreaterThan(note.sustain_ms ?? 0, 1900) // the swing stays in-tune throughout
        XCTAssertEqual(note.coverage ?? 0, 1.0, accuracy: 0.01)
    }

    func testVibratoAroundAnOffCenterStillGradesByTheCenter() throws {
        // Vibrato ±20 around +40: the center (40c) is inside ±50, so the note
        // grades on its center — mean-centered, per C-19.
        let reference = SessionFixtures.track(.bass, [SessionFixtures.note(0.5, 2.5, 48)])
        var frames: [PitchFrame] = []
        var t = 0.512
        while t < 2.5 {
            let swing = 20.0 * sin(2.0 * Double.pi * 5.5 * (t - 0.512))
            frames.append(SessionFixtures.frame(t: t, cents: 4800 + 40 + swing))
            t += 0.016
        }
        let result = try SessionFixtures.grade(reference: reference, live: frames)
        let note = try XCTUnwrap(result.perNote?.first)
        XCTAssertEqual(note.centsDeviation ?? 99, 40, accuracy: 2.0)
        XCTAssertEqual(note.hit, true)
    }
}
