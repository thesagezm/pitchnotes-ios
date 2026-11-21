import XCTest
@testable import EngineCore

/// Schema round-trip tests against the EXACT JSON field names of CONTRACTS v0.0
/// (C-2.1 song.json, C-2.3 NoteTrack, C-2.4 PitchFrames). The JSON fixtures below
/// are copied verbatim from the contract document.
final class SchemaCodableTests: XCTestCase {

    // MARK: - C-2.3 NoteTrack

    func testNoteTrackDecodesContractJSON() throws {
        let json = """
        {
          "contractVersion": "v0.0",
          "part": "BASS",
          "notes": [
            { "start_s": 1.232, "end_s": 2.500, "midi": 48, "cents_ref": 12, "confidence": 0.9 }
          ]
        }
        """
        let track = try JSONDecoder().decode(NoteTrack.self, from: Data(json.utf8))
        XCTAssertEqual(track.contractVersion, "v0.0")
        XCTAssertEqual(track.part, .bass)
        XCTAssertEqual(track.notes.count, 1)
        XCTAssertEqual(track.notes[0].start_s, 1.232)
        XCTAssertEqual(track.notes[0].end_s, 2.500)
        XCTAssertEqual(track.notes[0].midi, 48)
        XCTAssertEqual(track.notes[0].cents_ref, 12)
        XCTAssertEqual(track.notes[0].confidence, 0.9)
    }

    func testNoteTrackEncodesContractFieldNames() throws {
        let track = NoteTrack(part: .t1, notes: [Note(start_s: 0.0, end_s: 1.0, midi: 64, cents_ref: -7, confidence: 0.8)])
        let data = try JSONEncoder().encode(track)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["contractVersion", "part", "notes"])
        let note = try XCTUnwrap((object["notes"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(note.keys), ["start_s", "end_s", "midi", "cents_ref", "confidence"])
    }

    // MARK: - C-2.4 PitchFrames

    func testPitchFramesDecodesContractJSON() throws {
        let json = """
        {
          "contractVersion": "v0.0",
          "part": "BASS",
          "hopMs": 16,
          "frames": [
            { "t": 0.016, "hz": 0.0, "confidence": 0.02, "loudness_db": -92.1 }
          ]
        }
        """
        let frames = try JSONDecoder().decode(PitchFramesFile.self, from: Data(json.utf8))
        XCTAssertEqual(frames.contractVersion, "v0.0")
        XCTAssertEqual(frames.part, .bass)
        XCTAssertEqual(frames.hopMs, 16)
        XCTAssertEqual(frames.frames[0].t, 0.016)
        XCTAssertEqual(frames.frames[0].hz, 0.0)
        XCTAssertEqual(frames.frames[0].loudness_db, -92.1)
    }

    // MARK: - C-2.1 song.json

    func testManifestDecodesContractJSON() throws {
        let json = """
        {
          "contractVersion": "v0.0",
          "engineVersion": "engine-0.0.0",
          "id": "01JXXXXXXXXXXXXXXXXXXXXXXX",
          "title": "Just As I Am",
          "sourceHash": { "algo": "blake3", "hex": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
          "duration_s": 213.4,
          "sampleRate": 44100,
          "hasInstrumental": true,
          "parts": [
            {
              "part": "BASS",
              "stemFile": "stems/BASS.m4a",
              "channels": 1,
              "notesFile": "notes/BASS.json",
              "pitchFile": "pitch/BASS.json",
              "noteConfidence": 0.82
            }
          ],
          "confidenceSummary": { "meanNoteConfidence": 0.78 }
        }
        """
        let manifest = try JSONDecoder().decode(SongManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.contractVersion, "v0.0")
        XCTAssertEqual(manifest.engineVersion, "engine-0.0.0")
        XCTAssertEqual(manifest.id, "01JXXXXXXXXXXXXXXXXXXXXXXX")
        XCTAssertEqual(manifest.title, "Just As I Am")
        XCTAssertEqual(manifest.sourceHash.algo, "blake3")
        XCTAssertEqual(manifest.duration_s, 213.4)
        XCTAssertEqual(manifest.sampleRate, 44100)
        XCTAssertTrue(manifest.hasInstrumental)
        XCTAssertEqual(manifest.parts.count, 1)
        XCTAssertEqual(manifest.parts[0].part, .bass)
        XCTAssertEqual(manifest.parts[0].pitchFile, "pitch/BASS.json")
        XCTAssertEqual(manifest.confidenceSummary.meanNoteConfidence, 0.78)
    }

    func testManifestPitchFileIsOmittable() throws {
        let json = """
        {
          "contractVersion": "v0.0",
          "engineVersion": "engine-0.0.0",
          "id": "01JXXXXXXXXXXXXXXXXXXXXXXX",
          "title": "No Pitch Track",
          "sourceHash": { "algo": "blake3", "hex": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
          "duration_s": 10.0,
          "sampleRate": 44100,
          "hasInstrumental": false,
          "parts": [
            {
              "part": "T1",
              "stemFile": "stems/T1.m4a",
              "channels": 1,
              "notesFile": "notes/T1.json",
              "noteConfidence": 0.5
            }
          ],
          "confidenceSummary": { "meanNoteConfidence": 0.5 }
        }
        """
        // Contract v0.0: `pitchFile` key may be OMITTED.
        let manifest = try JSONDecoder().decode(SongManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.parts[0].pitchFile)

        // And when nil, encoding must omit the key (not write null).
        let data = try JSONEncoder().encode(manifest)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let part = try XCTUnwrap((object["parts"] as? [[String: Any]])?.first)
        XCTAssertFalse(part.keys.contains("pitchFile"))
    }
}
