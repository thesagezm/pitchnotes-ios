import Foundation
import SwiftUI

/// Library state (J-002 → X-006). Loads the MockEngine-materialized preview
/// catalog OFF the main thread and publishes it. Bundle verdicts come from
/// EngineCore validators over DISK truth (LibraryCatalog). The M2 real-import
/// swap (J-201/J-202) changes only the producer — views do not change.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var songs: [LibrarySong] = []
    @Published private(set) var isLoading = true

    init() {
        Task {
            let catalog = await Task.detached(priority: .userInitiated) {
                LibraryCatalog.makeCatalog()
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
