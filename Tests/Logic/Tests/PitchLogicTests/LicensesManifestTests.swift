import XCTest
import EngineCore
@testable import PitchLogic

// J-204 licenses-screen honesty tests: every shipped dependency is listed,
// Tier B entries carry D-30's exact honest line (never presented as clean),
// dettato entries carry the NOTICE duty, study-only repos are marked never-
// shipped, and the tier/ships invariant holds.

final class LicensesManifestTests: XCTestCase {

    func testEveryEntryHasCompleteFields() {
        XCTAssertFalse(LicensesCatalog.entries.isEmpty)
        for entry in LicensesCatalog.entries {
            XCTAssertFalse(entry.name.isEmpty, "name")
            XCTAssertFalse(entry.role.isEmpty, "role for \(entry.name)")
            XCTAssertFalse(entry.license.isEmpty, "license for \(entry.name)")
            XCTAssertFalse(entry.shipsIn.isEmpty, "shipsIn for \(entry.name)")
        }
    }

    func testShipsInvariantOnlyForShipSafeAndTierB() {
        for entry in LicensesCatalog.entries {
            let shouldShip = entry.tier == .shipSafe || entry.tier == .tierB
            XCTAssertEqual(entry.ships, shouldShip,
                           "\(entry.name): ships ⇔ tier is ship-safe/tier-b")
        }
        XCTAssertTrue(LicensesCatalog.entries.contains { $0.tier == .tierB },
                      "the Tier B row exists (htdemucs) — honesty must be exercised")
        XCTAssertTrue(LicensesCatalog.entries.contains { $0.tier == .studyOnly },
                      "study-only rows exist — the screen says what we do NOT ship")
    }

    func testTierBEntriesCarryD30ExactLine() {
        let tierB = LicensesCatalog.entries.filter { $0.tier == .tierB }
        XCTAssertFalse(tierB.isEmpty)
        for entry in tierB {
            XCTAssertTrue(entry.note.contains(LicensesCatalog.tierBProvenanceLine),
                          "\(entry.name) must carry D-30's exact honest line verbatim")
            XCTAssertTrue(entry.note.contains("MUSDB18"))
            XCTAssertTrue(entry.note.contains("NOT certified clean"),
                          "Tier B copy must state it is NOT clean (never presented as clean)")
        }
    }

    func testDettatoEntriesCarryNoticeDuty() {
        let dettato = LicensesCatalog.entries.filter { $0.name.contains("dettato") }
        XCTAssertFalse(dettato.isEmpty, "dettato-derived row present (Apache-2.0 NOTICE)")
        for entry in dettato {
            XCTAssertTrue(entry.note.contains("Apache-2.0 NOTICE"), "\(entry.name) NOTICE duty")
            XCTAssertTrue(entry.note.contains("D-21"), "training-data ruling referenced")
        }
    }

    func testStudyOnlyReposAreNeverShipped() {
        let neverShipped = ["Muskey", "Nightingale", "Rubber Band"]
        for name in neverShipped {
            guard let entry = LicensesCatalog.entries.first(where: { $0.name.contains(name) }) else {
                XCTFail("study-only row missing: \(name)")
                continue
            }
            XCTAssertEqual(entry.tier, .studyOnly)
            XCTAssertFalse(entry.ships)
            XCTAssertTrue(entry.shipsIn.contains("never"))
        }
    }

    func testRequiredShippedDependenciesAreListed() {
        // Eigen ships compiled into the M2 separation path (D-32.5 header-only
        // MPL-2.0 exception) — its absence would be a license-screen lie.
        let mustShip = ["ONNX Runtime", "SwiftF0", "Silero VAD", "demucs.cpp", "htdemucs", "Eigen"]
        for name in mustShip {
            XCTAssertTrue(LicensesCatalog.entries.contains { $0.name.contains(name) },
                          "required shipped dep missing from the catalog: \(name)")
        }
    }

    func testShippedSubsetIsOrderedAndNonEmpty() {
        let shipped = LicensesCatalog.shipped
        XCTAssertGreaterThanOrEqual(shipped.count, 5)
        XCTAssertTrue(shipped.contains { $0.tier == .tierB },
                      "the shipped list contains the Tier B entry — we never hide it")
    }

    // MARK: - D-46 (the basic-pitch weights are TIER C)

    func testTheBasicPitchWeightsAreTierCAndNeverCalledClean() {
        guard let entry = LicensesCatalog.entries.first(where: { $0.name.contains("basic-pitch") }) else {
            XCTFail("the basic-pitch row is missing from the catalog")
            return
        }
        XCTAssertEqual(entry.tier, .tierC,
                       "D-46: the ICASSP-2022 weights are TIER C — study-only for commercial distribution")
        XCTAssertFalse(entry.ships,
                       "a Tier C entry is not shipped (LicenseEntry.ships ⇔ ship-safe / Tier B)")
        // The CODE is unaffected — it stays Apache-2.0.
        XCTAssertTrue(entry.license.contains("Apache-2.0"),
                      "the code licence is unchanged by D-46")
        // The NC provenance is NAMED — MAESTRO / MedleyDB-pitch / iKala.
        XCTAssertTrue(entry.note.contains("MAESTRO"), "MAESTRO must be named")
        XCTAssertTrue(entry.note.contains("MedleyDB-pitch"), "MedleyDB-pitch must be named")
        XCTAssertTrue(entry.note.contains("iKala"), "iKala must be named")
        // NEVER presented as clean.
        XCTAssertFalse(entry.note.lowercased().contains("clean"),
                       "the Tier C line must never contain the word 'clean'")
        XCTAssertTrue(entry.note.contains("STUDY-ONLY FOR COMMERCIAL DISTRIBUTION"),
                      "the Tier C line must state the study-only consequence")
    }

    func testEveryTierCEntryIsListedAndNotShipped() {
        let tierC = LicensesCatalog.entries.filter { $0.tier == .tierC }
        XCTAssertFalse(tierC.isEmpty, "the Tier C rows exist — the screen says what we do NOT ship")
        for entry in tierC {
            XCTAssertFalse(entry.ships, "\(entry.name) must not be shipped")
            XCTAssertFalse(entry.note.isEmpty, "\(entry.name) must carry its verdict")
        }
    }
}
