import SwiftUI

// Bootstrap app so CI can produce an unsigned IPA before Jess's shell lands
// (L-003/L-004). J-001 REPLACES this file with the real SwiftUI TabView shell
// (Learn / Library / Theory / Ear / Settings) — no other file depends on it.
@main
struct PitchNotesApp: App {
    var body: some Scene {
        WindowGroup {
            Text("PitchNotes — bootstrap build")
        }
    }
}
