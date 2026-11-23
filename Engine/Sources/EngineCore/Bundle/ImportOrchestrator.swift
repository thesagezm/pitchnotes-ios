import Foundation

// P-202 L4 · The REAL import path (C-8 stages + C-2.2 atomic publish).
//
//   decoding   → ImportPipeline (source hash + decode/normalize + tuning estimate)
//   separating → the chunked separation engine (P-202 driver inside DemucsEngine)
//   assembling → stem encode (ALAC) + song.json + atomic publish
//
// ALL-OR-NOTHING: any failure, cancellation or throw removes the bundle
// staging directory, the staged mix and the separator's scratch stems — a
// cancelled import leaves NO partial bundle (C-2.2) and NO residue (C-8).
//
// Progress (C-8) is GLOBAL and MONOTONIC across the three stages:
//
//   decoding   → [0.00, 0.05]
//   separating → [0.05, 0.90]   (the SEPARATOR owns this band — DemucsEngine's
//                                driver band is already (0.05, 0.90); the
//                                orchestrator forwards it unchanged)
//   assembling → [0.90, 1.00]   (1.0 only AFTER the publish rename)
//
// The seams keep EngineCore portable (Linux-testable): the real conformers
// (ALAC encoder = P-204, the chunked separator = DemucsEngine) live in the
// Apple-side packages.

/// The result of a published import (C-9: the bundle id is the fact the app
/// needs — it is only known AFTER the atomic publish).
public struct ImportOutcome: Sendable {
    /// Bundle id == the published bundle directory name (C-2 / C-9 rule 4).
    public let bundleID: String
    /// The published bundle directory.
    public let bundleURL: URL
    /// The manifest as written into `song.json`.
    public let manifest: SongManifest

    public init(bundleID: String, bundleURL: URL, manifest: SongManifest) {
        self.bundleID = bundleID
        self.bundleURL = bundleURL
        self.manifest = manifest
    }
}

/// Encodes one staged stem into the bundle. The APP conformer writes ALAC
/// (`.m4a`, AVFoundation native — P-204); the Linux test conformer writes a
/// byte marker. The returned channel count is what actually landed on disk —
/// the orchestrator checks it against the D-8 policy (voice MONO,
/// INSTRUMENTAL STEREO) and writes THAT into `song.json` (V3).
public protocol StemEncoding: Sendable {
    /// Encodes `source` into `destination`; returns the channel count written
    /// (1 = mono, 2 = stereo).
    func encodeStem(source: URL, destination: URL, part: Part) throws -> Int
}

/// One separation run's output: the staged stems plus the cleanup the
/// SEPARATOR owns (its scratch directory). The orchestrator calls `cleanup`
/// exactly once — after the stems are encoded, or after a failure.
public struct SeparationOutput: Sendable {
    public let stems: [Part: URL]
    public let cleanup: @Sendable () -> Void

    public init(stems: [Part: URL], cleanup: @escaping @Sendable () -> Void) {
        self.stems = stems
        self.cleanup = cleanup
    }
}

public enum ImportOrchestrator {

