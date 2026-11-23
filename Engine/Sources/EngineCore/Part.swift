import Foundation

/// C-1 · Part enum (CONTRACTS.md v0.0 RATIFIED 2026-11-20 UTC — L-006; v1.0
/// FROZEN 2026-11-22 UTC — L-203, additive `vocals`).
///
/// Verbatim from CONTRACTS C-1. Raw values are STABLE FOREVER (AGENTS §7):
/// nothing here may change its raw string values, only add new cases (additive).
/// File/directory names use the rawValue verbatim (e.g. `stems/BASS.m4a`,
/// `stems/VOCALS.m4a`, `notes/T1.json`) — case-sensitive.
public enum Part: String, Codable, CaseIterable, Sendable, Comparable {
    case bass          = "BASS"
    case baritone      = "BARITONE"
    case baritenor     = "BARITENOR"
    case t2            = "T2"
    case t1            = "T1"
    case soprano       = "SOPRANO"   // female chorales only
    case alto          = "ALTO"      // female chorales only
    case vp            = "VP"        // vocal percussion
    case lead          = "LEAD"      // featured soloist within a song
    case instrumental  = "INSTRUMENTAL"
    case vocals        = "VOCALS"    // v1.0 (L-203): two-stem separation output
                                     // (M2); structural marker, never graded

    /// Contractual display/assignment order (see above).
    public var sortOrder: Int {
        switch self {
        case .soprano: return 0
        case .alto: return 1
        case .t1: return 2
        case .t2: return 3
        case .baritenor: return 4
        case .baritone: return 5
        case .bass: return 6
        case .vp: return 7
        case .lead: return 8
        case .instrumental: return 9
        case .vocals: return 10    // v1.0 (L-203): appended — no pre-existing
                                   // sortOrder value changed (additive rule)
        }
    }
    public static func < (l: Part, r: Part) -> Bool { l.sortOrder < r.sortOrder }

    /// Voice parts that get note tracks + grading (instrumental/VP/VOCALS are
    /// structural markers handled separately).
    public var isSingableVoice: Bool {
        switch self {
        case .bass, .baritone, .baritenor, .t2, .t1, .soprano, .alto, .lead: return true
        case .vp, .instrumental, .vocals: return false
        }
    }
}
