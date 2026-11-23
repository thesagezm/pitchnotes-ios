import Foundation
import EngineCore

// P-204 · The REAL import engine (Apple-side, ImportKit).
//
// It is the M2 engine the app talks to: it decodes MP3/FLAC/ALAC/WAV through
// AVFoundation (AVAudioFileDecoder, P-203), separates with the chunked
// driver (P-202 — the separator is INJECTED so this package stays free of the
// vendored C++ bridge), assembles the SongBundle (ALAC stems + song.json +
// atomic publish, C-2.2) and publishes `importedBundleID` (C-9).
//
// WHY THE SEPARATOR IS INJECTED: the vendored demucs.cpp bridge
// (Engine/Separation/DemucsEngine.swift) is compiled INTO THE APP TARGET
// (X-201), not into an SPM package — so ImportKit cannot link it. The seam
// (`ImportOrchestrator.SeparationRun`) lives in the portable EngineCore, and
// the app wires `DemucsEngine` into it (J-207/J-208's real-engine swap).
//
// The engine is deliberately honest about M2 scope: no note tracks (M3), no
// live pitch (that is LivePitchEngine/P-104), no per-voice stems (M3).

public final class SongBundleImportEngine: ProgressReportingEngine, BundleProducingEngine, @unchecked Sendable {

    private let separator: ImportOrchestrator.SeparationRun
    private let emitter = ImportProgressEmitter()
    private let lock = NSLock()
    private var publishedBundleID: String?

    /// Where published bundles live (the library root; one directory per song
    /// id, C-2).
    public let libraryRoot: URL

    /// Scratch directory for the staged mix (the standalone C-3 `importAudio`
    /// → `separate` flow needs the staged file to survive between the two
    /// calls; the full import path removes it when it is done).
    private let workDir: URL

    /// C-9: the id of the bundle this engine instance published. Set ONLY
    /// after the atomic publish; nil before that and after a cancelled or
    /// failed import (C-9 rule 1 — never a stale id pointing at staging).
    public var importedBundleID: String? {
        lock.lock()
        defer { lock.unlock() }
        return publishedBundleID
    }

    /// - Parameters:
    ///   - libraryRoot: the directory that holds the published bundles.
    ///   - separator: the chunked separation seam (the app injects
    ///     `DemucsEngine`'s implementation).
    public init(libraryRoot: URL, separator: @escaping ImportOrchestrator.SeparationRun) {
        self.libraryRoot = libraryRoot
        self.separator = separator
        self.workDir = libraryRoot.appendingPathComponent(".work", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: workDir)
    }

    public func setImportProgressHandler(_ handler: ImportProgressHandler?) {
        emitter.setHandler(handler)
    }

    // MARK: - The M2 import path (decode → separate → assemble → publish)

    /// Runs the whole import and publishes the bundle.
    ///
    /// The publish is ATOMIC (C-2.2): the bundle is written into
    /// `<library-root>/<id>.tmp` and renamed to `<library-root>/<id>` only
    /// when every step succeeded. A cancellation or a failure removes the
    /// staging directory — NO partial bundle, NO residue (C-8).
    ///
    /// - Returns: the published bundle's id, directory and manifest.
    @discardableResult
    public func importSong(source: URL, title: String) async throws -> ImportOutcome {
        // C-9 rule 1: a cancelled/failed import leaves the id nil.
        lock.lock(); publishedBundleID = nil; lock.unlock()

        let outcome = try await ImportOrchestrator.run(
            source: source,
            libraryRoot: libraryRoot,
            decoder: AVAudioFileDecoder(),
            separator: separator,
            encoder: ALACStemWriter(),
            emitter: emitter,
            config: .init(title: title,
                          engineVersion: ImportPipeline.engineVersion,
                          instrumentalPresence: InstrumentalPresenceHeuristic.presence))

        // C-9 rule 1: the id is published only after the bundle is complete
        // and visible at its final path.
        lock.lock(); publishedBundleID = outcome.bundleID; lock.unlock()

        // Engine-side import cache (P-204): source hash → bundle id.
        BundleCacheIndex.record(sourceHash: outcome.manifest.sourceHash.hex,
                                bundleID: outcome.bundleID,
                                title: outcome.manifest.title,
                                libraryRoot: libraryRoot)
        return outcome
    }

    /// The bundle id a previous import of the SAME source file produced (the
    /// import cache, P-204). nil when the file was never imported.
    public func cachedBundleID(forSourceHash hash: String) -> String? {
        BundleCacheIndex.lookup(sourceHash: hash, libraryRoot: libraryRoot)
    }

    // MARK: - C-3 EngineAPI (frozen signatures)

    /// Decodes the container at `url` into the normalized 44.1 kHz mix (D-8).
    /// The staged mix lives in the engine's work directory until the next
    /// import replaces it (the standalone `importAudio` → `separate` flow
    /// needs it to survive between the two calls).
    public func importAudio(url: URL) async throws -> DecodedAudio {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        // A fresh staging mix per call (the previous one is stale).
        let mix = workDir.appendingPathComponent("staging-mix-44k1.f32.wav")
        try? fm.removeItem(at: mix)
        return try AVAudioFileDecoder().decodeToMix(source: url, workDir: workDir)
    }

    /// Separates the staged mix into stems (two-stem only in M2, D-9).
    /// The returned URLs are owned by the CALLER (C-3 returns raw URLs; the
    /// full import path cleans up through the orchestrator instead).
    public func separate(_ audio: DecodedAudio, mode: SeparationMode) async throws -> [Part: URL] {
        guard mode == .twoStem else {
            throw EngineError.contractViolation(
                "multiStem mode not available in M2 (vocals+instrumental only per D-9)")
        }
        let out = try await separator(audio) { [emitter] p in emitter.emit(p) }
        return out.stems
    }

    /// The separation engine owns no batch pitch path (SwiftF0/PitchORT is
    /// the pitch engine) — an empty, immediately-finished stream.
    public func pitchFrames(_ audio: DecodedAudio, fmin: Double,
                            fmax: Double) async throws -> PitchFrameStream {
        PitchFrameStream(AsyncStream<PitchFrame> { $0.finish() })
    }

    /// M3 path (P-301) — not an M2 deliverable.
    public func noteTrack(_ source: NoteSource, part: Part) async throws -> NoteTrack {
        throw EngineError.unsupportedFormat("noteTrack lands in M3 (P-301/P-303)")
    }

    /// No live path in the separation engine — always the unvoiced frame
    /// (LivePitchEngine/P-104 owns live pitch).
    public func livePitch(_ chunk: MicChunk) -> PitchFrame {
        PitchFrame(t: chunk.captureTime_s, hz: 0.0, confidence: 0.0,
                   loudness_db: -120.0, engine_id: "RIBBON_MPM_YIN", lookahead_ms: 0)
    }
}
