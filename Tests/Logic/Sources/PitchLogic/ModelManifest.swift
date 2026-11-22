import Foundation

// ModelManifest + ModelCacheNaming (J-207) — the PURE half of the runtime
// model download (D-34 GAP 2, AGENTS §0 one-time-download rail).
//
// The manifest shape is the one `scripts/models/download.py` writes and
// `SwiftF0ModelStore.locateModel` (Engine/PitchORT) reads:
//
//   { "models": [ { "name": "htdemucs", "url": "https://…",
//                   "sha256": "…", "size": 83994361, "license": "…" }, … ] }
//
// ONE parser, two consumers (the CI script and the on-device downloader) must
// agree on the fields — hence the parsing lives in the shared package and is
// unit-tested here.
//
// The CACHE PATH follows the EXISTING scheme `<name>-<sha256[:16]>` (the one
// `scripts/models/download.py` uses and `SwiftF0ModelStore.modelURL(for:
// sha256:in:)` reproduces), so a model fetched on the device is found by the
// same locator the CI parity jobs use. The cache ROOT is the app's own
// choice (Application Support) — it is passed in, never hard-coded here.

/// One manifest entry (the fields the app needs to fetch and verify).
public struct ModelManifestEntry: Equatable, Sendable {
    public let name: String
    public let url: URL
    /// The SHA256 trust anchor (hex). A manifest entry WITHOUT one is not
    /// downloadable by the app: an unverifiable file is never cached.
    public let sha256: String
    /// Declared size in bytes (optional in the manifest).
    public let sizeBytes: Int64?
    /// License / provenance line (optional) — shown verbatim in the UI.
    public let license: String?

    public init(name: String, url: URL, sha256: String, sizeBytes: Int64? = nil, license: String? = nil) {
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.license = license
    }
}

/// Manifest reading.
public enum ModelManifest {

    public enum ParseError: Error, Equatable {
        case unreadable
        case noModelsArray
        case malformedEntry(String)
    }

    /// Parse a manifest JSON payload into entries. Entries that cannot be
    /// used (no name, no URL, no SHA256 trust anchor) are SKIPPED, not
    /// faked: the downloader may never cache an unverifiable file.
    public static func entries(from data: Data) throws -> [ModelManifestEntry] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError.unreadable
        }
        guard let root = object as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw ParseError.noModelsArray
        }
        var entries: [ModelManifestEntry] = []
        for raw in models {
            guard let name = raw["name"] as? String, !name.isEmpty,
                  let urlString = raw["url"] as? String,
                  let url = URL(string: urlString),
                  let sha = raw["sha256"] as? String,
                  !sha.isEmpty else {
                continue
            }
            var size: Int64?
            if let number = raw["size"] as? NSNumber { size = number.int64Value }
            else if let text = raw["size"] as? String, let value = Int64(text) { size = value }
            let license = raw["license"] as? String
            entries.append(ModelManifestEntry(
                name: name, url: url, sha256: sha, sizeBytes: size, license: license))
        }
        return entries
    }

    /// Look up one entry by name.
    public static func entry(named name: String, in entries: [ModelManifestEntry]) -> ModelManifestEntry? {
        entries.first { $0.name == name }
    }
}

/// The cache-path scheme — `<name>-<sha256[:16]>` (the EXISTING scheme from
/// `scripts/models/download.py`, reproduced by `SwiftF0ModelStore.modelURL`).
public enum ModelCacheNaming {

    /// The file name a verified model is cached under.
    public static func fileName(name: String, sha256: String) -> String {
        "\(name)-\(sha256.prefix(16))"
    }

    /// The full cached path for a model.
    public static func cachedURL(name: String, sha256: String, in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent(fileName(name: name, sha256: sha256))
    }

    /// A human-readable size string for the UI ("84 MB (83,994,361 B)").
    public static func sizeDescription(bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "size unknown" }
        let grouped = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let exact = formatter.string(from: NSNumber(value: bytes)) ?? String(bytes)
        return "\(grouped) (\(exact) B)"
    }
}
