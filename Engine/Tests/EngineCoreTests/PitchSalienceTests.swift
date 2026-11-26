import XCTest
@testable import EngineCore

// P-302 · Multi-f0 salience tests (PAUL lane).
//
// Three groups:
//   1. THE FRAME CLOCK — pinned against the C++ header's OWN numbers
//      (Engine/Transcription/BasicPitchNotes.hpp `frameToSeconds`), because
//      the Swift side and the app's C++ bridge must agree on time exactly.
//   2. THE PEAK PICKER — unit-tested on hand-built salience tables.
//   3. THE TRACKS — the per-pitch runs the assignment (P-303) consumes.

final class PitchSalienceTests: XCTestCase {

    // MARK: - 1. The frame clock (C++ parity)

    /// The expected values are the C++ header's OWN output, printed by
    /// compiling `BasicPitchNotes.hpp` verbatim:
    ///   frameToSeconds(0)   = 0.000000000000
    ///   frameToSeconds(1)   = 0.011609977324
    ///   frameToSeconds(141) = 1.637006802721   (last frame of chunk 0)
    ///   frameToSeconds(142) = 1.640090702948   (first frame of chunk 1)
    ///   frameToSeconds(283) = 3.277097505669
    ///   frameToSeconds(284) = 3.280181405896
    ///   frameToSeconds(500) = 5.779410430839
    ///   frameToSeconds(1000)= 11.550294784580
    func testFrameClockMatchesTheCppHeaderExactly() {
        let expected: [(Int, Double)] = [
            (0, 0.000000000000),
            (1, 0.011609977324),
            (141, 1.637006802721),
            (142, 1.640090702948),
            (143, 1.651700680272),
            (283, 3.277097505669),
            (284, 3.280181405896),
            (500, 5.779410430839),
            (1000, 11.550294784580)
        ]
        for (frame, want) in expected {
            XCTAssertEqual(BasicPitchFrameClock.seconds(forFrame: frame), want,
                           accuracy: 1e-9,
                           "frame \(frame): the Swift clock must equal the C++ header's value")
        }
    }

    func testFrameClockConstantsMatchTheHeader() {
        XCTAssertEqual(BasicPitchFrameClock.sampleRate, 22050)
        XCTAssertEqual(BasicPitchFrameClock.frameHop, 256)
        XCTAssertEqual(BasicPitchFrameClock.chunkSamples, 43844)
        XCTAssertEqual(BasicPitchFrameClock.overlapFrames, 30)
        XCTAssertEqual(BasicPitchFrameClock.chunkHop, 36164)
        XCTAssertEqual(BasicPitchFrameClock.trimmedFramesPerChunk, 142)
    }

    func testFrameClockIsMonotonic() {
        var previous = -1.0
        for frame in 0..<2000 {
            let now = BasicPitchFrameClock.seconds(forFrame: frame)
            XCTAssertGreaterThan(now, previous)
            previous = now
        }
    }

    func testFrameForSecondsRoundTripsToTheNearestFrame() {
        for frame in [0, 1, 50, 141, 142, 283, 500, 1000] {
            let seconds = BasicPitchFrameClock.seconds(forFrame: frame)
            XCTAssertEqual(BasicPitchFrameClock.frame(forSeconds: seconds), frame,
                           "frame \(frame) must map back to itself")
        }
    }

    // MARK: - 2. The peak picker

    /// A table with `binCount` bins per frame, built from a per-frame
    /// dictionary of MIDI → salience.
    private func table(_ rows: [[Int: Double]]) -> PitchSalienceTable {
        var frames: [[Double]] = []
        for row in rows {
            var bins = [Double](repeating: 0, count: PitchSalienceTable.binCount)
            for (midi, value) in row {
                bins[midi - PitchSalienceTable.lowestMidi] = value
            }
            frames.append(bins)
        }
        return PitchSalienceTable(frames: frames)
    }

