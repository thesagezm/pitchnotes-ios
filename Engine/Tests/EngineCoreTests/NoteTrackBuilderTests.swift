import XCTest
@testable import EngineCore

// P-301 · NoteTrackBuilder tests (PAUL lane).
//
// Every cleanup step is asserted INDEPENDENTLY (the pipeline is only as good
// as its weakest step), plus the contract-level properties the app depends on
// (C-2.3 V7–V10) and the honesty rules (no range filter without a preset,
// amplitude mapped and clamped, never rescaled).

final class NoteTrackBuilderTests: XCTestCase {

    // MARK: - Range filter

    func testRangeFilterDropsNotesOutsideThePartPreset() {
        // BASS preset = MIDI 40–55 (C-6.1).
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 1.0, midi: 48, amplitude: 0.9), // in
            TranscribedNote(start_s: 1.0, end_s: 2.0, midi: 72, amplitude: 0.9), // out (too high)
            TranscribedNote(start_s: 2.0, end_s: 3.0, midi: 30, amplitude: 0.9)  // out (too low)
        ]
        let track = NoteTrackBuilder.build(part: .bass, notes: notes)
        XCTAssertEqual(track.notes.map(\.midi), [48])
    }

    func testPartWithoutPresetKeepsEveryNote() {
        // VP has no C-6.1 preset ⇒ no range filter, NEVER a silent drop.
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 1.0, midi: 30, amplitude: 0.9),
            TranscribedNote(start_s: 1.0, end_s: 2.0, midi: 100, amplitude: 0.9)
        ]
        let track = NoteTrackBuilder.build(part: .vp, notes: notes)
        XCTAssertEqual(track.notes.count, 2)
        XCTAssertNil(NoteTrackBuilder.range(for: .vp))
        XCTAssertNotNil(NoteTrackBuilder.range(for: .bass))
    }

    // MARK: - Minimum duration

    func testMinimumDurationDropsBlips() {
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 0.020, midi: 48, amplitude: 0.9), // 20 ms blip
            TranscribedNote(start_s: 1.0, end_s: 1.200, midi: 48, amplitude: 0.9) // 200 ms
        ]
        let track = NoteTrackBuilder.build(part: .bass, notes: notes,
                                           options: NoteCleanupOptions(minimumDurationSeconds: 0.050))
        XCTAssertEqual(track.notes.count, 1)
        XCTAssertEqual(track.notes[0].start_s, 1.0, accuracy: 1e-9)
    }

    // MARK: - Hysteresis / amplitude gate

    func testAmplitudeGateUsesTheOnsetBar() {
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 1.0, midi: 48, amplitude: 0.10), // below onset bar
            TranscribedNote(start_s: 1.0, end_s: 2.0, midi: 48, amplitude: 0.35)  // above onset bar
        ]
        let track = NoteTrackBuilder.build(part: .bass, notes: notes,
                                           options: NoteCleanupOptions(keepAmplitude: 0.30,
                                                                        sustainAmplitude: 0.15))
        XCTAssertEqual(track.notes.count, 1)
        XCTAssertEqual(track.notes[0].confidence, 0.35, accuracy: 1e-9)
    }

    func testSustainBarIsBelowTheOnsetBar() {
        // The gate is hysteretic by construction: onset bar > continuation bar.
        let options = NoteCleanupOptions.default
        XCTAssertGreaterThan(options.keepAmplitude, options.sustainAmplitude)
    }

    // MARK: - Same-pitch merge (D-21.3: 30 ms)

    func testSamePitchNotesWithinGapAreMerged() {
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 0.5, midi: 48, amplitude: 0.8),
            TranscribedNote(start_s: 0.520, end_s: 1.0, midi: 48, amplitude: 0.6) // 20 ms gap
        ]
        let merged = NoteTrackBuilder.mergeSamePitch(notes, gap: 0.030)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(merged[0].end_s, 1.0, accuracy: 1e-9)
        // The merge must NOT manufacture confidence: the amplitude is the mean.
        XCTAssertEqual(merged[0].amplitude, 0.7, accuracy: 1e-6)
    }

    func testSamePitchNotesBeyondGapAreNotMerged() {
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 0.5, midi: 48, amplitude: 0.8),
            TranscribedNote(start_s: 0.600, end_s: 1.0, midi: 48, amplitude: 0.6) // 100 ms gap
        ]
        XCTAssertEqual(NoteTrackBuilder.mergeSamePitch(notes, gap: 0.030).count, 2)
    }

    func testDifferentPitchNotesAreNeverMerged() {
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 0.5, midi: 48, amplitude: 0.8),
            TranscribedNote(start_s: 0.510, end_s: 1.0, midi: 50, amplitude: 0.6)
        ]
        XCTAssertEqual(NoteTrackBuilder.mergeSamePitch(notes, gap: 0.030).count, 2)
    }

    // MARK: - Overlap repair (C-2.3 V8)

    func testOverlappingNotesAreRepairedWithoutOverlap() {
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 2.0, midi: 48, amplitude: 0.8),
            TranscribedNote(start_s: 1.0, end_s: 1.5, midi: 52, amplitude: 0.7)
        ]
        let repaired = NoteTrackBuilder.repairOverlaps(notes)
        XCTAssertEqual(repaired.count, 2)
        // The ONSETS stay exact (what P-306's onset metric measures).
        XCTAssertEqual(repaired[0].start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(repaired[1].start_s, 1.0, accuracy: 1e-9)
        // The earlier note's sustain is truncated at the later onset.
        XCTAssertEqual(repaired[0].end_s, 1.0, accuracy: 1e-9)
        // …and the track never overlaps (V8).
        XCTAssertLessThanOrEqual(repaired[0].end_s, repaired[1].start_s)
    }

    func testInnerNoteSurvivesWithItsExactOnset() {
        // The second note lies entirely inside the first. The policy is
        // "truncate the EARLIER sustain, keep every onset exact", so the inner
        // note survives untouched and the containing note is cut at its onset.
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 3.0, midi: 48, amplitude: 0.8),
            TranscribedNote(start_s: 1.0, end_s: 1.2, midi: 52, amplitude: 0.7)
        ]
        let repaired = NoteTrackBuilder.repairOverlaps(notes)
        XCTAssertEqual(repaired.count, 2)
        XCTAssertEqual(repaired[0].end_s, 1.0, accuracy: 1e-9)
        XCTAssertEqual(repaired[1].start_s, 1.0, accuracy: 1e-9)
        XCTAssertEqual(repaired[1].end_s, 1.2, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(repaired[0].end_s, repaired[1].start_s)
    }

    func testNoteWithZeroDurationAfterTruncationIsDropped() {
        // Two notes with the SAME onset: the earlier one is truncated to zero
        // length, which C-2.3 V7 forbids, so it is dropped.
        let notes = [
            TranscribedNote(start_s: 1.0, end_s: 2.0, midi: 48, amplitude: 0.8),
            TranscribedNote(start_s: 1.0, end_s: 1.5, midi: 52, amplitude: 0.7)
        ]
        let repaired = NoteTrackBuilder.repairOverlaps(notes)
        XCTAssertEqual(repaired.count, 1)
        XCTAssertGreaterThan(repaired[0].duration_s, 0)
    }

    // MARK: - Confidence mapping (honesty)

    func testConfidenceIsTheAmplitudeClampedNotRescaled() {
        XCTAssertEqual(NoteTrackBuilder.confidence(for: TranscribedNote(start_s: 0, end_s: 1, midi: 60, amplitude: 0.42)), 0.42, accuracy: 1e-9)
        XCTAssertEqual(NoteTrackBuilder.confidence(for: TranscribedNote(start_s: 0, end_s: 1, midi: 60, amplitude: 1.7)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(NoteTrackBuilder.confidence(for: TranscribedNote(start_s: 0, end_s: 1, midi: 60, amplitude: -0.2)), 0.0, accuracy: 1e-9)
    }

    // MARK: - Contract properties (C-2.3 V7–V10)

    func testBuiltTrackSatisfiesTheContractValidators() {
        let notes = [
            TranscribedNote(start_s: 0.0, end_s: 0.5, midi: 48, amplitude: 0.9),
            TranscribedNote(start_s: 0.520, end_s: 1.0, midi: 48, amplitude: 0.7),
            TranscribedNote(start_s: 1.0, end_s: 2.0, midi: 55, amplitude: 0.6),
            TranscribedNote(start_s: 1.5, end_s: 2.2, midi: 60, amplitude: 0.8)
        ]
        let track = NoteTrackBuilder.build(part: .bass, notes: notes)
        let result = BundleValidator.validate(noteTrack: track)
        XCTAssertTrue(result.violations.isEmpty, "violations: \(result.violations)")
        XCTAssertEqual(track.part, .bass)
    }

    func testTimeOffsetShiftsNotesIntoSongTime() {
        let notes = [TranscribedNote(start_s: 0.0, end_s: 1.0, midi: 48, amplitude: 0.9)]
        let track = NoteTrackBuilder.build(part: .bass, notes: notes,
                                           options: NoteCleanupOptions(timeOffsetSeconds: 12.5))
        XCTAssertEqual(track.notes[0].start_s, 12.5, accuracy: 1e-9)
        XCTAssertEqual(track.notes[0].end_s, 13.5, accuracy: 1e-9)
    }

    func testEmptyInputProducesAnEmptyTrackNotAFailure() {
        let track = NoteTrackBuilder.build(part: .t1, notes: [])
        XCTAssertTrue(track.notes.isEmpty)
        XCTAssertTrue(BundleValidator.validate(noteTrack: track).violations.isEmpty)
    }
}
