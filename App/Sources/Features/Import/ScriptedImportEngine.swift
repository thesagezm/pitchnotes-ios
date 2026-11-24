import Foundation
import EngineCore
import PitchLogic

// ScriptedImportEngine (J-201) — the M2 mock import engine: EngineAPI +
// ProgressReportingEngine with a paced staged import so the flow UI, progress
// enforcement, cancellation, and the C-2.2 atomic bundle semantics are
// exercisable end-to-end BEFORE Paul's real engine lands (P-201..P-204).
// Swaps for the real engine with ZERO UI changes: same interim C-8 types from
// PitchLogic, same EngineAPI signatures (CONTRACTS C-3).
//
// Honesty notes (D-12): this engine does NOT decode or separate audio — it
// validates the picked file, scripts plausible stage pacing, and assembles a
// REAL contract-valid bundle via MockEngine (V1–V13). The bundle is playable
// WAV stems over the mock's scripted arrangement; separation "quality" is
// mock-only until P-204.

final class ScriptedImportEngine: ProgressReportingEngine, @unchecked Sendable {

    /// Overall-fraction schedule (the ENGINE owns stage weighting per C-8;
    /// these boundaries are this mock's documented choice: decode 10%,
    /// separation 75%, assembly 15% — decode is cheap, separation is the A14
    /// long pole, AGENTS §8).
    private static let schedule: [ImportStage: ClosedRange<Double>] = [
        .decoding: 0.0...0.10,
        .separating: 0.10...0.85,
        .assembling: 0.85...0.999,
    ]

    /// Demo pacing — a full import plays out in ~2 s so the progress screen,
    /// monotonic bar, and cancel button are watchable in the device demo.
    private static let pacing: [ImportStage: UInt64] = [
        .decoding: 350_000_000,   // ns
        .separating: 90_000_000,
        .assembling: 120_000_000,
    ]
    private static let separatingTicks = 8

    /// Formats the mock accepts (the real P-203 engine decodes MP3/FLAC/WAV/
    /// ALAC via AVAudioFile; extensions mirror that list).
    private static let supportedExtensions: Set<String> =
        ["mp3", "flac", "wav", "m4a", "aif", "aiff"]

    private let bundleRoot: URL
    private let mockScenario: MockScenario
    private let mockSeed: UInt64
    private let mock: MockEngine

    private let lock = NSLock()
    private var handler: ImportProgressHandler?

    /// The manifest id of the last completed import (nil until a bundle has
    /// been assembled) — the model reads it to register the library record.
    private(set) var importedBundleID: String?

    init(bundleRoot: URL, scenario: MockScenario = .perfect, seed: UInt64 = 0x2011) {
        self.bundleRoot = bundleRoot
        self.mockScenario = scenario
        self.mockSeed = seed
        self.mock = MockEngine(scenario: scenario, seed: seed, referencePart: .bass)
    }

    // MARK: - ProgressReportingEngine (C-8)

    func setImportProgressHandler(_ handler: ImportProgressHandler?) {
        lock.lock()
        self.handler = handler // last handler wins
        lock.unlock()
    }

    private func emit(_ stage: ImportStage, _ fraction: Double, _ detail: String?) {
        lock.lock()
        let h = handler
        lock.unlock()
        h?(ImportProgress(stage: stage, fraction: fraction, detail: detail))
    }

    // MARK: - EngineAPI (C-3)

