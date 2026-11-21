import Foundation
import SwiftUI

/// Library state (J-002). Loads the preview catalog OFF the main thread and
/// publishes it. When Paul's MockEngine (P-001) lands + X-003 wiring, the
/// catalog source swaps to his engine — the views do not change.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var songs: [StubSong] = []
    @Published private(set) var isLoading = true

    init() {
        Task {
            let catalog = await Task.detached(priority: .userInitiated) {
                StubEngine.makeCatalog()
            }.value
            songs = catalog
            isLoading = false
        }
    }

    /// True if every report of every song is clean — drives the Library header.
    var allBundlesValid: Bool {
        songs.allSatisfy { song in song.reports.allSatisfy(\.isValid) }
    }
}
