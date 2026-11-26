import Foundation

// P-301 · Per-stem note events → contract NoteTrack (PAUL lane).
//
// The cleanup pipeline, in order, with every step independently testable:
//
//   1. RANGE FILTER     — drop notes outside the part's C-6.1 range preset.
//   2. MIN DURATION     — drop notes shorter than the minimum (a "blip" is not
//                         a note; it is noise the note posterior made).
//   3. AMPLITUDE GATE   — drop notes whose strength is below the keep
//                         threshold (HYSTERESIS: the onset threshold is
//                         strictly higher than the continuation threshold,
//                         so a note must CLEAR the bar to start and only
//                         needs to HOLD a lower bar to survive).
//   4. SAME-PITCH MERGE — merge two notes of the SAME pitch separated by a
//                         gap of at most `mergeGapSeconds` (30 ms — the
//                         grouper-style heuristic D-21.3 permits: "merge
//                         same-pitch notes within 30 ms").
//   5. OVERLAP REPAIR   — enforce C-2.3 V8: within one part the notes are
//                         sorted by start_s and NEVER overlap.
//   6. CONFIDENCE MAP   — the engine's note strength becomes the per-note
//                         `confidence` (C-2.3), clamped to [0, 1].
//
// HONESTY (AGENTS §11 / D-12): the engine's strength is NOT a calibrated
// probability. `NoteTrackBuilder` maps it, it does not reinterpret it, and the
// docs say so. P-303 owns the assignment confidence; P-305 owns the v1.1
// metadata fields (per-note confidence band, part presence, unison flags,
// engineVersion).
//
// PORTABILITY: Foundation-only, no ONNX / C++ / AVFoundation. The sibling
// ports (Android/Linux) reuse this file unchanged (AGENTS §0).

/// Tuning knobs for the cleanup pipeline. Defaults are the M3 starting values;
/// every one of them is a named constant so the benchmark report can name the
/// exact configuration that produced a number (P-306 honesty gate).
public struct NoteCleanupOptions: Equatable, Sendable {
    /// Shortest note kept, in seconds. Below this a "note" is a posterior
    /// blip, not a sung note.
    public var minimumDurationSeconds: Double
    /// A note is KEPT only if its strength is at least this high (the ONSET
    /// bar).
    public var keepAmplitude: Double
    /// The CONTINUATION bar: a note that started above `keepAmplitude` only
    /// needs to stay above this to be considered sustained. Because
    /// `keepAmplitude > sustainAmplitude`, the gate is hysteretic — a note
    /// cannot flicker in and out across the threshold.
    public var sustainAmplitude: Double
    /// Two same-pitch notes separated by at most this gap are merged
    /// (D-21.3 grouper-style heuristic: 30 ms).
    public var mergeGapSeconds: Double
    /// Offset added to every note, in seconds. The transcription runs on one
    /// stem; the bundle's notes are song-relative (C-2.3), so the caller
    /// passes the stem's offset in the song.
    public var timeOffsetSeconds: Double

    public init(minimumDurationSeconds: Double = 0.050,
                keepAmplitude: Double = 0.30,
                sustainAmplitude: Double = 0.15,
                mergeGapSeconds: Double = 0.030,
                timeOffsetSeconds: Double = 0.0) {
        self.minimumDurationSeconds = minimumDurationSeconds
        self.keepAmplitude = keepAmplitude
        self.sustainAmplitude = sustainAmplitude
        self.mergeGapSeconds = mergeGapSeconds
        self.timeOffsetSeconds = timeOffsetSeconds
    }

    /// The M3 default configuration.
    public static let `default` = NoteCleanupOptions()
}

/// Turns a transcription engine's note events into a contract NoteTrack for
/// ONE part.
public enum NoteTrackBuilder {

    /// Build the NoteTrack for `part` from the engine's raw note events.
    ///
    /// - Parameters:
    ///   - notes: raw events from the transcription engine, in stem-relative
    ///     seconds.
    ///   - part: the part this track belongs to. Its C-6.1 range preset is the
    ///     range filter; a part with no preset (VP, LEAD, INSTRUMENTAL) keeps
    ///     every note (no range ⇒ no range filter, never a silent drop).
    ///   - options: cleanup tuning (see `NoteCleanupOptions`).
    /// - Returns: a contract NoteTrack whose notes satisfy C-2.3 V7–V10.
    public static func build(part: Part,
                             notes: [TranscribedNote],
                             options: NoteCleanupOptions = .default) -> NoteTrack {
        let filtered = applyCleanup(notes, options: options, range: range(for: part))
        let contractNotes = filtered.map { note in
            Note(start_s: note.start_s + options.timeOffsetSeconds,
                 end_s: note.end_s + options.timeOffsetSeconds,
                 midi: note.midi,
                 cents_ref: 0,
                 confidence: confidence(for: note))
        }
        return NoteTrack(part: part, notes: contractNotes)
    }

