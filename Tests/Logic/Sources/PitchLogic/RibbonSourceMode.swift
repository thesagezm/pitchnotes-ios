import Foundation
import EngineCore

// RibbonSourceMode (J-FIX-104) — the tuner's frame-source selection, extracted
// from RibbonModel (App target) into PitchLogic so the control wiring is
// unit-testable (logic-tests cannot see SwiftUI).
//
// WHY this exists: the M1 device demo (UX §10.1) found the demo↔liveMic switch
// unreliable — both modes shared ONE Menu whose content mutated on selection
// (the demo menu additionally lists 8 scenarios), so re-opening it after a
// switch raced the relayout and taps were dropped. The fix moves mode selection
// to a segmented Picker (one tap in either direction, fixed hit targets) and
// keeps the scenario list as a separate demo-only menu. The decision data lives
// here; the view only binds.

/// Raw values STABLE (persisted-by-rawValue precedent; nothing writes them yet,
/// but renaming would orphan any future stored selection — same rule as C-1).
public enum RibbonSourceMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    /// Scripted MockEngine singer (M1 device-demo input; also the offline-safe
    /// default). Label in the segmented control.
    case demo
    /// The REAL causal ribbon via `LivePitchEngine.ribbonFrame(_:)` (C-6.0:
    /// engine_id RIBBON_MPM_YIN, lookahead_ms 0). Standalone-tuner semantics.
    case liveMic

    public var id: String { rawValue }

    /// Segmented-control label. Short by design — segments are fixed-width and
    /// must not truncate at dynamic-type sizes.
    public var label: String {
        switch self {
        case .demo: return "Demo"
        case .liveMic: return "Live mic"
        }
    }

    /// The demo-scenario menu (8 MockScenario rows) is shown ONLY in demo mode.
    /// In liveMic mode there is nothing to pick — the real engine has no script.
    public var showsScenarioPicker: Bool {
        self == .demo
    }
}
