import XCTest
@testable import PitchLogic

// PitchMath tests (J-004). Reference values from equal temperament, A440.

final class PitchMathTests: XCTestCase {

    // MARK: - cents(from:to:) — 1200·log2(f2/f1)

    func testCentsOctaveIs1200() {
        XCTAssertEqual(PitchMath.cents(from: 440, to: 880), 1200, accuracy: 0.001)
        XCTAssertEqual(PitchMath.cents(from: 880, to: 440), -1200, accuracy: 0.001)
    }

    func testCentsUnisonIsZero() {
        XCTAssertEqual(PitchMath.cents(from: 440, to: 440), 0, accuracy: 1e-9)
    }

    func testCentsMajorThirdFromA4ToC5() {
        // A4 (440) → C5 (523.2511) = 3 semitones = 300 cents.
        XCTAssertEqual(PitchMath.cents(from: 440, to: PitchMath.hz(forMidi: 72)), 300, accuracy: 0.001)
    }

    func testCentsTwentyCentResolution() {
        // NanoPitch ribbon resolution sanity (RESEARCH: 20-cent bins).
        let up20 = PitchMath.cents(from: 440, to: 440 * pow(2, 20.0 / 1200.0))
        XCTAssertEqual(up20, 20, accuracy: 0.001)
    }

    // MARK: - hz(forMidi:)

    func testHzA4Is440() {
        XCTAssertEqual(PitchMath.hz(forMidi: 69), 440, accuracy: 1e-9)
    }

    func testHzC4Is261_63() {
        XCTAssertEqual(PitchMath.hz(forMidi: 60), 261.6256, accuracy: 0.001)
    }

    func testHzBassE2Is82_41() {
        // X-001 preset low bound: Bass E2.
        XCTAssertEqual(PitchMath.hz(forMidi: 40), 82.4069, accuracy: 0.001)
    }

    // MARK: - midiNearest(forHz:)

    func testMidiNearestExactA4() {
        XCTAssertEqual(PitchMath.midiNearest(forHz: 440), 69)
    }

    func testMidiNearestSlightlySharpA4() {
        // +20 cents stays within MIDI 69.
        let hz = 440.0 * pow(2, 20.0 / 1200.0)
        XCTAssertEqual(PitchMath.midiNearest(forHz: hz), 69)
    }

    func testMidiNearestFlatA4FoldsToAb4() {
        // −98 cents from A4 → nearest semitone is MIDI 68.
        let hz = 440.0 * pow(2, -98.0 / 1200.0)
        XCTAssertEqual(PitchMath.midiNearest(forHz: hz), 68)
    }

    func testMidiNearestUnvoicedIsNil() {
        XCTAssertNil(PitchMath.midiNearest(forHz: 0))
        XCTAssertNil(PitchMath.midiNearest(forHz: -3.5))
    }

    // MARK: - centsRef (C-2.3 semantics)

    func testCentsRefDetunedPlus12() {
        let hz = PitchMath.hz(forMidi: 60) * pow(2, 12.0 / 1200.0)
        XCTAssertEqual(PitchMath.centsRef(hz: hz, midi: 60), 12, accuracy: 0.001)
    }

    func testCentsRefExactCenterIsZero() {
        XCTAssertEqual(PitchMath.centsRef(hz: PitchMath.hz(forMidi: 48), midi: 48), 0, accuracy: 1e-9)
    }

    // MARK: - Octave folding (C-5 octave-equivalence default ON)

    func testFoldedCentsExactOctaveUpIsZero() {
        XCTAssertEqual(PitchMath.foldedCents(1200), 0, accuracy: 1e-9)
    }

    func testFoldedCentsOctavePlus50() {
        XCTAssertEqual(PitchMath.foldedCents(1250), 50, accuracy: 1e-9)
    }

    func testFoldedCentsOctaveBelowNearlyInTune() {
        XCTAssertEqual(PitchMath.foldedCents(-1180), 20, accuracy: 1e-9)
    }

    func testFoldedCentsSmallDeviationUnchanged() {
        XCTAssertEqual(PitchMath.foldedCents(23), 23, accuracy: 1e-9)
    }

    func testFoldedCentsHalfOctaveBoundary() {
        // ±600 is the fold boundary; rounds half away from zero → −600.
        XCTAssertEqual(PitchMath.foldedCents(600), -600, accuracy: 1e-9)
    }

    func testIsOctaveError() {
        XCTAssertTrue(PitchMath.isOctaveError(1200))
        XCTAssertTrue(PitchMath.isOctaveError(1250))
        XCTAssertTrue(PitchMath.isOctaveError(-1150))
        XCTAssertFalse(PitchMath.isOctaveError(50))     // plain in-tune
        XCTAssertFalse(PitchMath.isOctaveError(100))    // half octave — flat/sharp, not octave
        XCTAssertFalse(PitchMath.isOctaveError(300))
    }

    func testIsOctaveErrorTightTolerance() {
        // ±25¢ preset (UX §3.4).
        XCTAssertTrue(PitchMath.isOctaveError(1220, tolerance: 25))
        XCTAssertFalse(PitchMath.isOctaveError(1230, tolerance: 25))
    }

    // MARK: - note names

    func testNoteNamesSharpsDefault() {
        XCTAssertEqual(PitchMath.noteName(forMidi: 60), "C4")
        XCTAssertEqual(PitchMath.noteName(forMidi: 61), "C♯4")
        XCTAssertEqual(PitchMath.noteName(forMidi: 69), "A4")
        XCTAssertEqual(PitchMath.noteName(forMidi: 40), "E2")   // X-001 Bass low
        XCTAssertEqual(PitchMath.noteName(forMidi: 24), "C1")   // V9 low bound
        XCTAssertEqual(PitchMath.noteName(forMidi: 96), "C7")   // V9 high bound
    }

    func testNoteNamesFlats() {
        XCTAssertEqual(PitchMath.noteName(forMidi: 61, preferFlats: true), "D♭4")
        XCTAssertEqual(PitchMath.noteName(forMidi: 68, preferFlats: true), "A♭4")
    }
}
