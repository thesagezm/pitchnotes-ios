// RibbonMappingTests (J-101 AC: "cents→UI mapping unit tests") — every row of
// the UX §3.4 state table, the §3.5 octave toggle, the §3.6 C-6.1 presets, and
// the NoteTrackQuery lookups the ribbon consumes. The SwiftUI layer renders
// `RibbonReading` only; these tests are the mapping's contract.

import XCTest
import PitchLogic
import EngineCore

final class RibbonMappingTests: XCTestCase {

    // MARK: - Helpers

    /// Equal-tempered center frequency of a MIDI note, detuned by cents.
    private func hz(_ midi: Int, cents: Double = 0) -> Double {
        PitchMath.hz(forMidi: midi) * pow(2.0, cents / 1200.0)
    }

    private func reading(hz: Double, confidence: Double = 0.9,
                         reference: RibbonReference? = nil,
                         tolerance: RibbonTolerance = .wide,
                         octave: Bool = false) -> RibbonReading {
        RibbonMapper.reading(hz: hz, confidence: confidence, reference: reference,
                             tolerance: tolerance.cents, octaveEquivalence: octave)
    }

    // MARK: - §3.4 state table

    func testInTuneAtCenterAndToleranceBoundary() {
        XCTAssertEqual(reading(hz: hz(52)).state, .inTune)                       // exact center
        XCTAssertEqual(reading(hz: hz(52, cents: 12)).state, .inTune)            // +12¢
        XCTAssertEqual(reading(hz: hz(52, cents: 50)).state, .inTune)            // +50 = |dev| ≤ tol (inclusive)
        XCTAssertEqual(reading(hz: hz(52, cents: -50)).state, .inTune)           // −50 inclusive
        // At exactly +50¢ the NEAREST semitone is the upper one (F3), so the
        // standalone-tuner deviation reads −50 from F3 — still in-tune, |dev| = 50.
        let at = reading(hz: hz(52, cents: 50))
        XCTAssertEqual(abs(at.cents), 50, accuracy: 0.001)
        XCTAssertEqual(at.direction, .none)
        XCTAssertNil(at.octaveBadge)
    }

    func testFlatOutOfRangeSingsHigher() {
        let r = reading(hz: hz(52, cents: -51))
        XCTAssertEqual(r.state, .flat)
        XCTAssertEqual(r.direction, .up, "flat → ↑ (sing higher), UX §3.4")
        XCTAssertNil(r.octaveBadge)
    }

    func testSharpOutOfRangeSingsLower() {
        let r = reading(hz: hz(52, cents: 51))
        XCTAssertEqual(r.state, .sharp)
        XCTAssertEqual(r.direction, .down, "sharp → ↓ (sing lower), UX §3.4")
    }

    func testUnvoicedGatesOnHzAndLowConfidence() {
        XCTAssertEqual(reading(hz: 0.0).state, .unvoiced)                        // hz == 0 (C-2.4)
        XCTAssertEqual(reading(hz: hz(52), confidence: 0.49).state, .unvoiced)   // conf < 0.5
        XCTAssertNil(reading(hz: 0.0).nearestMidi)
        XCTAssertEqual(reading(hz: hz(52), confidence: 0.5).state, .inTune, "0.5 is voiced (boundary inclusive)")
    }

    func testLowConfidenceFlagOnVoicedFrames() {
        XCTAssertTrue(reading(hz: hz(52), confidence: 0.6).lowConfidence, "0.5 ≤ conf < 0.75 → low")
        XCTAssertFalse(reading(hz: hz(52), confidence: 0.75).lowConfidence, "0.75 is NOT low (half-open)")
        XCTAssertFalse(reading(hz: hz(52), confidence: 0.9).lowConfidence)
        XCTAssertFalse(reading(hz: 0.0).lowConfidence, "unvoiced carries no low flag")
    }

    // MARK: - Reference mode (expected note)

    func testDeviationMeasuredAgainstReferenceCenterIncludingCentsRef() {
        // Reference = B3 detuned −30¢; singer hits B3 exactly.
        let ref = RibbonReference(midi: 59, centsRef: -30)
        let r = reading(hz: hz(59), reference: ref)
        XCTAssertEqual(r.cents, 30, accuracy: 0.001, "sung +0¢ vs reference −30¢ = +30¢ sharper than reference")
        XCTAssertEqual(r.state, .inTune)
    }

    func testReferenceNilFallsBackToNearestSemitone() {
        let r = reading(hz: hz(69, cents: 20)) // A4 +20¢
        XCTAssertEqual(r.nearestMidi, 69)
        XCTAssertEqual(r.cents, 20, accuracy: 0.01)
        XCTAssertEqual(r.state, .inTune)
    }

