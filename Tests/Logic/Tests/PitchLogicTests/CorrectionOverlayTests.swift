import XCTest
import EngineCore
@testable import PitchLogic

// J-302 — the correction overlay, rewritten for CONTRACTS v1.1 · C-11
// (RATIFIED — L-301, D-44).
//
// WHAT C-11 CHANGED AND WHY THE TESTS CHANGED WITH IT:
//   · the overlay is ONE FILE PER PART (`corrections/<PART>.json`), not one
//     file per song;
//   · a note is addressed by its INDEX in the engine's ORIGINAL, IMMUTABLE
//     `notes[]` array (`noteIndex`), not by an identity key;
//   · the operations are `reassign` / `delete` / `split` (not `move`), and a
//     split names TWO parts (`toParts`).
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

    /// Four T1 notes (so "note #3" is a real index) + one T2 note that
    /// overlaps the first T1 note (the overlap-repair case).
    private func rawTracks() -> [Part: NoteTrack] {
        [
            .t1: track(.t1, [note(0.0, 1.0, 60),
                             note(1.0, 2.0, 62),
                             note(2.0, 3.0, 64),
                             note(3.0, 4.0, 65)]),
            .t2: track(.t2, [note(0.5, 1.5, 60)]),
        ]
    }

    /// One long note to split, with nothing else in the way (a split into T2
    /// would otherwise overlap T2's own note).
    private func splittableTracks() -> [Part: NoteTrack] {
        [.t1: track(.t1, [note(0.0, 1.0, 60, confidence: 0.9)])]
    }

    // MARK: - The exact C-11 JSON

    func testTheOverlayJSONIsExactlyTheC11Shape() throws {
        let overlay = PartCorrectionOverlay(
            part: .t2,
            engineVersion: PartCorrectionOverlay.writerEngineVersion,
            operations: [
                .reassign(fromPart: .t2, noteIndex: 3, toPart: .t1, midi: 62),
                .delete(fromPart: .t2, noteIndex: 7),
                .split(fromPart: .t2, noteIndex: 9, splitAt_s: 2.5, toParts: [.t1, .t2]),
            ])

        let data = try JSONEncoder().encode(overlay)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The FILE's keys — exactly C-11's four, nothing more.
        XCTAssertEqual(Set(json.keys), ["contractVersion", "part", "engineVersion", "operations"])
        XCTAssertEqual(json["contractVersion"] as? String, "v1.1")
        XCTAssertEqual(json["part"] as? String, "T2")
        XCTAssertEqual(json["engineVersion"] as? String, "corrections-0.1.0")

        let ops = try XCTUnwrap(json["operations"] as? [[String: Any]])
        XCTAssertEqual(ops.count, 3)

        // A reassign carries `toPart` + the OPTIONAL `midi` — and nothing else.
        XCTAssertEqual(Set(ops[0].keys), ["op", "fromPart", "noteIndex", "toPart", "midi"])
        XCTAssertEqual(ops[0]["op"] as? String, "reassign")
        XCTAssertEqual(ops[0]["fromPart"] as? String, "T2")
        XCTAssertEqual(ops[0]["noteIndex"] as? Int, 3)
        XCTAssertEqual(ops[0]["toPart"] as? String, "T1")
        XCTAssertEqual(ops[0]["midi"] as? Int, 62)

        // A delete carries NOTHING else.
        XCTAssertEqual(Set(ops[1].keys), ["op", "fromPart", "noteIndex"])
        XCTAssertEqual(ops[1]["op"] as? String, "delete")
        XCTAssertEqual(ops[1]["fromPart"] as? String, "T2")
        XCTAssertEqual(ops[1]["noteIndex"] as? Int, 7)

        // A split carries `splitAt_s` + `toParts` — and nothing else.
        XCTAssertEqual(Set(ops[2].keys), ["op", "fromPart", "noteIndex", "splitAt_s", "toParts"])
        XCTAssertEqual(ops[2]["op"] as? String, "split")
        XCTAssertEqual(ops[2]["splitAt_s"] as? Double, 2.5)
        let toParts = try XCTUnwrap(ops[2]["toParts"] as? [String])
        XCTAssertEqual(toParts, ["T1", "T2"])
    }

    func testAReassignWithoutAMidiOmitsTheMidiKey() throws {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .reassign(fromPart: .t1, noteIndex: 0, toPart: .t2),
        ])
        let data = try JSONEncoder().encode(overlay)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ops = try XCTUnwrap(json["operations"] as? [[String: Any]])
        XCTAssertEqual(Set(ops[0].keys), ["op", "fromPart", "noteIndex", "toPart"])
    }

    func testTheOverlayJSONRoundTrips() throws {
        let overlay = PartCorrectionOverlay(part: .t2, operations: [
            .reassign(fromPart: .t2, noteIndex: 3, toPart: .t1, midi: 62),
            .delete(fromPart: .t2, noteIndex: 7),
            .split(fromPart: .t2, noteIndex: 9, splitAt_s: 2.5, toParts: [.t1, .t2],
                   confidence: 0.42),
        ])

        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(PartCorrectionOverlay.self, from: data)

        XCTAssertEqual(decoded, overlay)
        XCTAssertEqual(decoded.contractVersion, "v1.1")
        XCTAssertEqual(decoded.part, .t2)
        XCTAssertEqual(decoded.operations.count, 3)
    }

    func testAnUnknownOperationIsRefusedRatherThanMisread() {
        // Every OTHER field is valid, so the decode can only fail on the
        // unknown operation — the overlay is never half-read.
        let json = """
        {"contractVersion":"v1.1","part":"T2","engineVersion":"corrections-0.1.0",
         "operations":[{"op":"teleport","fromPart":"T2","noteIndex":3,"toPart":"T1"}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(PartCorrectionOverlay.self,
                                                      from: Data(json.utf8)))
    }

    func testASplitWithOtherThanTwoPartsIsRefused() {
        let json = """
        {"contractVersion":"v1.1","part":"T2","engineVersion":"corrections-0.1.0",
         "operations":[{"op":"split","fromPart":"T2","noteIndex":9,"splitAt_s":2.5,
                        "toParts":["T1"]}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(PartCorrectionOverlay.self,
                                                      from: Data(json.utf8)))
    }

    func testASplitWithOtherThanTwoPartsCannotEvenBeEncoded() {
        let overlay = PartCorrectionOverlay(part: .t2, operations: [
            .split(fromPart: .t2, noteIndex: 9, splitAt_s: 2.5, toParts: [.t1]),
        ])
        XCTAssertThrowsError(try JSONEncoder().encode(overlay))
    }

    // MARK: - Resolution, by ORIGINAL index

    func testAReassignMovesTheNoteByItsOriginalIndex() {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .reassign(fromPart: .t1, noteIndex: 3, toPart: .t2),
        ])

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlays: [.t1: overlay])

        XCTAssertEqual(result.tracks[.t1]?.notes.count, 3, "the note left T1")
        guard let moved = result.tracks[.t2]?.notes.first(where: { $0.start_s == 3.0 }) else {
            return XCTFail("the note should have moved to T2")
        }
        XCTAssertEqual(moved.midi, 65)
        XCTAssertEqual(moved.end_s, 4.0)
        XCTAssertEqual(result.appliedOpCount, 1)
        XCTAssertEqual(result.skippedOpCount, 0)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testACorrectedNoteKeepsTheEngineConfidence() {
        // C-11 rule 4: a correction does NOT erase the engine's doubt.
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .reassign(fromPart: .t1, noteIndex: 3, toPart: .t2, midi: 70),
        ])

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlays: [.t1: overlay])

        let moved = result.tracks[.t2]?.notes.first { $0.start_s == 3.0 }
        XCTAssertEqual(moved?.midi, 70, "the pitch correction is applied")
        XCTAssertEqual(moved?.confidence ?? 0, 0.9, accuracy: 1e-9,
                       "but the engine's confidence is NOT erased")
    }

    func testTheCorrectedNoteIsMarked() {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .reassign(fromPart: .t1, noteIndex: 3, toPart: .t2),
        ])

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlays: [.t1: overlay])

        guard let moved = result.tracks[.t2]?.notes.first(where: { $0.start_s == 3.0 }) else {
            return XCTFail("the note should have moved to T2")
        }
        let key = NoteKey(part: .t2, note: moved)
        XCTAssertEqual(result.correctedNotes.count, 1)
        XCTAssertTrue(result.correctedNotes.contains(key), "the UI can mark the user's note")
        // The origin map is how the UI turns the note it SHOWS back into the
        // contract's `noteIndex`.
        XCTAssertEqual(result.origin(for: key), NoteOrigin(part: .t1, index: 3))
    }

    func testADeleteRemovesTheNoteFromTheCorrectedTrackOnly() {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .delete(fromPart: .t1, noteIndex: 1),
        ])

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlays: [.t1: overlay])

        XCTAssertEqual(result.tracks[.t1]?.notes.count, 3)
        XCTAssertNil(result.tracks[.t1]?.notes.first { $0.start_s == 1.0 })
        XCTAssertEqual(result.tracks[.t2]?.notes.count, 1, "the other part is untouched")
        XCTAssertEqual(result.appliedOpCount, 1)
    }

    func testASplitCutsTheNoteAndPutsTheHalvesInTheNamedParts() {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .split(fromPart: .t1, noteIndex: 0, splitAt_s: 0.5, toParts: [.t1, .t2]),
        ])

        let result = CorrectionResolver.resolve(raw: splittableTracks(), overlays: [.t1: overlay])

        let first = result.tracks[.t1]?.notes.first
        XCTAssertEqual(first?.start_s ?? 0, 0.0, accuracy: 1e-9)
        XCTAssertEqual(first?.end_s ?? 0, 0.5, accuracy: 1e-9)

        let second = result.tracks[.t2]?.notes.first
        XCTAssertEqual(second?.start_s ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(second?.end_s ?? 0, 1.0, accuracy: 1e-9)

        // Both halves keep the ORIGINAL confidence (C-11).
        XCTAssertEqual(first?.confidence ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(second?.confidence ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(result.appliedOpCount, 1)
        XCTAssertEqual(result.skippedOpCount, 0)
    }

    func testASplitCanOverrideTheConfidence() {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .split(fromPart: .t1, noteIndex: 0, splitAt_s: 0.5, toParts: [.t1, .t2],
                   confidence: 0.42),
        ])

        let result = CorrectionResolver.resolve(raw: splittableTracks(), overlays: [.t1: overlay])

        XCTAssertEqual(result.tracks[.t1]?.notes.first?.confidence ?? 0, 0.42, accuracy: 1e-9)
        XCTAssertEqual(result.tracks[.t2]?.notes.first?.confidence ?? 0, 0.42, accuracy: 1e-9)
    }

    func testASplitNotStrictlyInsideTheNoteIsSkippedAndReported() {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .split(fromPart: .t1, noteIndex: 0, splitAt_s: 5.0, toParts: [.t1, .t2]),
        ])

        let result = CorrectionResolver.resolve(raw: splittableTracks(), overlays: [.t1: overlay])

        XCTAssertEqual(result.appliedOpCount, 0)
        XCTAssertEqual(result.skippedOpCount, 1)
        XCTAssertFalse(result.warnings.isEmpty, "a skipped correction must be reported, never silent")
        XCTAssertEqual(result.tracks[.t1]?.notes.count, 1, "the note is untouched")
    }

    func testASplitExactlyOnTheNoteBoundaryIsSkippedAndReported() {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .split(fromPart: .t1, noteIndex: 0, splitAt_s: 0.0, toParts: [.t1, .t2]),
        ])

        let result = CorrectionResolver.resolve(raw: splittableTracks(), overlays: [.t1: overlay])

        XCTAssertEqual(result.skippedOpCount, 1)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testANoteIndexOutsideTheOriginalArrayIsSkippedAndReported() {
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .delete(fromPart: .t1, noteIndex: 99),
        ])

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlays: [.t1: overlay])

        XCTAssertEqual(result.appliedOpCount, 0)
        XCTAssertEqual(result.skippedOpCount, 1)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    // MARK: - The order of the operations

    func testAReassignThenADeleteOfTheSameOriginalNoteRemovesIt() {
        // Both operations live in the SOURCE part's file (C-11: `fromPart` is
        // the part whose ORIGINAL array holds the note) and they apply in
        // order, even though the delete names the part the note moved to.
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .reassign(fromPart: .t1, noteIndex: 3, toPart: .t2),
            .delete(fromPart: .t1, noteIndex: 3),
        ])

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlays: [.t1: overlay])

        XCTAssertNil(result.tracks[.t2]?.notes.first { $0.start_s == 3.0 },
                     "the note is gone from the part it moved to")
        XCTAssertEqual(result.tracks[.t1]?.notes.count, 3)
        XCTAssertEqual(result.appliedOpCount, 2)
        XCTAssertEqual(result.skippedOpCount, 0)
    }

    func testTheReverseOrderDeletesFirstAndTheReassignIsReported() {
        // The delete comes first, so there is nothing left for the reassign to
        // move: it is SKIPPED and REPORTED, never guessed at, and the note is
        // NOT in the new part.
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .delete(fromPart: .t1, noteIndex: 3),
            .reassign(fromPart: .t1, noteIndex: 3, toPart: .t2),
        ])

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlays: [.t1: overlay])

        XCTAssertNil(result.tracks[.t2]?.notes.first { $0.start_s == 3.0 })
        XCTAssertEqual(result.tracks[.t1]?.notes.count, 3)
        XCTAssertEqual(result.appliedOpCount, 1)
        XCTAssertEqual(result.skippedOpCount, 1)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    // MARK: - The corrected-first contract

    func testTheRawTracksAreNeverMutated() {
        let raw = rawTracks()
        let before = raw
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .reassign(fromPart: .t1, noteIndex: 0, toPart: .bass),
            .delete(fromPart: .t1, noteIndex: 1),
        ])

        _ = CorrectionResolver.resolve(raw: raw, overlays: [.t1: overlay])

        XCTAssertEqual(raw, before, "the resolver must not touch the engine's tracks")
    }

    func testNoOverlayReturnsTheRawTracksUnchanged() {
        let raw = rawTracks()
        let result = CorrectionResolver.resolve(raw: raw, overlays: [:])

        XCTAssertEqual(result.tracks[.t1], raw[.t1])
        XCTAssertEqual(result.tracks[.t2], raw[.t2])
        XCTAssertFalse(result.hasCorrections)
        XCTAssertEqual(result.appliedOpCount, 0)
        XCTAssertEqual(result.skippedOpCount, 0)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testClearingTheOverlayRestoresTheEngineOutputExactly() {
        let raw = rawTracks()
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .reassign(fromPart: .t1, noteIndex: 0, toPart: .bass),
            .delete(fromPart: .t1, noteIndex: 1),
        ])

        let corrected = CorrectionResolver.resolve(raw: raw, overlays: [.t1: overlay])
        XCTAssertNotEqual(corrected.tracks[.t1], raw[.t1])

        let restored = CorrectionResolver.resolve(raw: raw, overlays: [:])

        XCTAssertEqual(restored.tracks[.t1], raw[.t1])
        XCTAssertEqual(restored.tracks[.t2], raw[.t2])
        XCTAssertTrue(restored.tracks[.bass] == nil, "the moved note is back where the engine put it")
    }

    // MARK: - The shared V8 repair

    func testAReassignThatOverlapsAnExistingNoteIsTrimmedAndReported() {
        // Moving T1's 0.0–1.0 note on top of T2's 0.5–1.5 note overlaps.
        let overlay = PartCorrectionOverlay(part: .t1, operations: [
            .reassign(fromPart: .t1, noteIndex: 0, toPart: .t2),
        ])

        let result = CorrectionResolver.resolve(raw: rawTracks(), overlays: [.t1: overlay])

        // V8: the track stays sorted and non-overlapping.
        let notes = result.tracks[.t2]?.notes ?? []
        XCTAssertEqual(notes.count, 2)
        for pair in zip(notes, notes.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.end_s, pair.1.start_s)
        }
        XCTAssertFalse(result.warnings.isEmpty, "the repair must be reported")
    }

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

    // MARK: - Calibration (C-6.1 presets + a per-song custom range)

    func testTheDefaultRangeIsTheC61Preset() {
        let range = PartCalibration.effectiveRange(for: .bass, rangeOverride: nil)
        XCTAssertEqual(range?.midiLow, 40)
        XCTAssertEqual(range?.midiHigh, 55)
        XCTAssertEqual(range?.presetName, "E2–G3")
        XCTAssertEqual(range?.isCustom, false)
    }

    func testThePresetCanBeNudgedWithinTheContractLimit() {
        // The nudge is DEVICE-LOCAL (C-6.1, C-15 rule 2, D-47 §4): it is not
        // part of the song's range override, it is applied on top of it.
        let range = PartCalibration.effectiveRange(
            for: .t1, rangeOverride: .preset(for: .t1), deviceNudge: 2)
        XCTAssertEqual(range?.midiLow, 57)
        XCTAssertEqual(range?.midiHigh, 78)
        XCTAssertEqual(range?.nudgeSemitones, 2)
        XCTAssertFalse(range?.isCustom ?? true)
    }

    func testANudgeBeyondTheContractLimitIsClamped() {
        let range = PartCalibration.effectiveRange(
            for: .t1, rangeOverride: .preset(for: .t1), deviceNudge: 9)
        XCTAssertEqual(range?.nudgeSemitones, 2, "C-6.1 clamps the nudge to ±2")
    }

    func testACustomRangeIsNotMovedByTheDeviceNudge() {
        // A custom range IS the range: C-6.1 applies the nudge to the
        // PRESET "before use", and a custom range replaces the preset.
        let range = PartCalibration.effectiveRange(
            for: .bass, rangeOverride: .custom(for: .bass, midiLow: 43, midiHigh: 60),
            deviceNudge: 2)
        XCTAssertEqual(range?.midiLow, 43)
        XCTAssertEqual(range?.midiHigh, 60)
        XCTAssertEqual(range?.nudgeSemitones, 0)
    }

    func testACustomRangeReplacesThePresetForThisSong() {
        let range = PartCalibration.effectiveRange(
            for: .bass, rangeOverride: .custom(for: .bass, midiLow: 43, midiHigh: 60))
        XCTAssertEqual(range?.midiLow, 43)
        XCTAssertEqual(range?.midiHigh, 60)
        XCTAssertEqual(range?.isCustom, true)
        XCTAssertEqual(range?.presetName, nil)
        // The Hz bounds follow the MIDI bounds (A440 equal temperament).
        XCTAssertEqual(range?.fmin ?? 0, EngineContract.hzForMidi(43), accuracy: 1e-9)
        XCTAssertEqual(range?.fmax ?? 0, EngineContract.hzForMidi(60), accuracy: 1e-9)
    }

    func testACustomRangeIsClampedIntoTheContractMidiRange() {
        let override = PartRangeOverride.custom(for: .bass, midiLow: 5, midiHigh: 200)
        XCTAssertEqual(override.midiLow, 24)
        XCTAssertEqual(override.midiHigh, 96)
    }

    func testACustomRangeKeepsItsBoundsOrdered() {
        let override = PartRangeOverride.custom(for: .bass, midiLow: 60, midiHigh: 40)
        XCTAssertLessThan(override.midiLow, override.midiHigh)
    }

    func testAPartWithoutAPresetHasNoRange() {
        XCTAssertNil(PartCalibration.effectiveRange(for: .instrumental, rangeOverride: nil))
        XCTAssertNil(PartCalibration.effectiveRange(for: .vocals, rangeOverride: nil))
    }

    func testNotesOutsideTheRangeAreCountedNotRejected() {
        let tracks: [Part: NoteTrack] = [
            .bass: track(.bass, [note(0.0, 1.0, 40), note(1.0, 2.0, 72)]),
        ]
        let ranges = PartCalibration.effectiveRanges(calibration: nil, parts: [.bass])

        let outside = PartCalibration.notesOutsideRange(in: tracks, ranges: ranges)

        XCTAssertEqual(outside[.bass], 1)
        // The notes are still there — a range is a filter, not a gate (D-12).
        XCTAssertEqual(tracks[.bass]?.notes.count, 2)
    }

    func testNoCalibrationMeansTheContractPresets() {
        // The absence rule: no `corrections/song.json` ⇒ exactly as before.
        let ranges = PartCalibration.effectiveRanges(calibration: nil, parts: [.t1, .bass])
        XCTAssertEqual(ranges[.t1]?.midiLow, 55)
        XCTAssertEqual(ranges[.t1]?.midiHigh, 76)
        XCTAssertEqual(ranges[.bass]?.midiLow, 40)
    }

    // MARK: - The calibration overlay (C-15 — RULED at D-47)

    func testTheCalibrationCarriesTheRenamesAndTheRanges() {
        var calibration = SongCalibrationOverlay()
        calibration.partRenames[Part.t1.rawValue] = "Tenor One"
        calibration.rangeOverrides[Part.t1.rawValue] = .preset(for: .t1)
        calibration.rangeOverrides[Part.bass.rawValue] = .custom(for: .bass, midiLow: 40,
                                                                 midiHigh: 60)

        XCTAssertEqual(calibration.displayName(for: .t1), "Tenor One")
        XCTAssertEqual(calibration.displayName(for: .t2), Part.t2.displayName)
        XCTAssertEqual(calibration.partNameMap()[.t1], "Tenor One")
        XCTAssertEqual(calibration.rangeOverride(for: .t1)?.mode, .preset)
        XCTAssertEqual(calibration.rangeOverride(for: .bass)?.mode, .custom)
    }

    func testAnEmptyRenameFallsBackToTheContractName() {
        var calibration = SongCalibrationOverlay()
        calibration.partRenames[Part.t1.rawValue] = "   "
        XCTAssertEqual(calibration.displayName(for: .t1), Part.t1.displayName)
    }

    func testTheStoredCalibrationJSONIsExactlyC15sShape() throws {
        var calibration = SongCalibrationOverlay()
        calibration.partRenames[Part.t1.rawValue] = "Tenor One"
        calibration.rangeOverrides[Part.t1.rawValue] = .preset(for: .t1)
        calibration.rangeOverrides[Part.bass.rawValue] = .custom(for: .bass, midiLow: 40,
                                                                 midiHigh: 60)

        let data = try JSONEncoder().encode(calibration)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(json.keys), ["contractVersion", "engineVersion", "partRenames",
                                        "rangeOverrides"])
        XCTAssertEqual(json["contractVersion"] as? String, "v1.1")

        let renames = try XCTUnwrap(json["partRenames"] as? [String: String])
        XCTAssertEqual(renames, ["T1": "Tenor One"])

        let overrides = try XCTUnwrap(json["rangeOverrides"] as? [String: [String: Any]])
        XCTAssertEqual(Set(overrides.keys), ["T1", "BASS"])

        // A preset override: {"preset": "..."} — the LABEL ONLY.
        let t1 = try XCTUnwrap(overrides["T1"])
        XCTAssertEqual(Set(t1.keys), ["preset"])
        XCTAssertEqual(t1["preset"] as? String, PartRangePresets.preset(for: .t1)?.presetName)

        // A custom override: {"custom": {"minMidi": N, "maxMidi": N}}.
        let bass = try XCTUnwrap(overrides["BASS"])
        XCTAssertEqual(Set(bass.keys), ["custom"])
        let custom = try XCTUnwrap(bass["custom"] as? [String: Any])
        XCTAssertEqual(Set(custom.keys), ["minMidi", "maxMidi"])
        XCTAssertEqual(custom["minMidi"] as? Int, 40)
        XCTAssertEqual(custom["maxMidi"] as? Int, 60)
    }

    func testTheWriterNeverWritesTheNudgeIntoTheSongFile() throws {
        // C-15 rule 2 / D-47 §4: the ±2 nudge is DEVICE-LOCAL. The per-song
        // file carries the RANGE only.
        var calibration = SongCalibrationOverlay()
        calibration.rangeOverrides[Part.t1.rawValue] = .preset(for: .t1)

        let data = try JSONEncoder().encode(calibration)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let overrides = try XCTUnwrap(json["rangeOverrides"] as? [String: [String: Any]])
        let t1 = try XCTUnwrap(overrides["T1"])

        XCTAssertNil(t1["nudgeSemitones"],
                     "C-15 rule 2: a writer MUST NOT write nudgeSemitones into corrections/song.json")
    }

    func testAStoredNudgeIsIgnoredAndNeverQuarantinesTheFile() throws {
        // C-15 rule 2 / D-47 §4: a reader that meets `nudgeSemitones` MUST
        // ignore it — never a validation error, never a reason to quarantine
        // the file. (An older build wrote it; the file must still load.)
        let json = """
        {
          "contractVersion": "v1.1",
          "partRenames": { "T1": "Tenor One" },
          "rangeOverrides": {
            "T1": { "preset": "G3–E5", "nudgeSemitones": 2 },
            "BASS": { "custom": { "minMidi": 40, "maxMidi": 60 } }
          }
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SongCalibrationOverlay.self, from: data)

        XCTAssertEqual(decoded.displayName(for: .t1), "Tenor One")
        // The bounds come from C-6.1's row for T1 — the label is display-only.
        XCTAssertEqual(decoded.rangeOverride(for: .t1)?.midiLow, 55)
        XCTAssertEqual(decoded.rangeOverride(for: .t1)?.midiHigh, 76)
        XCTAssertEqual(decoded.rangeOverride(for: .bass)?.midiLow, 40)
    }

    func testAnUnknownPresetLabelIsNotAnErrorAndTheBoundsComeFromTheTable() throws {
        // C-15 rule 2 / D-47 §3: the label is display-only; a stale or
        // unknown label (e.g. "TENOR_1") is NOT a contract violation and
        // MUST NOT reject the file.
        let json = """
        {
          "contractVersion": "v1.1",
          "rangeOverrides": { "T1": { "preset": "TENOR_1" } }
        }
        """
        let decoded = try JSONDecoder().decode(SongCalibrationOverlay.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(decoded.rangeOverride(for: .t1)?.midiLow, 55)
        XCTAssertEqual(decoded.rangeOverride(for: .t1)?.midiHigh, 76)
        XCTAssertEqual(decoded.rangeOverride(for: .t1)?.presetName, "TENOR_1",
                       "the label is kept for display, verbatim")
    }

    func testTheStoredCalibrationJSONRoundTrips() throws {
        var calibration = SongCalibrationOverlay()
        calibration.partRenames[Part.t1.rawValue] = "Tenor One"
        calibration.rangeOverrides[Part.t1.rawValue] = .preset(for: .t1)
        calibration.rangeOverrides[Part.bass.rawValue] = .custom(for: .bass, midiLow: 40,
                                                                 midiHigh: 60)

        let data = try JSONEncoder().encode(calibration)
        let decoded = try JSONDecoder().decode(SongCalibrationOverlay.self, from: data)

        XCTAssertEqual(decoded, calibration)
        XCTAssertEqual(decoded.displayName(for: .t1), "Tenor One")
        XCTAssertEqual(decoded.rangeOverride(for: .t1)?.mode, .preset)
        XCTAssertEqual(decoded.rangeOverride(for: .bass)?.midiLow, 40)
        XCTAssertEqual(decoded.rangeOverride(for: .bass)?.midiHigh, 60)
    }

    // MARK: - The device-local calibration (C-6.1, UX §3.6, C-15 rule 2)

    func testTheDeviceCalibrationStoresAndClampsTheNudge() {
        let suiteName = "DeviceCalibrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calibration = DeviceCalibration()
        calibration.setNudge(2, for: .t1)
        calibration.setNudge(9, for: .bass)
        calibration.setNudge(-9, for: .t2)
        calibration.save(to: defaults)

        let loaded = DeviceCalibration.load(from: defaults)
        XCTAssertEqual(loaded.nudge(for: .t1), 2)
        XCTAssertEqual(loaded.nudge(for: .bass), 2, "C-6.1 clamps the nudge to ±2")
        XCTAssertEqual(loaded.nudge(for: .t2), -2, "C-6.1 clamps the nudge to ±2")
        XCTAssertEqual(loaded.nudge(for: .baritone), 0, "an unset part has no nudge")
    }

    func testTheDeviceCalibrationIsEmptyWhenNothingWasEverSet() {
        let suiteName = "DeviceCalibrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let loaded = DeviceCalibration.load(from: defaults)
        XCTAssertEqual(loaded, DeviceCalibration())
        XCTAssertEqual(loaded.nudge(for: .t1), 0)
    }

    func testTheDeviceNudgeShiftsTheEffectiveRange() {
        var calibration = DeviceCalibration()
        calibration.setNudge(1, for: .t1)

        let ranges = PartCalibration.effectiveRanges(calibration: nil,
                                                     parts: [.t1],
                                                     deviceNudges: calibration.nudges)
        XCTAssertEqual(ranges[.t1]?.midiLow, 56)
        XCTAssertEqual(ranges[.t1]?.midiHigh, 77)
    }
}
