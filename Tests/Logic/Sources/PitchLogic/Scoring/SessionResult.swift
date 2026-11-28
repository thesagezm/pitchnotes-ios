import Foundation
import EngineCore

// J-401 · C-18 `SessionResult` (CONTRACTS v1.2, D-58) — the grading output.
//
// THE SHAPES ARE THE CONTRACT's, KEY FOR KEY; the formulas stay
// implementation-owned (SessionGrader). The absence rule is binding: every
// field except `sessionId`, `bundleId`, `part`, `createdAt` is OPTIONAL, and
// an absent field means the consumer behaves as before v1.2.
//
// `SessionResult` is LOCAL-ONLY (AGENTS §0): it lives in J-404's GRDB history
// and is the shape of the user-triggered session-JSON export. It never leaves
// the device except through that explicit export.

// MARK: - The grade

/// The A–F band (C-18: exact strings, no "E"). The thresholds are Jess's
/// implementation (C-18 leaves the bands to the grader); they are pinned by
/// the Scoring suite so a grade means the same thing forever.
public enum GradeBand: String, Codable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case f = "F"

    public static let thresholds: [(band: GradeBand, minimum: Double)] = [
        (.a, 0.90), (.b, 0.75), (.c, 0.60), (.d, 0.40),
    ]

    /// The band for a session score in [0, 1]: A ≥ 0.90, B ≥ 0.75,
    /// C ≥ 0.60, D ≥ 0.40, else F.
    public static func band(forScore score: Double) -> GradeBand {
        for (band, minimum) in thresholds where score >= minimum {
            return band
        }
        return .f
    }
}

// MARK: - The grading reference (C-18's `gradingReference` object)

/// WHICH composed reference graded the session (C-14's order — the UI MUST
/// state it). The source strings are the contract's exact values.
public struct GradingReferenceInfo: Codable, Equatable, Sendable {

    public enum Source: String, Codable, Sendable {
        /// C-14 case 1 — the user's corrections are authoritative.
        case correctionOverlay
        /// C-14 case 2 — the score-informed track (alignment accepted).
        case scoreInformed
        /// C-14 case 3 — the heuristic track (and the UI says so).
        case heuristic
    }

    public var source: Source
    /// The alignment's confidence — present ONLY for `scoreInformed`
    /// (C-18's example: `null` otherwise).
    public var alignmentConfidence: Double?

    public init(source: Source, alignmentConfidence: Double? = nil) {
        self.source = source
        self.alignmentConfidence = alignmentConfidence
    }

    // MARK: Codable (the contract's example carries `alignmentConfidence`
    // as an explicit `null` for a non-score reference — same explicit-null
    // rule as SessionAccuracy).

    private enum CodingKeys: String, CodingKey {
        case source, alignmentConfidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        if let alignmentConfidence {
            try container.encode(alignmentConfidence, forKey: .alignmentConfidence)
        } else {
            try container.encodeNil(forKey: .alignmentConfidence)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try container.decode(Source.self, forKey: .source),
                  alignmentConfidence: try container.decodeIfPresent(Double.self,
                                                                     forKey: .alignmentConfidence))
    }

    /// From PitchLogic's C-14 `GradingReference` (the review's decision).
    public init(_ reference: GradingReference, alignmentConfidence: Double? = nil) {
        switch reference {
        case .overlay: self.init(source: .correctionOverlay, alignmentConfidence: alignmentConfidence)
        case .scoreInformed: self.init(source: .scoreInformed, alignmentConfidence: alignmentConfidence)
        case .heuristic: self.init(source: .heuristic, alignmentConfidence: alignmentConfidence)
        }
    }
}

// MARK: - Per-note (C-18's `perNote[]` entry)

/// One GRADED reference note's result. `{centsDeviation, coverage, sustain,
/// hit}` are C-5's four outputs — the names are FROZEN as written there
/// (`sustain_ms` per C-18's JSON; the value is milliseconds, ≥ 0).
public struct PerNoteResult: Codable, Equatable, Sendable {

