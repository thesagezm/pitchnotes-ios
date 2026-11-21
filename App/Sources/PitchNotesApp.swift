import SwiftUI

// PitchNotes app entry — J-001 app shell v0. Replaces Leto's bootstrap stub
// (same path; at the M0 merge this file is the surviving version).
// Five-tab shell per Docs/UX.md §2: Learn, Library, Theory, Ear, Settings.
@main
struct PitchNotesApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
                // VoiceOver: announce the shell as a coherent whole, tabs are
                // individually labeled in RootTabView.
                .accessibilityLabel("PitchNotes")
        }
    }
}
