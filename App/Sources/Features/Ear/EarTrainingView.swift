import SwiftUI

/// Ear tab — M0 placeholder. M5: chord-completion drills (J-504): hear N−1
/// voices, sing the missing one; octave/key variants; JI/ET toggle.
struct EarTrainingView: View {
    var body: some View {
        FeaturePlaceholder(
            title: "Ear Training",
            icon: "ear",
            milestone: "M5",
            blurb: AppTab.ear.blurb
        )
    }
}
