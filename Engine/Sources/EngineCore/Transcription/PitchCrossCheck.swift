import Foundation

// P-305 · The SwiftF0 ↔ basic-pitch cross-check (PAUL lane).
//
// WHAT THIS IS: two INDEPENDENT estimators of the same thing, compared
// against each other so the engine can say how much they agree.
//
//   · SwiftF0 (MIT, lars76/swift-f0) — a MONOPHONIC neural pitch tracker.
//     It answers "what single pitch is loudest here".
//   · basic-pitch (sevagh/basicpitch.cpp; weights TIER C per D-46) — a
//     POLYPHONIC transcriber. It answers "which notes are sounding".
//
// WHY CROSS-CHECK THEM AT ALL: the note track the app grades against is
// basic-pitch's. If an INDEPENDENT estimator sees a different picture of the
// same audio, that difference is exactly the doubt the user should see. The
// metric is therefore REPORTED, never used to filter, gate or hide a note
// (AGENTS §11 / C-12: a hint, never a silent filter).
//
// WHAT IT IS NOT: it is not a calibration, and it does not make either
// estimator's output "true". A disagreement may be the transcriber's fault
// (an octave artefact), the tracker's fault (a polyphonic mixture defeats a
// monophonic tracker), or the truth (a real octave leap). The report says
// "these two disagree here" and nothing more.
//
// PORTABILITY: Foundation-only, no ONNX / C++ / AVFoundation (AGENTS §0).

// MARK: - The segmented note

/// A note segmented out of a pitch-frame stream.
public struct SegmentedNote: Equatable, Sendable {
    /// Seconds from the start of the audio.
    public var start_s: Double
    /// Seconds from the start of the audio (half-open: the last frame's slot
    /// belongs to the next frame).
    public var end_s: Double
    /// The MIDI note number.
    public var midi: Int
    /// The deviation from equal temperament, in cents (the frame's actual
    /// pitch against the quantized note).
    public var cents: Double
    /// The mean confidence over the note's frames, [0, 1].
    public var meanConfidence: Double

    public init(start_s: Double, end_s: Double, midi: Int, cents: Double, meanConfidence: Double) {
        self.start_s = start_s
        self.end_s = end_s
        self.midi = midi
        self.cents = cents
        self.meanConfidence = meanConfidence
    }

    /// The duration in seconds.
    public var duration: Double { max(0, end_s - start_s) }
}

// MARK: - The segmenter (SwiftF0's `segment_notes`)

/// Segments a pitch-frame stream into notes.
///
/// This is the "segment_notes" half of the cross-check: SwiftF0 emits a frame
/// per 16 ms with a pitch and a confidence; a NOTE is a run of frames that
/// carry the same quantized MIDI. A pitch CHANGE starts a new note; a short
/// unvoiced GAP (a single dropped frame) does not — that is a model wobble,
/// not a note ending.
public enum SwiftF0NoteSegmenter {

    /// The segmentation knobs. Every one is a named constant so the benchmark
    /// report can name the exact configuration that produced a number (the
    /// P-306 honesty gate).
    public struct Options: Equatable, Sendable {
        /// A frame is voiced at or above this confidence (SwiftF0's own
        /// calibration threshold).
        public var minimumConfidence: Double
        /// An unvoiced gap no longer than this does not end a note.
        public var maximumGapSeconds: Double
        /// A note shorter than this is a posterior blip, not a sung note.
        public var minimumDurationSeconds: Double

        public init(minimumConfidence: Double = SwiftF0Spec.voicedThreshold,
                    maximumGapSeconds: Double = 0.050,
                    minimumDurationSeconds: Double = 0.050) {
            self.minimumConfidence = minimumConfidence
            self.maximumGapSeconds = maximumGapSeconds
            self.minimumDurationSeconds = minimumDurationSeconds
        }

        public static let `default` = Options()
    }

