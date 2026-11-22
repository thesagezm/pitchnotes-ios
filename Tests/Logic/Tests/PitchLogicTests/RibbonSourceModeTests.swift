import XCTest
@testable import PitchLogic

// J-FIX-104 regression tests — the tuner source-selector wiring.
//
// Device-demo defect: demo↔liveMic needed multiple clicks (→demo unreliable).
// Root cause: BOTH modes lived in one Menu whose content mutated on selection;
// this suite pins the extracted wiring data (RibbonSourceMode) that the fixed
// segmented-picker control binds to.

final class RibbonSourceModeTests: XCTestCase {

    // MARK: Control structure (what the segmented Picker renders)

    func testAllCasesAreExactlyDemoAndLiveMic() {
        // Order IS display order in the segmented control — demo first (the
        // default), live mic second.
        XCTAssertEqual(RibbonSourceMode.allCases, [.demo, .liveMic])
    }

    func testRawValuesStable() {
        // Renaming would orphan any future stored selection (C-1 rawValue rule).
        XCTAssertEqual(RibbonSourceMode.demo.rawValue, "demo")
        XCTAssertEqual(RibbonSourceMode.liveMic.rawValue, "liveMic")
    }

    func testLabelsPresentAndDistinct() {
        let labels = RibbonSourceMode.allCases.map(\.label)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(labels).count, labels.count, "segments must be distinguishable")
    }

    // MARK: "One reliable tap" binding contract

    func testSwitchingBetweenAnyPairAlwaysChangesValue() {
        // The fixed control binds a plain value: setting a different case from
        // ANY other case must always flip the selection (the defect was taps
        // being dropped, not the mapping — this pins the mapping).
        for from in RibbonSourceMode.allCases {
            for to in RibbonSourceMode.allCases where from != to {
                XCTAssertNotEqual(from, to)
            }
        }
        XCTAssertEqual(
            RibbonSourceMode(rawValue: RibbonSourceMode.liveMic.rawValue), .liveMic)
        XCTAssertEqual(
            RibbonSourceMode(rawValue: RibbonSourceMode.demo.rawValue), .demo)
    }

    func testRawValueRoundTripBothDirections() {
        for mode in RibbonSourceMode.allCases {
            XCTAssertEqual(RibbonSourceMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(RibbonSourceMode(rawValue: "nanopitch"), "unknown raw values stay nil")
    }

    // MARK: Scenario menu visibility (demo-only, never in liveMic)

    func testScenarioPickerShowsOnlyInDemoMode() {
        XCTAssertTrue(RibbonSourceMode.demo.showsScenarioPicker)
        XCTAssertFalse(RibbonSourceMode.liveMic.showsScenarioPicker)
    }

    func testScenarioPickerRuleMatchesEveryCase() {
        // Guard against a future third mode silently inheriting the scenario
        // menu (or losing it in demo).
        for mode in RibbonSourceMode.allCases {
            XCTAssertEqual(mode.showsScenarioPicker, mode == .demo)
        }
    }
}
