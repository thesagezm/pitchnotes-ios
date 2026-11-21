import SwiftUI

/// The five shell tabs (Docs/UX.md §2). Order and titles are product-facing;
/// raw values are UI-only and not contractual.
enum AppTab: String, CaseIterable, Identifiable {
    case learn
    case library
    case theory
    case ear
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .learn: return "Learn"
        case .library: return "Library"
        case .theory: return "Theory"
        case .ear: return "Ear"
        case .settings: return "Settings"
        }
    }

    /// SF Symbol for the tab item.
    var icon: String {
        switch self {
        case .learn: return "mic.fill"
        case .library: return "music.note.list"
        case .theory: return "book.closed.fill"
        case .ear: return "ear"
        case .settings: return "gearshape.fill"
        }
    }

    /// Milestone where the tab becomes functional (drives the placeholder chip).
    var milestone: String {
        switch self {
        case .learn: return "M1"
        case .library: return "M2"
        case .theory: return "M5"
        case .ear: return "M5"
        case .settings: return "M0"
        }
    }

    /// One-line roadmap for the placeholder screen (UX principle 6: no dead ends).
    var blurb: String {
        switch self {
        case .learn: return "Live tuner ribbon with pitch feedback lands first; graded practice sessions follow."
        case .library: return "Import songs, build voice parts, and mix a focus part."
        case .theory: return "Key and chord analysis plus a clickable notation glossary."
        case .ear: return "Chord-completion drills — hear the other voices, sing the missing one."
        case .settings: return "Parts, grading, audio latency, and storage."
        }
    }
}
