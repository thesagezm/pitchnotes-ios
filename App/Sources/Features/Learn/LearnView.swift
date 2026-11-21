import SwiftUI

/// Learn tab — M0 placeholder. M1: live tuner entry (J-101 ribbon);
/// M4: graded session launcher + recent sessions (J-402/J-404).
struct LearnView: View {
    var body: some View {
        FeaturePlaceholder(
            title: "Learn",
            icon: "mic.fill",
            milestone: "M1",
            blurb: AppTab.learn.blurb
        )
    }
}
