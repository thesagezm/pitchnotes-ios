import Foundation

// C-2 · SongBundle schemas (CONTRACTS.md v0.0, RATIFIED 2026-11-20 UTC — L-006).
// Codable models whose JSON field names match the contract EXACTLY (mixed
// camelCase / snake_case is contractual — see CodingKeys).

// MARK: - C-2.3 NoteTrack

/// One note in a `NoteTrack` (C-2.3). JSON: `{ "start_s", "end_s", "midi",
/// "cents_ref", "confidence" }`.
public struct Note: Codable, Equatable, Sendable {
    /// Seconds from song start.
    public var start_s: Double
    /// Seconds from song start. V7: `start_s < end_s`.
    public var end_s: Double
    /// Equal-tempered MIDI note number (A440, C4 = 60). V9: range 24–96.
    public var midi: Int
    /// Deviation of the note's center pitch from equal temperament, V9: clamped
    /// [-50, +50] (+ = sharper).
    public var cents_ref: Int
    /// V9: [0, 1].
    public var confidence: Double

    public init(start_s: Double, end_s: Double, midi: Int, cents_ref: Int = 0, confidence: Double) {
        self.start_s = start_s
        self.end_s = end_s
        self.midi = midi
        self.cents_ref = cents_ref
        self.confidence = confidence
    }
}

/// `notes/<PART>.json` (C-2.3). JSON: `{ "contractVersion", "part", "notes": [...] }`.
/// V-rules: V7 start<end per note; V8 sorted by start_s and NON-overlapping within
/// a part; V9 ranges; V10 `part` matches filename PART.
public struct NoteTrack: Codable, Equatable, Sendable {
    public var contractVersion: String
    public var part: Part
    public var notes: [Note]

    public static let currentContractVersion = "v0.0"

    public init(contractVersion: String = NoteTrack.currentContractVersion, part: Part, notes: [Note]) {
        self.contractVersion = contractVersion
        self.part = part
        self.notes = notes
    }
}

// MARK: - C-2.4 PitchFrames

/// One frame of a `pitch/<PART>.json` track (C-2.4). Also the C-3 live-path value.
/// JSON keys are exactly `t`, `hz`, `confidence`, `loudness_db`.
/// `hz == 0.0` means UNVOICED; voiced range 46.9–2093.75 Hz (V11).
public struct PitchFrame: Codable, Equatable, Sendable {
    /// Seconds from song start; fixed 16 ms grid (`frames[i].t == i * 0.016`).
    public var t: Double
    /// 0.0 = unvoiced.
    public var hz: Double
    /// [0, 1] (V12).
    public var confidence: Double
    /// dBFS.
    public var loudness_db: Double
    /// v0.1 ADDITIVE (C-6.0): emitting engine's `PitchEngineID` rawValue;
    /// `""` legal only in v0.0-era persisted data. Decodes as nil for old files.
    public var engine_id: String?
    /// v0.1 ADDITIVE (C-6.0): source lookahead in ms (SWIFTF0 = 176,
    /// RIBBON_MPM_YIN = 0). Decodes as nil for old files.
    public var lookahead_ms: Int?

    public init(t: Double, hz: Double, confidence: Double, loudness_db: Double,
                engine_id: String? = nil, lookahead_ms: Int? = nil) {
        self.t = t
        self.hz = hz
        self.confidence = confidence
        self.loudness_db = loudness_db
        self.engine_id = engine_id
        self.lookahead_ms = lookahead_ms
    }
}

/// `pitch/<PART>.json` (C-2.4). Optional file per contract v0.0.
/// V13: `t` strictly increasing, uniform 16 ms grid within 1 ms tolerance.
public struct PitchFramesFile: Codable, Equatable, Sendable {
    public static let hopMs: Int = 16
    public static let contractVersion = "v0.0"

    public var contractVersion: String
    public var part: Part
    public var hopMs: Int
    public var frames: [PitchFrame]

    public init(contractVersion: String = PitchFramesFile.contractVersion, part: Part,
                hopMs: Int = PitchFramesFile.hopMs, frames: [PitchFrame]) {
        self.contractVersion = contractVersion
        self.part = part
        self.hopMs = hopMs
        self.frames = frames
    }
}

// MARK: - C-2.1 song.json manifest

