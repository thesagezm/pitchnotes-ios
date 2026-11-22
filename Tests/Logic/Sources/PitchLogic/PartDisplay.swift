// PartDisplay — UI-only presentation for CONTRACTS C-1 Part raw values.
//
// The raw values and ordering are contract (EngineCore.Part, stable forever);
// display names are UX surface (Docs/UX.md §3.6 chips) and live in Jess's
// logic core so the app, ribbon (J-101), and tests share ONE spelling.
// UI-only by contract: nothing here feeds engine logic or persistence.

import Foundation
import EngineCore

extension Part {
    /// Human chip label ("Bass", "T2", …). Scientific note names in range
    /// presets come from PitchMath.noteName, not from here.
    public var displayName: String {
        switch self {
        case .bass: return "Bass"
        case .baritone: return "Baritone"
        case .baritenor: return "Baritenor"
        case .t2: return "T2"
        case .t1: return "T1"
        case .soprano: return "Soprano"
        case .alto: return "Alto"
        case .vp: return "VP"
        case .lead: return "Lead"
        case .instrumental: return "Instrumental"
        }
    }
}
