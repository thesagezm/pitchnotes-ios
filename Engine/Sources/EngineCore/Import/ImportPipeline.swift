import Foundation

// P-203 · Import pipeline (C-8 `decoding` stage orchestration):
//   source file → BLAKE3 of ORIGINAL bytes (pre-decode) → decode to the
//   normalized 44.1 kHz staging mix → SongManifest v1.0 population.
// Progress per C-8 (monotonic via ImportProgressEmitter, `decoding` stage),
// cooperative cancellation between steps, staging cleanup on ANY throw so a
// cancelled/failed import leaves no residue (C-2.2 staging discipline).

/// Result of a completed `decoding` stage: the staged mix descriptor plus the
/// manifest as of import (parts[]/hasInstrumental finalize at P-202/P-204 when
/// separation + bundle assembly know the real stems; the builder accepts them
/// so a fully-valid v1.0 manifest is constructible at this stage too).
public struct ImportResult: Sendable {
    public let mix: DecodedAudio
    public let manifest: SongManifest
    public let sourceHash: SourceHash

    public init(mix: DecodedAudio, manifest: SongManifest, sourceHash: SourceHash) {
        self.mix = mix
        self.manifest = manifest
        self.sourceHash = sourceHash
    }
}

public enum ImportPipeline {
    /// Engine version stamped into manifests (monotonic per engine, C-2.1).
    public static let engineVersion = "engine-0.1.0"

    public static func run(source: URL,
                           title: String,
                           workDir: URL,
                           hasher: SourceHashing?,
                           decoder: AudioDecoding,
                           emitter: ImportProgressEmitter?,
                           tuningCents: Int? = nil,
                           hasInstrumental: Bool = true,
                           parts: [PartInfo] = [],
                           meanNoteConfidence: Double = 0.0,
                           id: String? = nil) async throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw EngineError.importFailed("input file does not exist at \(source.path)")
        }

        // The `decoding` stage covers hashing + decode: 0–0.25 hash, 0.25–1.0
        // decode/normalize (monotonic clamp lives in the emitter, C-8).
        func emit(_ fraction: Double, _ detail: String) {
            emitter?.emit(ImportProgress(stage: .decoding, fraction: fraction, detail: detail))
        }
        emit(0.0, "hashing source bytes")

        try Task.checkCancellation()
        let hash: SourceHash
        do {
            hash = try (hasher ?? Blake3FileHasher()).hashFile(at: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineError.importFailed("source hashing failed: \(error.localizedDescription)")
        }
        emit(0.25, "decoded hash \(hash.hex.prefix(12))…")

        try Task.checkCancellation()
        var mix: DecodedAudio?
        do {
            mix = try decoder.decodeToMix(source: source, workDir: workDir)
            // Cancellation AFTER decode but BEFORE manifest: the staged mix
            // must not survive a cancelled import (C-2.2 staging discipline —
            // a cancelled/failed job leaves no residue).
            try Task.checkCancellation()
        } catch {
            if let staged = mix {
                try? FileManager.default.removeItem(at: staged.url)
            }
            throw error
        }
        let decodedMix = mix!

        emit(1.0, "mix \(decodedMix.channels)ch 44.1 kHz \(String(format: "%.1f", decodedMix.duration_s))s")

        // P-207 (D-22): nil tuningCents = ESTIMATE from the staged mix (circular
        // mean of refined spectral peaks, ±50c clamp, MIN_CENTS gate); explicit
        // value = user/pipeline override (J-205 UI override lives above us).
        // Stored audio is NEVER resampled/retuned — the estimator is read-only.
        let resolvedTuning: Int
        if let explicit = tuningCents {
            resolvedTuning = explicit
        } else {
            do {
                let (samples, sr, ch) = try PCMF32Wav.read(url: decodedMix.url)
                // Channel-mean fold (stereo stays stereo in the STAGED mix; the
                // estimator is mono by design).
                let mono: [Float]
                if ch == 1 {
                    mono = samples
                } else {
                    var folded = [Float](repeating: 0, count: samples.count / ch)
                    for (i, v) in samples.enumerated() { folded[i / ch] += v / Float(ch) }
                    mono = folded
                }
                resolvedTuning = TuningEstimator().estimate(samples: mono, sampleRate: sr)
            } catch {
                resolvedTuning = 0 // weak/failed estimate → D-22 default 0
            }
        }

        let manifest = ImportManifestBuilder.build(
            mix: decodedMix, title: title, sourceHash: hash,
            tuningCents: resolvedTuning, hasInstrumental: hasInstrumental,
            parts: parts, meanNoteConfidence: meanNoteConfidence,
            engineVersion: engineVersion, id: id)
        return ImportResult(mix: decodedMix, manifest: manifest, sourceHash: hash)
    }
}

/// v1.0 manifest population from the decoded mix (C-2.1 field rules).
public enum ImportManifestBuilder {
    public static func build(mix: DecodedAudio,
                             title: String,
                             sourceHash: SourceHash,
                             tuningCents: Int = 0,
                             hasInstrumental: Bool = true,
                             parts: [PartInfo],
                             meanNoteConfidence: Double = 0.0,
                             engineVersion: String = ImportPipeline.engineVersion,
                             id: String? = nil) -> SongManifest {
        SongManifest(
            engineVersion: engineVersion,
            // ULID at import (C-2.1); injectable for deterministic tests.
            id: id ?? ULID.generate(),
            title: title,
            sourceHash: sourceHash,
            duration_s: mix.duration_s,
            sampleRate: DecodePolicy.targetSampleRate,
            channels: mix.channels,
            // D-22: v1.0 required field; P-207 supplies the estimator — the
            // pipeline passes the value through, clamped to the contract range.
            tuning_cents: max(-50, min(50, tuningCents)),
            hasInstrumental: hasInstrumental,
            parts: parts,
            confidenceSummary: ConfidenceSummary(meanNoteConfidence: meanNoteConfidence))
    }
}
