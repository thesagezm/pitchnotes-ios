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
//
// P-202 L2 — chunked separation (D-25):
//  - `separate` now drives EngineCore's ChunkedSeparationDriver: the staged
//    mix is windowed, each window is inferred SEPARATELY by the vendor, and
//    the driver blends the overlaps. Memory stays bounded by the window (not
//    the song) — the §8 peak-RSS budget.
//  - This class implements `SegmentEngine` (the driver's seam).
//  - The vendor's internal segmentation (7.8 s segments, 0.25 overlap) still
//    applies PER WINDOW — a 4.5 s window therefore pays a full 7.8 s segment
//    of compute. That is the honest RTF price of external chunking and it is
//    measured in L3 (BENCHMARKS §4), not hidden.
//  - Cancellation: the driver's between-window check PLUS a mid-window abort
//    seam (demucs_shim_request_abort → the shim unwinds the vendor at its
//    next progress tick → DEMUCS_SHIM_ERR_ABORTED → CancellationError).
//  - Progress: the vendor's per-stage callback is scaled into the driver's
//    progress band (window-granular slices) — the user sees movement during
//    a long window instead of a frozen bar.
public final class DemucsEngine: ProgressReportingEngine, SegmentEngine, @unchecked Sendable {

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

    /// Chunking policy (D-25). Both arms are implemented; L3's measured
    /// benchmark picks the production default.
    public let policy: ChunkPolicy

