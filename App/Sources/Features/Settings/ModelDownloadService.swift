import Foundation
import PitchLogic

// ModelDownloadService (J-207) — the on-device half of the AGENTS §0 rail:
// fetch the model ONCE, verify it, cache it, then work offline forever.
//
// What it does NOT do (hard rails):
//   · no telemetry, no server, no upload — the fetch is a plain HTTPS GET of
//     the project Hugging Face mirror URL that the MANIFEST names;
//   · no second copy of the manifest — the app reads the bundled
//     `Models/manifest.json` (X-207: Leto's project.yml one-liner) and parses
//     it with the SHARED pure parser (PitchLogic `ModelManifest`), the same
//     shape `SwiftF0ModelStore.locateModel` reads;
//   · no silent pass — a download that cannot be verified is DELETED, never
//     cached, and the failure is stated verbatim in the UI (D-12 honesty).
//
// The cache scheme is the EXISTING one (`<name>-<sha256[:16]>`, the scheme
// `scripts/models/download.py` writes and `SwiftF0ModelStore.modelURL(for:
// sha256:in:)` reproduces), so the engine can locate the file with the same
// helper the CI parity jobs use. The cache ROOT is the app's Application
// Support directory (never Caches — iOS may purge Caches, and the AGENTS §0
// rail says the model must not be needed again).

// MARK: - Cache locations

/// Where the app keeps verified model files.
enum ModelCache {

    static let downloadsFolderName = "Models/downloads"

    /// The cache root: `Application Support/PitchNotes/Models/downloads`.
    static func rootDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("PitchNotes", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)
    }

    /// The cached path of a model, under the EXISTING naming scheme.
    static func cachedURL(for entry: ModelManifestEntry) -> URL {
        ModelCacheNaming.cachedURL(
            name: entry.name, sha256: entry.sha256, in: rootDirectory())
    }

    /// The cached path of a model ONLY when the file is actually there.
    static func verifiedModelURL(named name: String) -> URL? {
        guard let entry = manifestEntries().first(where: { $0.name == name }) else { return nil }
        let url = cachedURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The manifest entries from the BUNDLED manifest (X-207). Returns an
    /// empty array when the manifest is not bundled in this build — the UI
    /// then says so honestly instead of pretending a download is possible.
    static func manifestEntries() -> [ModelManifestEntry] {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? ModelManifest.entries(from: data)) ?? []
    }
}

// MARK: - Download service

/// Fetches + verifies + caches model files.
struct ModelDownloadService {

    enum Outcome: Equatable {
        /// Already cached and verified earlier.
        case alreadyCached(URL)
        /// Downloaded, verified and cached.
        case downloaded(URL)
        /// The file was fetched but did NOT match the manifest's SHA256 —
        /// deleted, never cached.
        case verificationFailed(expected: String, actual: String)
        /// The download itself failed (offline, server, disk).
        case failed(String)
    }

    /// The shared session (injectable for tests).
    var session: URLSession = .shared

    /// Download one manifest entry, verify it, and cache it.
    ///
    /// - Parameter progress: called with the fraction downloaded (0…1). The
    ///   callback is main-actor isolated, so the UI can touch its state
    ///   directly.
    func download(
        entry: ModelManifestEntry,
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async -> Outcome {
        let destination = ModelCache.cachedURL(for: entry)
        if FileManager.default.fileExists(atPath: destination.path) {
            return .alreadyCached(destination)
        }
        do {
            let temporary = try await fetch(entry: entry, progress: progress)
            defer { try? FileManager.default.removeItem(at: temporary) }

            let digest = try SHA256.hexDigest(ofFileAt: temporary)
            guard SHA256.matches(computed: digest, expected: entry.sha256) else {
                // D-12: a file that does not match the trust anchor is NOT
                // cached. The temporary copy is removed by the defer above.
                return .verificationFailed(expected: entry.sha256.lowercased(), actual: digest)
            }
            try FileManager.default.createDirectory(
                at: ModelCache.rootDirectory(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return .downloaded(destination)
        } catch is CancellationError {
            return .failed("The download was cancelled.")
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// Adopt a file the HUMAN placed in the app's Files container (the
    /// gate's fallback when the download path is unavailable): the hash is
    /// verified exactly as a downloaded file's, then the file is moved into
    /// the cache under the canonical name.
    ///
    /// - Returns: the cached URL when a file in the container matches the
    ///   manifest's SHA256, nil when none does.
    func adoptFromDocuments(entry: ModelManifestEntry) async -> Outcome {
        let documents = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsSubdirectoryDescendants]) else {
            return .failed("The Files container could not be read.")
        }
        for candidate in contents {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            guard let digest = try? SHA256.hexDigest(ofFileAt: candidate) else { continue }
            guard SHA256.matches(computed: digest, expected: entry.sha256) else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: ModelCache.rootDirectory(), withIntermediateDirectories: true)
                let destination = ModelCache.cachedURL(for: entry)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: candidate, to: destination)
                return .downloaded(destination)
            } catch {
                return .failed(Self.describe(error))
            }
        }
        return .failed(
            "No file in the Files container matches the manifest checksum for \(entry.name).")
    }

    // MARK: - Internals

    /// Stream the URL to a temporary file (never 84 MB in memory).
    private func fetch(
        entry: ModelManifestEntry,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: entry.url)
        let expected = entry.sizeBytes ?? 0
        var written: Int64 = 0
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("model-\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: Data(buffer))
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    let fraction = min(Double(written) / Double(expected), 1)
                    await MainActor.run { progress(fraction) }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: Data(buffer))
            written += Int64(buffer.count)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        await MainActor.run { progress(1) }
        return temporary
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection. PitchNotes needs a connection only for this one-time model download — after that it works in airplane mode."
            case .timedOut:
                return "The download timed out. Try again on a better connection."
            default:
                return "The download failed: \(urlError.localizedDescription)"
            }
        }
        return "The download failed: \(error.localizedDescription)"
    }
}
