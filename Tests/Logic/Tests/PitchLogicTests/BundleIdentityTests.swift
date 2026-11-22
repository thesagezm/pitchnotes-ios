import XCTest
import EngineCore
@testable import PitchLogic

// BundleIdentity tests (J-208) — the C-9 "which bundle did this import
// publish" fact (CONTRACTS v1.0.1, D-34), as PURE rules:
//
//   · C-9 rule 2: the consumer MUST prefer the producer's id;
//   · C-9 rule 3: the consumer MAY derive the id from a stem URL;
//   · C-9 rule 4: the id is a directory name only;
//   · C-9 rule 1 + C-2.2: only a COMPLETE bundle (song.json present) may be
//     named — a half-written bundle is never registered.
//
// These hold in BOTH worlds (pre- and post-swap): the pure rules do not
// depend on which module carries the C-9 protocol.

final class BundleIdentityTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/library", isDirectory: true)

    private func stemURL(id: String, part: String = "VOCALS") -> URL {
        root.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("stems", isDirectory: true)
            .appendingPathComponent("\(part).m4a")
    }

    // MARK: - Rule 4 (id shape)

    func testLegalBundleIDsAreAccepted() {
        XCTAssertTrue(BundleIdentity.isValidBundleID("01JABCDEF"))
        XCTAssertTrue(BundleIdentity.isValidBundleID("song-2026-11-22"))
        XCTAssertTrue(BundleIdentity.isValidBundleID("a.b_c"))
    }

    func testPathTricksAreRejected() {
        XCTAssertFalse(BundleIdentity.isValidBundleID(""))
        XCTAssertFalse(BundleIdentity.isValidBundleID("."))
        XCTAssertFalse(BundleIdentity.isValidBundleID(".."))
        XCTAssertFalse(BundleIdentity.isValidBundleID("a/b"))
        XCTAssertFalse(BundleIdentity.isValidBundleID("a\\b"))
        XCTAssertFalse(BundleIdentity.isValidBundleID("..evil"))
        XCTAssertFalse(BundleIdentity.isValidBundleID("a\0b"))
        XCTAssertFalse(BundleIdentity.isValidBundleID("C:evil"))
    }

    // MARK: - Rule 3 (derivation)

    func testBundleDirectoryIsTheGrandparentOfAStemURL() {
        let url = stemURL(id: "01JXYZ")
        XCTAssertEqual(BundleIdentity.bundleDirectoryURL(forStemURL: url).lastPathComponent, "01JXYZ")
        XCTAssertEqual(BundleIdentity.candidateBundleID(forStemURL: url), "01JXYZ")
    }

    func testCandidateFromStemsPicksTheSharedParent() {
        // Parts that exist in BOTH the M1-era and the v1.0 EngineCore (the
        // `.vocals` case only arrives with Paul's merge).
        let stems: [Part: URL] = [
            .t1: stemURL(id: "01JXYZ", part: "T1"),
            .instrumental: stemURL(id: "01JXYZ", part: "INSTRUMENTAL"),
        ]
        XCTAssertEqual(BundleIdentity.candidateBundleID(fromStems: stems), "01JXYZ")
    }

    func testCandidateFromStemsIsNilWithoutStems() {
        XCTAssertNil(BundleIdentity.candidateBundleID(fromStems: [:]))
    }

    // MARK: - Rules 1 + 2 + 3 (the resolution)

    func testProducerIDWinsOverTheDerivedOne() {
        XCTAssertEqual(
            BundleIdentity.resolve(producerID: "from-protocol", derivedID: "from-stems",
                                  producerBundleIsComplete: true, derivedBundleIsComplete: true),
            "from-protocol")
    }

    func testDerivedIDIsUsedWhenTheProducerNamesNothing() {
        XCTAssertEqual(
            BundleIdentity.resolve(producerID: nil, derivedID: "from-stems",
                                  producerBundleIsComplete: false, derivedBundleIsComplete: true),
            "from-stems")
    }

    func testDerivedIDIsUsedWhenTheProducerNamesAnIncompleteBundle() {
        // A producer id whose bundle is not complete must not be registered —
        // the derived one is used when IT is complete.
        XCTAssertEqual(
            BundleIdentity.resolve(producerID: "half-written", derivedID: "from-stems",
                                  producerBundleIsComplete: false, derivedBundleIsComplete: true),
            "from-stems")
    }

    func testNoCompleteBundleMeansNoID() {
        XCTAssertNil(
            BundleIdentity.resolve(producerID: "half-written", derivedID: nil,
                                  producerBundleIsComplete: false, derivedBundleIsComplete: false))
        XCTAssertNil(
            BundleIdentity.resolve(producerID: nil, derivedID: "also-half-written",
                                  producerBundleIsComplete: false, derivedBundleIsComplete: false))
    }

    func testIllegalIDsAreNeverResolved() {
        XCTAssertNil(
            BundleIdentity.resolve(producerID: "../escape", derivedID: nil,
                                  producerBundleIsComplete: true, derivedBundleIsComplete: false))
        XCTAssertNil(
            BundleIdentity.resolve(producerID: nil, derivedID: "../escape",
                                  producerBundleIsComplete: false, derivedBundleIsComplete: true))
    }

    // MARK: - The honest engine label (D-12)

    func testMockEngineSaysItIsAMock() {
        XCTAssertEqual(ImportEngineKind.mock.statusLine,
                       "DEMO ENGINE (mock) — no real separation was run.")
        XCTAssertFalse(ImportEngineKind.mock.isReal)
    }

    func testRealEngineSaysItIsReal() {
        XCTAssertTrue(ImportEngineKind.real.isReal)
        XCTAssertEqual(ImportEngineKind.real.statusLine, "Real engine (htdemucs fp16).")
    }

    // MARK: - The PRE-import badge (J-208, session 6 — UX §10.2 step 0)

    func testAvailabilitySaysReadyWhenTheRealEngineAndTheWeightsAreThere() {
        let availability = ImportEngineAvailability.resolve(compiledIn: true, modelPresent: true)
        XCTAssertEqual(availability, .realReady)
        XCTAssertTrue(availability.isReal)
        XCTAssertTrue(availability.statusLine.contains("Real engine"),
                      "the demo badge must read 'Real engine': \(availability.statusLine)")
        XCTAssertTrue(availability.statusLine.contains("ready"), availability.statusLine)
    }

    func testAvailabilitySaysTheModelIsMissingWhenOnlyTheWeightsAreAbsent() {
        let availability = ImportEngineAvailability.resolve(compiledIn: true, modelPresent: false)
        XCTAssertEqual(availability, .realModelMissing)
        XCTAssertTrue(availability.isReal, "the real engine IS in the build — only the model is missing")
        XCTAssertTrue(availability.statusLine.contains("Settings"), availability.statusLine)
    }

    func testAvailabilitySaysMockWhenNeitherTheEngineNorTheWeightsAreThere() {
        let availability = ImportEngineAvailability.resolve(compiledIn: false, modelPresent: false)
        XCTAssertEqual(availability, .mockOnly)
        XCTAssertFalse(availability.isReal)
        XCTAssertTrue(availability.statusLine.contains("DEMO ENGINE (mock)"), availability.statusLine)
    }

    func testAvailabilityDoesNotPromiseAMockWhenTheWeightsAreAlreadyOnTheDevice() {
        let availability = ImportEngineAvailability.resolve(compiledIn: false, modelPresent: true)
        XCTAssertEqual(availability, .realUnavailable)
        XCTAssertFalse(availability.isReal)
        XCTAssertTrue(availability.statusLine.contains("fail"),
                      "the import FAILS in this world — the badge must not imply a mock runs: \(availability.statusLine)")
    }

    func testAvailabilityNeverUsesZeroLikeWording() {
        for availability in [ImportEngineAvailability.realReady,
                             .realModelMissing,
                             .mockOnly,
                             .realUnavailable] {
            XCTAssertFalse(availability.statusLine.isEmpty)
            XCTAssertFalse(availability.statusLine.contains("0.00"), availability.statusLine)
        }
    }
}