    func importAudio(url: URL) async throws -> DecodedAudio {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.importFailed("input file does not exist at \(url.path)")
        }
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw EngineError.unsupportedFormat(".\(ext) is not an importable audio format")
        }
        try checkCancelled(cleanup: nil)
        emit(.decoding, Self.schedule[.decoding]!.lowerBound, "reading container")
        try await pacedSleep(stage: .decoding)
        try checkCancelled(cleanup: nil)

        // Mock decode: duration estimated from file size (compressed sources
        // ≈ 176 KB/s heuristic, clamped to a 10 s–10 min song). P-203 replaces
        // this with a real AVAudioFile decode.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 256_000
        let estimatedSeconds = min(max(Double(size) / 176_000.0, 10), 600)
        emit(.decoding, Self.schedule[.decoding]!.upperBound, "44.1 kHz mix ready")
        return DecodedAudio(url: url, sampleRate: 44100, channels: 1, duration_s: estimatedSeconds)
    }

    func separate(_ audio: DecodedAudio, mode: SeparationMode) async throws -> [Part: URL] {
        // Stage 2: chunked separation — paced ticks with per-chunk detail.
        let range = Self.schedule[.separating]!
        let ticks = Self.separatingTicks
        for i in 1...ticks {
            try checkCancelled(cleanup: nil)
            let f = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(ticks)
            emit(.separating, f, "chunk \(i)/\(ticks)")
            try await pacedSleep(stage: .separating)
        }
        try checkCancelled(cleanup: nil)

        // Stage 3: assemble the SongBundle (C-2.2 atomic semantics):
        // staging dir inside the bundle root → song.json written ATOMICALLY by
        // MockEngine → verify it parses → rename to <id>. Cancel at any point
        // removes the staging dir — NO partial bundle.
        let fm = FileManager.default
        try fm.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let staging = bundleRoot.appendingPathComponent("pending-import.tmp", isDirectory: true)
        if fm.fileExists(atPath: staging.path) {
            try? fm.removeItem(at: staging) // stale staging from a killed import
        }

        emit(.assembling, Self.schedule[.assembling]!.lowerBound, "writing ALAC stems")
        do {
            try mock.makeBundle(to: staging) // internal tmp+rename, C-2.2
        } catch {
            try? fm.removeItem(at: staging)
            throw EngineError.importFailed("bundle assembly failed: \(error)")
        }
        try checkCancelled(cleanup: staging)

        emit(.assembling, 0.92, "assembling bundle")
        guard let manifestData = try? Data(contentsOf: staging.appendingPathComponent("song.json")),
              let manifest = try? JSONDecoder().decode(SongManifest.self, from: manifestData) else {
            try? fm.removeItem(at: staging)
            throw EngineError.importFailed("assembled song.json does not parse — bundle rejected")
        }

        let final = bundleRoot.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: final.path) {
            try? fm.removeItem(at: staging)
            throw EngineError.importFailed("song already imported (\(manifest.id))")
        }
        do {
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw EngineError.importFailed("finalizing bundle failed: \(error)")
        }
        importedBundleID = manifest.id

        var stems: [Part: URL] = [:]
        for p in manifest.parts {
            stems[p.part] = final.appendingPathComponent(p.stemFile)
        }
        emit(.assembling, Self.schedule[.assembling]!.upperBound, "bundle complete")
        return stems
    }

    func pitchFrames(_ audio: DecodedAudio, fmin: Double, fmax: Double) async throws -> PitchFrameStream {
        try await mock.pitchFrames(audio, fmin: fmin, fmax: fmax)
    }

    func noteTrack(_ source: NoteSource, part: Part) async throws -> NoteTrack {
        try await mock.noteTrack(source, part: part)
    }

    func livePitch(_ chunk: MicChunk) -> PitchFrame {
        mock.livePitch(chunk)
    }

    // MARK: - Internals

    /// C-8 cancellation: cooperative checks between chunks; throws
    /// CancellationError unwrapped (never a fake EngineError — engines may
    /// only wrap for causes OTHER than the cancellation itself), and removes
    /// the staging directory when one exists.
    private func checkCancelled(cleanup staging: URL?) throws {
        guard !Task.isCancelled else {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            throw CancellationError()
        }
    }

    private func pacedSleep(stage: ImportStage) async throws {
        let ns = Self.pacing[stage] ?? 100_000_000
        try await Task.sleep(nanoseconds: ns)
    }
}