    func testPeakPickerFindsEverySingingVoice() {
        // Four voices at one frame (an SATB chord): C3, G3, C4, E4.
        let table = self.table([[48: 0.9, 55: 0.8, 60: 0.7, 64: 0.95]])
        let candidates = MultiFOSalience.candidates(in: table)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].map(\.midi), [64, 48, 55, 60], "strongest first")
        XCTAssertEqual(candidates[0].map(\.salience), [0.95, 0.9, 0.8, 0.7])
    }

    func testPeakPickerDropsValuesBelowTheSalienceFloor() {
        let table = self.table([[48: 0.29, 55: 0.30, 60: 0.31]])
        let candidates = MultiFOSalience.candidates(in: table)
        XCTAssertEqual(candidates[0].map(\.midi), [60, 55], "0.29 is below the 0.30 floor")
    }

    func testPeakPickerSuppressesTheNeighbouringBinsOfOneVoice() {
        // A single voice at C4 with a smeared neighbour at B3 and C#4: only the
        // centre survives the ±2-semitone local-maximum test.
        let table = self.table([[59: 0.55, 60: 0.9, 61: 0.5]])
        let candidates = MultiFOSalience.candidates(in: table)
        XCTAssertEqual(candidates[0].map(\.midi), [60])
    }

    func testPeakPickerDropsAWeakerNeighbourWithinTheWindow() {
        // THE RULE (measured on the real model): a candidate is the strict
        // local maximum within ±2 semitones, so a STRONGER neighbour inside
        // that window erases it. A weaker neighbour does not erase the
        // stronger candidate.
        //
        // THE LIMITATION, stated honestly: two real voices a semitone apart
        // keep only the stronger one. The model's posterior does not produce
        // such pairs on the synthetic SATB fixture (it is semitone-clean —
        // its artefacts are OCTAVES, not semitones), and in SDA the parts are
        // routinely more than a semitone apart; but the limit is real and is
        // recorded rather than papered over.
        let table = self.table([[60: 0.9, 61: 0.4]])
        let candidates = MultiFOSalience.candidates(in: table)
        XCTAssertEqual(candidates[0].map(\.midi), [60],
                       "the weaker neighbour inside the ±2-semitone window is dropped")
    }

    func testPeakPickerBreaksTiesDeterministicallyOnTheLowerPitch() {
        let table = self.table([[60: 0.8, 61: 0.8]])
        let candidates = MultiFOSalience.candidates(in: table)
        XCTAssertEqual(candidates[0].map(\.midi), [60], "the tie goes to the LOWER pitch")
    }

    func testPeakPickerReportsTheFrameTime() {
        let table = self.table([[60: 0.9], [60: 0.9]])
        let candidates = MultiFOSalience.candidates(in: table)
        XCTAssertEqual(candidates[0][0].frameIndex, 0)
        XCTAssertEqual(candidates[0][0].time, 0, accuracy: 1e-12)
        XCTAssertEqual(candidates[1][0].frameIndex, 1)
        XCTAssertEqual(candidates[1][0].time, BasicPitchFrameClock.seconds(forFrame: 1),
                       accuracy: 1e-12)
    }

    func testEmptyTableProducesNoCandidates() {
        let table = PitchSalienceTable(frames: [])
        XCTAssertTrue(MultiFOSalience.candidates(in: table).isEmpty)
    }

    // MARK: - 3. The tracks

    func testTracksJoinConsecutiveFramesOfTheSamePitch() {
        let table = self.table([[60: 0.9], [60: 0.8], [60: 0.7], [61: 0.6]])
        let tracks = MultiFOSalience.tracks(in: table)
        XCTAssertEqual(tracks.count, 2)
        let c4 = tracks[0]
        XCTAssertEqual(c4.midi, 60)
        XCTAssertEqual(c4.firstFrameIndex, 0)
        XCTAssertEqual(c4.lastFrameIndex, 2)
        XCTAssertEqual(c4.meanSalience, 0.8, accuracy: 1e-9)
        XCTAssertEqual(c4.peakSalience, 0.9, accuracy: 1e-9)
        XCTAssertEqual(c4.startTime, 0, accuracy: 1e-12)
        XCTAssertEqual(c4.endTime, BasicPitchFrameClock.seconds(forFrame: 3), accuracy: 1e-12)
    }

    func testTracksBridgeASingleDroppedFrame() {
        // The model wobbles: one frame below the floor does not end a note.
        let table = self.table([[60: 0.9], [60: 0.0], [60: 0.9]])
        let tracks = MultiFOSalience.tracks(in: table, maximumGapFrames: 2)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].firstFrameIndex, 0)
        XCTAssertEqual(tracks[0].lastFrameIndex, 2)
    }

    func testTracksEndAfterALongGap() {
        let table = self.table([[60: 0.9], [60: 0.0], [60: 0.0], [60: 0.0], [60: 0.9]])
        let built = MultiFOSalience.tracks(in: table, maximumGapFrames: 2)
        XCTAssertEqual(built.count, 2, "a 3-frame gap ends the run")
    }

    func testTracksAreSortedByStartTime() {
        let table = self.table([[60: 0.0, 72: 0.9], [60: 0.9, 72: 0.9]])
        let tracks = MultiFOSalience.tracks(in: table)
        XCTAssertEqual(tracks.map(\.midi), [72, 60])
    }

    // MARK: - The flat-buffer constructor (the C++ bridge's shape)

    func testFlatBufferConstructorReadsRowMajor() {
        var flat: [Double] = []
        for frame in 0..<3 {
            for bin in 0..<PitchSalienceTable.binCount {
                flat.append(Double(frame * 100 + bin))
            }
        }
        let table = PitchSalienceTable(flat: flat, frameCount: 3)
        XCTAssertEqual(table.frameCount, 3)
        XCTAssertEqual(table.salience(frame: 1, midi: PitchSalienceTable.lowestMidi + 5), 105)
        XCTAssertEqual(table.salience(frame: 9, midi: 60), 0, "out-of-range frames read as 0")
    }
}