    /// - Parameters:
    ///   - modelPath: ggml fp16 htdemucs weights (ggml-model-htdemucs-4s-f16.bin;
    ///     downloaded once + sha256-verified, never committed to git).
    ///   - threads: D-32.4 vendor thread count (1 = stock serial).
    ///   - policy: chunk window/overlap (D-25 arms: `.planDefault` 8 s/2 s,
    ///     `.muskeyRecipe` 4.5 s/1 s).
    public init(modelPath: URL, threads: Int32 = 1,
                policy: ChunkPolicy = .planDefault) {
        self.modelPath = modelPath
        self.threads = threads
        self.policy = policy
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

    /// The loaded model handle (read under the lock — `handle` is mutated by
    /// `loadModelIfNeeded`).
    private var modelHandle: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    // MARK: - EngineAPI (C-3)

    /// Legacy WAV-only decode helper. The REAL import path (MP3/FLAC/ALAC/WAV,
    /// 44.1 kHz normalization, channel policy) lives in Engine/ImportKit
    /// (AVAudioFileDecoder, P-203) and writes the staged float32 mix that
    /// `separate` reads. This method stays for the EngineAPI contract and for
    /// PCM16 WAV callers; it never resamples stored audio (D-22).
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

    /// Real separation (htdemucs fp16) over the staged 44.1 kHz mix.
    ///
    /// P-202 L2: the song is separated in WINDOWS (ChunkedSeparationDriver,
    /// D-25) instead of one whole-song vendor pass — the vendor's per-window
    /// call is the same shim call as before, only bounded in length, so the
    /// peak memory no longer scales with the song.
    ///
    /// Progress (C-8): the driver owns the `separating` band [0.05, 0.90];
    /// staging the stems uses 0.95; 1.0 is emitted ONLY after both stems are
    /// on disk (the driver is told not to emit its own completion).
    ///
    /// Cancellation (C-8): the driver checks between windows; the vendor call
    /// itself aborts through the shim's abort seam (one encoder stage of
    /// latency). On cancel/error the staging directory is removed — no partial
    /// bundle ever survives (C-2.2).
    public func separate(_ audio: DecodedAudio, mode: SeparationMode) async throws -> [Part: URL] {
        guard mode == .twoStem else {
            // Honest M2: per-voice stems are the M3 assignment path (P-301).
            throw EngineError.contractViolation(
                "multiStem mode not available in M2 (vocals+instrumental only per D-9)")
        }
        return try await separateStagedMix(audio) { [emitter] p in emitter.emit(p) }
    }

    /// The separation core with an INJECTED progress sink.
    ///
    /// The C-8 `separate(_:mode:)` above routes progress through this
    /// engine's own emitter (the app's handler). The import path (P-204)
    /// needs the progress to reach the ORCHESTRATOR instead, without
    /// hijacking the app's C-8 handler — hence this overload: the same
    /// driver, the same staging discipline, a different sink.
    ///
    /// Progress fractions are GLOBAL and land in the separating band
    /// [0.05, 0.90] (the driver's band) — the seam contract of
    /// `ImportOrchestrator.SeparationRun`.
    public func separateStagedMix(_ audio: DecodedAudio,
                                  progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> [Part: URL] {
        try Task.checkCancellation()
        try loadModelIfNeeded()

        // P-209 (the P-202 follow-up): the staged mix is read WINDOW BY WINDOW
        // from disk — the song is NEVER held in memory (the old path read the
        // whole f32 staging WAV, upmixed it to stereo and accumulated every
        // blended frame: two O(song) terms).
        let source = try PCMF32WavWindowSource(url: audio.url)
        guard source.sampleRate == 44100 else {
            throw EngineError.unsupportedFormat(
                "separate input must be the decoded 44.1 kHz mix (got \(source.sampleRate))")
        }
        // Processing layout is always stereo (the shim's contract): a mono mix
        // is upmixed per window — the same math as the old whole-song path.
        // D-8's stem policy (voice MONO / instrumental STEREO) is applied by
        // the SINK as the frames are written, never mid-blend.
        let stereoSource = StereoWindowSource(base: source)

        var config = ChunkedSeparationDriver.Config()
        config.progressBand = (0.05, 0.90)
        config.emitCompletion = false // the engine owns the final 1.0 (staging follows)
        let driver = try ChunkedSeparationDriver(
            policy: policy,
            config: config,
            thermalProvider: { DemucsEngine.currentThermalState() },
            progress: { p in progress(p) })

        // Staging dir is created up front and removed on ANY failure below
        // (including cancellation) — the C-2.2 no-partial-bundle discipline.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("pitchnotes-sep-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            let vocalsURL = staging.appendingPathComponent("vocals.wav")
            let instrumentalURL = staging.appendingPathComponent("instrumental.wav")
            // The streaming path: each window's blended stems are written to
            // disk as soon as they are final (the driver's retained buffer is
            // bounded by ONE window). On failure or cancellation the sinks
            // are aborted — no partial stem file survives.
            _ = try await driver.runStreaming(source: stereoSource, engine: self) { part in
                switch part {
                case .vocals:
                    // D-8: voice MONO.
                    return try PCM16StreamWriter(url: vocalsURL, sampleRate: 44100,
                                                 outputChannels: 1)
                case .instrumental:
                    // D-8: instrumental STEREO.
                    return try PCM16StreamWriter(url: instrumentalURL, sampleRate: 44100,
                                                 outputChannels: 2)
                default:
                    throw EngineError.contractViolation(
                        "separation produced an unexpected part \(part.rawValue) (M2 is the D-9 two-stem pair)")
                }
            }

            emitter.emit(ImportProgress(stage: .separating, fraction: 0.95,
                                        detail: "staging stems"))
            emitter.emit(ImportProgress(stage: .separating, fraction: 1.0,
                                        detail: "separation complete"))
            return [.vocals: vocalsURL, .instrumental: instrumentalURL]
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Import seam (P-204)

    /// The import seam: the app injects this into the real import engine
    /// (`SongBundleImportEngine`, ImportKit) so the orchestrator can drive
    /// the chunked separation without the portable core ever linking the
    /// vendored C++ bridge.
    ///
    /// The returned closure OWNS the staging directory it creates (the one
    /// the stems are written into) and hands the orchestrator the cleanup
    /// that removes it once the stems have been encoded — so an import
    /// leaves no scratch files behind, on success or on failure.
    public func separationRun() -> ImportOrchestrator.SeparationRun {
        { [weak self] mix, onProgress in
            guard let self else {
                throw EngineError.separationFailed("DemucsEngine was released before separation")
            }
            let stems = try await self.separateStagedMix(mix, progress: onProgress)
            // The stems share one staging directory (created by separateStagedMix).
            let directories = Set(stems.values.map { $0.deletingLastPathComponent() })
            let cleanup: @Sendable () -> Void = {
                for directory in directories {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            return SeparationOutput(stems: stems, cleanup: cleanup)
        }
    }

    // MARK: - SegmentEngine (P-202 L2)
    /// One window of the mix → the C-1 two-stem pair, in the PROCESSING layout
    /// (stereo, interleaved) — the driver blends the overlaps there.
    ///
    /// The vendor call is wrapped in a cancellation handler: cancelling the
    /// surrounding Task sets the shim's abort flag, the shim unwinds the
    /// vendor at its next progress tick and returns
    /// DEMUCS_SHIM_ERR_ABORTED, which surfaces as CancellationError (C-8).
    public func separate(window: [Float], channels: Int) async throws -> [Part: [Float]] {
        try await separate(window: window, channels: channels) { _, _ in }
    }

    public func separate(window: [Float], channels: Int,
                          progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Part: [Float]] {
        try Task.checkCancellation()
        try loadModelIfNeeded()

        // The shim is stereo-only; the driver's layout is the mix layout.
        let stereo = try SeparationChannels.upmixToStereo(frames: window, channels: channels)
        let frameCount = stereo.count / 2

        let raw = try await inferStereo(stereo: stereo, frameCount: frameCount, progress: progress)

        // Map → C-1 two-stem pair (portable mapper, Linux-tested).
        let mapped = try DemucsOutputMapper.map(rawStems: raw, nSamples: frameCount)

        // Back to the driver's layout (frames × channels).
        return [
            .vocals: try SeparationChannels.fromStereo(stereo: mapped.vocals.samples, channels: channels),
            .instrumental: try SeparationChannels.fromStereo(stereo: mapped.instrumental.samples, channels: channels),
        ]
    }

    /// Runs the vendor inference on stereo interleaved input; returns the raw
    /// source-major stem buffer. Throws CancellationError when the task was
    /// cancelled (mid-window abort through the shim's abort seam).
    private func inferStereo(stereo: [Float], frameCount: Int,
                             progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Float] {
        guard let handle = modelHandle else {
            throw EngineError.modelMissing("demucs model handle is nil")
        }
        // Clear a stale abort BEFORE the cancellation handler is installed: if
        // the task is already cancelled, the handler fires immediately and
        // re-arms the flag, so the vendor unwinds at its first progress tick.
        demucs_shim_clear_abort(handle)

        final class ProgressBox: @unchecked Sendable {
            let handler: @Sendable (Double, String) -> Void
            init(_ h: @escaping @Sendable (Double, String) -> Void) { handler = h }
        }
        let box = ProgressBox(progress)
        let cb: demucs_shim_progress_cb = { fraction, detail, ctx in
            guard let ctx else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            let d = detail.map { String(cString: $0) } ?? ""
            box.handler(Double(max(0, min(1, fraction))), d)
        }

        final class OutputBox: @unchecked Sendable {
            var stems: UnsafeMutablePointer<Float>?
            var count: Int32 = 0
        }
        let out = OutputBox()

        // The handle is an OpaquePointer (not Sendable) — carry it in a box so
        // the @Sendable cancellation closure can hold it without a concurrency
        // warning (an error under the Swift 6 language mode).
        final class HandleBox: @unchecked Sendable {
            let handle: OpaquePointer
            init(_ h: OpaquePointer) { handle = h }
        }
        let handleBox = HandleBox(handle)

        let status = await withTaskCancellationHandler {
            stereo.withUnsafeBufferPointer { buf -> Int32 in
                demucs_shim_infer(handle, buf.baseAddress, Int32(frameCount),
                                  cb, Unmanaged.passUnretained(box).toOpaque(),
                                  &out.stems, &out.count)
            }
        } onCancel: {
            // Runs on the cancelling thread — the vendor sees the flag at its
            // next progress tick and unwinds (P-202 L2 abort seam).
            demucs_shim_request_abort(handleBox.handle)
        }

        if status == DEMUCS_SHIM_ERR_ABORTED.rawValue {
            if let s = out.stems { demucs_shim_free_buffer(s) }
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard status == DEMUCS_SHIM_OK.rawValue, let stems = out.stems, out.count > 0 else {
            throw EngineError.separationFailed("demucs_shim_infer status \(status)")
        }
        defer { demucs_shim_free_buffer(stems) }

        let nSources = Int(demucs_shim_num_sources(handle))
        return Array(UnsafeBufferPointer(start: stems, count: nSources * 2 * Int(out.count)))
    }

    /// Portable thermal state (ProcessInfo.thermalState is Darwin-only; the
    /// app target is iOS/macOS, so the real provider is wired here).
    public static func currentThermalState() -> ThermalState {
        #if os(iOS) || os(macOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
        #else
        return .nominal
        #endif
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
