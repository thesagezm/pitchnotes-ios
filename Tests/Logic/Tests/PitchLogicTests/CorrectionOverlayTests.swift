import XCTest
import EngineCore
@testable import PitchLogic

// J-302 — the correction overlay: every operation, the merge semantics, the
// corrected-first resolver, the calibration, and the exact JSON shape.
//
// THE INVARIANT EVERY TEST HERE GUARDS (D-41 §4 + AGENTS §7):
//   the engine's raw tracks are NEVER touched; the overlay is additive; and
//   the resolver is the ONE entry point every consumer (grading included)
//   reads, so the corrected track always wins.

final class CorrectionOverlayTests: XCTestCase {

    private func note(_ start: Double, _ end: Double, _ midi: Int,
                      cents: Int = 0, confidence: Double = 0.9) -> Note {
        Note(start_s: start, end_s: end, midi: midi, cents_ref: cents, confidence: confidence)
    }

    private func track(_ part: Part, _ notes: [Note]) -> NoteTrack {
        NoteTrack(part: part, notes: notes)
    }

    /// Two parts, one note each, plus a T2 note that overlaps the T1 one
    /// (the overlap-repair case).
    private func rawTracks() -> [Part: NoteTrack] {
        [
            .t1: track(.t1, [note(0.0, 1.0, 60), note(2.0, 3.0, 62)]),
            .t2: track(.t2, [note(0.5, 1.5, 60)]),
        ]
    }

    // MARK: - The operations

    func testMoveMovesANoteToAnotherPart() {
        let overlay = CorrectionOverlay.empty(bundleID: "song")
        let key = NoteKey(part: .t1, note: note(0.0, 1.0, 60))
        overlay.append(.move(key, toPart: .bass))

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlay: overlay)

