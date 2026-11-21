import Foundation

// C-6.0 · LivePitchEngine facade (CONTRACTS.md v0.1, RATIFIED 2026-11-21 — L-102;
// implementation = P-105, PAUL lane). Two streaming pitch sources exist by
// design (D-17/D-19, PLAN R2): a CAUSAL zero-lookahead ribbon for instant
// feedback, and an ACCURATE post-hoc stream for grading. The facade makes both
// explicit and labeled; frames from either source carry engine_id/lookahead_ms.
//
// - Ribbon source: EngineCore RibbonEngine (Swift MPM, P-102) — engine_id
//   RIBBON_MPM_YIN, lookahead_ms 0, confidence = NSDF clarity (MPM has no
//   voicing decision; the optional Silero VAD gate owns the voicing fusion).
// - Grading source: SwiftF0PitchEngine (P-101) — engine_id SWIFTF0,
//   lookahead_ms 176 (C-6 contract value).
//
// Jess consumes via MockEngine (same protocol, mock tagging) TODAY; ORT-backed
// construction of the injected inferences arrives with X-008 (PitchORT).
// importAudio/separate/noteTrack stay EngineError stubs until M2 — MockEngine
// covers those UI flows (C-3 rule: never block UI work on engine work).

/// RawValues STABLE FOREVER (additive only). Persisted in PitchFrame JSON
/// (C-2.4) — renaming an engine's rawValue would orphan stored frames.
public enum PitchEngineID: String, Sendable, Codable, CaseIterable {
    case ribbonMpmYin = "RIBBON_MPM_YIN"  // D-17/D-19 v1 causal ribbon
                                          // (vendored sevagh MPM/YIN; no
                                          // training data, zero lookahead)
    case swiftf0      = "SWIFTF0"         // SwiftF0 ONNX grading-grade stream
                                          // (176 ms streaming lookahead)
    // future (additive): a clean-weights NanoPitch retrain (D-17.2) would add
    // e.g. "NANOPITCH_RETRAIN"; optional reference engines (X-601) likewise.
}

/// Additive composition over EngineAPI (C-3): an engine that exposes BOTH
/// sources with explicit identity. Implemented by Paul (P-105); Jess consumes
/// via MockEngine conforming to the same protocol. Threading semantics of
/// ribbonFrame mirror EngineAPI.livePitch (synchronous, audio-safe).
public protocol LivePitchEngine: EngineAPI {
    /// The causal ribbon source: engine_id == RIBBON_MPM_YIN, lookahead_ms == 0.
    var ribbonSource: PitchEngineID { get }
    /// The accurate grading source: engine_id == SWIFTF0, lookahead_ms == 176.
    var gradingSource: PitchEngineID { get }

    /// One live frame from the ribbon source (causal, zero-lookahead).
    /// Returned frame MUST carry engine_id == ribbonSource, lookahead_ms == 0.
    func ribbonFrame(_ chunk: MicChunk) -> PitchFrame

    /// Grading-grade frames over a decoded buffer (post-hoc, band-limited).
    /// Same frame semantics as EngineAPI.pitchFrames; returned frames MUST
    /// carry engine_id == gradingSource and that source's lookahead_ms.
    func gradingFrames(_ audio: DecodedAudio, fmin_hz: Double, fmax_hz: Double)
        async throws -> PitchFrameStream
}

