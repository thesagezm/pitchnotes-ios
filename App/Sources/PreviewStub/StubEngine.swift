import Foundation
import PitchLogic

// ⚠️ THROWAWAY PREVIEW STUB (J-002) — see StubContract.swift header.
// Deterministic, contract-shaped fake bundles so the Library + bundle inspector
// render before Paul's MockEngine (P-001) lands. Named scenarios anticipate
// X-002 ("perfect / flat(-30c) / sharp(+35c) / octaveError / silent / breathy /
// lateOnset / vibrato") so the swap to Paul's MockEngine aligns 1:1.

/// MockEngine scenarios (X-002 proposal). M0 uses them as song captions; M1/M4
/// use them to drive ribbon + grading preview states.
enum StubScenario: String, CaseIterable {
    case perfect = "perfect"
    case flat = "flat (−30¢)"
    case sharp = "sharp (+35¢)"
    case octaveError = "octave error"
    case silent = "silent"
    case breathy = "breathy"
    case lateOnset = "late onset"
    case vibrato = "vibrato"
}

/// Validation verdict for one bundle file, displayed by the inspector.
struct StubFileReport: Identifiable, Equatable {
    let fileName: String
    let violations: [ContractViolation]
    var id: String { fileName }
    var isValid: Bool { violations.isEmpty }
}

/// One preview bundle: manifest + typed note tracks (what the UI renders now).
/// Stems are NOT written to disk in M0 — the inspector renders manifest
/// placeholders (stemFile paths) per J-002 scope.
struct StubSong: Identifiable, Equatable {
    let manifest: StubSongManifest
    let noteTracks: [StubPart: StubNoteTrack]
    let pitchFrames: [StubPart: StubPitchFrames]
    let scenario: StubScenario
    let reports: [StubFileReport]
    /// Pairs of singable parts with overlapping time AND pitch (±100¢) — UX §3.7.
    let unisonPairs: [String]

    var id: String { manifest.id }
}

enum StubEngine {

    // MARK: - Public surface (async; nothing on the main thread)

    /// Deterministic preview catalog. Off-main by call-site contract
    /// (LibraryModel detaches); pure CPU, no I/O.
    static func makeCatalog() -> [StubSong] {
        [
            makeSong(
                id: "01JDEMO0000000000000000001",
                title: "Just As I Am (demo)",
                scenario: .perfect,
                meanConfidence: 0.86,
                corrupt: false
            ),
            makeSong(
                id: "01JDEMO0000000000000000003",
                title: "Breathe On Me (demo)",
                scenario: .breathy,
                meanConfidence: 0.58,
                corrupt: false
            ),
            // Deliberate contract violations — the inspector MUST show red and a
            // logic test (J-004) asserts the validator catches these.
            makeSong(
                id: "01JDEMO0000000000000000002",
                title: "Mismatch Demo (must FAIL)",
                scenario: .perfect,
                meanConfidence: 0.9,
                corrupt: true
            ),
        ]
    }

    // MARK: - Deterministic generation

    /// Hymn-ish phrase per part: (midi, startBeat, lengthBeats) on an 8-beat
    /// grid at 90 BPM. Ranges roughly inside X-001 presets.
    private static let phrase: [StubPart: [(midi: Int, start: Int, length: Int)]] = [
        .bass: [(40, 0, 2), (40, 2, 2), (45, 4, 2), (43, 6, 2)],
        .baritone: [(47, 0, 2), (47, 2, 2), (48, 4, 2), (47, 6, 2)],
        .baritenor: [(52, 0, 2), (53, 2, 2), (57, 4, 2), (52, 6, 2)], // note 3 unisons with T2 (bleed demo)
        .t2: [(57, 0, 2), (57, 2, 2), (57, 4, 2), (55, 6, 2)],
        .t1: [(60, 0, 2), (62, 2, 2), (60, 4, 2), (59, 6, 2)],
    ]

    private static let secondsPerBeat = 60.0 / 90.0