/// `sourceHash` (C-2.1). V5: `algo == "blake3"`, `hex` is 64 lowercase hex chars.
/// BLAKE3 of the ORIGINAL imported file bytes (pre-decode).
public struct SourceHash: Codable, Equatable, Sendable {
    public var algo: String
    public var hex: String

    public init(algo: String = "blake3", hex: String) {
        self.algo = algo
        self.hex = hex
    }
}

/// One entry of `song.json` `parts[]` (C-2.1).
public struct PartInfo: Codable, Equatable, Sendable {
    public var part: Part
    /// Path inside the bundle, e.g. `stems/BASS.m4a`.
    public var stemFile: String
    /// V3: 1 (voice stems, D-8 mono) or 2 (INSTRUMENTAL, D-8 stereo).
    public var channels: Int
    /// Path inside the bundle, e.g. `notes/BASS.json`.
    public var notesFile: String
    /// OPTIONAL in contract v0.0 — omitted (key absent) when the engine wrote no
    /// pitch track for this part.
    public var pitchFile: String?
    /// Mean note confidence of this part's NoteTrack, [0,1]; parts without a
    /// NoteTrack use 0.0.
    public var noteConfidence: Double

    public init(part: Part, stemFile: String, channels: Int, notesFile: String,
                pitchFile: String? = nil, noteConfidence: Double) {
        self.part = part
        self.stemFile = stemFile
        self.channels = channels
        self.notesFile = notesFile
        self.pitchFile = pitchFile
        self.noteConfidence = noteConfidence
    }

    enum CodingKeys: String, CodingKey {
        case part, stemFile, channels, notesFile, pitchFile, noteConfidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        part = try c.decode(Part.self, forKey: .part)
        stemFile = try c.decode(String.self, forKey: .stemFile)
        channels = try c.decode(Int.self, forKey: .channels)
        notesFile = try c.decode(String.self, forKey: .notesFile)
        pitchFile = try c.decodeIfPresent(String.self, forKey: .pitchFile)
        noteConfidence = try c.decode(Double.self, forKey: .noteConfidence)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(part, forKey: .part)
        try c.encode(stemFile, forKey: .stemFile)
        try c.encode(channels, forKey: .channels)
        try c.encode(notesFile, forKey: .notesFile)
        try c.encodeIfPresent(pitchFile, forKey: .pitchFile)
        try c.encode(noteConfidence, forKey: .noteConfidence)
    }
}

public struct ConfidenceSummary: Codable, Equatable, Sendable {
    public var meanNoteConfidence: Double
    public init(meanNoteConfidence: Double) { self.meanNoteConfidence = meanNoteConfidence }
}

/// `song.json` manifest (C-2.1). One SongBundle directory per song, named by `id`.
public struct SongManifest: Codable, Equatable, Sendable {
    /// String `"v<major>.<minor>"`; consumers reject unknown MAJOR.
    public var contractVersion: String
    /// Free string, engine-authored, monotonic per engine.
    public var engineVersion: String
    /// ULID (26 chars, Crockford base32, uppercase) generated at import.
    public var id: String
    public var title: String
    public var sourceHash: SourceHash
    /// Of the decoded mix at 44.1 kHz. V4: `duration_s > 0`.
    public var duration_s: Double
    /// V4: must be 44100 (D-8).
    public var sampleRate: Int
    /// D-9: two-stem separation always runs; near-silent instrumental ⇒ false and
    /// NO `stems/INSTRUMENTAL.m4a` exists.
    public var hasInstrumental: Bool
    public var parts: [PartInfo]
    public var confidenceSummary: ConfidenceSummary

    public static let currentContractVersion = "v0.0"

    public init(contractVersion: String = SongManifest.currentContractVersion,
                engineVersion: String,
                id: String,
                title: String,
                sourceHash: SourceHash,
                duration_s: Double,
                sampleRate: Int = 44100,
                hasInstrumental: Bool,
                parts: [PartInfo],
                confidenceSummary: ConfidenceSummary) {
        self.contractVersion = contractVersion
        self.engineVersion = engineVersion
        self.id = id
        self.title = title
        self.sourceHash = sourceHash
        self.duration_s = duration_s
        self.sampleRate = sampleRate
        self.hasInstrumental = hasInstrumental
        self.parts = parts
        self.confidenceSummary = confidenceSummary
    }
}