/// Default LivePitchEngine (P-105): real ribbon + injected SwiftF0 inference
/// + optional Silero VAD gating. Portable Foundation only (Linux-testable);
/// the ORT-backed inferences are injected by the Apple-only PitchORT package
/// (X-008). One instance per live session; `reset()` on interruption.
///
/// Live-path semantics (documented, C-6-compliant):
/// - `ribbonFrame` returns the LAST frame emitted by the ribbon for this push.
///   Sub-hop chunks (fewer than 256 new samples) emit no ribbon estimate; the
///   facade returns the previous frame unchanged (sticky — the UI cursor holds)
///   or an unvoiced frame when nothing has been emitted yet.
/// - Frames are timestamped on the ribbon's own 16 ms hop grid (seconds from
///   session start), matching the C-2.4 live grid. `MicChunk.captureTime_s` is
///   only used for the pre-first-frame unvoiced placeholder.
/// - VAD fusion (when a `SileroVADInference` is injected): gate CLOSED forces
///   `hz = 0` while confidence keeps the ribbon clarity — the deviation UI can
///   still show how certain the ribbon was. VAD errors fail OPEN (a broken VAD
///   must never kill the ribbon); the gate is per-instance state.
/// - Non-16 kHz chunks violate the C-3 MicChunk contract; defensively the
///   engine is left untouched and an unvoiced frame is returned.
public final class LivePitchFacade: LivePitchEngine, @unchecked Sendable {

    /// C-6.0: SWIFTF0's streaming lookahead in ms (contract constant).
    public static let gradingLookaheadMs = 176

    /// C-6.0 raw values as PitchFrame.engine_id strings.
    public var ribbonSource: PitchEngineID { .ribbonMpmYin }
    public var gradingSource: PitchEngineID { .swiftf0 }

    private let lock = NSLock()
    private let ribbon: RibbonEngine
    private let swiftf0: SwiftF0PitchEngine
    private let vad: SileroVADStream?
    private var gate = VADGate()
    private var lastRibbonFrame: PitchFrame?

    /// - Parameters:
    ///   - swiftf0Inference: neural seam for the grading source (ORT-backed via
    ///     PitchORT/X-008; deterministic mocks are fine for tests/previews).
    ///   - vadInference: optional Silero seam; `nil` = no gating (all ribbon
    ///     frames pass through, clarity-only confidence).
    public init(swiftf0Inference: any SwiftF0Inference,
                vadInference: (any SileroVADInference)? = nil) {
        self.ribbon = RibbonEngine()
        self.swiftf0 = SwiftF0PitchEngine(inference: swiftf0Inference)
        self.vad = vadInference.map { SileroVADStream(inference: $0) }
    }

    /// Causal ribbon path (EngineAPI.livePitch + C-6 ribbonFrame). Audio-safe:
    /// short critical section, no I/O, deterministic cost per sample.
    public func ribbonFrame(_ chunk: MicChunk) -> PitchFrame {
        let ribbonID = PitchEngineID.ribbonMpmYin.rawValue
        guard chunk.sampleRate == RibbonSpec.sampleRate else {
            // C-3 says MicChunk is 16 kHz mono. Never feed the state machine
            // foreign-rate audio; answer unvoiced (defensive, documented).
            return PitchFrame(t: max(0, chunk.captureTime_s), hz: 0, confidence: 0,
                              loudness_db: -120, engine_id: ribbonID, lookahead_ms: 0)
        }

        lock.lock()
        defer { lock.unlock() }

        // 1) Optional VAD gating (fail-open on inference errors).
        var gateOpen = true
        if let vad {
            do {
                for prob in try vad.push(chunk.samples) {
                    gateOpen = gate.observe(prob: prob)
                }
            } catch {
                gateOpen = true // fail OPEN — documented in the class docs
            }
        }

        // 2) Ribbon estimate over the new samples (causal, zero lookahead).
        let loudness = Self.dbfs(chunk.samples)
        let frames = ribbon.push(chunk.samples)
        if let rf = frames.last {
            var f = PitchFrame(t: rf.t, hz: rf.hz, confidence: rf.clarity,
                               loudness_db: loudness,
                               engine_id: ribbonID, lookahead_ms: 0)
            if !gateOpen { f.hz = 0 } // gate closed ⇒ hz=0, confidence=clarity
            lastRibbonFrame = f
            return f
        }
        // 3) Sub-hop push: sticky previous frame (or the first-chunk placeholder).
        if let last = lastRibbonFrame { return last }
        return PitchFrame(t: max(0, chunk.captureTime_s), hz: 0, confidence: 0,
                          loudness_db: loudness, engine_id: ribbonID, lookahead_ms: 0)
    }

