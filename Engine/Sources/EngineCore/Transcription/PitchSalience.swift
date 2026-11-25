import Foundation

// P-302 · Multi-f0 salience — per-frame pitch candidates + their salience
// (PAUL lane).
//
// WHAT THIS IS: the basic-pitch model emits a `notes` tensor of shape
// [time][88] — for every ~11.6 ms frame, a value per pitch bin (bin 0 = MIDI
// 21 … bin 87 = MIDI 108). That tensor is the model's multi-f0 posterior: at
// a frame where four voices sing, FOUR bins carry energy. P-301 consumed only
// the DECODED note events (the vendor's peak-picking + melodia pass); this
// file exposes the posterior itself, which is what the voice assignment
// (P-303) and the score alignment (P-304) need.
//
// HONESTY (AGENTS §11): the tensor value is the model's posterior strength,
// NOT a calibrated probability. It is reported as `salience` (C-10.0's OPTIONAL
// per-note field) and is NEVER used to silently drop a note (C-12: salience is
// a DISPLAY/ANALYSIS hint; absent ⇒ behave exactly as before v1.1).
//
// PORTABILITY: Foundation-only, no ONNX / C++ / AVFoundation. The sibling
// ports (Android/Linux) reuse this file unchanged (AGENTS §0).

// MARK: - The frame clock (the corrected frame → seconds mapping)

/// The frame-domain clock of the vendored basic-pitch pipeline.
///
/// WHY THIS EXISTS (and why it is NOT `frame * 256 / 22050`): the vendor
/// concatenates the model's per-chunk outputs CHUNK-MAJOR and trims 15 frames
/// at each end of every chunk, while the chunks themselves advance by only
/// `hop` samples. The concatenated frame grid therefore DRIFTS against the
/// audio: 188 samples (8.5 ms — one frame is 256 samples) per chunk, i.e.
/// ~5.2 ms per second of audio. On a 4-minute song the naive mapping puts the
/// tail ~1.25 s late.
///
/// The mapping below reconstructs the chunk each frame came from and is
/// EXACT for the whole song. It is a faithful port of
/// `Engine/Transcription/BasicPitchNotes.hpp` (`frameToSeconds`) — the SAME
/// header the app's C++ bridge uses, so the Swift side and the C++ side agree
/// by construction. `EngineCoreFrameClockParityTests` pins the values against
/// the header's own numbers.
public enum BasicPitchFrameClock {
    /// The model's native sample rate.
    public static let sampleRate: Double = 22050
    /// The model's FFT hop (samples per annotation frame).
    public static let frameHop: Int = 256
    /// `AUDIO_N_SAMPLES` — the model's input window (2 s minus one hop).
    public static let chunkSamples: Int = 43844
    /// `n_overlapping_frames` — the frames the vendor trims at each chunk end.
    public static let overlapFrames: Int = 30
    /// The overlap in SAMPLES (30 frames × 256).
    public static let overlapSamples: Int = overlapFrames * frameHop
    /// How far the chunks advance (the window minus the overlap).
    public static let chunkHop: Int = chunkSamples - overlapSamples
    /// The model's output frames per chunk.
    public static let modelFramesPerChunk: Int = 172
    /// The frames the vendor KEEPS per chunk (172 − 30).
    public static let trimmedFramesPerChunk: Int = modelFramesPerChunk - overlapFrames

    /// The frame index → seconds mapping (chunk-aware, exact).
    ///
    /// A frame index `frame` belongs to chunk `frame / trimmedFramesPerChunk`;
    /// within that chunk it is `frame % trimmedFramesPerChunk`, and the
    /// chunk's first kept frame sits at `chunk * chunkHop` samples of the
    /// ORIGINAL audio.
    public static func seconds(forFrame frame: Int) -> Double {
        let chunk = frame / trimmedFramesPerChunk
        let within = frame % trimmedFramesPerChunk
        let sample = chunk * chunkHop + within * frameHop
        return Double(sample) / sampleRate
    }

    /// The inverse mapping (seconds → the frame whose START is nearest).
    /// Used by the alignment (P-304) to map a score time back onto the
    /// salience grid. Nearest-frame, not interpolated: the grid is the
    /// model's own, and inventing a fractional frame would claim a precision
    /// the engine does not have.
    public static func frame(forSeconds seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        // Invert the chunk-aware mapping: find the chunk whose start is the
        // last one at or before the requested sample.
        let sample = seconds * sampleRate
        var chunk = 0
        while Double((chunk + 1) * chunkHop) <= sample {
            chunk += 1
        }
        let sampleInChunk = sample - Double(chunk * chunkHop)
        let within = Int((sampleInChunk / Double(frameHop)).rounded())
        let frame = chunk * trimmedFramesPerChunk + within
        return max(0, frame)
    }
}

