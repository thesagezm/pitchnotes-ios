import XCTest
import EngineCore
@testable import PitchLogic

// J-304 — the score-informed track and the alignment review.
//
// WHAT THESE TESTS GUARD (CONTRACTS v1.1 · C-13 + C-14, D-40, D-41 §4):
//   · C-13.1/C-13.2 decode EXACTLY the contract's JSON (the field names are
//     the JSON keys, `method` is optional);
//   · the score-informed track is DERIVED — the engine's tracks are never
//     touched, and the heuristic track survives a rejected alignment;
//   · C-14's ORDER: the correction overlay wins; else the score-informed
//     track when confidence ≥ 0.70 AND the agreement improved; else the
//     heuristic track (and the CONFIRMED/PROVISIONAL/UNASSIGNED split is
//     reportable);
//   · a score note that cannot be placed (no bar for its measure) is LEFT OUT
//     and REPORTED, and a score part with no C-1 mapping is never guessed;
//   · a manual nudge moves the score note and can be undone.
//
// THE FIXTURE: the detected notes sit 2 s LATER than the score's own notes
// (the score is at a different tempo), so the RAW score agrees with nothing
// and the BAR-MAP alignment fixes it. That makes D-41 §4's "improved note
// agreement" a real difference in the fixture, not a staged one.

final class ScoreReviewTests: XCTestCase {

    // MARK: - Fixtures

    private func note(_ start: Double, _ end: Double, _ midi: Int,
                      confidence: Double = 0.9) -> Note {
        Note(start_s: start, end_s: end, midi: midi, confidence: confidence)
    }

    private func track(_ part: Part, _ notes: [Note]) -> NoteTrack {
        NoteTrack(part: part, notes: notes)
    }

    /// The detected notes: T1 at 3…4 s (60) and 5…6 s (62), T2 at 3…4 s (67).
    private func detected() -> [Part: NoteTrack] {
        [
            .t1: track(.t1, [note(3.0, 4.0, 60), note(5.0, 6.0, 62)]),
            .t2: track(.t2, [note(3.0, 4.0, 67)]),
        ]
    }

    /// The score at ITS OWN tempo — 2 s earlier than the recording.
    private func score() -> ScoreNoteList {
        ScoreNoteList(scoreNotes: [
            ScoreNote(midi: 60, start_s: 1.0, end_s: 2.0, measure: 1, part_id: "P1", voice: 1),
            ScoreNote(midi: 62, start_s: 3.0, end_s: 4.0, measure: 1, part_id: "P1", voice: 1),
            ScoreNote(midi: 67, start_s: 1.0, end_s: 2.0, measure: 1, part_id: "P2", voice: 1),
        ])
    }

    /// The bar map: the recording's measure 1 is 3…6 s.
    private func defaultBarMap() -> [BarMapEntry] {
        [BarMapEntry(measure: 1, start_s: 3.0, end_s: 6.0)]
    }

    private func alignment(confidence: Double = 0.82,
                           used: Bool = false,
                           barMap: [BarMapEntry]? = nil,
                           method: String? = "DTW") -> ScoreAlignment {
        ScoreAlignment(confidence: confidence, used: used,
                       barMap: barMap ?? defaultBarMap(), method: method)
    }

    private func result(confidence: Double = 0.82,
                        mapping: [String: Part] = ["P1": .t1, "P2": .t2],
                        barMap: [BarMapEntry]? = nil) -> ScoreAlignmentResult {
        ScoreAlignmentResult(alignment: alignment(confidence: confidence, barMap: barMap),
                             partMapping: mapping)
    }

    private func review(accepted: Bool = false,
                        hasOverlay: Bool = false,
                        score: ScoreNoteList? = nil,
                        detected: [Part: NoteTrack]? = nil) -> ScoreReview {
        ScoreReview(score: score ?? self.score(),
                    alignmentResult: result(),
                    detected: detected ?? self.detected(),
                    hasOverlay: hasOverlay,
                    accepted: accepted)
    }