    /// The index into the grading-reference `notes[]` (the order the composer
    /// produced — CorrectionResolver's repaired order).
    public var noteIndex: Int
    /// True when the note was sung in tune (its mean-centered center inside
    /// the tolerance) AND at least `SessionGrader.minCoverageForHit` of it was
    /// voiced. `false` = a graded miss; `nil` = not assessed at all.
    public var hit: Bool?
    /// Signed cents, LIVE minus REFERENCE (C-18) — the note's mean-centered
    /// center deviation (vibrato's mean is the measured center, C-19).
    public var centsDeviation: Double?
    /// The share of the note's duration the singer produced (voiced, post
    /// breath gate), [0, 1].
    public var coverage: Double?
    /// The LONGEST continuous in-tune run in milliseconds (sustain — the
    /// vibrato swing around the center counts as in tune; C-19).
    public var sustain_ms: Int?
    /// The reference note's C-10 band — REPORTED, never a scoring weight
    /// (D-54 §2). Reuses EngineCore's `AssignmentBand` (the exact C-10
    /// spellings, one semantic type).
    public var confidenceBand: AssignmentBand?
    /// The reference note's C-10 unison flag — reported; changes NO math
    /// (D-54 §3: grading stays per-part).
    public var unison: Bool?
    /// D-54 §4's class: true when this note starts within 50 ms after the
    /// preceding note of the SAME part ends (legato transitions are the
    /// hazard); the first note of a part is `false`.
    public var transitional: Bool?
    /// True when the note contributed NO score — the exclusion is VISIBLE,
    /// never silent (D-54 §1).
    public var notAssessable: Bool?
    /// Why it was not assessable: `"unassigned"` (C-14's excluded band) or
    /// `"noLiveFrames"` (no live pitch frames covered the note).
    public var notAssessableReason: String?

    /// The two exact reason strings (C-18).
    public static let reasonUnassigned = "unassigned"
    public static let reasonNoLiveFrames = "noLiveFrames"

    public init(noteIndex: Int,
                hit: Bool? = nil,
                centsDeviation: Double? = nil,
                coverage: Double? = nil,
                sustain_ms: Int? = nil,
                confidenceBand: AssignmentBand? = nil,
                unison: Bool? = nil,
                transitional: Bool? = nil,
                notAssessable: Bool? = nil,
                notAssessableReason: String? = nil) {
        self.noteIndex = noteIndex
        self.hit = hit
        self.centsDeviation = centsDeviation
        self.coverage = coverage
        self.sustain_ms = sustain_ms
        self.confidenceBand = confidenceBand
        self.unison = unison
        self.transitional = transitional
        self.notAssessable = notAssessable
        self.notAssessableReason = notAssessableReason
    }
}

// MARK: - Per-phrase, accuracy, the not-assessable summary

public struct PerPhraseResult: Codable, Equatable, Sendable {
    public var phraseIndex: Int
    /// The phrase's duration-weighted note-score aggregate, clamped [0, 1]
    /// (golden notes contribute their bonus inside; a phrase whose notes are
    /// ALL not-assessable is OMITTED — the notAssessable summary carries the
    /// visibility, never a zero that looks like a bad grade).
    public var score: Double

    public init(phraseIndex: Int, score: Double) {
        self.phraseIndex = phraseIndex
        self.score = score
    }
}

/// `{overall, steady, transition}` — BOTH classes are reported whenever an
/// accuracy number is published (D-54 §4); each is [0, 1] or `null` when
/// that class has no graded members ("the split says so"). The null is
/// ENCODED explicitly (C-18's shape: the key with `null`, not an absent key —
/// the split's "no such class" is information, and a key that vanishes cannot
/// say it). Every number this type carries is SYNTHETIC-labelled wherever it
/// is published (D-54 §5) — no real-acapella grading accuracy exists in this
/// repo.
public struct SessionAccuracy: Codable, Equatable, Sendable {
    public var overall: Double?
    public var steady: Double?
    public var transition: Double?

    public init(overall: Double?, steady: Double?, transition: Double?) {
        self.overall = overall
        self.steady = steady
        self.transition = transition
    }

