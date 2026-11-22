import SwiftUI

/// Learn tab — M1: live tuner ribbon (J-101, MockEngine singer demo; the real
/// LivePitchEngine swaps in behind RibbonFrameSource at P-105 with zero view
/// changes). M4: graded session launcher + recent sessions (J-402/J-404) grow
/// around the ribbon without re-design.
struct LearnView: View {
    var body: some View {
        TunerRibbonView()
    }
}