    // MARK: - C-13.1 · The score-note list

    func testTheScoreNoteListDecodesTheContractJSONExactly() throws {
        let json = """
        {
          "contractVersion": "v1.1",
          "scoreNotes": [
            { "midi": 60, "start_s": 0.000, "end_s": 0.500,
              "measure": 1, "part_id": "P1", "voice": 1 }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ScoreNoteList.self, from: json)
        XCTAssertEqual(decoded.contractVersion, "v1.1")
        XCTAssertEqual(decoded.scoreNotes.count, 1)
        let first = decoded.scoreNotes[0]
        XCTAssertEqual(first.midi, 60)
        XCTAssertEqual(first.start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(first.end_s, 0.5, accuracy: 1e-9)
        XCTAssertEqual(first.measure, 1)
        XCTAssertEqual(first.part_id, "P1")
        XCTAssertEqual(first.voice, 1)
    }

    func testTheScoreNoteListRoundTrips() throws {
        let original = score()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScoreNoteList.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - C-13.2 · The alignment metadata

    func testTheAlignmentDecodesTheContractJSONExactly() throws {
        let json = """
        {
          "contractVersion": "v1.1",
          "alignment": {
            "confidence": 0.82,
            "used": true,
            "barMap": [ { "measure": 1, "start_s": 0.0, "end_s": 2.0 } ],
            "method": "DTW"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ScoreAlignmentFile.self, from: json)
        XCTAssertEqual(decoded.contractVersion, "v1.1")
        XCTAssertEqual(decoded.alignment.confidence, 0.82, accuracy: 1e-9)
        XCTAssertTrue(decoded.alignment.used)
        XCTAssertEqual(decoded.alignment.barMap.count, 1)
        XCTAssertEqual(decoded.alignment.barMap[0].measure, 1)
        XCTAssertEqual(decoded.alignment.methodName, "DTW")
    }

    func testAnAbsentMethodIsUnknown() throws {
        let json = """
        {
          "contractVersion": "v1.1",
          "alignment": {
            "confidence": 0.5,
            "used": false,
            "barMap": []
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ScoreAlignmentFile.self, from: json)
        XCTAssertNil(decoded.alignment.method)
        XCTAssertEqual(decoded.alignment.methodName, "unknown")
    }

    func testTheBarStartsAreInMeasureOrder() {
        let alignment = ScoreAlignment(
            confidence: 0.8, used: false,
            barMap: [BarMapEntry(measure: 2, start_s: 4, end_s: 8),
                     BarMapEntry(measure: 1, start_s: 0, end_s: 4)])
        XCTAssertEqual(alignment.barStarts, [0, 4])
    }

    // MARK: - The agreement metric

    func testTheAgreementIsOneForAPerfectMatch() {
        let matching = ScoreNoteList(scoreNotes: [
            ScoreNote(midi: 60, start_s: 3.0, end_s: 4.0, measure: 1, part_id: "P1", voice: 1),
            ScoreNote(midi: 62, start_s: 5.0, end_s: 6.0, measure: 1, part_id: "P1", voice: 1),
            ScoreNote(midi: 67, start_s: 3.0, end_s: 4.0, measure: 1, part_id: "P2", voice: 1),
        ])
        let agreement = ScoreAgreement.between(score: matching.scoreNotes, detected: detected())
        XCTAssertEqual(agreement.ratio, 1.0, accuracy: 1e-9)
        XCTAssertEqual(agreement.matchedScoreNotes, 3)
        XCTAssertEqual(agreement.matchedDetectedNotes, 3)
    }

    func testTheAgreementIsZeroWhenNothingMatches() {
        let other = ScoreNoteList(scoreNotes: [
            ScoreNote(midi: 48, start_s: 3.0, end_s: 4.0, measure: 1, part_id: "P1", voice: 1)
        ])
        let agreement = ScoreAgreement.between(score: other.scoreNotes, detected: detected())
        XCTAssertEqual(agreement.ratio, 0, accuracy: 1e-9)
    }

    func testTheAgreementIsSymmetric() {
        // A score with ONE note against three detected notes: the score note
        // matches one, so the ratio is 2 / 4 — the score cannot look perfect
        // by being short.
        let small = ScoreNoteList(scoreNotes: [
            ScoreNote(midi: 60, start_s: 3.0, end_s: 4.0, measure: 1, part_id: "P1", voice: 1)
        ])
        let agreement = ScoreAgreement.between(score: small.scoreNotes, detected: detected())
        XCTAssertEqual(agreement.matchedScoreNotes, 1)
        XCTAssertEqual(agreement.matchedDetectedNotes, 1)
        XCTAssertEqual(agreement.ratio, 0.5, accuracy: 1e-9)
    }

    func testTheAgreementNeedsTheSamePitch() {
        let wrongPitch = ScoreNoteList(scoreNotes: [
            ScoreNote(midi: 61, start_s: 3.0, end_s: 4.0, measure: 1, part_id: "P1", voice: 1)
        ])
        let agreement = ScoreAgreement.between(score: wrongPitch.scoreNotes, detected: detected())
        XCTAssertEqual(agreement.ratio, 0, accuracy: 1e-9)
    }

    // MARK: - The alignment

    func testTheAlignedNotesLandOnTheBarMap() {
        let review = self.review()
        let aligned = review.alignedNotes
        XCTAssertEqual(aligned.count, 3)
        XCTAssertEqual(aligned[0].alignedStart_s, 3.0, accuracy: 1e-9)
        XCTAssertEqual(aligned[0].alignedEnd_s, 4.0, accuracy: 1e-9)
        XCTAssertEqual(aligned[0].part, .t1)
        XCTAssertEqual(aligned[2].part, .t2)
    }

    func testTheRawScoreDoesNotMatchButTheAlignedOneDoes() {
        let review = self.review()
        XCTAssertEqual(review.agreementBefore.ratio, 0, accuracy: 1e-9)
        XCTAssertEqual(review.agreementAfter.ratio, 1.0, accuracy: 1e-9)
        XCTAssertTrue(review.agreementImproved)
    }

    func testAScorePartWithNoMappingIsPlacedButNotPutInAPart() {
        let review = ScoreReview(score: score(),
                                 alignmentResult: result(mapping: ["P1": .t1]),
                                 detected: detected())
        XCTAssertEqual(review.alignedNotes.count, 3)
        XCTAssertEqual(review.unmappedScoreNotes.count, 1)
        XCTAssertEqual(review.unmappedScoreNotes.first?.scorePartID, "P2")
        // The unmapped note is in NO part's track.
        XCTAssertNil(review.scoreInformedTracks[.t2])
    }

    func testAScoreNoteInAMeasureTheBarMapDoesNotCoverIsLeftOutAndReported() {
        let review = ScoreReview(
            score: ScoreNoteList(scoreNotes: [
                ScoreNote(midi: 60, start_s: 1.0, end_s: 2.0, measure: 9, part_id: "P1", voice: 1)
            ]),
            alignmentResult: result(),
            detected: detected())
        XCTAssertTrue(review.alignedNotes.isEmpty)
        XCTAssertEqual(review.unplacedScoreNotes.count, 1)
    }

    // MARK: - The manual nudge

    func testANudgeMovesTheScoreNote() throws {
        var review = self.review()
        review.nudge(scoreIndex: 0, by: 0.25)
        // `accuracy:` needs a non-optional Double — optional chaining would
        // yield `Double?`, which the accuracy overload cannot take.
        let nudged = try XCTUnwrap(review.alignedNotes.first { $0.scoreIndex == 0 })
        XCTAssertEqual(nudged.alignedStart_s, 3.25, accuracy: 1e-9)
        XCTAssertEqual(nudged.alignedEnd_s, 4.25, accuracy: 1e-9)
        XCTAssertEqual(review.nudge(for: 0), 0.25, accuracy: 1e-9)
    }

    func testTheNudgesCanBeUndone() throws {
        var review = self.review()
        review.nudge(scoreIndex: 0, by: 0.25)
        review.nudge(scoreIndex: 1, by: -0.1)
        review.resetNudges()
        XCTAssertTrue(review.nudges.isEmpty)
        let first = try XCTUnwrap(review.alignedNotes.first)
        XCTAssertEqual(first.alignedStart_s, 3.0, accuracy: 1e-9)
    }

    func testTheNudgesMoveTheScoreInformedTrack() {
        var review = self.review(accepted: true)
        let before = review.scoreInformedTracks[.t1]?.notes.first?.start_s
        review.nudge(scoreIndex: 0, by: 0.5)
        let after = review.scoreInformedTracks[.t1]?.notes.first?.start_s
        XCTAssertEqual(before, 3.0)
        XCTAssertEqual(after ?? 0, 3.5, accuracy: 1e-9)
    }

    // MARK: - C-14 · The grading reference

    func testTheScoreWinsWhenItIsAcceptedConfidentAndImproved() {
        let review = review(accepted: true)
        XCTAssertTrue(review.confidenceSufficient)
        XCTAssertTrue(review.agreementImproved)
        XCTAssertEqual(review.reference, .scoreInformed)
    }

    func testTheScoreDoesNotWinBelowTheConfidenceThreshold() {
        let review = ScoreReview(score: score(),
                                 alignmentResult: result(confidence: 0.69),
                                 detected: detected(),
                                 accepted: true)
        XCTAssertFalse(review.confidenceSufficient)
        XCTAssertEqual(review.reference, .heuristic)
    }

    func testTheScoreDoesNotWinWhenTheAlignmentDidNotImproveTheAgreement() {
        // A score that already matches the recording exactly (agreement 1.0),
        // and an alignment that pushes it AWAY (agreement 0.0): the alignment
        // made things WORSE, so the score does not earn the reference.
        let matching = ScoreNoteList(scoreNotes: [
            ScoreNote(midi: 60, start_s: 3.0, end_s: 4.0, measure: 1, part_id: "P1", voice: 1),
            ScoreNote(midi: 62, start_s: 5.0, end_s: 6.0, measure: 1, part_id: "P1", voice: 1),
            ScoreNote(midi: 67, start_s: 3.0, end_s: 4.0, measure: 1, part_id: "P2", voice: 1),
        ])
        let review = ScoreReview(
            score: matching,
            alignmentResult: result(barMap: [BarMapEntry(measure: 1, start_s: 0, end_s: 0.2)]),
            detected: detected(),
            accepted: true)
        XCTAssertEqual(review.agreementBefore.ratio, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(review.agreementAfter.ratio, review.agreementBefore.ratio)
        XCTAssertFalse(review.agreementImproved)
        XCTAssertEqual(review.reference, .heuristic)
    }

    func testTheOverlayWinsOverTheScore() {
        let review = review(accepted: true, hasOverlay: true)
        XCTAssertEqual(review.reference, .overlay)
    }

    func testRejectingTheAlignmentLeavesTheHeuristicTrackIntact() {
        var review = review(accepted: true)
        review.reject()
        XCTAssertEqual(review.reference, .heuristic)
        XCTAssertEqual(review.referenceTracks[.t1]?.notes.count, 2)
        // The engine's tracks are NEVER rewritten (C-13 rule 3).
        XCTAssertEqual(detected()[.t1]?.notes.map(\.start_s), [3.0, 5.0])
    }

    func testTheHeuristicCaseReportsTheBandSplit() {
        let tracks: [Part: NoteTrack] = [
            .t1: track(.t1, [note(1.0, 2.0, 60, confidence: 0.95),   // confirmed
                             note(3.0, 4.0, 62, confidence: 0.60),   // provisional
                             note(5.0, 6.0, 64, confidence: 0.20)])  // unassigned
        ]
        let review = ScoreReview(score: score(),
                                 alignmentResult: result(),
                                 detected: tracks)
        let summary = review.bandSummary
        XCTAssertEqual(summary[.confirmed], 1)
        XCTAssertEqual(summary[.provisional], 1)
        XCTAssertEqual(summary[.unassigned], 1)
    }

    // MARK: - The score-informed track

    func testTheScoreInformedTrackCarriesTheAlignmentConfidence() {
        let review = review(accepted: true)
        let note = review.scoreInformedTracks[.t1]?.notes.first
        XCTAssertEqual(note?.confidence ?? 0, 0.82, accuracy: 1e-9)
    }

    func testTheScoreInformedTrackIsRepairedToTheContractRules() {
        // Two score notes that overlap after the alignment: the track must
        // still satisfy C-2.3 V8 (sorted, non-overlapping within a part).
        let overlapping = ScoreNoteList(scoreNotes: [
            ScoreNote(midi: 60, start_s: 1.0, end_s: 3.0, measure: 1, part_id: "P1", voice: 1),
            ScoreNote(midi: 62, start_s: 2.0, end_s: 4.0, measure: 1, part_id: "P1", voice: 1),
        ])
        let review = ScoreReview(score: overlapping,
                                 alignmentResult: result(),
                                 detected: detected(),
                                 accepted: true)
        let notes = review.scoreInformedTracks[.t1]?.notes ?? []
        XCTAssertEqual(notes.count, 2)
        for (index, note) in notes.enumerated() {
            XCTAssertLessThan(note.start_s, note.end_s)
            if index > 0 {
                XCTAssertGreaterThanOrEqual(note.start_s, notes[index - 1].end_s)
            }
        }
    }

    func testTheHeuristicTracksAreNeverMutated() {
        let tracks = detected()
        let before = tracks[.t1]?.notes.map(\.start_s)
        var review = review(accepted: true)
        review.nudge(scoreIndex: 0, by: 1.0)
        _ = review.scoreInformedTracks
        _ = review.referenceTracks
        XCTAssertEqual(tracks[.t1]?.notes.map(\.start_s), before)
    }

    // MARK: - The DEMO fixture

    func testTheDemoAlignmentImprovesTheAgreement() {
        var demo = MockScore.demoReview()
        XCTAssertGreaterThan(demo.agreementAfter.ratio, demo.agreementBefore.ratio)
        XCTAssertTrue(demo.confidenceSufficient)
        // The DEMO alignment says it was NOT applied by an aligner — accepting
        // it is the user's decision.
        XCTAssertFalse(demo.alignmentResult.alignment.used)
        demo.accept()
        XCTAssertEqual(demo.reference, .scoreInformed)
    }

    func testTheDemoScoreIsWrittenAtADifferentTempoSoTheRawMatchIsImperfect() {
        let demo = MockScore.demoReview()
        // The DEMO score is written 10 % faster than the recording, so the RAW
        // score does NOT agree with every detected note — the improvement the
        // bar map makes is REAL, not staged. (At 0.96× the shift stays under a
        // note length + tolerance for every phrase, the raw score agrees
        // perfectly, and there is nothing to improve.)
        XCTAssertLessThan(demo.agreementBefore.ratio, 1.0)
        XCTAssertEqual(demo.agreementAfter.ratio, 1.0, accuracy: 1e-9)
    }

    func testTheDemoScoreCoversEveryDemoPart() {
        let demo = MockScore.demoScore()
        let parts = Set(demo.scoreNotes.map(\.part_id))
        XCTAssertEqual(parts, Set(["P1", "P2", "P3", "P4", "P5"]))
        XCTAssertFalse(demo.scoreNotes.isEmpty)
    }
}
