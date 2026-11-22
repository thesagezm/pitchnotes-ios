import Foundation
import EngineCore
import DemucsShim

// DemucsEngine (P-201, PAUL lane) — Swift bridge over the vendored
// sevagh/demucs.cpp library (vendor/demucs.cpp, MIT, D-30 Tier A code) via the
// C-ABI seam (DemucsShim.h/.cpp, same directory). Weights = htdemucs fp16
// ggml, TIER B per D-30 (MIT © Meta; MUSDB18 CC BY-NC-SA training-data risk
// recorded — human sign-off before any commercial distribution, NEVER called
// "clean"; provenance chain D-32.6: Meta .th @e976d93e → pinned converter →
// HF mirror, sha256 trust anchor).
//
// Wiring (Leto X-task — intake README "Build notes for P-201"): project.yml
// app target compiles this file + DemucsShim.cpp + vendor/demucs.cpp/src/*.cpp
// with header search paths Engine/Separation, vendor/demucs.cpp/src,
// vendor/demucs.cpp/third_party/eigen; SWIFT_INCLUDE_PATHS gains
// Engine/Separation so `import DemucsShim` resolves the module.modulemap.
// NOT part of the EngineCore package (it links C++ — the portable core stays
// clean per AGENTS §0); portable pieces (DemucsOutputMapper, PCMWavWriter,
// PCMWaveReader) live in EngineCore and are Linux-tested.
//
// Scope honesty (M2):
//  - `separate` runs the REAL 4-source htdemucs inference and composes the
//    C-1 two-stem pair (vocals = target_3, instrumental = drums+bass+other
//    residual — D-9). Stems stage as PCM16 WAV; ALAC encode + bundle
//    assembly = P-204.
//  - `importAudio` decodes WAV via EngineCore.PCMWaveReader only; MP3/FLAC
//    decode (AVFoundation/ExtAudioFile) = P-203.
//  - `multiStem` mode throws — per-voice stems need the M3 assignment work
//    (P-301 path); the 4-source run exists for the residual instrumental,
//    not as multi-stem output.
//  - `livePitch` returns the unvoiced frame — separation has no live path.
//  - `pitchFrames` returns an empty (immediately-finished) stream — no batch
//    pitch path in the separation engine; SwiftF0/PitchORT is the pitch engine.
//  - Cancellation is checked before/after the (uninterruptible) vendor
//    inference call; segment-boundary cancellation arrives with P-202's
//    chunked driver (which will also own the abort-flag vendor patch).
public final class DemucsEngine: ProgressReportingEngine, @unchecked Sendable {

    public enum EngineState: Error, Sendable {
        case modelNotLoaded
        case inferenceFailed(Int32)
        case cancelled
    }

    private let modelPath: URL
    private let lock = NSLock()
    private var handle: OpaquePointer? // demucs_shim_model*
    private let emitter = ImportProgressEmitter()

    /// Thread count for the D-32.4 vendor threading patch (1 = stock behavior).
    public var threads: Int32 {
        didSet { demucs_shim_set_threads(threads) }
    }

    /// - Parameter modelPath: ggml fp16 htdemucs weights
    ///   (ggml-model-htdemucs-4s-f16.bin; downloaded once + sha256-verified,
    ///   never committed to git).
    public init(modelPath: URL, threads: Int32 = 1) {
        self.modelPath = modelPath
        self.threads = threads
        demucs_shim_set_threads(threads)
    }

    deinit {
        if let handle { demucs_shim_free(handle) }
    }

    public func setImportProgressHandler(_ handler: ImportProgressHandler?) {
        emitter.setHandler(handler)
    }

    // MARK: - Model lifecycle