    /// Segment the frames into notes.
    public static func segment(frames: [PitchFrame], options: Options = .default) -> [SegmentedNote] {
        var notes: [SegmentedNote] = []
        var openMidi: Int? = nil
        var openStart = 0.0
        var openLast = 0.0
        var openCents: [Double] = []
        var openConfidence: [Double] = []

        func closeOpen() {
            guard let midi = openMidi else { return }
            let end = openLast + EngineContract.hopSeconds
            let meanCents = openCents.reduce(0, +) / Double(openCents.count)
            let meanConfidence = openConfidence.reduce(0, +) / Double(openConfidence.count)
            if end - openStart >= options.minimumDurationSeconds {
                notes.append(SegmentedNote(start_s: openStart,
                                           end_s: end,
                                           midi: midi,
                                           cents: meanCents,
                                           meanConfidence: meanConfidence))
            }
            openMidi = nil
            openCents = []
            openConfidence = []
        }

        for frame in frames {
            let voiced = frame.hz > 0 && frame.confidence >= options.minimumConfidence
            guard voiced else {
                // An unvoiced frame ends the note only after the allowed gap.
                if let midi = openMidi, frame.t - openLast > options.maximumGapSeconds {
                    closeOpen()
                    _ = midi
                }
                continue
            }
            let midi = midiNumber(forHz: frame.hz)
            let cents = centsDeviation(forHz: frame.hz, midi: midi)
            if let current = openMidi, current == midi, frame.t - openLast <= options.maximumGapSeconds {
                openLast = frame.t
                openCents.append(cents)
                openConfidence.append(frame.confidence)
            } else {
                closeOpen()
                openMidi = midi
                openStart = frame.t
                openLast = frame.t
                openCents = [cents]
                openConfidence = [frame.confidence]
            }
        }
        closeOpen()

        return notes.sorted { lhs, rhs in
            lhs.start_s == rhs.start_s ? lhs.midi < rhs.midi : lhs.start_s < rhs.start_s
        }
    }

    /// The nearest MIDI note number for a frequency.
    public static func midiNumber(forHz hz: Double) -> Int {
        guard hz > 0 else { return 0 }
        return Int((69 + 12 * log2(hz / 440.0)).rounded())
    }

    /// The deviation of a frequency from its quantized note, in cents.
    public static func centsDeviation(forHz hz: Double, midi: Int) -> Double {
        guard hz > 0 else { return 0 }
        let reference = 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
        return 1200.0 * log2(hz / reference)
    }
}

// MARK: - The comparison

/// A note in the cross-check's own shape (both engines' notes map onto it).
public struct CrossCheckNote: Equatable, Sendable {
    public var start_s: Double
    public var end_s: Double
    public var midi: Int
    public var cents: Double

    public init(start_s: Double, end_s: Double, midi: Int, cents: Double = 0) {
        self.start_s = start_s
        self.end_s = end_s
        self.midi = midi
        self.cents = cents
    }

    /// A contract note (C-2.3) as a cross-check note.
    public init(_ note: Note) {
        self.init(start_s: note.start_s, end_s: note.end_s, midi: note.midi, cents: Double(note.cents_ref))
    }

    /// A segmented note as a cross-check note.
    public init(_ note: SegmentedNote) {
        self.init(start_s: note.start_s, end_s: note.end_s, midi: note.midi, cents: note.cents)
    }

    /// The duration in seconds.
    public var duration: Double { max(0, end_s - start_s) }
}

/// The result of comparing two estimators' notes.
///
/// The headline number is `disagreementRate` (1 − `agreementF1`): the share of
/// the note events the two engines do NOT agree on. It is REPORTED (in
/// BENCHMARKS and in the app's honesty surfaces), never used to filter.
public struct TranscriptionCrossCheckReport: Equatable, Sendable {
    /// How many notes the reference (SwiftF0) produced.
    public var referenceCount: Int
    /// How many notes the hypothesis (basic-pitch) produced.
    public var hypothesisCount: Int
    /// How many notes matched (same pitch, overlapping in time).
    public var matchedCount: Int
    /// Reference notes with no match.
    public var unmatchedReference: Int
    /// Hypothesis notes with no match.
    public var unmatchedHypothesis: Int
    /// Hypothesis notes that overlap a reference note of a DIFFERENT pitch —
    /// the classic octave artefact, counted separately because "the two
    /// engines disagree about the pitch" is a different failure from "the two
    /// engines disagree about whether there was a note".
    public var pitchMismatches: Int
    /// The median onset difference over the matched pairs, in ms.
    public var medianOnsetDeltaMs: Double?
    /// The median offset difference over the matched pairs, in ms.
    public var medianOffsetDeltaMs: Double?
    /// The share of the reference notes that were matched, [0, 1].
    public var referenceRecall: Double
    /// The share of the hypothesis notes that were matched, [0, 1].
    public var hypothesisPrecision: Double
    /// The F1 of recall and precision, [0, 1] — the AGREEMENT.
    public var agreementF1: Double
    /// `1 − agreementF1` — the headline DISAGREEMENT rate, [0, 1].
    public var disagreementRate: Double

    /// A one-line, human-readable summary (for the docs and the app).
    public var summary: String {
        String(format: "agreement F1 %.3f (disagreement %.3f) — matched %d/%d reference, %d/%d hypothesis, %d pitch mismatch(es)",
               agreementF1, disagreementRate, matchedCount, referenceCount,
               matchedCount, hypothesisCount, pitchMismatches)
    }
}