// MARK: - The salience table

/// The model's per-frame multi-f0 posterior: `[frame][pitch bin]`.
///
/// The bin index is `midi - 21` (the vendor's `MIDI_OFFSET`), so bin 0 is
/// MIDI 21 (A0) and bin 87 is MIDI 108 (C8) — the piano's 88 keys.
public struct PitchSalienceTable: Equatable, Sendable {
    /// The number of pitch bins (88 piano keys).
    public static let binCount = 88
    /// The MIDI number of bin 0.
    public static let lowestMidi = 21

    /// One row per frame, 88 values per row.
    public let frames: [[Double]]

    public init(frames: [[Double]]) {
        self.frames = frames
    }

    public var frameCount: Int { frames.count }

    /// The salience of one pitch at one frame (0 when out of range).
    public func salience(frame: Int, midi: Int) -> Double {
        guard frame >= 0, frame < frames.count else { return 0 }
        let bin = midi - Self.lowestMidi
        guard bin >= 0, bin < Self.binCount else { return 0 }
        let row = frames[frame]
        guard bin < row.count else { return 0 }
        return row[bin]
    }

    /// Build a table from a flat row-major buffer (`frameCount × 88`), which is
    /// the layout the C++ bridge hands over (and the layout the `notes.f32`
    /// dump uses).
    public init(flat: [Double], frameCount: Int) {
        var rows: [[Double]] = []
        rows.reserveCapacity(max(0, frameCount))
        for f in 0..<max(0, frameCount) {
            let start = f * Self.binCount
            let end = min(start + Self.binCount, flat.count)
            rows.append(start < flat.count ? Array(flat[start..<end]) : [])
        }
        self.frames = rows
    }
}

// MARK: - Candidates

/// One pitch candidate at one frame, with its salience.
public struct SalienceCandidate: Equatable, Sendable {
    /// The frame index in the salience grid.
    public var frameIndex: Int
    /// The frame's time in seconds (the chunk-aware clock).
    public var time: Double
    /// The MIDI note number.
    public var midi: Int
    /// The model's posterior strength at this frame, in [0, 1].
    public var salience: Double

    public init(frameIndex: Int, time: Double, midi: Int, salience: Double) {
        self.frameIndex = frameIndex
        self.time = time
        self.midi = midi
        self.salience = salience
    }
}

/// The peak-picking knobs. Every one is a named constant so the benchmark
/// report can name the exact configuration that produced a number (P-306's
/// honesty gate).
public struct SaliencePeakOptions: Equatable, Sendable {
    /// A frame/pitch below this salience is not a candidate. The default is the
    /// vendored pipeline's own `FRAME_THRESHOLD` (0.3) — the bar the vendor
    /// uses to decide "this note is still sounding".
    public var minimumSalience: Double
    /// A candidate must be the strict local maximum within ± this many
    /// semitones. 2 is the default: it suppresses the neighbouring bins of one
    /// voice's fundamental without erasing a genuine semitone neighbour.
    public var localMaxWindowSemitones: Int
    /// Two candidates of the SAME pitch closer than this (in frames) collapse
    /// into the stronger one. 1 frame = one grid step (~11.6 ms).
    public var minimumPeakSpacingFrames: Int

    public init(minimumSalience: Double = 0.30,
                localMaxWindowSemitones: Int = 2,
                minimumPeakSpacingFrames: Int = 1) {
        self.minimumSalience = minimumSalience
        self.localMaxWindowSemitones = localMaxWindowSemitones
        self.minimumPeakSpacingFrames = minimumPeakSpacingFrames
    }

    public static let `default` = SaliencePeakOptions()
}

/// The per-frame candidates and the pitch TRACKS they form.
public enum MultiFOSalience {

    /// Pick the per-frame pitch candidates out of the salience table.
    ///
    /// A candidate is a (frame, pitch) pair whose salience is at least
    /// `minimumSalience` AND which is the strict local maximum within
    /// ± `localMaxWindowSemitones` semitones. The candidates of one frame are
    /// returned strongest-first (a stable tie-break by MIDI number keeps the
    /// output deterministic).
    public static func candidates(in table: PitchSalienceTable,
                                  options: SaliencePeakOptions = .default) -> [[SalienceCandidate]] {
        var result: [[SalienceCandidate]] = []
        result.reserveCapacity(table.frameCount)
        for frame in 0..<table.frameCount {
            var found: [SalienceCandidate] = []
            for midi in PitchSalienceTable.lowestMidi..<(PitchSalienceTable.lowestMidi + PitchSalienceTable.binCount) {
                let value = table.salience(frame: frame, midi: midi)
                guard value >= options.minimumSalience else { continue }
                guard isLocalMaximum(table: table, frame: frame, midi: midi,
                                     window: options.localMaxWindowSemitones) else { continue }
                found.append(SalienceCandidate(frameIndex: frame,
                                               time: BasicPitchFrameClock.seconds(forFrame: frame),
                                               midi: midi,
                                               salience: value))
            }
            found.sort { lhs, rhs in
                lhs.salience == rhs.salience ? lhs.midi < rhs.midi : lhs.salience > rhs.salience
            }
            result.append(found)
        }
        return result
    }