    func testNearestSemitoneReadout() {
        XCTAssertEqual(reading(hz: hz(64, cents: 49)).nearestMidi, 64)
        XCTAssertEqual(reading(hz: hz(64, cents: 51)).nearestMidi, 65, "51¢ rounds to the upper semitone")
    }

    // MARK: - §3.5 octave-equivalence toggle

    func testOctaveFoldShowsInTuneWithMandatoryBadge() {
        let ref = RibbonReference(midi: 60)
        let up = reading(hz: hz(60, cents: 1200), reference: ref, octave: true)
        XCTAssertEqual(up.state, .inTune, "folded octave = in-tune color (§3.5)")
        XCTAssertEqual(up.octaveBadge, .up, "8va badge ALWAYS shown — silent folding would lie")
        XCTAssertEqual(up.cents, 1200, accuracy: 0.001, "raw deviation stays visible to the view")
        let down = reading(hz: hz(60, cents: -1200), reference: ref, octave: true)
        XCTAssertEqual(down.state, .inTune)
        XCTAssertEqual(down.octaveBadge, .down, "8vb")
    }

    func testOctaveOffRendersPlainFlatSharp() {
        let ref = RibbonReference(midi: 60)
        let up = reading(hz: hz(60, cents: 1200), reference: ref, octave: false)
        XCTAssertEqual(up.state, .sharp)
        XCTAssertEqual(up.direction, .down)
        XCTAssertNil(up.octaveBadge, "no badge when octave equivalence is OFF")
    }

    func testOctaveBadgeRequiresFoldMatchWithinTolerance() {
        let ref = RibbonReference(midi: 60)
        // 1200 + 30 folds to +30 (within ±50) → badge.
        let near = reading(hz: hz(60, cents: 1230), reference: ref, octave: true)
        XCTAssertEqual(near.octaveBadge, .up)
        XCTAssertEqual(near.state, .inTune)
        // 1200 + 80 folds to +80 (outside ±50) → plain sharp, NO badge.
        let far = reading(hz: hz(60, cents: 1280), reference: ref, octave: true)
        XCTAssertEqual(far.state, .sharp)
        XCTAssertNil(far.octaveBadge)
    }

    func testInTuneWithinSemitoneNeverBadges() {
        let r = reading(hz: hz(60, cents: 10), reference: RibbonReference(midi: 60), octave: true)
        XCTAssertNil(r.octaveBadge, "badge only when folding happened (|dev| > tol)")
    }

    // MARK: - Tolerance presets (±50 / ±25 / ±10)

    func testTolerancePresetsChangeTheBoundary() {
        let hz30 = hz(52, cents: -30)
        XCTAssertEqual(reading(hz: hz30, tolerance: .wide).state, .inTune)
        XCTAssertEqual(reading(hz: hz30, tolerance: .medium).state, .inTune)
        XCTAssertEqual(reading(hz: hz30, tolerance: .narrow).state, .flat, "−30 outside ±10")
        let hz12 = hz(52, cents: -12)
        XCTAssertEqual(reading(hz: hz12, tolerance: .narrow).state, .inTune)
        let hz35 = hz(52, cents: 35)
        XCTAssertEqual(reading(hz: hz35, tolerance: .medium).state, .sharp, "+35 outside ±25")
    }

    func testToleranceLabels() {
        XCTAssertEqual(RibbonTolerance.wide.label, "±50¢")
        XCTAssertEqual(RibbonTolerance.medium.label, "±25¢")
        XCTAssertEqual(RibbonTolerance.narrow.label, "±10¢")
    }

    // MARK: - VoiceOver summaries (UX §7)

    func testSpokenSummaryStates() {
        XCTAssertEqual(reading(hz: 0.0).spokenSummary, "unvoiced")
        XCTAssertEqual(reading(hz: hz(52, cents: 12)).spokenSummary, "E3, in tune")
        XCTAssertEqual(reading(hz: hz(52, cents: -23)).spokenSummary, "E3, 23 cents flat, sing higher")
        XCTAssertEqual(reading(hz: hz(52, cents: 41)).spokenSummary, "E3, 41 cents sharp, sing lower")
        let oct = reading(hz: hz(60, cents: 1200), reference: RibbonReference(midi: 60), octave: true)
        XCTAssertEqual(oct.spokenSummary, "C4, in tune, one octave up")
    }

    // MARK: - PartRangePresets (CONTRACTS v0.1 C-6.1 verbatim)