/// Compares two estimators' note sets.
public enum TranscriptionCrossCheck {

    /// The matching rule.
    public struct Options: Equatable, Sendable {
        /// The minimum overlap (as a share of the SHORTER note's duration)
        /// for two notes to be considered the same event.
        public var minimumOverlapFraction: Double
        /// How far apart two notes' pitches may be (in cents) and still count
        /// as the same pitch. 0 = the same MIDI note exactly.
        public var pitchToleranceCents: Double

        public init(minimumOverlapFraction: Double = 0.5, pitchToleranceCents: Double = 0.0) {
            self.minimumOverlapFraction = minimumOverlapFraction
            self.pitchToleranceCents = pitchToleranceCents
        }

        public static let `default` = Options()
    }

    /// Compare the reference (SwiftF0) with the hypothesis (basic-pitch).
    ///
    /// Matching is greedy one-to-one: the candidate pairs (same pitch, enough
    /// overlap) are taken in order of decreasing overlap, and each note is
    /// used at most once.
    public static func compare(reference: [CrossCheckNote],
                               hypothesis: [CrossCheckNote],
                               options: Options = .default) -> TranscriptionCrossCheckReport {
        var pairs: [(referenceIndex: Int, hypothesisIndex: Int, overlap: Double, onsetDelta: Double, offsetDelta: Double)] = []
        for (r, ref) in reference.enumerated() {
            for (h, hyp) in hypothesis.enumerated() {
                guard abs(Double(ref.midi) - Double(hyp.midi)) * 100.0 <= options.pitchToleranceCents else { continue }
                let overlap = overlapSeconds(ref, hyp)
                let shorter = min(ref.duration, hyp.duration)
                guard shorter > 0, overlap >= shorter * options.minimumOverlapFraction else { continue }
                pairs.append((r, h, overlap,
                              (hyp.start_s - ref.start_s) * 1000.0,
                              (hyp.end_s - ref.end_s) * 1000.0))
            }
        }
        pairs.sort { lhs, rhs in
            lhs.overlap == rhs.overlap ? lhs.referenceIndex < rhs.referenceIndex : lhs.overlap > rhs.overlap
        }

        var usedReference = Set<Int>()
        var usedHypothesis = Set<Int>()
        var onsets: [Double] = []
        var offsets: [Double] = []
        for pair in pairs {
            guard !usedReference.contains(pair.referenceIndex), !usedHypothesis.contains(pair.hypothesisIndex) else { continue }
            usedReference.insert(pair.referenceIndex)
            usedHypothesis.insert(pair.hypothesisIndex)
            onsets.append(abs(pair.onsetDelta))
            offsets.append(abs(pair.offsetDelta))
        }

        // The pitch mismatches: an unmatched hypothesis note that overlaps a
        // reference note of a DIFFERENT pitch (the octave artefact).
        var pitchMismatches = 0
        for (h, hyp) in hypothesis.enumerated() where !usedHypothesis.contains(h) {
            for ref in reference {
                let shorter = min(ref.duration, hyp.duration)
                guard shorter > 0 else { continue }
                guard overlapSeconds(ref, hyp) >= shorter * options.minimumOverlapFraction else { continue }
                if ref.midi != hyp.midi { pitchMismatches += 1 }
                break
            }
        }

        let matched = usedReference.count
        let recall = reference.isEmpty ? 0 : Double(matched) / Double(reference.count)
        let precision = hypothesis.isEmpty ? 0 : Double(matched) / Double(hypothesis.count)
        let f1: Double
        if reference.isEmpty && hypothesis.isEmpty {
            f1 = 1.0        // nothing to disagree about
        } else if recall + precision == 0 {
            f1 = 0.0
        } else {
            f1 = 2 * recall * precision / (recall + precision)
        }

        return TranscriptionCrossCheckReport(referenceCount: reference.count,
                                             hypothesisCount: hypothesis.count,
                                             matchedCount: matched,
                                             unmatchedReference: reference.count - matched,
                                             unmatchedHypothesis: hypothesis.count - matched,
                                             pitchMismatches: pitchMismatches,
                                             medianOnsetDeltaMs: median(onsets),
                                             medianOffsetDeltaMs: median(offsets),
                                             referenceRecall: recall,
                                             hypothesisPrecision: precision,
                                             agreementF1: f1,
                                             disagreementRate: 1.0 - f1)
    }

    /// The overlap of two time spans, in seconds (0 when they do not overlap).
    static func overlapSeconds(_ lhs: CrossCheckNote, _ rhs: CrossCheckNote) -> Double {
        max(0, min(lhs.end_s, rhs.end_s) - max(lhs.start_s, rhs.start_s))
    }

    /// The median of a sample (nil for an empty sample).
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }
}
