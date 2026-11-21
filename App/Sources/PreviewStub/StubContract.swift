import Foundation

// ⚠️ THROWAWAY PREVIEW STUB (J-002) — DO NOT EXTEND, DO NOT DEPEND ON FOR REAL WORK.
//
// Paul's Engine (P-001) has not landed, so J-002 previews against locally defined
// contract-shaped types. The single typed source of truth for these types is
// Paul's Engine per CONTRACTS v0.0 C-1/C-2 ("one definition, no lane-local
// copies"). When P-001 lands + X-003 wiring is applied: DELETE this whole
// PreviewStub/ directory, consume Paul's models, and the UI changes zero lines
// (views only touch LibraryModel + PitchLogic validators).
//
// Everything here mirrors CONTRACTS.md v0.0 JSON schemas EXACTLY (snake_case
// keys), so encoded output validates against PitchLogic.ContractValidator.

// MARK: - C-1 Part (rawValues stable forever)

enum StubPart: String, Codable, CaseIterable, Identifiable {
    case bass = "BASS"
    case baritone = "BARITONE"
    case baritenor = "BARITENOR"
    case t2 = "T2"
    case t1 = "T1"
    case soprano = "SOPRANO"
    case alto = "ALTO"
    case vp = "VP"
    case lead = "LEAD"
    case instrumental = "INSTRUMENTAL"

    var id: String { rawValue }

    /// C-1 sortOrder: soprano < alto < t1 < t2 < baritenor < baritone < bass.
    var sortOrder: Int {
        switch self {
        case .soprano: return 0
        case .alto: return 1
        case .t1: return 2
        case .t2: return 3
        case .baritenor: return 4
        case .baritone: return 5
        case .bass: return 6
        case .vp: return 7
        case .lead: return 8
        case .instrumental: return 9
        }
    }

    var isSingableVoice: Bool {
        switch self {
        case .bass, .baritone, .baritenor, .t2, .t1, .soprano, .alto, .lead: return true
        case .vp, .instrumental: return false
        }
    }

    /// UI display name (UX §3.6 chips).
    var displayName: String {
        switch self {
        case .bass: return "Bass"
        case .baritone: return "Baritone"
        case .baritenor: return "Baritenor"
        case .t2: return "T2"
        case .t1: return "T1"
        case .soprano: return "Soprano"
        case .alto: return "Alto"
        case .vp: return "VP"
        case .lead: return "Lead"
        case .instrumental: return "Instrumental"
        }
    }
}

// MARK: - C-2.1 song.json manifest

struct StubSourceHash: Codable, Equatable {
    let algo: String
    let hex: String
}

struct StubManifestPart: Codable, Equatable {
    let part: String
    let stemFile: String
    let channels: Int
    let notesFile: String
    let pitchFile: String?
    let noteConfidence: Double
}

struct StubConfidenceSummary: Codable, Equatable {
    let meanNoteConfidence: Double
}

struct StubSongManifest: Codable, Equatable {
    let contractVersion: String
    let engineVersion: String
    let id: String
    let title: String
    let sourceHash: StubSourceHash
    let duration_s: Double
    let sampleRate: Int
    let hasInstrumental: Bool
    let parts: [StubManifestPart]
    let confidenceSummary: StubConfidenceSummary

    enum CodingKeys: String, CodingKey {
        case contractVersion, engineVersion, id, title, sourceHash
        case duration_s
        case sampleRate, hasInstrumental, parts, confidenceSummary
    }
}

// MARK: - C-2.3 NoteTrack

struct StubNote: Codable, Equatable {
    let start_s: Double
    let end_s: Double
    let midi: Int
    let cents_ref: Int
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case start_s, end_s, midi
        case cents_ref
        case confidence
    }
}

struct StubNoteTrack: Codable, Equatable {
    let contractVersion: String
    let part: String
    let notes: [StubNote]

    enum CodingKeys: String, CodingKey {
        case contractVersion, part, notes
    }
}

// MARK: - C-2.4 PitchFrames

struct StubPitchFrame: Codable, Equatable {
    let t: Double
    let hz: Double
    let confidence: Double
    let loudness_db: Double

    enum CodingKeys: String, CodingKey {
        case t, hz, confidence
        case loudness_db
    }
}

struct StubPitchFrames: Codable, Equatable {
    let contractVersion: String
    let part: String
    let hopMs: Int
    let frames: [StubPitchFrame]

    enum CodingKeys: String, CodingKey {
        case contractVersion, part, hopMs, frames
    }
}
