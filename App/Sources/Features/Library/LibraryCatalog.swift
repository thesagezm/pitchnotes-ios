import Foundation
import EngineCore
import PitchLogic

// LibraryCatalog (X-006) — the M0 preview stub (App/Sources/PreviewStub, deleted)
// replaced by Paul's MockEngine + EngineCore validators. Deterministic,
// contract-valid bundles materialized OFF the main thread; validation verdicts
// come from the REAL V1–V13 validators, never from a self-consistent lie.
//
// The M2 real-import swap (J-201/J-202) keeps this row shape: manifest + disk
// truth + honest verdicts. Only the producer changes.

/// Validation verdict for one bundle file, displayed by the inspector.
struct BundleFileReport: Identifiable, Equatable {
    let fileName: String
    let violations: [ContractViolation]
    var id: String { fileName }
    var isValid: Bool { violations.isEmpty }
}

/// One Library row: an on-disk bundle + what the UI renders from it.
/// `noteTracks` load FROM DISK (the inspector shows reality, not the script).
struct LibrarySong: Identifiable {
    let manifest: SongManifest
    let noteTracks: [Part: NoteTrack]
    let unisonPairs: [UnisonPair]
    let reports: [BundleFileReport]
    /// Provenance caption ("perfect", "breathy", "tampered — must FAIL").
    /// Demo rows only; real imports render their own provenance via `record`.
    let scenarioCaption: String
    /// J-202: non-nil for a REAL imported bundle (BundleStore disk truth) —
    /// delete/storage/provenance UI applies; nil for the demo catalog.
    let record: BundleRecord?
    /// J-202: bytes this bundle occupies on disk (0 for demo rows — their
    /// temporary-directory size is meaningless and would mislead).
    let bytesOnDisk: Int64
    /// J-205/D-22: the manifest's `tuning_cents` when the bundle is a v1.0
    /// manifest (nil = v0-era/unknown — the lane-local ManifestV1 decoder
    /// rejects v0.x; callers treat nil as "no estimate yet").
    let tuningCents: Int?
    /// J-203: the bundle directory (stems live here) — nil only for failed
    /// rows with nothing playable.
    let bundleDirectory: URL?

    var id: String { manifest.id }
    var allReportsValid: Bool { reports.allSatisfy(\.isValid) }
    /// Real imported song (deletable, storage-counted) vs demo catalog row.
    var isImported: Bool { record != nil }
}

enum LibraryCatalog {

    // MARK: - Catalog assembly (call OFF main; CPU + tmp-file I/O only)

    /// Four deterministic MockEngine bundles: three clean scenarios + one
    /// deliberately tampered on disk, so the inspector demonstrably catches
    /// real contract violations (J-002 AC, now via EngineCore).
    static func makeCatalog() -> [LibrarySong] {
        var songs: [LibrarySong] = []
        songs.append(song(scenario: .perfect, seed: 0x5017, caption: "perfect"))
        songs.append(song(scenario: .breathy, seed: 0x5018, caption: "breathy"))
        songs.append(song(scenario: .vibrato, seed: 0x5019, caption: "vibrato"))
        songs.append(tamperedSong(seed: 0x5020))
        return songs
    }

    // MARK: - One song: materialize → read back → validate

