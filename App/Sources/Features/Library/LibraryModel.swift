import Foundation
import SwiftUI
import PitchLogic

/// Library state (J-002 → X-006 → J-202). Disk truth FIRST: real imported
/// bundles come from `BundleStore.scan()` (the C-2.2 complete-marker rule —
/// a bundle exists IFF its song.json parses; `*.tmp` staging never surfaces).
/// The MockEngine demo catalog follows after the real rows until the real
/// engine lands (P-204 swap), so the tab is never empty on a fresh install.
///
/// All file I/O runs OFF the main thread (AGENTS §8); only published-state
/// assignment hops back. Deletion goes through `BundleStore.delete` — bundle
/// directory first, then the index entry — so a crash mid-delete self-heals
/// on the next scan.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var songs: [LibrarySong] = []
    @Published private(set) var isLoading = true
    /// Storage header: total bytes under the bundle root (J-202 AC).
    @Published private(set) var totalBytesOnDisk: Int64 = 0
    /// Set on store/scan/delete failures — rendered as an honest error banner
    /// with a retry, never a silent empty list.
    @Published private(set) var loadErrorMessage: String?

    private var store: BundleStore?

    init() {
        Task { await load() }
    }

    /// Loads real rows (disk truth) + demo rows + storage totals.
    /// Call again after an import completes or a delete lands.
    func load() async {
        isLoading = songs.isEmpty
        let result = await Task.detached(priority: .userInitiated) { () -> LoadResult in
            guard let store = try? BundleStore.makeDefault() else {
                return LoadResult(store: nil, songs: LibraryCatalog.makeCatalog(),
                                  totalBytes: 0,
                                  error: "Storage is unavailable — imported songs can't be loaded.")
            }
            let records = store.scan()
            var imported: [LibrarySong] = []
            for record in records {
                let dir = store.root.appendingPathComponent(record.id, isDirectory: true)
                imported.append(LibraryCatalog.importedSong(
                    at: dir, record: record,
                    bytesOnDisk: store.bytesOnDisk(forID: record.id)))
            }
            return LoadResult(store: store, songs: imported + LibraryCatalog.makeCatalog(),
                              totalBytes: store.totalBytesOnDisk(), error: nil)
        }.value
        store = result.store
        songs = result.songs
        totalBytesOnDisk = result.totalBytes
        loadErrorMessage = result.error
        isLoading = false
    }

    /// True if every report of every song is clean — drives the Library header.
    var allBundlesValid: Bool {
        songs.allSatisfy { song in song.reports.allSatisfy(\.isValid) }
    }

    /// Storage line for the header ("5.6 MB on device").
    var storageSummary: String {
        ByteCountFormatter.string(fromByteCount: totalBytesOnDisk, countStyle: .file)
    }

    /// Deletes a REAL imported bundle (demo rows are regenerated mocks and
    /// have nothing on the bundle root to delete). Reloads disk truth after.
    func delete(_ song: LibrarySong) {
        guard let store, let record = song.record else { return }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try store.delete(id: record.id)
                    return nil
                } catch {
                    return "Could not delete “\(record.title)” (\(String(describing: error)))."
                }
            }.value
            if let message = outcome {
                loadErrorMessage = message
            } else {
                await load()
            }
        }
    }
}

/// Everything one detached load pass produces, shipped back to the main actor
/// in one hop (matches the X-006/J-002 off-main catalog precedent).
private struct LoadResult {
    let store: BundleStore?
    let songs: [LibrarySong]
    let totalBytes: Int64
    let error: String?
}
