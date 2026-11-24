import Foundation

// P-301 · Basic-pitch transcription output types (PAUL lane).
//
// These are the PORTABLE half of the note-transcription pipeline: the shapes a
// transcription engine produces and the shapes the rest of the app consumes.
// They deliberately carry NO ONNX / C++ / AVFoundation dependency, so the whole
// cleanup + contract-mapping path is Linux-testable and portable to the sibling
// ports (AGENTS §0: C/C++/Swift engine code must not depend on UIKit/SwiftUI).
//
// The engine that produces them is the basic-pitch bridge (D-39: ONE ORT
// runtime — the existing SPM ORT 1.24.2; the model file is `nmp.onnx`, whose
// WEIGHTS are TIER C per D-46 — NC training data ⇒ STUDY-ONLY for commercial
// distribution; the CODE is Apache-2.0/MIT and unaffected). The engine emits
// `TranscribedNote`s; `NoteTrackBuilder` turns them into a contract NoteTrack
// (C-2.3) for one part.
//
// TIMING CONVENTION: all times are seconds from the start of the AUDIO that was
// transcribed (the stem), NOT from the start of the song. The caller adds the
// stem's offset when it writes `notes/<PART>.json` — the bundle's notes are
// song-relative (C-2.3).

/// One note event as produced by the transcription engine, BEFORE any
/// per-part cleanup.
///
/// Mirrors basic-pitch's `NoteEvent` (start_idx / end_idx / pitch / amplitude)
/// but in seconds and with explicit semantics:
///
/// - `start_s` / `end_s` — seconds from the start of the transcribed audio.
/// - `midi` — equal-tempered MIDI note number (A440, C4 = 60).
/// - `amplitude` — the engine's note strength in [0, 1]. This becomes the
///   per-note `confidence` (C-2.3) after the confidence normalization in
///   `NoteTrackBuilder`; it is NOT a calibrated probability and the builder
///   never claims it is (D-12 honesty rail).
public struct TranscribedNote: Equatable, Sendable {
    public var start_s: Double
    public var end_s: Double
    public var midi: Int
    /// Engine note strength in [0, 1].
    public var amplitude: Double

    public init(start_s: Double, end_s: Double, midi: Int, amplitude: Double) {
        self.start_s = start_s
        self.end_s = end_s
        self.midi = midi
        self.amplitude = amplitude
    }

    /// Duration in seconds (never negative).
    public var duration_s: Double { max(0, end_s - start_s) }
}