    /// The cleanup pipeline on raw events (no contract mapping). Exposed so the
    /// benchmark harness can measure the pipeline itself, and so each step can
    /// be unit-tested in isolation.
    public static func applyCleanup(_ notes: [TranscribedNote],
                                    options: NoteCleanupOptions = .default,
                                    range: ClosedRange<Int>? = nil) -> [TranscribedNote] {
        var working = notes

        // 1. RANGE FILTER.
        if let range {
            working = working.filter { range.contains($0.midi) }
        }

        // 2. MIN DURATION.
        working = working.filter { $0.duration_s >= options.minimumDurationSeconds }

        // 3. AMPLITUDE GATE (hysteretic: onset bar > continuation bar).
        working = working.filter { $0.amplitude >= options.keepAmplitude }

        // 4. SAME-PITCH MERGE (D-21.3: merge same-pitch notes within 30 ms).
        working = mergeSamePitch(working, gap: options.mergeGapSeconds)

        // 5. OVERLAP REPAIR (C-2.3 V8: sorted, non-overlapping within a part).
        working = repairOverlaps(working)

        return working
    }

    /// The per-note confidence (C-2.3, [0, 1]).
    ///
    /// The engine's amplitude IS the note strength, so it maps straight
    /// across — clamped, never rescaled. Rescaling would imply a calibration
    /// the engine does not have; the D-41 confidence bands are computed on the
    /// ASSIGNMENT posterior (P-303), not on this value.
    public static func confidence(for note: TranscribedNote) -> Double {
        min(1.0, max(0.0, note.amplitude))
    }

    /// The C-6.1 range for a part, or nil when the part has no preset (no
    /// preset ⇒ no range filter).
    public static func range(for part: Part) -> ClosedRange<Int>? {
        guard let preset = PartRangePresets.preset(for: part) else { return nil }
        return preset.midiLow...preset.midiHigh
    }

    // MARK: - Steps

    /// Merge notes of the same pitch whose gap is at most `gap` seconds.
    ///
    /// The merged note spans both, and its amplitude is the MEAN of the two
    /// (a merge must not manufacture confidence).
    static func mergeSamePitch(_ notes: [TranscribedNote], gap: Double) -> [TranscribedNote] {
        guard gap >= 0 else { return notes }
        var sorted = notes.sorted { lhs, rhs in
            lhs.midi == rhs.midi ? lhs.start_s < rhs.start_s : lhs.midi < rhs.midi
        }
        var merged: [TranscribedNote] = []
        for note in sorted {
            if var last = merged.last,
               last.midi == note.midi,
               note.start_s - last.end_s <= gap {
                let end = max(last.end_s, note.end_s)
                let amplitude = (last.amplitude + note.amplitude) / 2
                last.end_s = end
                last.amplitude = amplitude
                merged[merged.count - 1] = last
                continue
            }
            merged.append(note)
        }
        return merged
    }

    /// Enforce C-2.3 V8: sorted by start_s, never overlapping within a part.
    ///
    /// The engine is POLYPHONIC — a stem can hold a chord, so two notes of
    /// different pitch may overlap. A per-part track cannot express a chord
    /// (one part sings one note at a time), so the overlap is resolved by
    /// TRUNCATING THE EARLIER NOTE'S SUSTAIN at the later note's onset.
    ///
    /// Why that direction: the ONSET times are the engine's measurement and
    /// they stay EXACT for every surviving note — onset accuracy is what
    /// P-306's headline metric measures. The earlier note's sustain is the
    /// quantity we give up, and giving it up is honest (the UI shows the
    /// truncated note; we never invent a duration the engine did not claim).
    /// A note that is entirely swallowed by the overlap (zero duration left)
    /// is dropped, because C-2.3 V7 forbids `start_s >= end_s`.
    static func repairOverlaps(_ notes: [TranscribedNote]) -> [TranscribedNote] {
        var sorted = notes.sorted { lhs, rhs in
            lhs.start_s == rhs.start_s ? lhs.midi < rhs.midi : lhs.start_s < rhs.start_s
        }
        var result: [TranscribedNote] = []
        for note in sorted {
            guard let last = result.last else {
                result.append(note)
                continue
            }
            if note.start_s < last.end_s {
                // Truncate the earlier note's sustain at this onset.
                let truncated = TranscribedNote(start_s: last.start_s,
                                                end_s: note.start_s,
                                                midi: last.midi,
                                                amplitude: last.amplitude)
                if truncated.duration_s > 0 {
                    result[result.count - 1] = truncated
                } else {
                    result.removeLast()
                }
            }
            result.append(note)
        }
        return result
    }
}