    /// Grading-grade stream (C-6): SwiftF0 over the decoded mix, tagged with
    /// engine_id SWIFTF0 + lookahead_ms 176. Band-limited by fmin_hz/fmax_hz
    /// (C-6.1 calibrated bands feed this from Jess's lane).
    public func gradingFrames(_ audio: DecodedAudio, fmin_hz: Double, fmax_hz: Double) async throws -> PitchFrameStream {
        guard fmin_hz >= 0, fmin_hz < fmax_hz else {
            throw EngineError.contractViolation(
                "gradingFrames: require 0 <= fmin_hz < fmax_hz (got \(fmin_hz), \(fmax_hz))")
        }
        let wav: PCMWaveReader.Content
        do {
            wav = try PCMWaveReader.read(url: audio.url)
        } catch {
            // Portable decode = RIFF WAV (PCM16/float32); compressed decodes
            // arrive with the Apple layer (P-203). Honest error, no silent fallback.
            throw EngineError.unsupportedFormat("grading source decode: \(error)")
        }
        let detected = try swiftf0.detect(samples: wav.samples, sampleRate: wav.sampleRate,
                                          fmin: fmin_hz, fmax: fmax_hz)
        let tagged = detected.map { frame -> PitchFrame in
            var f = frame.contractPitchFrame
            f.engine_id = PitchEngineID.swiftf0.rawValue
            f.lookahead_ms = Self.gradingLookaheadMs
            return f
        }
        return PitchFrameStream(AsyncStream<PitchFrame>(bufferingPolicy: .unbounded) { continuation in
            for frame in tagged {
                if Task.isCancelled { break }
                continuation.yield(frame)
            }
            continuation.finish()
        })
    }

    /// Interruption reset (call on phone call, route change, session restart):
    /// clears ribbon history/context, the VAD gate state, and the sticky frame.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        ribbon.reset()
        vad?.reset()
        gate = VADGate()
        lastRibbonFrame = nil
    }

    // MARK: - EngineAPI (C-3)

    public func importAudio(url: URL) async throws -> DecodedAudio {
        // M2 scope (P-203 real decode + BLAKE3). MockEngine covers UI flows.
        throw EngineError.importFailed("LivePitchFacade: importAudio arrives with the M2 engine (P-203)")
    }

    public func separate(_ audio: DecodedAudio, mode: SeparationMode) async throws -> [Part: URL] {
        // M2 scope (P-204 separation). MockEngine covers UI flows until then.
        throw EngineError.separationFailed("LivePitchFacade: separation arrives with the M2 engine (P-204)")
    }

    public func pitchFrames(_ audio: DecodedAudio, fmin: Double, fmax: Double) async throws -> PitchFrameStream {
        // The batch pitch track IS the grading-grade stream (tagged SWIFTF0/176).
        try await gradingFrames(audio, fmin_hz: fmin, fmax_hz: fmax)
    }

    public func noteTrack(_ source: NoteSource, part: Part) async throws -> NoteTrack {
        // M2/M3 scope (stem-based note tracking). MockEngine covers UI flows.
        throw EngineError.separationFailed("LivePitchFacade: noteTrack arrives with the M2/M3 engine (stems + basicpitch)")
    }

    public func livePitch(_ chunk: MicChunk) -> PitchFrame {
        // C-3 live path = the causal ribbon source.
        ribbonFrame(chunk)
    }

    // MARK: - Helpers

    /// RMS dBFS of a chunk, clamped to [-120, 0]. Silence → -120.
    static func dbfs(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -120 }
        return min(0, max(-120, 20.0 * log10(rms)))
    }
}
