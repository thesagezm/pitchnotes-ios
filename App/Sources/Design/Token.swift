import SwiftUI
import UIKit

// Design tokens — single source of truth is Docs/UX.md §1 (J-003).
// Semantic colors resolve light/dark at draw time; neutral surfaces intentionally
// use system colors (free dark mode + Increase Contrast support).

/// Spacing grid (4 pt base), corner radii, motion constants. UX §1.3.
enum Token {
    enum Spacing {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 24
        static let s6: CGFloat = 32
    }

    enum Radius {
        static let chip: CGFloat = 8
        static let card: CGFloat = 12
        static let sheet: CGFloat = 16
    }

    enum Motion {
        /// Standard transition duration (UX §1.3: ≤ 250 ms).
        static let quick: Double = 0.25
    }

    enum Fonts {
        static let title = Font.largeTitle.weight(.bold)
        static let heading = Font.title3.weight(.semibold)
        static let body = Font.body
        static let caption = Font.caption
        /// Numeric readouts (cents, scores) — monospaced digits, UX §1.2.
        static let numeric = Font.body.monospacedDigit()
    }
}

extension Color {
    /// Dynamic light/dark color from UX §1.1 hex pairs, resolved per trait.
    /// Module-wide (not file-private): J-301's PartPalette needs the SAME
    /// initializer — a second private copy in another file redeclares the
    /// same member on the same type.
    init(hexLight light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hexDark: dark) : UIColor(hexDark: light)
        })
    }

    // Ribbon + brand semantics (UX §1.1). State never relies on hue alone —
    // call sites pair colors with arrows/text per UX §3.4.
    static let pnAccent = Color(hexLight: 0x3B6FE0, dark: 0x6E9BFF)
    static let inTune = Color(hexLight: 0x2E9E5B, dark: 0x4CCB82)
    static let flat = Color(hexLight: 0xD97E00, dark: 0xFFA940)
    static let sharp = Color(hexLight: 0x7A5CD0, dark: 0xA48CF0)
    static let octaveWarn = Color(hexLight: 0xC24343, dark: 0xE56A6A)
    static let referenceBar = Color(hexLight: 0x9AA0AC, dark: 0x6E7480)
    /// Opacity is applied at the call site (UX §1.1: 45% base).
    static let unvoiced = Color(hexLight: 0x8E939E, dark: 0x7C828E)

    // Neutral surfaces map to system semantics so Increase Contrast and
    // Smart Invert work without extra code.
    static let pnBackground = Color(.systemBackground)
    static let pnSurface = Color(.secondarySystemGroupedBackground)
    static let pnSurfaceElevated = Color(.tertiarySystemGroupedBackground)
    static let pnTextPrimary = Color(.label)
    static let pnTextSecondary = Color(.secondaryLabel)
    static let pnTrack = Color(.systemGray5)
}

private extension UIColor {
    convenience init(hexDark hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

/// Milestone chip shown on placeholder screens ("Lands in M2") so empty tabs
/// communicate a roadmap, never a dead end (UX principle 6).
struct MilestoneChip: View {
    let milestone: String

    var body: some View {
        Text("Lands in \(milestone)")
            .font(Token.Fonts.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.pnAccent)
            .padding(.horizontal, Token.Spacing.s2)
            .padding(.vertical, Token.Spacing.s1)
            .background(Color.pnAccent.opacity(0.12), in: Capsule())
            .accessibilityLabel("Planned for milestone \(milestone)")
    }
}