        XCTAssertEqual(result.tracks[.t1]?.notes.count, 1)
        XCTAssertEqual(result.tracks[.bass]?.notes.count, 1)
        XCTAssertEqual(result.tracks[.bass]?.notes.first?.midi, 60)
        XCTAssertEqual(result.tracks[.bass]?.notes.first?.start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.appliedOpCount, 1)
        XCTAssertEqual(result.skippedOpCount, 0)
        XCTAssertTrue(result.warnings.isEmpty)
        // The moved note keeps its identity, so the "you corrected this"
        // marker follows it into the new part.
        XCTAssertTrue(result.correctedIdentities.contains(NoteIdentity(note: note(0.0, 1.0, 60))))
        XCTAssertEqual(result.movedFrom[NoteIdentity(note: note(0.0, 1.0, 60))], .t1)
    }

    func testDeleteRemovesTheNote() {
        let overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.delete(NoteKey(part: .t1, note: note(2.0, 3.0, 62))))

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlay: overlay)

        XCTAssertEqual(result.tracks[.t1]?.notes.count, 1)
        XCTAssertEqual(result.tracks[.t1]?.notes.first?.midi, 60)
        XCTAssertEqual(result.appliedOpCount, 1)
    }

    func testSplitMakesTwoNotesAtTheSplitPoint() {
        let overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.split(NoteKey(part: .t1, note: note(0.0, 1.0, 60)), at_ms: 500))

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlay: overlay)

        let notes = result.tracks[.t1]?.notes ?? []
        XCTAssertEqual(notes.count, 3)   // two halves + the untouched second note
        let halves = notes.filter { $0.midi == 60 }
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(halves[0].start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(halves[0].end_s, 0.5, accuracy: 1e-9)
        XCTAssertEqual(halves[1].start_s, 0.5, accuracy: 1e-9)
        XCTAssertEqual(halves[1].end_s, 1.0, accuracy: 1e-9)
        // Both halves carry the original pitch detail.
        XCTAssertEqual(halves[0].cents_ref, 0)
        XCTAssertEqual(halves[1].confidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(result.appliedOpCount, 1)
    }

    // MARK: - Merge semantics (the order of the operations matters)

    func testOperationsApplyInOrderSoAMoveThenDeleteWorks() {
        let overlay = CorrectionOverlay.empty(bundleID: "song")
        let key = NoteKey(part: .t1, note: note(0.0, 1.0, 60))
        overlay.append(.move(key, toPart: .bass))
        // The same note, now in BASS: the delete must find it there.
        overlay.append(.delete(NoteKey(part: .bass, note: note(0.0, 1.0, 60))))

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlay: overlay)

        XCTAssertEqual(result.tracks[.bass]?.notes.count, 0)
        XCTAssertEqual(result.appliedOpCount, 2)
        XCTAssertEqual(result.skippedOpCount, 0)
    }

    func testACorrectionWhoseNoteIsGoneIsSkippedAndReported() {
        let overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.delete(NoteKey(part: .t1, note: note(9.0, 9.5, 70))))

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlay: overlay)

        XCTAssertEqual(result.appliedOpCount, 0)
        XCTAssertEqual(result.skippedOpCount, 1)
        XCTAssertFalse(result.warnings.isEmpty, "a skipped correction must be reported, never silent")
    }

    func testASplitOutsideTheNoteIsSkippedAndReported() {
        let overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.split(NoteKey(part: .t1, note: note(0.0, 1.0, 60)), at_ms: 5_000))

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlay: overlay)

        XCTAssertEqual(result.appliedOpCount, 0)
        XCTAssertEqual(result.skippedOpCount, 1)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testAMoveThatOverlapsAnExistingNoteIsRepairedAndReported() {
        // Moving T1's 0.0–1.0 note on top of T2's 0.5–1.5 note overlaps.
        let overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.move(NoteKey(part: .t1, note: note(0.0, 1.0, 60)), toPart: .t2))

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlay: overlay)

        // V8: the track stays sorted and non-overlapping.
        let notes = result.tracks[.t2]?.notes ?? []
        XCTAssertEqual(notes.count, 2)
        for pair in zip(notes, notes.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.end_s, pair.1.start_s)
        }
        XCTAssertFalse(result.warnings.isEmpty, "the repair must be reported")
    }

    // MARK: - The corrected-first contract

    func testTheRawTracksAreNeverMutated() {
        let raw = rawTracks()
        let before = raw
        let overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.move(NoteKey(part: .t1, note: note(0.0, 1.0, 60)), toPart: .bass))
        overlay.append(.delete(NoteKey(part: .t1, note: note(2.0, 3.0, 62))))

        _ = CorrectionResolver.resolve(raw: raw, overlay: overlay)

        XCTAssertEqual(raw, before, "the resolver must not touch the engine's tracks")
    }

    func testAnEmptyOverlayReturnsTheRawTracksUnchanged() {
        let raw = rawTracks()
        let result = CorrectionResolver.resolve(raw: raw, overlay: .empty(bundleID: "song"))

        XCTAssertEqual(result.tracks[.t1], raw[.t1])
        XCTAssertEqual(result.tracks[.t2], raw[.t2])
        XCTAssertFalse(result.hasCorrections)
        XCTAssertEqual(result.appliedOpCount, 0)
    }

    func testClearingTheOverlayRestoresTheEngineOutputExactly() {
        let raw = rawTracks()
        var overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.move(NoteKey(part: .t1, note: note(0.0, 1.0, 60)), toPart: .bass))
        overlay.append(.delete(NoteKey(part: .t1, note: note(2.0, 3.0, 62))))

        let corrected = CorrectionResolver.resolve(raw: raw, overlay: overlay)
        XCTAssertNotEqual(corrected.tracks[.t1], raw[.t1])

        overlay.resetAll()
        let restored = CorrectionResolver.resolve(raw: raw, overlay: overlay)

        XCTAssertEqual(restored.tracks[.t1], raw[.t1])
        XCTAssertEqual(restored.tracks[.t2], raw[.t2])
        XCTAssertTrue(restored.tracks[.bass] == nil, "the moved note is back where the engine put it")
    }

    func testUndoLastRemovesExactlyTheLastCorrection() {
        var overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.move(NoteKey(part: .t1, note: note(0.0, 1.0, 60)), toPart: .bass))
        overlay.append(.delete(NoteKey(part: .t1, note: note(2.0, 3.0, 62))))

        overlay.undoLast()

        XCTAssertEqual(overlay.ops.count, 1)
        let result = CorrectionResolver.resolve(raw: rawTracks(), overlay: overlay)
        XCTAssertEqual(result.tracks[.t1]?.notes.count, 1)   // the delete is undone
        XCTAssertEqual(result.tracks[.bass]?.notes.count, 1)   // the move still stands
    }

    // MARK: - The overlay's own editing

    func testRenamingAPartIsPerSongAndClearedByAnEmptyName() {
        var overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.rename(part: .t1, to: "Tenor One")

        XCTAssertEqual(overlay.displayName(for: .t1), "Tenor One")
        XCTAssertEqual(overlay.displayName(for: .t2), Part(.t2).displayName)

        overlay.rename(part: .t1, to: "   ")
        XCTAssertEqual(overlay.displayName(for: .t1), Part(.t1).displayName)
    }

    func testTheOverlayCarriesItsBundleID() {
        let overlay = CorrectionOverlay.empty(bundleID: "01JABC")
        XCTAssertEqual(overlay.bundleID, "01JABC")
        XCTAssertTrue(overlay.isEmpty)
        XCTAssertEqual(overlay.correctionCount, 0)
    }

    // MARK: - The JSON shape (the exact schema proposed to Leto)

    func testTheCorrectionJSONShapeIsExactlyTheProposedOne() throws {
        let key = NoteKey(part: .t1, note: note(12.0, 12.5, 60))
        var overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.move(key, toPart: .t2))
        overlay.append(.delete(NoteKey(part: .t2, note: note(30.0, 30.5, 62))))
        overlay.append(.split(NoteKey(part: .bass, note: note(40.0, 41.0, 43)), at_ms: 40_500))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(overlay)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // The flat, hand-writable operation shape.
        XCTAssertTrue(json.contains("{\"end_ms\":12500,\"midi\":60,\"op\":\"move\",\"part\":\"T1\",\"start_ms\":12000,\"toPart\":\"T2\"}"), json)
        XCTAssertTrue(json.contains("{\"end_ms\":30500,\"midi\":62,\"op\":\"delete\",\"part\":\"T2\",\"start_ms\":30000}"), json)
        XCTAssertTrue(json.contains("{\"at_ms\":40500,\"end_ms\":41000,\"midi\":43,\"op\":\"split\",\"part\":\"BASS\",\"start_ms\":40000}"), json)
    }

    func testTheCorrectionJSONRoundTrips() throws {
        var overlay = CorrectionOverlay.empty(bundleID: "song")
        overlay.append(.move(NoteKey(part: .t1, note: note(12.0, 12.5, 60)), toPart: .t2))
        overlay.append(.split(NoteKey(part: .bass, note: note(40.0, 41.0, 43)), at_ms: 40_500))

        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(CorrectionOverlay.self, from: data)

        XCTAssertEqual(decoded.ops, overlay.ops)
        XCTAssertEqual(decoded.bundleID, "song")
    }

    func testAnUnknownOperationIsRefusedRatherThanMisread() {
        // Every OTHER field is valid, so the decode can only fail on the
        // unknown operation — the overlay is never half-read.
        let json = """
        {"version":1,"bundleID":"song","updatedAt":0,"partRenames":{},"rangeOverrides":{},
         "ops":[{"op":"teleport","part":"T1","start_ms":0,"end_ms":100,"midi":60}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CorrectionOverlay.self, from: Data(json.utf8)))
    }

    // MARK: - Calibration (C-6.1 presets + a per-song custom range)

    func testTheDefaultRangeIsTheC61Preset() {
        let range = PartCalibration.effectiveRange(for: .bass, override: nil)
        XCTAssertEqual(range?.midiLow, 40)
        XCTAssertEqual(range?.midiHigh, 55)
        XCTAssertEqual(range?.presetName, "E2–G3")
        XCTAssertEqual(range?.isCustom, false)
    }

    func testThePresetCanBeNudgedWithinTheContractLimit() {
        let range = PartCalibration.effectiveRange(
            for: .t1, override: .preset(for: .t1, nudgeSemitones: 2))
        XCTAssertEqual(range?.midiLow, 57)
        XCTAssertEqual(range?.midiHigh, 78)
        XCTAssertEqual(range?.nudgeSemitones, 2)
        XCTAssertFalse(range?.isCustom ?? true)
    }

    func testANudgeBeyondTheContractLimitIsClamped() {
        let range = PartCalibration.effectiveRange(
            for: .t1, override: .preset(for: .t1, nudgeSemitones: 9))
        XCTAssertEqual(range?.nudgeSemitones, 2, "C-6.1 clamps the nudge to ±2")
    }

    func testACustomRangeReplacesThePresetForThisSong() {
        let range = PartCalibration.effectiveRange(
            for: .bass, override: .custom(midiLow: 43, midiHigh: 60))
        XCTAssertEqual(range?.midiLow, 43)
        XCTAssertEqual(range?.midiHigh, 60)
        XCTAssertEqual(range?.isCustom, true)
        XCTAssertEqual(range?.presetName, nil)
        // The Hz bounds follow the MIDI bounds (A440 equal temperament).
        XCTAssertEqual(range?.fmin ?? 0, EngineContract.hzForMidi(43), accuracy: 1e-9)
        XCTAssertEqual(range?.fmax ?? 0, EngineContract.hzForMidi(60), accuracy: 1e-9)
    }

    func testACustomRangeIsClampedIntoTheContractMidiRange() {
        let override = PartRangeOverride.custom(midiLow: 5, midiHigh: 200)
        XCTAssertEqual(override.midiLow, 24)
        XCTAssertEqual(override.midiHigh, 96)
    }

    func testACustomRangeKeepsItsBoundsOrdered() {
        let override = PartRangeOverride.custom(midiLow: 60, midiHigh: 40)
        XCTAssertLessThan(override.midiLow, override.midiHigh)
    }

    func testAPartWithoutAPresetHasNoRange() {
        XCTAssertNil(PartCalibration.effectiveRange(for: .instrumental, override: nil))
        XCTAssertNil(PartCalibration.effectiveRange(for: .vocals, override: nil))
    }

    func testNotesOutsideTheRangeAreCountedNotRejected() {
        let tracks: [Part: NoteTrack] = [
            .bass: track(.bass, [note(0.0, 1.0, 40), note(1.0, 2.0, 72)]),
        ]
        let ranges = PartCalibration.effectiveRanges(
            overlay: .empty(bundleID: "song"), parts: [.bass])

        let outside = PartCalibration.notesOutsideRange(in: tracks, ranges: ranges)

        XCTAssertEqual(outside[.bass], 1)
        // The notes are still there — a range is a filter, not a gate (D-12).
        XCTAssertEqual(tracks[.bass]?.notes.count, 2)
    }

    // MARK: - The shared V8 repair

    func testTheRepairSortsAndTrimsOverlaps() {
        let outcome = NoteTrackRepair.repair([
            note(1.0, 2.0, 60),
            note(0.0, 1.5, 62),
        ])
        XCTAssertEqual(outcome.notes.count, 2)
        XCTAssertEqual(outcome.notes[0].start_s, 0.0, accuracy: 1e-9)
        XCTAssertEqual(outcome.notes[0].end_s, 1.0, accuracy: 1e-9)
        XCTAssertEqual(outcome.trimmedCount, 1)
        XCTAssertEqual(outcome.droppedCount, 0)
    }

    func testTheRepairDropsANoteThatStartsAtTheSameInstant() {
        let outcome = NoteTrackRepair.repair([
            note(0.0, 1.0, 60),
            note(0.0, 1.0, 62),
        ])
        XCTAssertEqual(outcome.notes.count, 1)
        XCTAssertEqual(outcome.droppedCount, 1)
    }
}