    func testC61TableVerbatim() {
        // (part, preset, midiLow, midiHigh) — C-6.1 rows, no substitutions.
        let expected: [(Part, String, Int, Int)] = [
            (.bass, "E2–G3", 40, 55),
            (.baritone, "A2–D4", 45, 62),
            (.baritenor, "C3–F4", 48, 65),
            (.t2, "E3–A4", 52, 69),
            (.t1, "G3–E5", 55, 76),
            (.soprano, "C4–G5", 60, 79),
            (.alto, "G3–D5", 55, 74),
        ]
        for (part, name, lo, hi) in expected {
            let range = PartRangePresets.range(for: part)
            XCTAssertNotNil(range, "\(part.rawValue) missing from presets")
            XCTAssertEqual(range?.presetName, name)
            XCTAssertEqual(range?.midiLow, lo)
            XCTAssertEqual(range?.midiHigh, hi)
        }
        XCTAssertEqual(PartRangePresets.all.count, 7)
    }

    func testC61HzValuesMatchContractRounding() {
        // C-6.1 Hz column (rounded to 0.1). BASS 82.4–196.0, BARITONE
        // 110.0–293.7, BARITENOR 130.8–349.2, T2 164.8–440.0, T1 196.0–659.3,
        // SOPRANO 261.6–784.0, ALTO 196.0–587.3.
        XCTAssertEqual(PartRangePresets.bass.hzLow, 82.4, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.bass.hzHigh, 196.0, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.baritone.hzLow, 110.0, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.baritone.hzHigh, 293.7, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.baritenor.hzLow, 130.8, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.baritenor.hzHigh, 349.2, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.t2.hzLow, 164.8, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.t2.hzHigh, 440.0, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.t1.hzLow, 196.0, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.t1.hzHigh, 659.3, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.soprano.hzLow, 261.6, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.soprano.hzHigh, 784.0, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.alto.hzLow, 196.0, accuracy: 0.05)
        XCTAssertEqual(PartRangePresets.alto.hzHigh, 587.3, accuracy: 0.05)
    }

    func testStructuralPartsHaveNoPreset() {
        XCTAssertNil(PartRangePresets.range(for: .vp))
        XCTAssertNil(PartRangePresets.range(for: .lead))
        XCTAssertNil(PartRangePresets.range(for: .instrumental))
    }

    func testPresetDisplayNameAndCenter() {
        XCTAssertEqual(PartRangePresets.bass.displayName, "Bass E2–G3")
        XCTAssertEqual(PartRangePresets.bass.centerCents, 4750, "center of E2(40)…G3(55)")
    }

    // MARK: - NoteTrackQuery

    private func note(_ s: Double, _ e: Double, _ midi: Int) -> Note {
        Note(start_s: s, end_s: e, midi: midi, cents_ref: 0, confidence: 0.9)
    }

    func testCurrentNoteFindsActiveAndGapReturnsNil() {
        let track = NoteTrack(part: .bass, notes: [note(0, 2, 48), note(3, 5, 45)])
        XCTAssertEqual(NoteTrackQuery.currentNote(in: track, at: 1.0)?.midi, 48)
        XCTAssertEqual(NoteTrackQuery.currentNote(in: track, at: 1.999)?.midi, 48, "t < end_s (half-open)")
        XCTAssertEqual(NoteTrackQuery.currentNote(in: track, at: 2.0)?.midi, nil, "gap between notes")
        XCTAssertEqual(NoteTrackQuery.currentNote(in: track, at: 3.5)?.midi, 45)
        XCTAssertEqual(NoteTrackQuery.currentNote(in: track, at: 6.0)?.midi, nil, "past the end")
        XCTAssertEqual(NoteTrackQuery.currentNote(in: track, at: -1)?.midi, nil)
    }

    func testCurrentNoteBinarySearchHandlesManyNotes() {
        let notes = (0..<200).map { note(Double($0), Double($0) + 0.8, 40 + $0 % 20) }
        let track = NoteTrack(part: .bass, notes: notes)
        XCTAssertEqual(NoteTrackQuery.currentNote(in: track, at: 137.5)?.start_s, 137)
        XCTAssertNil(NoteTrackQuery.currentNote(in: track, at: 137.9), "0.8-length notes leave gaps")
    }

    func testWindowQueryIntersectsVisibleBars() {
        let track = NoteTrack(part: .bass, notes: [note(0, 2, 48), note(3, 5, 45), note(6, 8, 41)])
        XCTAssertEqual(NoteTrackQuery.notes(in: track, from: 1, to: 4).count, 2, "note 0 overlaps window start, note 1 overlaps window end")
        XCTAssertEqual(NoteTrackQuery.notes(in: track, from: 2.5, to: 2.9), [])
        XCTAssertEqual(NoteTrackQuery.notes(in: track, from: 7.9, to: 9).count, 1)
    }
}
