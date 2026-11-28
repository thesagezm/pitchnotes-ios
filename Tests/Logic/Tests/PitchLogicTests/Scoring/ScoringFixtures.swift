import Foundation
import XCTest
import EngineCore
@testable import PitchLogic

// Support for the J-401 Scoring suite — the fixture loader + stream builders.
// NOT a test file (the L-402 gate counts `func test` in Scoring/*.swift; this
// file carries none).
//
// FIXTURES: the committed L-402 session fixtures live at
// `Tests/Sessions/fixtures/*.json` (11 scenarios, generator + integrity gate
// ALWAYS blocking). Read via `#filePath` — the ImportKit pattern; no
// Package.swift resource declaration needed. The fixtures carry DATA
// invariants and contract pins, deliberately NOT expected hit/miss verdicts —
// computing those is what the grader under test does.

enum SessionFixtures {

    struct Loaded {
        let name: String
        let raw: [String: Any]
        let description: String
        let reference: NoteTrack
        let live: [PitchFrame]
        var environment: SessionEnvironment
        let correctionOverlay: PartCorrectionOverlay?
        let expectedClasses: [String]?
        let expectedTransformed: [[String: Any]]?
    }

    /// The repo root, resolved from THIS file's path:
    /// `<root>/Tests/Logic/Tests/PitchLogicTests/Scoring/` — six components
    /// above the file itself (the file, Scoring, PitchLogicTests, Tests,
    /// Logic, Tests).
    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url = url.deletingLastPathComponent() }
        return url
    }

    static func dictionary(_ name: String) throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent("Tests/Sessions/fixtures/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    static func load(_ name: String) throws -> Loaded {
        let raw = try dictionary(name)
        let liveObject = try XCTUnwrap(raw["live"] as? [String: Any])
        return Loaded(
            name: name,
            raw: raw,
            description: try XCTUnwrap(raw["description"] as? String),
            reference: try decode(NoteTrack.self, from: XCTUnwrap(raw["reference"])),
            live: try decode([PitchFrame].self, from: XCTUnwrap(liveObject["frames"])),
            environment: try decode(SessionEnvironment.self, from: XCTUnwrap(raw["environment"])),
            correctionOverlay: try raw["correctionOverlay"].map {
                try decode(PartCorrectionOverlay.self, from: $0)
            },
            expectedClasses: raw["expectedClasses"] as? [String],
            expectedTransformed: raw["expectedTransformed"] as? [[String: Any]])
    }

    /// Grades a loaded fixture with the suite's fixed identity (determinism:
    /// the grader never reads the clock, so every test passes explicit values).
    static func grade(_ fixture: Loaded,
                      config: GradingConfig = .default,
                      gradingReference: GradingReferenceInfo = GradingReferenceInfo(source: .heuristic),
                      golden: Set<Int> = []) throws -> SessionResult {
        try SessionGrader.grade(reference: fixture.reference,
                                live: fixture.live,
                                config: config,
                                environment: fixture.environment,
                                gradingReference: gradingReference,
                                goldenNoteIndices: golden,
                                sessionId: "fixture-session-\(fixture.name)",
                                bundleId: "fixture-bundle",
                                createdAt: "2026-11-27T12:00:00Z")
    }

    // MARK: - Synthetic stream builders (the fixtures' generator conventions)

    /// Hz for a pitch expressed in cents (A4 = 6900) — the generator's own
    /// closed form.
    static func hzOf(cents: Double) -> Double {
        440.0 * pow(2.0, (cents - 6900.0) / 1200.0)
    }

    static func frame(t: Double, cents: Double, voiced: Bool = true,
                      loudness_db: Double = -30.0) -> PitchFrame {
        PitchFrame(t: t,
                   hz: voiced ? hzOf(cents: cents) : 0.0,
                   confidence: voiced ? 0.95 : 0.02,
                   loudness_db: voiced ? loudness_db : -75.0,
                   engine_id: "SWIFTF0",
                   lookahead_ms: 176)
    }

    /// A contiguous 16 ms session stream: voiced at each note's cents inside
    /// its span, unvoiced between notes (inter-note silence is unvoiced
    /// frames, never absent ones), with optional grid HOLES (absent frames —
    /// the uncovered-span reality `notAssessableReason: "noLiveFrames"` is for).
    static func stream(notes: [(start: Double, end: Double, cents: Double)],
                       holes: [(Double, Double)] = []) -> [PitchFrame] {
        guard let first = notes.map(\.start).min(), let last = notes.map(\.end).max() else { return [] }
        let t0 = (first / 0.016).rounded(.up) * 0.016
        var frames: [PitchFrame] = []
        var t = t0
        while t < last - 1e-9 {
            defer { t += 0.016 }
            if holes.contains(where: { $0.0 - 1e-9 <= t && t < $0.1 - 1e-9 }) { continue }
            if let note = notes.first(where: { $0.start - 1e-9 <= t && t < $0.end - 1e-9 }) {
                frames.append(frame(t: t, cents: note.cents))
            } else {
                frames.append(frame(t: t, cents: 0, voiced: false))
            }
        }
        return frames
    }

    // MARK: - Reference builders

    static func note(_ start: Double, _ end: Double, _ midi: Int,
                     cents_ref: Int = 0, confidence: Double = 0.9) -> Note {
        Note(start_s: start, end_s: end, midi: midi, cents_ref: cents_ref,
             confidence: confidence)
    }

    static func track(_ part: Part, _ notes: [Note]) -> NoteTrack {
        NoteTrack(part: part, notes: notes)
    }

    /// The grader call with the suite's fixed identity.
    static func grade(reference: NoteTrack,
                      live: [PitchFrame],
                      config: GradingConfig = .default,
                      environment: SessionEnvironment = SessionEnvironment(),
                      gradingReference: GradingReferenceInfo = GradingReferenceInfo(source: .heuristic),
                      golden: Set<Int> = []) throws -> SessionResult {
        try SessionGrader.grade(reference: reference,
                                live: live,
                                config: config,
                                environment: environment,
                                gradingReference: gradingReference,
                                goldenNoteIndices: golden,
                                sessionId: "synthetic-session",
                                bundleId: "synthetic-bundle",
                                createdAt: "2026-11-27T12:00:00Z")
    }
}
