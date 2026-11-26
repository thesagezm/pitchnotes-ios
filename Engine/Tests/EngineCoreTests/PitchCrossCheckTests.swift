import XCTest
@testable import EngineCore

// P-305 · The SwiftF0 ↔ basic-pitch cross-check.
//
// The metric is REPORTED, never used to filter (C-12 / AGENTS §11), so the
// tests pin the MEANING of every number: which notes match, which do not,
// and what the headline disagreement rate is.

final class PitchCrossCheckTests: XCTestCase {

    // MARK: - Helpers

    /// A contract-shaped pitch frame.
    private func frame(_ t: Double, hz: Double, confidence: Double = 0.9) -> PitchFrame {
        PitchFrame(t: t, hz: hz, confidence: confidence, loudness_db: -20)
    }

    /// A run of frames at one frequency.
    private func run(start: Double, count: Int, hz: Double, confidence: Double = 0.9) -> [PitchFrame] {
        (0..<count).map { frame(start + Double($0) * 0.016, hz: hz, confidence: confidence) }
    }

    // MARK: - The segmenter

    func testSegmentsAPitchChangeIntoTwoNotes() {
        let frames = run(start: 0.0, count: 10, hz: 440.0) + run(start: 0.160, count: 10, hz: 880.0)
        let notes = SwiftF0NoteSegmenter.segment(frames: frames)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].midi, 69)     // A4
        XCTAssertEqual(notes[1].midi, 81)     // A5
        XCTAssertEqual(notes[0].start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(notes[0].end_s, 0.160, accuracy: 1e-9)
        XCTAssertEqual(notes[1].start_s, 0.160, accuracy: 1e-9)
    }

    func testAShortUnvoicedGapDoesNotSplitANote() {
        var frames = run(start: 0.0, count: 5, hz: 440.0)
        frames.append(frame(0.080, hz: 0, confidence: 0.0))
        frames.append(contentsOf: run(start: 0.096, count: 5, hz: 440.0))
        let notes = SwiftF0NoteSegmenter.segment(frames: frames)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(notes[0].end_s, 0.176, accuracy: 1e-9)
    }

    func testALongUnvoicedGapSplitsTheNote() {
        var frames = run(start: 0.0, count: 5, hz: 440.0)
        frames.append(frame(0.080, hz: 0, confidence: 0.0))
        frames.append(contentsOf: run(start: 0.400, count: 5, hz: 440.0))
        let notes = SwiftF0NoteSegmenter.segment(frames: frames)
        XCTAssertEqual(notes.count, 2)
    }

    func testABlinkIsNotANote() {
        let frames = run(start: 0.0, count: 2, hz: 440.0)
        XCTAssertTrue(SwiftF0NoteSegmenter.segment(frames: frames).isEmpty)
    }

    func testUnvoicedFramesNeverProduceANote() {
        let frames = (0..<20).map { frame(Double($0) * 0.016, hz: 0, confidence: 0.0) }
        XCTAssertTrue(SwiftF0NoteSegmenter.segment(frames: frames).isEmpty)
    }

    func testTheCentsDeviationIsMeasured() {
        // A440 + 30 cents — unambiguous, it quantizes to A4.
        let hz = 440.0 * pow(2.0, 30.0 / 1200.0)
        let frames = run(start: 0.0, count: 10, hz: hz)
        let notes = SwiftF0NoteSegmenter.segment(frames: frames)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].midi, 69)
        XCTAssertEqual(notes[0].cents, 30.0, accuracy: 0.1)
    }

    func testAHalfCentTieQuantizesUpwards() {
        // Exactly +50 cents from A4 is a tie: it quantizes to the UPPER note
        // (70) and is therefore measured at −50 cents. The tie-break is
        // stated here so the benchmark can name it.
        let hz = 440.0 * pow(2.0, 50.0 / 1200.0)
        let frames = run(start: 0.0, count: 10, hz: hz)
        let notes = SwiftF0NoteSegmenter.segment(frames: frames)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].midi, 70)
        XCTAssertEqual(notes[0].cents, -50.0, accuracy: 0.1)
    }

    // MARK: - The comparison

    func testIdenticalNoteSetsAgreeCompletely() {
        let reference = [CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48)]
        let hypothesis = [CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48)]
        let report = TranscriptionCrossCheck.compare(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(report.matchedCount, 1)
        XCTAssertEqual(report.agreementF1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.disagreementRate, 0.0, accuracy: 1e-9)
        XCTAssertEqual(report.pitchMismatches, 0)
        XCTAssertEqual(report.medianOnsetDeltaMs ?? 0, 0, accuracy: 1e-9)
    }

    func testAnExtraHypothesisNoteLowersThePrecision() {
        let reference = [CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48)]
        let hypothesis = [
            CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48),
            CrossCheckNote(start_s: 2.0, end_s: 3.0, midi: 52)
        ]
        let report = TranscriptionCrossCheck.compare(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(report.matchedCount, 1)
        XCTAssertEqual(report.unmatchedHypothesis, 1)
        XCTAssertEqual(report.referenceRecall, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.hypothesisPrecision, 0.5, accuracy: 1e-9)
        XCTAssertEqual(report.agreementF1, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testAMissingReferenceNoteLowersTheRecall() {
        let reference = [
            CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48),
            CrossCheckNote(start_s: 1.0, end_s: 2.0, midi: 52)
        ]
        let hypothesis = [CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48)]
        let report = TranscriptionCrossCheck.compare(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(report.unmatchedReference, 1)
        XCTAssertEqual(report.referenceRecall, 0.5, accuracy: 1e-9)
        XCTAssertEqual(report.hypothesisPrecision, 1.0, accuracy: 1e-9)
    }

    func testAnOctaveArtefactIsCountedAsAPitchMismatch() {
        // The same event, an octave apart: the times agree, the pitch does
        // not. That is a PITCH mismatch, not a missing note.
        let reference = [CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48)]
        let hypothesis = [CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 60)]
        let report = TranscriptionCrossCheck.compare(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(report.matchedCount, 0)
        XCTAssertEqual(report.pitchMismatches, 1)
        XCTAssertEqual(report.disagreementRate, 1.0, accuracy: 1e-9)
    }

    func testTheMatchingNeedsEnoughOverlap() {
        let reference = [CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48)]
        // A 20 % overlap is below the 50 % bar ⇒ NOT the same event.
        let hypothesis = [CrossCheckNote(start_s: 0.8, end_s: 1.8, midi: 48)]
        let report = TranscriptionCrossCheck.compare(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(report.matchedCount, 0)
        XCTAssertEqual(report.disagreementRate, 1.0, accuracy: 1e-9)
    }

    func testTheOnsetAndOffsetDeltasAreMeasured() {
        let reference = [CrossCheckNote(start_s: 0.0, end_s: 1.0, midi: 48)]
        let hypothesis = [CrossCheckNote(start_s: 0.020, end_s: 1.040, midi: 48)]
        let report = TranscriptionCrossCheck.compare(reference: reference, hypothesis: hypothesis)
        XCTAssertEqual(report.medianOnsetDeltaMs ?? -1, 20.0, accuracy: 1e-6)
        XCTAssertEqual(report.medianOffsetDeltaMs ?? -1, 40.0, accuracy: 1e-6)
    }

    func testTwoEmptySetsAgree() {
        let report = TranscriptionCrossCheck.compare(reference: [], hypothesis: [])
        XCTAssertEqual(report.agreementF1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.disagreementRate, 0.0, accuracy: 1e-9)
    }

    func testContractNotesMapOntoTheCrossCheckShape() {
        let note = Note(start_s: 0.0, end_s: 1.0, midi: 48, cents_ref: 7, confidence: 0.9)
        let mapped = CrossCheckNote(note)
        XCTAssertEqual(mapped.midi, 48)
        XCTAssertEqual(mapped.cents, 7, accuracy: 1e-9)
    }
}