    private static func makeSong(
        id: String,
        title: String,
        scenario: StubScenario,
        meanConfidence: Double,
        corrupt: Bool
    ) -> StubSong {
        let contractVersion = "v0.0"
        let engineVersion = "stub-0.0.0"

        // Note tracks per part; confidence varies by scenario/corruption.
        var noteTracks: [StubPart: StubNoteTrack] = [:]
        for (part, notes) in phrase {
            let baseConfidence = meanConfidence
            let track = StubNoteTrack(
                contractVersion: contractVersion,
                part: part.rawValue,
                notes: notes.map { note in
                    StubNote(
                        start_s: Double(note.start) * secondsPerBeat,
                        end_s: Double(note.start + note.length) * secondsPerBeat,
                        midi: corrupt && part == .t1 && note.start == 4 ? 120 : note.midi, // V9
                        cents_ref: corrupt && part == .bass && note.start == 0 ? 120 : 0, // V9
                        confidence: corrupt && note.start == 2 ? 1.5 : baseConfidence      // V9/V12
                    )
                }
            )
            if corrupt && part == .t2 {
                // V7 (start >= end) + V8 (out of order / overlap).
                let broken = track.notes
                noteTracks[part] = StubNoteTrack(
                    contractVersion: contractVersion,
                    part: part.rawValue,
                    notes: [
                        StubNote(start_s: 2.8, end_s: 2.8, midi: broken[2].midi, cents_ref: 0, confidence: 0.9),
                        StubNote(start_s: 1.0, end_s: 4.5, midi: broken[1].midi, cents_ref: 0, confidence: 0.9),
                    ]
                )
            } else {
                noteTracks[part] = track
            }
        }

        // 3 s of 16 ms pitch frames on T1 (188 frames) — sine 440 Hz with a
        // breathy gap; corrupt file breaks V11/V12/V13.
        var frames: [StubPitchFrame] = []
        let frameCount = 187
        for index in 0...frameCount {
            let t = Double(index) * 0.016
            let unvoiced = !corrupt && (t > 1.2 && t < 1.6) // breath gap between phrases
            let hz = unvoiced ? 0.0 : (corrupt && index == 50 ? 5000.0 : 440.0 + Double(index % 8) * 0.25)
            let confidence = corrupt && index == 80 ? 1.2 : (unvoiced ? 0.02 : 0.9)
            let loudness = unvoiced ? -92.0 : -18.0
            frames.append(StubPitchFrame(t: t, hz: hz, confidence: confidence, loudness_db: loudness))
        }
        if corrupt {
            // V13: non-uniform grid (breaks Δ = 16 ms).
            let broken = frames[100]
            frames[100] = StubPitchFrame(t: 1.5, hz: broken.hz, confidence: broken.confidence, loudness_db: broken.loudness_db)
        }
        var pitchFrames: [StubPart: StubPitchFrames] = [:]
        pitchFrames[.t1] = StubPitchFrames(
            contractVersion: contractVersion,
            part: StubPart.t1.rawValue,
            hopMs: 16,
            frames: frames
        )

        // Manifest. Corruption breaks V3 (channels), V5 (hash), V4 (duration).
        let parts = StubPart.allCases
            .filter { $0.isSingableVoice && phrase[$0] != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { part -> StubManifestPart in
                StubManifestPart(
                    part: part.rawValue,
                    stemFile: "stems/\(part.rawValue).m4a",
                    channels: corrupt && part == .bass ? 2 : 1, // V3
                    notesFile: "notes/\(part.rawValue).json",
                    pitchFile: part == .t1 ? "pitch/T1.json" : nil,
                    noteConfidence: meanConfidence
                )
            }
        let manifest = StubSongManifest(
            contractVersion: contractVersion,
            engineVersion: engineVersion,
            id: id,
            title: title,
            sourceHash: StubSourceHash(
                algo: "blake3",
                hex: corrupt ? "deadbeef" : String(repeating: "ab", count: 32) // V5
            ),
            duration_s: corrupt ? 0.0 : 5.34, // V4
            sampleRate: 44_100,
            hasInstrumental: false,
            parts: parts,
            confidenceSummary: StubConfidenceSummary(meanNoteConfidence: meanConfidence)
        )

        // Validate through the REAL contract validators (PitchLogic) so the
        // inspector shows the honest verdict, not a self-consistent lie.
        let encoder = JSONEncoder()
        var reports: [StubFileReport] = []
        if let data = try? encoder.encode(manifest) {
            reports.append(StubFileReport(fileName: "song.json", violations: ContractValidator.validateManifest(data)))
        }
        for (part, track) in noteTracks.sorted(by: { $0.key.sortOrder < $1.key.sortOrder }) {
            if let data = try? encoder.encode(track) {
                let name = "notes/\(part.rawValue).json"
                reports.append(StubFileReport(fileName: name, violations: ContractValidator.validateNoteTrack(data, expectedPart: part.rawValue)))
            }
        }
        for (part, framesFile) in pitchFrames.sorted(by: { $0.key.sortOrder < $1.key.sortOrder }) {
            if let data = try? encoder.encode(framesFile) {
                let name = "pitch/\(part.rawValue).json"
                reports.append(StubFileReport(fileName: name, violations: ContractValidator.validatePitchFrames(data, expectedPart: part.rawValue)))
            }
        }

        return StubSong(
            manifest: manifest,
            noteTracks: noteTracks,
            pitchFrames: pitchFrames,
            scenario: scenario,
            reports: reports,
            unisonPairs: Self.unisonPairs(noteTracks: noteTracks)
        )
    }

    /// Parts whose reference notes overlap in time AND pitch (|Δcents| ≤ 100) —
    /// physically inseparable by pitch; surfaced honestly (UX §3.7, RESEARCH).
    static func unisonPairs(noteTracks: [StubPart: StubNoteTrack]) -> [String] {
        let singable = noteTracks
            .filter { $0.key.isSingableVoice }
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
        var pairs: [String] = []
        for i in singable.indices {
            for j in (i + 1)..<singable.count {
                let a = singable[i], b = singable[j]
                let overlaps = a.value.notes.contains { noteA in
                    b.value.notes.contains { noteB in
                        noteA.start_s < noteB.end_s && noteB.start_s < noteA.end_s
                            && abs(Double(noteA.midi - noteB.midi) * 100) <= 100
                    }
                }
                if overlaps {
                    pairs.append("\(a.key.displayName) ↔ \(b.key.displayName)")
                }
            }
        }
        return pairs
    }
}
