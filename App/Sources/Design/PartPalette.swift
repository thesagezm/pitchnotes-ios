import SwiftUI
import EngineCore

// PartPalette — one color per C-1 part, for the piano roll (J-301) and the
// part chips.
//
// UX §1.1 principle: STATE NEVER RELIES ON HUE ALONE. Every place a part
// color appears, the part NAME appears with it (the chip row, the legend, the
// VoiceOver text, the note-detail sheet). The colors are also chosen to stay
// distinguishable in light AND dark mode and to avoid the red/green axis as
// the only difference between two parts.
//
// The palette is UI-ONLY (like PartDisplay in PitchLogic): it never feeds
// engine logic, scoring, or persistence.

enum PartPalette {

    /// Dynamic (light/dark) color for a part.
    static func color(for part: Part) -> Color {
        Color(hexLight: lightHex(for: part), dark: darkHex(for: part))
    }

    /// Secondary/dimmer variant — used for a part that is ABSENT in the
    /// current phrase (D-41 §2: dimmed, never hidden).
    static func dimmedColor(for part: Part) -> Color {
        color(for: part).opacity(0.28)
    }

    private static func lightHex(for part: Part) -> UInt32 {
        switch part {
        case .t1: return 0x3B6FE0          // accent blue
        case .t2: return 0x0E8C86          // teal
        case .baritenor: return 0x7A5CD0   // violet
        case .baritone: return 0xD97E00    // amber
        case .bass: return 0x2E9E5B        // green
        case .soprano: return 0xC2437A     // magenta
        case .alto: return 0x8A5A2B        // brown
        case .lead: return 0x4A4FC7        // indigo
        case .vp: return 0x6C7280          // gray — structural parts
        case .instrumental: return 0x8E939E
        case .vocals: return 0x8E939E
        }
    }

    private static func darkHex(for part: Part) -> UInt32 {
        switch part {
        case .t1: return 0x6E9BFF
        case .t2: return 0x43C2B4
        case .baritenor: return 0xA48CF0
        case .baritone: return 0xFFA940
        case .bass: return 0x4CCB82
        case .soprano: return 0xE56A9F
        case .alto: return 0xC08A52
        case .lead: return 0x8B8FF0
        case .vp: return 0x7C828E
        case .instrumental: return 0x7C828E
        case .vocals: return 0x7C828E
        }
    }
}
