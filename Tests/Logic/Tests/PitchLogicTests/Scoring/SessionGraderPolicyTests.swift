import XCTest
import EngineCore
@testable import PitchLogic

// J-401 · the D-54 grading policy (confidence REPORTED, never a weight;
// UNASSIGNED excluded VISIBLY; unison per-part, no math change; steady vs
// transition reported separately) + the C-11 overlay as the grading truth.
final class SessionGraderPolicyTests: XCTestCase {

    // MARK: low_confidence_unison — the D-54 policy scenario

    func testUnassignedNoteIsExcludedVisibly() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("low_confidence_unison"))
        let note = try XCTUnwrap(result.perNote?[2])
        XCTAssertEqual(note.confidenceBand, .unassigned)
        XCTAssertEqual(note.notAssessable, true)
        XCTAssertEqual(note.notAssessableReason, "unassigned")
        XCTAssertEqual(note.hit, nil) // contributed NO score
        XCTAssertEqual(note.centsDeviation, nil)
        let summary = try XCTUnwrap(result.notAssessable)
        XCTAssertEqual(summary.byReason.unassigned, 1)
        XCTAssertEqual(summary.byReason.noLiveFrames, 0)
        XCTAssertEqual(summary.total, 1)
    }

    func testProvisionalNoteIsGradedAtFullWeight() throws {
        // D-54 §2: confidence is an UNCALIBRATED posterior — the band is
        // REPORTED, never a weight. The same frames against the same note at
        // 0.60 (PROVISIONAL) and 0.90 (CONFIRMED) must score IDENTICALLY.
        // (The fixture carries an explicit `assignmentBand`, and C-10/V18
        // make an explicit band authoritative — so the flip moves BOTH the
        // confidence and the band, keeping V18 coherence.)
        let fixture = try SessionFixtures.load("low_confidence_unison")
        let provisional = try SessionFixtures.grade(fixture)

        var confirmedRaw = fixture.reference
        confirmedRaw.notes[1].confidence = 0.90 // 0.60 → 0.90: band flips only
        confirmedRaw.notes[1].assignmentBand = AssignmentBand.confirmed.rawValue
        let confirmed = try SessionFixtures.grade(reference: confirmedRaw,
                                                  live: fixture.live,
                                                  environment: fixture.environment)

        XCTAssertEqual(provisional.perNote?[1].confidenceBand, .provisional)
        XCTAssertEqual(confirmed.perNote?[1].confidenceBand, .confirmed)
        XCTAssertEqual(provisional.perNote?[1].hit, confirmed.perNote?[1].hit)
        XCTAssertEqual(provisional.perNote?[1].centsDeviation, confirmed.perNote?[1].centsDeviation)
        XCTAssertEqual(provisional.accuracy?.overall, confirmed.accuracy?.overall)
        XCTAssertEqual(provisional.grade, confirmed.grade)
    }

    func testUnisonIsReportedAndChangesNoMath() throws {
        // D-54 §3: grading stays PER-PART; the unison flag is reportable and
        // changes NO math in v1.2 — the same session without the flag grades
        // identically.
        let fixture = try SessionFixtures.load("low_confidence_unison")
        let withUnison = try SessionFixtures.grade(fixture)

        var strippedRaw = fixture.reference
        strippedRaw.notes[3].unison = nil
        let stripped = try SessionFixtures.grade(reference: strippedRaw,
                                                 live: fixture.live,
                                                 environment: fixture.environment)

        XCTAssertEqual(withUnison.perNote?[3].unison, true)
        XCTAssertEqual(stripped.perNote?[3].unison, false)
        XCTAssertEqual(withUnison.accuracy?.overall, stripped.accuracy?.overall)
        XCTAssertEqual(withUnison.perNote?[3].hit, stripped.perNote?[3].hit)
    }

    func testBandsAreReportedOnEveryGradedNote() throws {
        let result = try SessionFixtures.grade(try SessionFixtures.load("low_confidence_unison"))
        let perNote = try XCTUnwrap(result.perNote)
        XCTAssertEqual(perNote[0].confidenceBand, .confirmed)
        XCTAssertEqual(perNote[1].confidenceBand, .provisional)
        XCTAssertEqual(perNote[2].confidenceBand, .unassigned)
        XCTAssertEqual(perNote[3].confidenceBand, .confirmed)
    }

    func testAbsenceDerivesTheBandFromConfidence() throws {
        // V16's rule: a note WITHOUT an explicit `assignmentBand` derives it
        // from the confidence at the same thresholds.
        let reference = SessionFixtures.track(.bass, [
            SessionFixtures.note(0.5, 1.5, 48, confidence: 0.85), // ≥ 0.80 → CONFIRMED
            SessionFixtures.note(1.6, 2.6, 50, confidence: 0.55), // 0.50–0.80 → PROVISIONAL
        ])
        let live = SessionFixtures.stream(notes: [(0.5, 1.5, 4800), (1.6, 2.6, 5000)])
        let result = try SessionFixtures.grade(reference: reference, live: live)
        XCTAssertEqual(result.perNote?[0].confidenceBand, .confirmed)
        XCTAssertEqual(result.perNote?[1].confidenceBand, .provisional)
    }

    // MARK: steady vs transition (D-54 §4, the 50 ms note-boundary window)

    func testTheFixturePinsTheClassComputation() throws {
        let fixture = try SessionFixtures.load("steady_vs_transition")
        let result = try SessionFixtures.grade(fixture) // empty live: classes still computed
        let perNote = try XCTUnwrap(result.perNote)
        // expectedClasses mirrors D-54 §4 exactly: first note steady, the
        // 30 ms-gap note TRANSITION, the 470 ms-gap note steady.
        XCTAssertEqual(fixture.expectedClasses, ["steady", "transition", "steady"])
        XCTAssertEqual(perNote.map(\.transitional), [false, true, false])
    }

    func testAccuracySplitsSteadyAndTransitionAndReportsBoth() {
        // A legato pair (30 ms gap): the second note is sung +30c (inside the
        // ±50 tolerance, so a hit with a docked pitch component), the first is
        // perfect — steady stays high, transition drops, and BOTH numbers are
        // reported (the lower one is the honest one).
        let reference = SessionFixtures.track(.bass, [
            SessionFixtures.note(0.5, 1.5, 48),
            SessionFixtures.note(1.53, 2.53, 50),
        ])
        let live = SessionFixtures.stream(notes: [(0.5, 1.5, 4800), (1.53, 2.53, 5030)])
        let result = try? SessionFixtures.grade(reference: reference, live: live)
        let accuracy = result?.accuracy
        XCTAssertEqual(accuracy?.steady ?? 0, 1.0, accuracy: 0.005)
        // transition = 0.5·(1−30/50) + 0.3·1 + 0.2·1 = 0.7 — docked, reported.
        XCTAssertEqual(accuracy?.transition ?? 0, 0.7, accuracy: 0.05)
        XCTAssertLessThan(accuracy?.transition ?? 1, accuracy?.steady ?? 1)
        XCTAssertLessThan(accuracy?.overall ?? 1, accuracy?.steady ?? 1)
        XCTAssertEqual(result?.perNote?[1].transitional, true)
    }

    func testTransitionIsNullWhenNoLegatoBoundaryExists() throws {
        // D-54 §4: "where no consecutive-note boundary exists in a part, that
        // part has no transition class and the split says so" — null, not 0.
        let result = try SessionFixtures.grade(try SessionFixtures.load("steady_sung"))
        let accuracy = try XCTUnwrap(result.accuracy)
        XCTAssertNotNil(accuracy.steady)
        XCTAssertEqual(accuracy.transition, nil)
    }

    func testFullyExcludedSessionSaysSoInsteadOfGrading() throws {
        // A session whose every note is not-assessable has NO grade — a grade
        // from an empty set would be a lie (D-54 §1).
        let reference = SessionFixtures.track(.bass, [
            SessionFixtures.note(0.5, 1.5, 48, confidence: 0.3), // UNASSIGNED
            SessionFixtures.note(1.6, 2.6, 50, confidence: 0.3), // UNASSIGNED
        ])
        let live = SessionFixtures.stream(notes: [(0.5, 1.5, 4800), (1.6, 2.6, 5000)])
        let result = try SessionFixtures.grade(reference: reference, live: live)
        XCTAssertEqual(result.grade, nil)
        XCTAssertEqual(result.accuracy?.overall, nil)
        XCTAssertEqual(result.perPhrase?.count, 0)
        XCTAssertEqual(result.notAssessable?.total, 2)
    }

    // MARK: The C-11 overlay IS the grading truth (C-14 case 1)

    func testCorrectionOverlayFixtureEndToEnd() throws {
        let fixture = try SessionFixtures.load("correction_overlay")
        let overlay = try XCTUnwrap(fixture.correctionOverlay)
        let effective = CorrectionResolver.resolve(raw: [.bass: fixture.reference],
                                                   overlays: [.bass: overlay])
        let composed = try XCTUnwrap(effective.tracks[.bass])

        // The fixture's ops: reassign note 1 to BARITONE, delete note 3,
        // split note 0 at 1.0 s — so BASS's composed reference is the two
        // halves of note 0 + note 2, and NOTHING grades the deleted note 3.
        XCTAssertEqual(composed.notes.count, 3)
        let result = try SessionGrader.grade(
            reference: composed,
            live: fixture.live,
            config: .default,
            environment: fixture.environment,
            gradingReference: GradingReferenceInfo(.overlay),
            sessionId: "overlay-session", bundleId: "fixture-bundle",
            createdAt: "2026-11-27T12:00:00Z")

        XCTAssertEqual(result.gradingReference?.source, .correctionOverlay)
        let perNote = try XCTUnwrap(result.perNote)
        XCTAssertEqual(perNote.count, 3)
        for note in perNote {
            XCTAssertEqual(note.hit, true)
            XCTAssertEqual(note.centsDeviation ?? 99, 0, accuracy: 0.01)
        }
        XCTAssertEqual(result.notAssessable?.total, 0)
        XCTAssertNotNil(result.grade)
    }
}
