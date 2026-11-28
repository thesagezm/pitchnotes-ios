import XCTest
@testable import EngineCore

// P-402 · THE VARISPEED MEASUREMENT (RESEARCH Addendum A.2.8 — the AC's
// "confirm varispeed pitch compensation = −12·log2(speed) semitones").
//
// THE MEASUREMENT IS REAL, NOT A FORMULA RE-ASSERTION: a 440 Hz sine is
// synthesized, READ AT A VARISPEED (the samples are consumed `speed`×
// faster — exactly what a varispeed path does), and its frequency is
// MEASURED from the zero crossings of the result. The measured semitone
// drift must equal +12·log2(speed) (faster = SHARPER — tape physics), and
// the compensation must cancel it EXACTLY, on top of any key change.
//
// This is platform-neutral DSP (no AVAudioEngine) so it runs in the docker
// loop AND on the macOS runner. The AVAudioUnit-specific behaviour — that
// `AVAudioUnitTimePitch.rate` is pitch-preserved and that its `pitch` is in
// cents — is bound in Engine/PlaybackKit (the Apple-only package) and
// confirmed on the device at the D-56 demo leg, like every AGENTS §8 number.

final class VarispeedCompensationTests: XCTestCase {

    /// The sample rate every test uses.
    private let sampleRate = 44_100.0

    /// A pure sine at `frequency` Hz, `seconds` long.
    private func sine(frequency: Double, seconds: Double) -> [Double] {
        let frames = Int(seconds * sampleRate)
        return (0..<frames).map { sin(2.0 * .pi * frequency * Double($0) / sampleRate) }
    }

    /// A plain varispeed: consume the input at `speed`× (linear
    /// interpolation between samples — what every speed-change path does).
    private func varispeed(_ input: [Double], speed: Double) -> [Double] {
        guard input.count > 1, speed > 0 else { return [] }
        var output: [Double] = []
        var position = 0.0
        while position < Double(input.count - 1) {
            let index = Int(position)
            let fraction = position - Double(index)
            output.append(input[index] * (1 - fraction) + input[index + 1] * fraction)
            position += speed
        }
        return output
    }

    /// The frequency measured from positive-going zero crossings — exact for
    /// a clean sine, no FFT needed.
    private func measuredFrequency(_ samples: [Double]) -> Double {
        guard samples.count > 2 else { return 0 }
        var crossings = 0
        for index in 1..<samples.count where samples[index - 1] <= 0 && samples[index] > 0 {
            crossings += 1
        }
        let seconds = Double(samples.count) / sampleRate
        return Double(crossings) / seconds
    }

    /// The semitone distance between two frequencies: `12·log2(f_out/f_in)`.
    private func semitones(from f0: Double, to f1: Double) -> Double {
        12.0 * log2(f1 / f0)
    }

    // MARK: - The imposed drift is +12·log2(speed) — MEASURED

    func testAPlainVarispeedShiftsPitchUpByTwelveLogTwoOfSpeed() {
        let original = sine(frequency: 440.0, seconds: 2.0)
        // Sanity: the measurement recovers the synthesized frequency.
        XCTAssertEqual(measuredFrequency(original), 440.0, accuracy: 1.0)
        // Sanity: no speed change, no shift.
        XCTAssertEqual(semitones(from: 440.0,
                                 to: measuredFrequency(varispeed(original, speed: 1.0))),
                       0.0, accuracy: 0.05)

        for speed: Double in [0.5, 0.8, 1.25, 1.5, 2.0] {
            let shifted = varispeed(original, speed: speed)
            let measured = semitones(from: 440.0, to: measuredFrequency(shifted))
            // FASTER = SHARPER (positive), SLOWER = FLATTER (negative), and
            // the amount is +12·log2(speed) — measured, to within the
            // interpolation's tolerance.
            XCTAssertEqual(measured,
                           VarispeedPitchCompensation.imposedDrift(forSpeed: speed),
                           accuracy: 0.1,
                           "speed \(speed): the MEASURED drift must be +12·log2(speed) — faster SHARPER, slower FLATTER")
        }
    }

    // MARK: - The compensation cancels the drift EXACTLY — MEASURED

    func testTheCompensationCancelsTheMeasuredDriftExactly() {
        let original = sine(frequency: 440.0, seconds: 2.0)
        for speed: Double in [0.5, 1.25, 2.0] {
            // The compensation is the NEGATION of the imposed drift, so a
            // varispeeded signal re-read at the compensated ratio returns to
            // the original pitch — measured.
            let compensationRatio = VarispeedPitchCompensation.speed(
                forSemitones: VarispeedPitchCompensation.imposedDrift(forSpeed: speed))
            XCTAssertEqual(compensationRatio, 1.0 / speed, accuracy: 1e-9,
                           "the inverse mapping IS the speed's reciprocal")
            let compensated = varispeed(varispeed(original, speed: speed),
                                        speed: compensationRatio)
            let residual = semitones(from: 440.0, to: measuredFrequency(compensated))
            XCTAssertEqual(residual, 0.0, accuracy: 0.15,
                           "speed \(speed): compensated playback measures back at 440 Hz")
            // And the bookkeeping identity the AC quotes:
            // imposed + compensation == 0.
            XCTAssertEqual(VarispeedPitchCompensation.imposedDrift(forSpeed: speed)
                               + VarispeedPitchCompensation.semitones(forSpeed: speed),
                           0.0, accuracy: 1e-12)
        }
    }

    // MARK: - "On top of any key change" — the composition is additive

    func testTheCompensationComposesAdditivelyWithAKeyChange() {
        // A key change of +2 semitones AND a varispeed of 1.25: the imposed
        // total is +2 + 12·log2(1.25); cancelling the VARISPEED part leaves
        // exactly the key change — the AC's "on top of any key change".
        let keySemitones = 2.0
        let speed = 1.25
        let imposedTotal = keySemitones
            + VarispeedPitchCompensation.imposedDrift(forSpeed: speed)
        let compensated = imposedTotal
            + VarispeedPitchCompensation.semitones(forSpeed: speed)
        XCTAssertEqual(compensated, keySemitones, accuracy: 1e-12,
                       "the compensation cancels the varispeed part and leaves the key change")
    }

    // MARK: - The compensation formula itself (the ruling's number)

    func testTheCompensationFormulaMatchesA28() {
        // −12·log2(speed): −12 semitones at 2× (a varispeeded octave-up
        // drift needs an octave-down compensation), +12 at 0.5×.
        XCTAssertEqual(VarispeedPitchCompensation.semitones(forSpeed: 1.0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(VarispeedPitchCompensation.semitones(forSpeed: 2.0), -12.0, accuracy: 1e-12)
        XCTAssertEqual(VarispeedPitchCompensation.semitones(forSpeed: 0.5), 12.0, accuracy: 1e-12)
        XCTAssertEqual(VarispeedPitchCompensation.semitones(forSpeed: 1.25), -3.863_137, accuracy: 1e-6)
        // The inverse mapping returns the speed.
        XCTAssertEqual(VarispeedPitchCompensation.speed(forSemitones: -3.863_137), 1.25, accuracy: 1e-6)
        XCTAssertEqual(VarispeedPitchCompensation.speed(forSemitones: 12.0), 0.5, accuracy: 1e-12)
        for speed: Double in [0.5, 0.8, 1.0, 1.25, 2.0] {
            let semis = VarispeedPitchCompensation.semitones(forSpeed: speed)
            XCTAssertEqual(VarispeedPitchCompensation.speed(forSemitones: semis), speed, accuracy: 1e-9)
        }
    }
}