    /// Loads the ggml weights (dequantize to fp32 Eigen tensors, ~84 MB).
    /// Called lazily by `separate`; safe to call repeatedly (no-op when held).
    public func loadModelIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { return }
        // C enum constants import as `demucs_shim_status`; the shim's out-param
        // is int32_t* — hand it the rawValue (Xcode 26 import semantics).
        var status = DEMUCS_SHIM_ERR_LOAD.rawValue
        guard let h = modelPath.path.withCString({ p in
            demucs_shim_load(p, &status)
        }) else {
            throw EngineError.modelMissing(
                "demucs ggml load failed (status \(status)) at \(modelPath.path)")
        }
        handle = h
    }

    // MARK: - EngineAPI (C-3)

    /// WAV-only decode until P-203 brings the AVFoundation seam (MP3/FLAC).
    /// Input must be 44.1 kHz (D-8 SR policy) — resampling policy lands with
    /// P-203 via AVAudioConverter (never resample STORED audio for tuning — D-22).
    public func importAudio(url: URL) async throws -> DecodedAudio {
        let content = try PCMWaveReader.read(url: url)
        guard content.sampleRate == 44100 else {
            throw EngineError.unsupportedFormat(
                "sample rate \(content.sampleRate) ≠ 44100 (D-8); resampling decode lands with P-203")
        }
        let duration = Double(content.samples.count) / Double(content.sampleRate)
        return DecodedAudio(url: url, sampleRate: content.sampleRate,
                            channels: content.channels, duration_s: duration)
    }

    /// Real separation (htdemucs fp16, one 4-source pass per song). Reports
    /// C-8 `separating` progress driven by the vendor callback (monotonic via
    /// ImportProgressEmitter). Throws on cancellation BEFORE/AFTER the vendor
    /// call; mid-inference abort = P-202 (vendor abort-flag patch).
    public func separate(_ audio: DecodedAudio, mode: SeparationMode) async throws -> [Part: URL] {
        guard mode == .twoStem else {
            // Honest M2: per-voice stems are the M3 assignment path (P-301).
            throw EngineError.contractViolation(
                "multiStem mode not available in M2 (vocals+instrumental only per D-9)")
        }
        try Task.checkCancellation()
        try loadModelIfNeeded()

        let content = try PCMWaveReader.read(url: audio.url)
        guard content.sampleRate == 44100 else {
            throw EngineError.unsupportedFormat(
                "separate input must be the decoded 44.1 kHz mix (got \(content.sampleRate))")
        }

        // Interleave to the shim's stereo contract (mono duplicated).
        let ch = content.channels
        var interleaved = [Float]()
        interleaved.reserveCapacity(2 * content.samples.count / ch)
        for i in 0..<(content.samples.count / ch) {
            let l = content.samples[i * ch]
            let r = ch == 2 ? content.samples[i * ch + 1] : l
            interleaved.append(l)
            interleaved.append(r)
        }

        // C-8 separating progress: vendor cb → emitter (monotonic clamp);
        // reserve 0–5% for decode, 5–95% inference, 95–100% staging writes.
        emitter.emit(ImportProgress(stage: .separating, fraction: 0.05,
                                    detail: "demucs inference starting"))
        final class ProgressBox: @unchecked Sendable {
            let engine: DemucsEngine
            init(_ e: DemucsEngine) { engine = e }
        }
        let box = ProgressBox(self)
        let cb: demucs_shim_progress_cb = { fraction, detail, ctx in
            guard let ctx else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            // Map vendor [0,1] into the separating band [0.05, 0.95].
            let f = 0.05 + 0.9 * Double(max(0, min(1, fraction)))
            let d = detail.map { String(cString: $0) }
            box.engine.emitter.emit(ImportProgress(stage: .separating, fraction: f,
                                                   detail: d))
        }

        var stems: UnsafeMutablePointer<Float>?
        var outN: Int32 = 0
        let status = try interleaved.withUnsafeBufferPointer { buf in
            demucs_shim_infer(handle, buf.baseAddress, Int32(content.samples.count / ch),
                              cb, Unmanaged.passUnretained(box).toOpaque(),
                              &stems, &outN)
        }
        try Task.checkCancellation()
        guard status == DEMUCS_SHIM_OK.rawValue, let stems, outN > 0 else {
            throw EngineError.separationFailed("demucs_shim_infer status \(status)")
        }
        defer { demucs_shim_free_buffer(stems) }

        // Map → C-1 two-stem pair (portable mapper, Linux-tested).
        let raw = Array(UnsafeBufferPointer(start: stems,
                                            count: Int(demucs_shim_num_sources(handle)) * 2 * Int(outN)))
        let mapped = try DemucsOutputMapper.map(rawStems: raw, nSamples: Int(outN))

        // Stage stems (PCM16 WAV now; ALAC + bundle = P-204). D-8: voice MONO,
        // instrumental STEREO. Staging dir is removed on any failure below.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitchnotes-sep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            emitter.emit(ImportProgress(stage: .separating, fraction: 0.95,
                                        detail: "staging stems"))
            let vocalsURL = staging.appendingPathComponent("vocals.wav")
            let instrumentalURL = staging.appendingPathComponent("instrumental.wav")
            try PCMWavWriter.write(url: vocalsURL, samples: mapped.vocals.mono(),
                                   sampleRate: 44100, channels: 1)
            try PCMWavWriter.write(url: instrumentalURL, samples: mapped.instrumental.samples,
                                   sampleRate: 44100, channels: 2)
            emitter.emit(ImportProgress(stage: .separating, fraction: 1.0,
                                        detail: "separation complete"))
            return [.vocals: vocalsURL, .instrumental: instrumentalURL]
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// M3 path (P-301) — not an M2 deliverable.
    public func noteTrack(_ source: NoteSource, part: Part) async throws -> NoteTrack {
        throw EngineError.unsupportedFormat("noteTrack lands in M3 (P-301/P-303)")
    }

    /// Separation engine has no live path — always the unvoiced frame.
    /// Live input goes through LivePitchEngine (P-105) / MicCapture (P-104).
    public func livePitch(_ chunk: MicChunk) -> PitchFrame {
        PitchFrame(t: chunk.captureTime_s, hz: 0.0, confidence: 0.0,
                   loudness_db: -120.0, engine_id: "RIBBON_MPM_YIN", lookahead_ms: 0)
    }

    /// Separation engine owns no batch pitch path (SwiftF0/PitchORT is the
    /// pitch engine) — always an empty, immediately-finished stream. Mirrors
    /// the documented "livePitch returns unvoiced" M2 scope honesty.
    public func pitchFrames(_ audio: DecodedAudio, fmin: Double,
                            fmax: Double) async throws -> PitchFrameStream {
        PitchFrameStream(AsyncStream<PitchFrame> { $0.finish() })
    }
}