    /// The separation seam. The closure receives the staged mix and a progress
    /// sink; it MUST report fractions inside the GLOBAL separating band
    /// [0.05, 0.90] (the seam contract — DemucsEngine's driver band is
    /// exactly that) and MUST return stems the caller may delete after use.
    /// NOTE: Swift forbids `@escaping` on a typealias; engines that STORE a
    /// SeparationRun declare `@escaping` at the storage/parameter site
    /// (SongBundleImportEngine does).
    public typealias SeparationRun = @Sendable (
        DecodedAudio,
        @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> SeparationOutput

    /// D-9 presence decision: `true` ⇒ the source has accompaniment and the
    /// INSTRUMENTAL stem ships; `false` ⇒ acapella (no INSTRUMENTAL stem, no
    /// INSTRUMENTAL entry in `parts[]` — V15). The argument is the SEPARATOR's
    /// staged instrumental stem (the PCM WAV, NOT the encoded file) so the
    /// decision can be measured portably (P-205's RMS heuristic). P-205
    /// replaces the default with the measured near-silent heuristic.
    public typealias InstrumentalPresence = @Sendable (URL?) throws -> Bool

    public struct Config: Sendable {
        public var title: String
        /// nil ⇒ estimate from the staged mix (D-22, P-207); a value ⇒
        /// explicit override (J-205 UI override).
        public var tuningCents: Int?
        public var engineVersion: String
        public var hasher: SourceHashing?
        public var instrumentalPresence: InstrumentalPresence

        public init(title: String = "",
                    tuningCents: Int? = nil,
                    engineVersion: String = ImportPipeline.engineVersion,
                    hasher: SourceHashing? = nil,
                    instrumentalPresence: @escaping InstrumentalPresence = { _ in true }) {
            self.title = title
            self.tuningCents = tuningCents
            self.engineVersion = engineVersion
            self.hasher = hasher
            self.instrumentalPresence = instrumentalPresence
        }
    }

    /// Runs the whole import and publishes the bundle.
    ///
    /// - Throws: `CancellationError` when the surrounding task is cancelled
    ///   (the staging directory is removed first — no partial bundle);
    ///   `EngineError.*` for decode/separation/assembly failures — same
    ///   cleanup guarantee.
    public static func run(source: URL,
                           libraryRoot: URL,
                           decoder: AudioDecoding,
                           separator: SeparationRun,
                           encoder: StemEncoding,
                           emitter: ImportProgressEmitter? = nil,
                           config: Config = Config()) async throws -> ImportOutcome {
        let fm = FileManager.default
        // The global emitter is the monotonic anchor for the whole import.
        // `beginImport()` resets its baseline so a second import in the same
        // process does not start clamped at the previous import's 1.0.
        let global = emitter ?? ImportProgressEmitter()
        global.beginImport()

        // The decode stage occupies the global [0, 0.05] band; ImportPipeline
        // reports its own [0, 1] decode fraction, which is mapped down here.
        let decodeEmitter = ImportProgressEmitter()
        decodeEmitter.setHandler { p in
            global.emit(ImportProgress(stage: .decoding,
                                       fraction: ImportOrchestrator.decodeBand.high * p.fraction,
                                       detail: p.detail))
        }

        // Scratch space for the staged mix (never inside the bundle).
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("pitchnotes-import-\(UUID().uuidString)", isDirectory: true)

        var staging: BundleStaging?
        var separation: SeparationOutput?

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            // MARK: 1 · decoding (hash + decode/normalize + tuning estimate)
            try Task.checkCancellation()
            let decoded = try await ImportPipeline.run(
                source: source,
                title: config.title,
                workDir: workDir,
                hasher: config.hasher,
                decoder: decoder,
                emitter: decodeEmitter,
                tuningCents: config.tuningCents)

            // MARK: 2 · separating (chunked; the separator owns the band)
            try Task.checkCancellation()
            let out = try await separator(decoded.mix) { p in
                global.emit(p)
            }
            separation = out

            // MARK: 3 · assembling (encode stems → song.json → publish)
            global.emit(ImportProgress(stage: .assembling, fraction: 0.90,
                                       detail: "assembling bundle"))

            let stage = try BundleStaging(libraryRoot: libraryRoot,
                                          bundleID: decoded.manifest.id)
            staging = stage
            try stage.create()

            var partInfos: [PartInfo] = []
            var instrumentalSource: URL?
            // Deterministic order (C-1 sortOrder) → byte-identical manifests.
            for part in out.stems.keys.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                try Task.checkCancellation()
                guard let stemURL = out.stems[part] else { continue }
                let relative = "stems/\(part.rawValue).m4a"
                let destination = stage.stagingURL.appendingPathComponent(relative)
                let channels = try encoder.encodeStem(source: stemURL,
                                                      destination: destination,
                                                      part: part)
                // D-8: voice stems MONO, INSTRUMENTAL STEREO.
                let expected = (part == .instrumental) ? 2 : 1
                guard channels == expected else {
                    throw EngineError.contractViolation(
                        "stem \(part.rawValue) encoded with \(channels) channel(s); D-8 requires \(expected)")
                }
                partInfos.append(PartInfo(part: part, stemFile: relative,
                                          channels: channels, noteConfidence: 0.0))
                if part == .instrumental { instrumentalSource = stemURL }
            }
            guard !partInfos.isEmpty else {
                throw EngineError.contractViolation(
                    "separation produced no stems — nothing to assemble")
            }

            // D-9 / V15: acapella ⇒ no INSTRUMENTAL stem AND no INSTRUMENTAL
            // entry in parts[]. The decision is measured on the SEPARATOR's
            // staged stem (portable RMS — P-205).
            let hasInstrumental = try config.instrumentalPresence(instrumentalSource)
            if !hasInstrumental {
                if let instrumentalPart = partInfos.first(where: { $0.part == .instrumental }) {
                    try? fm.removeItem(at: stage.stagingURL.appendingPathComponent(instrumentalPart.stemFile))
                }
                partInfos.removeAll { $0.part == .instrumental }
            }

            let manifest = SongManifest(
                contractVersion: SongManifest.currentContractVersion,
                engineVersion: config.engineVersion,
                id: decoded.manifest.id,
                title: config.title,
                sourceHash: decoded.manifest.sourceHash,
                duration_s: decoded.manifest.duration_s,
                sampleRate: DecodePolicy.targetSampleRate,
                channels: decoded.manifest.channels,
                tuning_cents: decoded.manifest.tuning_cents,
                hasInstrumental: hasInstrumental,
                parts: partInfos,
                confidenceSummary: ConfidenceSummary(meanNoteConfidence: 0.0))

            // The completion marker is written LAST (C-2.2 consumer rule: a
            // bundle is complete IFF it contains a parseable song.json).
            let encoderJSON = JSONEncoder()
            encoderJSON.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoderJSON.encode(manifest)
                .write(to: stage.stagingURL.appendingPathComponent("song.json"))

            // Validate BEFORE the publish: an invalid bundle must never become
            // visible under its final name.
            let validation = BundleValidator.validate(bundleDirectory: stage.stagingURL)
            guard validation.isValid else {
                throw EngineError.contractViolation(
                    "assembled bundle violates the contract: \(validation.violations)")
            }

            try Task.checkCancellation()
            try stage.publish()
            // C-8: 1.0 only at completion — after the rename.
            global.emit(ImportProgress(stage: .assembling, fraction: 1.0,
                                       detail: "bundle published"))

            // Success: the scratch space and the separator's stems are gone.
            try? fm.removeItem(at: workDir)
            out.cleanup()
            return ImportOutcome(bundleID: manifest.id,
                                  bundleURL: stage.publishedURL,
                                  manifest: manifest)
        } catch {
            // C-2.2 / C-8: NO partial bundle, NO residue.
            staging?.discard()
            separation?.cleanup()
            try? fm.removeItem(at: workDir)
            throw error
        }
    }

    /// Global progress bands (C-8). The separating band is owned by the
    /// separator (DemucsEngine's driver band is (0.05, 0.90)).
    enum ProgressBand {
        static let decodeLow: Double = 0.00
        static let decodeHigh: Double = 0.05
        static let separatingLow: Double = 0.05
        static let separatingHigh: Double = 0.90
        static let assemblingLow: Double = 0.90
        static let assemblingHigh: Double = 1.00
    }

    /// The decode band, exposed for the mapping above (kept in one place so
    /// the orchestrator and its tests cannot drift apart).
    static var decodeBand: (low: Double, high: Double) {
        (ProgressBand.decodeLow, ProgressBand.decodeHigh)
    }
}
