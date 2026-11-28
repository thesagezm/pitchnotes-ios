import Foundation
import EngineCore

// J-401 · C-20 (CONTRACTS v1.2, D-58) — the session environment and the
// transposition/tempo/latency mapping the grader consumes.
//
// THE RULES THIS FILE IMPLEMENTS (C-20, verbatim):
//   1. THE TRANSFORM IS A VIEW, NEVER A REWRITE — the bundle's files are
//      never mutated by a key/tempo shift; the transform applies AT LOAD to
//      the composed grading reference: `midi' = midi + transpositionSemitones`
//      and `t' = start + (t − start)/tempoScale` about the session start.
//   2. THE OVERLAY TRANSFORMS IDENTICALLY TO THE TRACK IT CORRECTS (the
//      caller composes overlay + track FIRST; both then go through THIS
//      transform, so a corrected split stays corrected under any key/tempo).
//   3. `tuningCents` IS PRESERVED UNDER TRANSPOSITION — a semitone shift adds
//      exactly 100·n cents via midi'; the recording's deviation from equal
//      temperament is invariant. The reference pitch for grading is
//      `cents(midi') + cents_ref + tuningCents` (D-22: the grader offsets the
//      REFERENCE, never the stored audio — a faithful singer of a +32c
//      recording shifted +2 semitones is still graded against +32c).
//   4. THE LATENCY OFFSET — `latencyOffset_ms ≥ 0` means the live path is
//      LATE by that much; the grader compares the live frame captured at `t`
//      against the reference at `t − latencyOffset_ms`. Its HOME is
//      device-local (J-403); a session records only the value APPLIED.
//   5. RANGES — transpositionSemitones ∈ [-12, +12], tempoScale ∈ [0.5, 2.0].
//      A shift outside the range is REFUSED, never clamped into silent
//      wrongness (a clamped key change would grade against a key the user
//      did not hear) — `validatedForGrading()` throws.
public struct SessionEnvironment: Codable, Equatable, Sendable {

    /// C-20 §5's ranges (refused outside, never clamped).
    public static let transpositionSemitonesRange = -12...12
    public static let tempoScaleRange = 0.5...2.0

    /// ≥ 0 = the live path is LATE by this much (C-20 §4). Device-local.
    public var latencyOffset_ms: Int
    /// The recording's resolved tuning offset (D-22, ±50c-clamped upstream;
    /// the J-205 override composes BEFORE this point). PRESERVED under
    /// transposition (C-20 §3).
    public var tuningCents: Int
    /// The key shift the user hears (C-20 §1: midi' = midi + n).
    public var transpositionSemitones: Int
    /// The playback speed factor (1.0 = unchanged; a 1.25× tempo renders a
    /// 4.0 s phrase as 3.2 s).
    public var tempoScale: Double

    public init(latencyOffset_ms: Int = 0,
                tuningCents: Int = 0,
                transpositionSemitones: Int = 0,
                tempoScale: Double = 1.0) {
        self.latencyOffset_ms = latencyOffset_ms
        self.tuningCents = tuningCents
        self.transpositionSemitones = transpositionSemitones
        self.tempoScale = tempoScale
    }

    // MARK: C-20 §5 — refuse, never clamp

    public enum EnvironmentError: Error, Equatable {
        case transpositionOutOfRange(Int)
        case tempoScaleOutOfRange(Double)
    }

    /// C-20 §5: a shift outside the range is refused by the UI, never
    /// clamped into silent wrongness. The grader calls this before grading.
    public func validatedForGrading() throws {
        guard SessionEnvironment.transpositionSemitonesRange.contains(transpositionSemitones) else {
            throw EnvironmentError.transpositionOutOfRange(transpositionSemitones)
        }
        guard SessionEnvironment.tempoScaleRange.contains(tempoScale) else {
            throw EnvironmentError.tempoScaleOutOfRange(tempoScale)
        }
    }

    // MARK: The view transform (C-20 §1)

    /// `midi' = midi + transpositionSemitones` (int; the reference's MIDI
    /// moves with the key shift).
    public func transformedMidi(_ midi: Int) -> Int {
        midi + transpositionSemitones
    }

    /// `t' = sessionStart + (t − sessionStart)/tempoScale` — the whole
    /// composed reference scales about the session start by the SAME factor
    /// (note times AND phrase/bar spans).
    public func transformedTime(_ t: Double, sessionStart_s: Double = 0) -> Double {
        sessionStart_s + (t - sessionStart_s) / tempoScale
    }

    /// A note's transformed span (the pair of `transformedTime` calls).
    public func transformedSpan(start_s: Double, end_s: Double,
                                sessionStart_s: Double = 0) -> (start: Double, end: Double) {
        (transformedTime(start_s, sessionStart_s: sessionStart_s),
         transformedTime(end_s, sessionStart_s: sessionStart_s))
    }

    // MARK: The reference pitch (C-20 §3 + D-22)

    /// The grading reference pitch in cents (A4 = 6900): `100·midi' +
    /// cents_ref + tuningCents`. A semitone shift adds exactly 100·n via
    /// midi'; `cents_ref` (the note's own deviation) and `tuningCents` (the
    /// recording's deviation) are UNCHANGED by the shift.
    public func referenceCents(midi: Int, cents_ref: Int) -> Double {
        Double(transformedMidi(midi)) * 100.0 + Double(cents_ref) + Double(tuningCents)
    }

    /// The grading reference pitch in Hz (for `PitchMath.cents(from:to:)`).
    public func referenceHz(midi: Int, cents_ref: Int) -> Double {
        PitchMath.hz(forMidi: transformedMidi(midi))
            * pow(2.0, Double(cents_ref + tuningCents) / 1200.0)
    }

    // MARK: The latency mapping (C-20 §4)

    /// The latency offset in seconds.
    public var latencyOffset_s: Double { Double(latencyOffset_ms) / 1000.0 }

    /// A live frame captured at `t` corresponds to reference time
    /// `t − latencyOffset_ms` (≥ 0 = live is LATE — compare the live frame
    /// against the EARLIER reference moment).
    public func referenceTime(forLiveT t: Double) -> Double {
        t - latencyOffset_s
    }
}
