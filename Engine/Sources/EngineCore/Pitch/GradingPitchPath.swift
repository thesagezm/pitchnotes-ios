import Foundation

// P-401 · The grading-grade pitch path — the ACCURATE SwiftF0 stream for
// scoring, the causal ribbon for live feedback, and the bundle-timeline
// alignment that makes session grading reproducible (CONTRACTS v1.2 C-20 §4).
//
// THE TWO-ESTIMATOR RULE (restated where it bites — D-7/D-22):
//   · GRADING reads ONLY `GradingPitchBatch` — the post-hoc SwiftF0 batch
//     (176 ms lookahead is FINE post-hoc; the batch sees the whole session).
//   · THE LIVE RIBBON keeps the causal engine (RibbonEngine, D-7) and NEVER
//     feeds a grade: its frames are window-end causal estimates for the
//     ribbon UI, absorbed into the live path's END-TO-END latency that
//     J-403's loopback calibration measures. No batch/ribbon compensation is
//     invented here — the calibration is measured, not modelled.
//
// THE BUNDLE TIMELINE (the alignment AC, stated honestly): the batch's t=0
// IS the bundle timeline's t=0 BY CONSTRUCTION — the caller decodes the SAME
// staged audio whose decoded clock wrote `song.json`'s `duration_s` and from
// which the separator cut the stems (C-2). No offset is applied or invented
// in this file; the P-203 MP3 padding finding (decoded duration up to
// ~51 ms longer than ffmpeg's) is uniform across mix, stems and manifest —
// one clock, three consumers. The ONE offset that DOES apply to a session is
// J-403's measured loopback latency, consumed below exactly as C-20 §4 pins
// it (≥ 0 = live is LATE; compare live t against reference t − offset).
//
// PORTABILITY (AGENTS §0): the caller hands in decoded MONO samples —
// AVFoundation (ALAC stems) stays in the app/ImportKit layer; this file is
// Foundation-only and Linux-tested.

/// WHICH audio the grading batch consumed (the bundle timeline's provenance —
/// reported to the session so a grade is reproducible, C-18's determinism).
public enum GradingPitchSource: Equatable, Sendable {
    /// The bundle's decoded mix (the default grading source).
    case mix(URL)
    /// One part's stem (the focus-mix grading variant).
    case stem(part: Part, url: URL)

    /// The provenance label a session record carries.
    public var label: String {
        switch self {
        case .mix(let url): return "mix:\(url.lastPathComponent)"
        case .stem(let part, let url): return "stem:\(part.rawValue):\(url.lastPathComponent)"
        }
    }
}

/// The session's grading pitch batch: the SwiftF0 frames on the C-2.4 grid
/// (16 ms, `frames[i].t == i × 0.016`), aligned to the bundle timeline.
///
/// THE GRADER READS THIS, NEVER THE RIBBON (the two-estimator rule above).
public struct GradingPitchBatch: Sendable, Equatable {

    /// The batch estimator's identity (the grading path's reported origin —
    /// distinct from the ribbon's `RIBBON_*` engines, C-6.0).
    public static let estimatorID = "SWIFTF0-BATCH"

    /// The frames, on the C-2.4 grid.
    public let frames: [PitchFrame]

    /// Which audio the batch consumed.
    public let source: GradingPitchSource

    /// The audio's duration (bundle seconds — the manifest clock's value).
    public let duration_s: Double

    public init(frames: [PitchFrame], source: GradingPitchSource, duration_s: Double) throws {
        // GRID INTEGRITY (C-2.4): the batch is the grader's reference clock —
        // a frame off the grid is a contract violation, never silently kept.
        for (index, frame) in frames.enumerated() {
            let expected = Double(index) * EngineContract.hopSeconds
            guard abs(frame.t - expected) < 1e-9 else {
                throw EngineError.contractViolation(
                    "GradingPitchBatch: frame \(index) is off the C-2.4 grid (\(frame.t) ≠ \(expected))")
            }
        }
        self.frames = frames
        self.source = source
        self.duration_s = duration_s
    }

    /// Build the batch over DECODED MONO samples (any source rate — resampled
    /// to SwiftF0's 16 kHz internally by `SwiftF0PitchEngine.detect`). The
    /// samples' t=0 is the bundle timeline's t=0 (see the file header).
    /// Deterministic: the same samples and the same inference produce a
    /// byte-equal batch (the S-rules).
    public static func build(samples: [Float], sampleRate: Int,
                             source: GradingPitchSource,
                             inference: any SwiftF0Inference,
                             band: SwiftF0Band? = nil) throws -> GradingPitchBatch {
        guard sampleRate > 0 else {
            throw EngineError.contractViolation("GradingPitchBatch: sampleRate must be positive")
        }
        let engine = SwiftF0PitchEngine(inference: inference)
        let frames = try engine.detectContractFrames(
            samples: samples, sampleRate: sampleRate,
            fmin: band?.fmin, fmax: band?.fmax)
        let duration = Double(samples.count) / Double(sampleRate)
        return try GradingPitchBatch(frames: frames, source: source, duration_s: duration)
    }

    /// THE GRADER'S COMPARISON (C-20 §4, the pinned sign): the batch frames a
    /// LIVE frame captured at bundle time `liveTime_s` grades against,
    /// computed against the reference time `liveTime_s − latencyOffset_ms/1000`
    /// and returned within `tolerance_s` (default 50 ms — the C-5 tolerance's
    /// own scale). Empty when nothing voiced is nearby — the caller treats
    /// that as `noLiveFrames`/`notAssessable`, never as a miss.
    public func frames(forLiveTime liveTime_s: Double,
                       latencyOffset_ms: Double,
                       tolerance_s: Double = 0.05) -> [PitchFrame] {
        // C-20 §4: latencyOffset_ms ≥ 0 = the live path is LATE, so the live
        // frame at t compares against the EARLIER reference at t − offset.
        let referenceTime = liveTime_s - latencyOffset_ms / 1000.0
        return frames(nearReferenceTime: referenceTime, tolerance_s: tolerance_s)
    }

    /// The batch frames near a reference time (the C-20 §4 comparison already
    /// applied — for graders that mapped the time themselves through
    /// `PlaybackTransform`).
    public func frames(nearReferenceTime referenceTime_s: Double,
                       tolerance_s: Double = 0.05) -> [PitchFrame] {
        guard !frames.isEmpty else { return [] }
        let hop = EngineContract.hopSeconds
        let lower = referenceTime_s - tolerance_s
        let upper = referenceTime_s + tolerance_s
        var start = Int((lower / hop).rounded(.down))
        var end = Int((upper / hop).rounded(.up))
        start = max(0, start)
        end = min(frames.count, end)
        guard start < end else { return [] }
        return Array(frames[start..<end])
    }

    /// The first voiced frame's time (the onset the alignment tests measure
    /// against the ribbon's — the estimator-bias measurement).
    public var firstVoicedTime: Double? {
        frames.first { $0.confidence >= SwiftF0Spec.voicedThreshold && $0.hz > 0 }?.t
    }
}