    /// Build the per-pitch TRACKS (a candidate run of the same pitch),
    /// including the mean salience over the run.
    ///
    /// A run continues while the same pitch is a candidate in the next frame.
    /// A gap of up to `maximumGapFrames` frames is bridged (a single dropped
    /// frame is a model wobble, not a note ending); a longer gap ends the run.
    public static func tracks(in table: PitchSalienceTable,
                              options: SaliencePeakOptions = .default,
                              maximumGapFrames: Int = 2) -> [PitchSalienceTrack] {
        let perFrame = candidates(in: table, options: options)
        var open: [Int: PitchSalienceTrack] = [:]
        var finished: [PitchSalienceTrack] = []

        for (frame, frameCandidates) in perFrame.enumerated() {
            let pitches = Set(frameCandidates.map { $0.midi })
            // Close the runs whose pitch is absent (after the allowed gap).
            for midi in Array(open.keys) {
                guard !pitches.contains(midi) else { continue }
                let track = open[midi]!
                if frame - track.lastFrameIndex > maximumGapFrames {
                    finished.append(track)
                    open.removeValue(forKey: midi)
                }
            }
            for candidate in frameCandidates {
                if var track = open[candidate.midi] {
                    track.append(candidate)
                    open[candidate.midi] = track
                } else {
                    open[candidate.midi] = PitchSalienceTrack(midi: candidate.midi,
                                                              firstFrameIndex: candidate.frameIndex)
                    open[candidate.midi]!.append(candidate)
                }
            }
        }
        finished.append(contentsOf: open.values)
        return finished.sorted { lhs, rhs in
            lhs.startTime == rhs.startTime ? lhs.midi < rhs.midi : lhs.startTime < rhs.startTime
        }
    }

    /// Is the salience at (frame, midi) the strict local maximum within
    /// ± `window` semitones? Ties go to the LOWER pitch (a stable,
    /// deterministic tie-break).
    private static func isLocalMaximum(table: PitchSalienceTable,
                                       frame: Int,
                                       midi: Int,
                                       window: Int) -> Bool {
        let value = table.salience(frame: frame, midi: midi)
        for neighbour in (midi - window)...(midi + window) where neighbour != midi {
            guard neighbour >= PitchSalienceTable.lowestMidi,
                  neighbour < PitchSalienceTable.lowestMidi + PitchSalienceTable.binCount
            else { continue }
            let other = table.salience(frame: frame, midi: neighbour)
            if other > value { return false }
            if other == value && neighbour < midi { return false }
        }
        return true
    }
}

/// A run of one pitch through the salience grid — the multi-f0 "track" before
/// the voice assignment (P-303) decides WHICH part sings it.
public struct PitchSalienceTrack: Equatable, Sendable {
    /// The MIDI note number.
    public var midi: Int
    /// The first frame of the run.
    public var firstFrameIndex: Int
    /// The last frame of the run.
    public var lastFrameIndex: Int
    /// The salience values of the run.
    public var saliences: [Double]

    public init(midi: Int, firstFrameIndex: Int, saliences: [Double] = []) {
        self.midi = midi
        self.firstFrameIndex = firstFrameIndex
        self.lastFrameIndex = firstFrameIndex
        self.saliences = saliences
    }

    /// The run's start time (the chunk-aware clock).
    public var startTime: Double { BasicPitchFrameClock.seconds(forFrame: firstFrameIndex) }
    /// The run's end time (the chunk-aware clock; half-open — the last frame's
    /// slot belongs to the next frame).
    public var endTime: Double { BasicPitchFrameClock.seconds(forFrame: lastFrameIndex + 1) }
    /// The duration in seconds.
    public var duration: Double { max(0, endTime - startTime) }
    /// The mean salience over the run.
    public var meanSalience: Double {
        guard !saliences.isEmpty else { return 0 }
        return saliences.reduce(0, +) / Double(saliences.count)
    }
    /// The strongest salience in the run.
    public var peakSalience: Double { saliences.max() ?? 0 }

    /// Extend the run with another candidate of the same pitch.
    mutating func append(_ candidate: SalienceCandidate) {
        saliences.append(candidate.salience)
        lastFrameIndex = candidate.frameIndex
    }
}
