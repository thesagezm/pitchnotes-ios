import SwiftUI

/// Library tab — M0 placeholder. M2: import flow (J-201), song list (J-202),
/// focus mixer (J-203), debug bundle inspector (J-002).
struct LibraryView: View {
    var body: some View {
        FeaturePlaceholder(
            title: "Library",
            icon: "music.note.list",
            milestone: "M2",
            blurb: AppTab.library.blurb
        )
    }
}
