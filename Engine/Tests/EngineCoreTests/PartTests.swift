import XCTest
@testable import EngineCore

/// C-1 Part enum contract tests (rawValues STABLE FOREVER — CONTRACTS v0.0).
final class PartTests: XCTestCase {

    func testRawValuesAreContractExact() {
        let expected: [(Part, String)] = [
            (.bass, "BASS"), (.baritone, "BARITONE"), (.baritenor, "BARITENOR"),
            (.t2, "T2"), (.t1, "T1"), (.soprano, "SOPRANO"), (.alto, "ALTO"),
            (.vp, "VP"), (.lead, "LEAD"), (.instrumental, "INSTRUMENTAL"),
        ]
        XCTAssertEqual(Part.allCases.count, 10)
        for (part, raw) in expected {
            XCTAssertEqual(part.rawValue, raw)
            XCTAssertEqual(Part(rawValue: raw), part)
        }
    }

    func testSortOrderMatchesContract() {
        // C-1 sortOrder is contractual AND numeric: soprano 0, alto 1, t1 2, t2 3,
        // baritenor 4, baritone 5, bass 6, vp 7, lead 8, instrumental 9. The C-1
        // sentence "bass < baritone < …" is the voice-RANK reading for the P-303
        // no-crossing constraint (bass = lowest voice); Comparable compares the
        // numeric sortOrder (score layout order). Both are asserted here.
        let expectedOrder: [(Part, Int)] = [
            (.soprano, 0), (.alto, 1), (.t1, 2), (.t2, 3), (.baritenor, 4),
            (.baritone, 5), (.bass, 6), (.vp, 7), (.lead, 8), (.instrumental, 9),
        ]
        for (part, order) in expectedOrder {
            XCTAssertEqual(part.sortOrder, order, part.rawValue)
        }
        // Comparable = numeric sortOrder ascending (layout order).
        XCTAssertTrue(Part.soprano < Part.alto)
        XCTAssertTrue(Part.alto < Part.t1)
        XCTAssertTrue(Part.t1 < Part.t2)
        XCTAssertTrue(Part.t2 < Part.baritenor)
        XCTAssertTrue(Part.baritenor < Part.baritone)
        XCTAssertTrue(Part.baritone < Part.bass)
        XCTAssertTrue(Part.bass < Part.vp)
        XCTAssertTrue(Part.vp < Part.lead)
        XCTAssertTrue(Part.lead < Part.instrumental)
        // Voice-rank reading (P-303 no-crossing): bass is the LOWEST voice —
        // first in pitch order = last among voices by numeric sortOrder.
        XCTAssertTrue(Part.bass.sortOrder > Part.baritone.sortOrder)
    }

    func testIsSingableVoice() {
        let singable: Set<Part> = [.bass, .baritone, .baritenor, .t2, .t1, .soprano, .alto, .lead]
        for part in Part.allCases {
            XCTAssertEqual(part.isSingableVoice, singable.contains(part), "part \(part.rawValue)")
        }
    }

    func testCodableRoundTrip() throws {
        for part in Part.allCases {
            let data = try JSONEncoder().encode(part)
            let decoded = try JSONDecoder().decode(Part.self, from: data)
            XCTAssertEqual(decoded, part)
        }
        // Invalid rawValue must not decode (V6 relies on this).
        XCTAssertThrowsError(try JSONDecoder().decode(Part.self, from: Data("\"TENOR_1\"".utf8)))
    }
}
