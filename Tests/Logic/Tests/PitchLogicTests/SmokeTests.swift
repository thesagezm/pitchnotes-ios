import XCTest
@testable import PitchLogic

// M0 placeholder so the `logic-tests` CI job runs real `swift test` infra
// (L-004). Jess REPLACES this file with the real suite in J-004: cents
// conversion, Part enum round-trip, manifest/NoteTrack/PitchFrame schema
// validation (red→green against P-001's fixtures).
final class SmokeTests: XCTestCase {
    func testContractVersionMatchesContractsDoc() {
        XCTAssertEqual(PitchLogicInfo.contractVersion, "v0.0")
    }
}
