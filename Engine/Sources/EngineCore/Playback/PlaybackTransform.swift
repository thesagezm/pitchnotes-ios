import Foundation

// P-402 · The reference playback transform — CONTRACTS v1.2 C-20 (D-58), the
// portable engine-side implementation. P-402 shifts the reference playback
// (key via the playback node's pitch, tempo via its rate — pitch-preserved)
// and J-403 calibrates the live-path latency; grading must stay aligned
// through BOTH. This file is the ONE implementation of that mapping — the app
// consumes it, never re-derives it (the D-33 "one semantic, never two"
// pattern; C-20: "P-402 implements it; J-401/J-402 consume it").
//
// THE RULES (C-20, verbatim in CONTRACTS.md):
//
//  §1  THE TRANSFORM IS A VIEW, NEVER A REWRITE. The bundle's files are NEVER
//      mutated by a key/tempo shift; the transform applies AT LOAD to the
//      composed grading reference, uniformly:
//        midi' = midi + transpositionSemitones
//        t'    = start + (t − start) / tempoScale   for every t
//      — the whole composed reference (note times AND phrase/bar spans)
//      scales about the SESSION START by the SAME factor. (tempoScale is the
//      playback speed factor; 1.0 unchanged; 1.25× renders a 4.0 s phrase as
//      3.2 s.)
//  §2  THE OVERLAY TRANSFORMS IDENTICALLY TO THE TRACK IT CORRECTS. C-11's
//      ops address notes by INDEX (the transform never adds, removes or
//      reorders), and its time-carrying fields (splitAt_s) and C-16's
//      offset_s are expressed in UNTRANSPOSED bundle time and map through the
//      SAME time mapping as the note times they address.
//  §3  tuningCents IS PRESERVED UNDER TRANSPOSITION. A semitone shift adds
//      exactly 100·n cents; the recording's deviation from equal temperament
//      is invariant. The grading reference pitch is cents(midi') +
//      tuningCents (D-22: the grader offsets the REFERENCE, never the stored
//      audio; the ±50c clamp and the user override compose BEFORE this
//      point).
//  §4  THE LATENCY OFFSET — sign convention PINNED: latencyOffset_ms ≥ 0
//      means the live path is LATE by that much; the grader compares the
//      live frame captured at t against the reference at t − latencyOffset.
//      Home DEVICE-LOCAL (never in a bundle; SessionResult records the
//      applied value, C-18).
//  §5  RANGES: transpositionSemitones ∈ [−12, +12] int; tempoScale ∈
//      [0.5, 2.0]. A shift outside the range is REFUSED by the UI, never
//      clamped into silent wrongness — so this type's initialiser THROWS on
//      an out-of-range value rather than clamping.
//
// THE VARISPEED FACT (RESEARCH Addendum A.2.8, Muskey-verified — and
// MEASURED in EngineCoreTests/VarispeedCompensationTests.swift, the pure-DSP
// zero-crossing test that runs on every platform): changing playback SPEED
// without pitch correction shifts pitch UP by +12·log2(speed) semitones
// (faster = sharper — tape physics). The COMPENSATION a varispeed-based path
// must therefore apply is **−12·log2(speed) semitones, on top of any key
// change** — that is what A.2.8's number IS. `AVAudioUnitTimePitch` needs NO
// such compensation (its pitch and rate are independent by construction —
// the reason P-402's player uses it; the pitch-preserved-rate behaviour is
// confirmed on the device at the D-56 demo leg, like every §8 number). The
// formula lives in ONE place (`VarispeedPitchCompensation`) so a future
// Varispeed path is never wired uncorrected.

// MARK: - The session's playback environment

/// The session's key/tempo environment (C-20 §1/§5) — the values a session
/// records (C-18's `transpositionSemitones` / `tempoScale`) and the transform
/// applies. Ranges are REFUSED, never clamped (C-20 §5).
public struct PlaybackEnvironment: Equatable, Sendable {

    /// The key shift in semitones, [−12, +12].
    public var transpositionSemitones: Int

    /// The playback speed factor, [0.5, 2.0]; 1.0 = unchanged.
    public var tempoScale: Double

    /// Throws `PlaybackEnvironmentError` on an out-of-range value (C-20 §5:
    /// refused, never clamped into silent wrongness).
    public init(transpositionSemitones: Int = 0, tempoScale: Double = 1.0) throws {
        guard transpositionSemitones >= -12, transpositionSemitones <= 12 else {
            throw PlaybackEnvironmentError.transpositionOutOfRange(transpositionSemitones)
        }
        guard tempoScale >= 0.5, tempoScale <= 2.0 else {
            throw PlaybackEnvironmentError.tempoScaleOutOfRange(tempoScale)
        }
        self.transpositionSemitones = transpositionSemitones
        self.tempoScale = tempoScale
    }

    /// The neutral environment (no key shift, no tempo change).
    public static let neutral = try! PlaybackEnvironment()
}

public enum PlaybackEnvironmentError: Error, Equatable, Sendable {
    case transpositionOutOfRange(Int)
    case tempoScaleOutOfRange(Double)
}

// MARK: - The varispeed fact

