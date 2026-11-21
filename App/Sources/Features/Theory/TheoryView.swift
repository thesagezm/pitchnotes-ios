import SwiftUI

/// Theory tab — M0 placeholder. M5: key/chord analysis (J-501), notation +
/// clickable glyph glossary (J-502).
struct TheoryView: View {
    var body: some View {
        FeaturePlaceholder(
            title: "Theory",
            icon: "book.closed.fill",
            milestone: "M5",
            blurb: AppTab.theory.blurb
        )
    }
}