    /// J-202: assemble a LibrarySong from a REAL imported bundle directory
    /// (BundleStore.scan() record). Same disk-truth validation as the demo
    /// rows — the only difference is provenance and the on-disk size.
    /// `scan()` guarantees a parseable song.json, but a vanished/corrupted
    /// bundle between scan and read still renders as a failed row, not a crash.
    static func importedSong(at dir: URL, record: BundleRecord, bytesOnDisk: Int64) -> LibrarySong {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("song.json")),
              let manifest = try? JSONDecoder().decode(SongManifest.self, from: data) else {
            return failedSong(id: record.id, error: BundleStoreError.bundleIncomplete(record.id),
                              record: record, bytesOnDisk: bytesOnDisk)
        }
        // J-205: v1.0 manifests carry tuning_cents (D-22); v0-era → nil.
        let tuning = (try? ManifestV1.decode(data))?.tuning_cents
        return assemble(manifest: manifest, in: dir,
                        caption: "", record: record, bytesOnDisk: bytesOnDisk,
                        tuningCents: tuning)
    }

    private static func song(scenario: MockScenario, seed: UInt64, caption: String) -> LibrarySong {
        let engine = MockEngine(scenario: scenario, seed: seed, referencePart: .bass)
        do {
            let manifest = try engine.makeBundle()
            return assemble(manifest: manifest, in: engine.bundleDirectory, caption: caption)
        } catch {
            // A mock bundle that fails to materialize is itself a red report —
            // never a crash, never a silent row.
            return failedSong(id: "mock-\(scenario.rawValue)-\(seed)", error: error, caption: caption)
        }
    }

    /// Materializes a VALID MockEngine bundle, then corrupts a note on disk
    /// (midi 120 → V9). The inspector must show FAIL against the real validator.
    private static func tamperedSong(seed: UInt64) -> LibrarySong {
        let engine = MockEngine(scenario: .perfect, seed: seed, referencePart: .bass)
        do {
            _ = try engine.makeBundle()
            let notesURL = engine.bundleDirectory.appendingPathComponent("notes/T1.json")
            var track = try JSONDecoder().decode(NoteTrack.self, from: Data(contentsOf: notesURL))
            track.notes[0].midi = 120
            try JSONEncoder().encode(track).write(to: notesURL)
            let manifest = try JSONDecoder().decode(
                SongManifest.self, from: Data(contentsOf: engine.bundleDirectory.appendingPathComponent("song.json")))
            return assemble(manifest: manifest, in: engine.bundleDirectory, caption: "tampered — must FAIL")
        } catch {
            return failedSong(id: "mock-tampered-\(seed)", error: error, caption: "tampered — must FAIL")
        }
    }

    /// Reads song.json + notes/* + pitch/* FROM DISK and validates each with
    /// EngineCore validators (per-file reports) plus the file-level bundle pass
    /// (V1/V2/V3 stem reality/V10). This is the honesty layer: disk truth.
    private static func assemble(manifest: SongManifest, in dir: URL, caption: String,
                                 record: BundleRecord? = nil, bytesOnDisk: Int64 = 0,
                                 tuningCents: Int? = nil) -> LibrarySong {
        var reports: [BundleFileReport] = []
        var tracks: [Part: NoteTrack] = [:]

        // song.json (V1 parse + V3 declared policy/V4/V5/V6/V9-conf).
        let manifestReport: BundleFileReport
        if let data = try? Data(contentsOf: dir.appendingPathComponent("song.json")),
           let decoded = try? JSONDecoder().decode(SongManifest.self, from: data) {
            manifestReport = BundleFileReport(
                fileName: "song.json",
                violations: BundleValidator.validate(manifest: decoded).violations)
        } else {
            manifestReport = BundleFileReport(
                fileName: "song.json",
                violations: [ContractViolation("V1", "song.json missing or does not parse as SongManifest")])
        }
        reports.append(manifestReport)

        for p in manifest.parts {
            // Stem existence (V2) reported per declared stem file.
            let stemURL = dir.appendingPathComponent(p.stemFile)
            reports.append(BundleFileReport(
                fileName: p.stemFile,
                violations: FileManager.default.fileExists(atPath: stemURL.path)
                    ? []
                    : [ContractViolation("V2", "stemFile \(p.stemFile) does not exist in bundle")]))

            // notes/<PART>.json (V7–V10 from disk).
            let notesURL = dir.appendingPathComponent(p.notesFile)
            if let data = try? Data(contentsOf: notesURL),
               let track = try? JSONDecoder().decode(NoteTrack.self, from: data) {
                tracks[p.part] = track
                reports.append(BundleFileReport(
                    fileName: p.notesFile,
                    violations: BundleValidator.validate(noteTrack: track).violations))
            } else {
                reports.append(BundleFileReport(
                    fileName: p.notesFile,
                    violations: [ContractViolation("V1", "notes file missing or does not parse as NoteTrack")]))
            }

            // pitch/<PART>.json — optional file (C-2); validated when present.
            if let pitchFile = p.pitchFile {
                let pitchURL = dir.appendingPathComponent(pitchFile)
                if let data = try? Data(contentsOf: pitchURL),
                   let frames = try? JSONDecoder().decode(PitchFramesFile.self, from: data) {
                    reports.append(BundleFileReport(
                        fileName: pitchFile,
                        violations: BundleValidator.validate(pitchFrames: frames).violations))
                } else {
                    reports.append(BundleFileReport(
                        fileName: pitchFile,
                        violations: [ContractViolation("V1", "pitch file missing or does not parse as PitchFrames")]))
                }
            }
        }

        // File-level pass (stem reality channels, filename conventions). Its
        // violations are folded into the manifest report — the bundle-level
        // check is about the whole directory.
        let bundleResult = BundleValidator.validate(bundleDirectory: dir)
        let bundleOnly = bundleResult.violations.filter { v in
            !reports.contains { report in report.violations.contains(v) }
        }
        if !bundleOnly.isEmpty {
            reports[0] = BundleFileReport(
                fileName: "song.json",
                violations: manifestReport.violations + bundleOnly)
        }

        return LibrarySong(
            manifest: manifest,
            noteTracks: tracks,
            unisonPairs: UnisonDetector.pairs(in: tracks),
            reports: reports,
            scenarioCaption: caption,
            record: record,
            bytesOnDisk: bytesOnDisk,
            tuningCents: tuningCents,
            bundleDirectory: dir)
    }

    /// Materialization itself failed — one red report row, no crash.
    /// `caption` doubles as the honest reason ("tampered — must FAIL" for the
    /// demo, "bundle no longer readable" for a real import that went bad).
    private static func failedSong(id: String, error: Error, caption: String = "",
                                   record: BundleRecord? = nil, bytesOnDisk: Int64 = 0,
                                   tuningCents: Int? = nil,
                                   bundleDirectory: URL? = nil) -> LibrarySong {
        let manifest = SongManifest(
            engineVersion: "unavailable",
            id: id,
            title: "Bundle failed to load",
            sourceHash: SourceHash(hex: String(repeating: "0", count: 64)),
            duration_s: 1.0,
            hasInstrumental: false,
            parts: [],
            confidenceSummary: ConfidenceSummary(meanNoteConfidence: 0.0))
        return LibrarySong(
            manifest: manifest,
            noteTracks: [:],
            unisonPairs: [],
            reports: [BundleFileReport(
                fileName: "bundle",
                violations: [ContractViolation("V1", "load error: \(error)")])],
            scenarioCaption: caption,
            record: record,
            bytesOnDisk: bytesOnDisk,
            tuningCents: tuningCents,
            bundleDirectory: bundleDirectory)
    }
}
