import XCTest
import EngineCore
@testable import PitchLogic

// ManifestContents tests (J-202/J-205) — the J-lane's read-only view over
// EngineCore's manifest model. The load-bearing case (a v1.x two-stem bundle
// whose parts declare NO notesFile) becomes constructible only once the v1.0
// PartInfo (optional `notesFile`) lands with Paul's engine merge — it is
// covered at the SWAP (see the swap commit); the cases below hold in BOTH
// worlds.

final class ManifestContentsTests: XCTestCase {

    private func manifest(partsJSON: String, contractVersion: String = "v1.0") throws -> SongManifest {
        let json = """
        {
          "contractVersion": "\(contractVersion)",
          "engineVersion": "mock-test",
          "id": "01JTTTTTTTTTTTTTTTTTTTTTTT",
          "title": "Contents probe",
          "sourceHash": { "algo": "blake3", "hex": "\(String(repeating: "a", count: 64))" },
          "duration_s": 30.0,
          "sampleRate": 44100,
          "channels": 1,
          "tuning_cents": 0,
          "hasInstrumental": false,
          "parts": [\(partsJSON)],
          "confidenceSummary": { "meanNoteConfidence": 0.8 }
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(SongManifest.self, from: json)
    }

    func testManifestWithANotesFileHasNoteTracks() throws {
        let m = try manifest(partsJSON: #"""
            { "part": "T1", "stemFile": "stems/T1.m4a", "channels": 1, "notesFile": "notes/T1.json", "noteConfidence": 0.8 }
            """#)
        XCTAssertTrue(ManifestContents.hasNoteTracks(in: m),
                      "a part that declares a notesFile carries a note track")
    }

    func testManifestWithNoPartsHasNoNoteTracks() throws {
        let m = try manifest(partsJSON: "")
        XCTAssertFalse(ManifestContents.hasNoteTracks(in: m),
                       "no parts ⇒ no note tracks ⇒ the confidence summary is undefined")
    }

    /// The v0-era shape (parts always declared their notesFile) — the
    /// predicate must agree with the engine's model, not with an era.
    func testV0EraManifestWithNotesFileHasNoteTracks() throws {
        let m = try manifest(partsJSON: #"""
            { "part": "T1", "stemFile": "stems/T1.m4a", "channels": 1, "notesFile": "notes/T1.json", "noteConfidence": 0.8 }
            """#, contractVersion: "v0.0")
        XCTAssertTrue(ManifestContents.hasNoteTracks(in: m))
    }
}
