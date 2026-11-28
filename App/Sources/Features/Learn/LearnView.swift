import SwiftUI
import PitchLogic
import EngineCore

/// Learn tab — M1: live tuner ribbon (J-101, MockEngine singer demo; the real
/// LivePitchEngine swaps in behind RibbonFrameSource at P-105 with zero view
/// changes). M4 (J-402): the graded session launcher grows around the ribbon —
/// the DEMO path grades the synthetic tracks (labelled); the real-bundle path
/// arrives with the library wiring (the same launcher takes a bundle's
/// `rawTracks` + directory and reads its corrections through C-14).
struct LearnView: View {
    @State private var isLauncherPresented = false
    @State private var session: LearnSessionModel?

    var body: some View {
        VStack(spacing: Token.Spacing.s3) {
            TunerRibbonView()
            Button {
                isLauncherPresented = true
            } label: {
                Label("Start a graded session (demo)", systemImage: "music.mic")
            }
            .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $isLauncherPresented) {
            SessionLauncherView(
                rawTracks: MockNoteTracks.demoTracks(),
                bundleDirectory: nil,
                songTitle: "Demo song",
                bundleId: "demo-bundle",
                isDemo: true,
                detectedTuningCents: 0,
                tuningOverride: nil) { model in
                    isLauncherPresented = false
                    session = model
                    model.start()
                }
        }
        .fullScreenCover(item: $session) { model in
            SessionView(model: model) { session = nil }
        }
    }
}

/// Identifiable so the model can drive a fullScreenCover(item:) — the id is
/// the OBJECT's identity (stable for the session's lifetime; not a timestamp).
extension LearnSessionModel: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}