    private enum CodingKeys: String, CodingKey {
        case overall, steady, transition
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        for (value, key) in [(overall, CodingKeys.overall),
                             (steady, CodingKeys.steady),
                             (transition, CodingKeys.transition)] {
            if let value {
                try container.encode(value, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(overall: try container.decodeIfPresent(Double.self, forKey: .overall),
                  steady: try container.decodeIfPresent(Double.self, forKey: .steady),
                  transition: try container.decodeIfPresent(Double.self, forKey: .transition))
    }
}

/// `{total, byReason{unassigned, noLiveFrames}}` — the counts agree with the
/// `perNote` flags (C-18).
public struct NotAssessableSummary: Codable, Equatable, Sendable {

    public struct Reasons: Codable, Equatable, Sendable {
        public var unassigned: Int
        public var noLiveFrames: Int

        public init(unassigned: Int, noLiveFrames: Int) {
            self.unassigned = unassigned
            self.noLiveFrames = noLiveFrames
        }
    }

    public var total: Int
    public var byReason: Reasons

    public init(total: Int, byReason: Reasons) {
        self.total = total
        self.byReason = byReason
    }
}

// MARK: - The session result

public struct SessionResult: Codable, Equatable, Sendable {

    /// The on-disk contract version of a C-18 session file (the NEW v1.2
    /// files carry "v1.2").
    public static let currentContractVersion = "v1.2"

    public var contractVersion: String
    // REQUIRED (C-18): sessionId, bundleId, part, createdAt.
    public var sessionId: String
    public var bundleId: String
    public var part: Part
    /// ISO-8601 UTC, caller-supplied (a fixed string keeps the result
    /// byte-deterministic across platforms — the macOS-vs-Linux formatter
    /// lesson; the grader never reads the clock).
    public var createdAt: String
    // Everything below is OPTIONAL (C-18's absence rule).
    public var duration_s: Double?
    public var gradingReference: GradingReferenceInfo?
    public var config: GradingConfig?
    public var latencyOffset_ms: Int?
    public var tuningCents: Int?
    public var transpositionSemitones: Int?
    public var tempoScale: Double?
    public var perNote: [PerNoteResult]?
    public var perPhrase: [PerPhraseResult]?
    public var accuracy: SessionAccuracy?
    public var notAssessable: NotAssessableSummary?
    public var grade: GradeBand?
    public var engineVersion: String?

    public init(contractVersion: String = SessionResult.currentContractVersion,
                sessionId: String,
                bundleId: String,
                part: Part,
                createdAt: String,
                duration_s: Double? = nil,
                gradingReference: GradingReferenceInfo? = nil,
                config: GradingConfig? = nil,
                latencyOffset_ms: Int? = nil,
                tuningCents: Int? = nil,
                transpositionSemitones: Int? = nil,
                tempoScale: Double? = nil,
                perNote: [PerNoteResult]? = nil,
                perPhrase: [PerPhraseResult]? = nil,
                accuracy: SessionAccuracy? = nil,
                notAssessable: NotAssessableSummary? = nil,
                grade: GradeBand? = nil,
                engineVersion: String? = nil) {
        self.contractVersion = contractVersion
        self.sessionId = sessionId
        self.bundleId = bundleId
        self.part = part
        self.createdAt = createdAt
        self.duration_s = duration_s
        self.gradingReference = gradingReference
        self.config = config
        self.latencyOffset_ms = latencyOffset_ms
        self.tuningCents = tuningCents
        self.transpositionSemitones = transpositionSemitones
        self.tempoScale = tempoScale
        self.perNote = perNote
        self.perPhrase = perPhrase
        self.accuracy = accuracy
        self.notAssessable = notAssessable
        self.grade = grade
        self.engineVersion = engineVersion
    }

    // MARK: Codable (required fields required; optionals absent when nil —
    // the synthesized encoder writes optionals with encodeIfPresent).

    private enum CodingKeys: String, CodingKey {
        case contractVersion, sessionId, bundleId, part, createdAt, duration_s
        case gradingReference, config, latencyOffset_ms, tuningCents
        case transpositionSemitones, tempoScale, perNote, perPhrase, accuracy
        case notAssessable, grade, engineVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            contractVersion: try container.decodeIfPresent(String.self, forKey: .contractVersion)
                ?? SessionResult.currentContractVersion,
            sessionId: try container.decode(String.self, forKey: .sessionId),
            bundleId: try container.decode(String.self, forKey: .bundleId),
            part: try container.decode(Part.self, forKey: .part),
            createdAt: try container.decode(String.self, forKey: .createdAt),
            duration_s: try container.decodeIfPresent(Double.self, forKey: .duration_s),
            gradingReference: try container.decodeIfPresent(GradingReferenceInfo.self, forKey: .gradingReference),
            config: try container.decodeIfPresent(GradingConfig.self, forKey: .config),
            latencyOffset_ms: try container.decodeIfPresent(Int.self, forKey: .latencyOffset_ms),
            tuningCents: try container.decodeIfPresent(Int.self, forKey: .tuningCents),
            transpositionSemitones: try container.decodeIfPresent(Int.self, forKey: .transpositionSemitones),
            tempoScale: try container.decodeIfPresent(Double.self, forKey: .tempoScale),
            perNote: try container.decodeIfPresent([PerNoteResult].self, forKey: .perNote),
            perPhrase: try container.decodeIfPresent([PerPhraseResult].self, forKey: .perPhrase),
            accuracy: try container.decodeIfPresent(SessionAccuracy.self, forKey: .accuracy),
            notAssessable: try container.decodeIfPresent(NotAssessableSummary.self, forKey: .notAssessable),
            grade: try container.decodeIfPresent(GradeBand.self, forKey: .grade),
            engineVersion: try container.decodeIfPresent(String.self, forKey: .engineVersion))
    }
}