/// THE VARISPEED COMPENSATION, one place (C-20 / RESEARCH A.2.8). Plain
/// varispeed (reading samples at `speed`) imposes a pitch drift of
/// **+12·log2(speed) semitones UP** (faster = sharper — tape physics,
/// MEASURED by `VarispeedCompensationTests` via zero crossings on a
/// synthesized sine). The COMPENSATION such a path must apply is therefore
/// **−12·log2(speed) semitones, on top of any key change** — A.2.8's number.
/// `AVAudioUnitTimePitch` needs none of this (rate is pitch-preserved by
/// construction); the enum exists so a future Varispeed-based path is never
/// wired uncorrected.
public enum VarispeedPitchCompensation {

    /// The COMPENSATION semitones for a varispeed of `speed` — the value to
    /// ADD to the key shift to cancel the drift (negative = down, cancelling
    /// the sharpening). `−12·log2(speed)`.
    public static func semitones(forSpeed speed: Double) -> Double {
        -12.0 * log2(speed)
    }

    /// The varispeed speed whose compensation equals `semitones` — the
    /// inverse mapping.
    public static func speed(forSemitones semitones: Double) -> Double {
        pow(2.0, -semitones / 12.0)
    }

    /// The pitch drift a plain varispeed of `speed` IMPOSES, in semitones
    /// (positive = sharper). `+12·log2(speed)`. The compensation is its
    /// negation: `imposedDrift(speed) + semitones(forSpeed: speed) == 0` —
    /// pinned by measurement in the tests.
    public static func imposedDrift(forSpeed speed: Double) -> Double {
        12.0 * log2(speed)
    }
}

// MARK: - The transform

/// The C-20 view transform over the composed grading reference. Constructed
/// once per session; every mapping below is the SAME mapping the playback
/// engine and the grader must agree on. The bundle's files are never touched
/// (C-20 §1) — the transform is applied to in-memory copies at load.
public struct PlaybackTransform: Equatable, Sendable {

    /// The session's key/tempo environment.
    public let environment: PlaybackEnvironment

    /// The pivot the tempo scaling is anchored to (C-20 §1: "scales about the
    /// session start"). 0 for a whole-song session; a session that begins at
    /// t = s pivots there.
    public let sessionStart_s: Double

    public init(environment: PlaybackEnvironment = .neutral, sessionStart_s: Double = 0) {
        self.environment = environment
        self.sessionStart_s = sessionStart_s
    }

    /// `midi' = midi + transpositionSemitones` (C-20 §1).
    public func mapMidi(_ midi: Int) -> Int {
        midi + environment.transpositionSemitones
    }

    /// `t' = sessionStart + (t − sessionStart) / tempoScale` (C-20 §1) — the
    /// ONE time mapping for note times, phrase/bar spans, and the overlay's
    /// time-carrying fields alike (C-20 §2).
    public func mapTime(_ t: Double) -> Double {
        sessionStart_s + (t - sessionStart_s) / environment.tempoScale
    }

    /// An interval maps endpoint-wise through the same time mapping (a note
    /// stays a note: start' < end' for any admissible tempoScale).
    public func mapInterval(start: Double, end: Double) -> (start: Double, end: Double) {
        (mapTime(start), mapTime(end))
    }

    /// Apply to an engine note: the note's MIDI and its interval move; every
    /// other field (confidence, salience, unison, band…) is carried through
    /// UNCHANGED — the transform is a view, it invents nothing (C-20 §1).
    public func apply(to note: EngineCore.Note) -> EngineCore.Note {
        var mapped = note
        mapped.midi = mapMidi(note.midi)
        let interval = mapInterval(start: note.start_s, end: note.end_s)
        mapped.start_s = interval.start
        mapped.end_s = interval.end
        return mapped
    }

    /// Apply to a whole track (order-preserving — the transform never adds,
    /// removes or reorders notes, which is exactly what keeps C-11's
    /// index-addressed corrections valid under the transform, C-20 §2).
    public func apply(to track: NoteTrack) -> NoteTrack {
        NoteTrack(contractVersion: track.contractVersion,
                  part: track.part,
                  notes: track.notes.map { self.apply(to: $0) },
                  engineVersion: track.engineVersion)
    }

    /// The grading REFERENCE PITCH for a note under this session's
    /// environment (C-20 §3): `cents(midi') + tuningCents` — the resolved
    /// tuning (D-22's clamp and any user override already composed by the
    /// caller) is PRESERVED under transposition. A faithful singer of a +32c
    /// recording shifted +2 semitones is still graded against +32c.
    public func referenceCents(midi: Int, tuningCents: Double) -> Double {
        Double(mapMidi(midi) * 100) + tuningCents
    }

    /// C-20 §4's comparison time: the reference time a LIVE frame at
    /// `liveTime_s` is graded against, given the session's applied latency
    /// offset. Sign convention PINNED: `latencyOffset_ms ≥ 0` = the live path
    /// is LATE, so the live frame at t compares against the EARLIER reference
    /// at `t − offset`.
    public func referenceTime(forLiveTime liveTime_s: Double,
                              latencyOffset_ms: Double) -> Double {
        liveTime_s - latencyOffset_ms / 1000.0
    }
}
