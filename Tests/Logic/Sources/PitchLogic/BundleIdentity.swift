import Foundation
import EngineCore

// BundleIdentity (J-208) — the PURE half of the C-9 "which bundle did this
// import publish" fact (CONTRACTS v1.0.1, D-34).
//
// C-9 carries the fact in an ADDITIVE protocol (`BundleProducingEngine`.
// `importedBundleID`) because C-3 is frozen and `separate` returns raw stem
// URLs. Rule 3 permits the consumer to DERIVE the bundle directory from a
// returned stem URL when an engine does not conform — so C-9 can never become
// a blocker for an import.
//
// The derivation here is pure URL arithmetic on the FROZEN bundle layout
// (CONTRACTS §7 SongBundle):
//
//   <bundleRoot>/<id>/stems/<part>.m4a   ← the stem URL `separate` returns
//   <bundleRoot>/<id>/song.json           ← the completion marker (C-2.2)
//
// so the bundle directory is the stem file's GRANDPARENT. The App layer adds
// the one thing that cannot be pure — "does that directory really contain
// song.json?" — before trusting a derived id (see `BundleIdentityResolver` in
// App/Sources/Features/Import). A derived id is never trusted on its own:
// a half-written bundle must not be registered in the library (C-2.2).

public enum BundleIdentity {

    /// C-9 rule 4: the id is a DIRECTORY NAME only — no path separators, no
    /// "..", not empty. A consumer joins it to the library root itself.
    public static func isValidBundleID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        // A leading dot covers ".", ".." and "../"-style tricks ("..evil").
        guard !id.hasPrefix(".") else { return false }
        guard !id.contains("/"), !id.contains("\\") else { return false }
        // A NUL byte or a colon would be a path trick on some filesystems.
        guard !id.contains("\0"), !id.contains(":") else { return false }
        return true
    }

    /// The bundle directory implied by a stem URL (`<root>/<id>/stems/<part>`).
    /// Pure URL arithmetic — no filesystem access.
    public static func bundleDirectoryURL(forStemURL stemURL: URL) -> URL {
        // stem file → stems/ → <id>/
        stemURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The bundle id implied by a stem URL, or nil when the implied name is
    /// not a legal bundle id (C-9 rule 4). Pure — the caller still verifies
    /// the directory against `song.json` before trusting it.
    public static func candidateBundleID(forStemURL stemURL: URL) -> String? {
        let id = bundleDirectoryURL(forStemURL: stemURL).lastPathComponent
        return isValidBundleID(id) ? id : nil
    }

    /// Pick the bundle id from a set of stems: the first stem that yields a
    /// legal candidate wins (the stems of one bundle share the same parent).
    public static func candidateBundleID(fromStems stems: [Part: URL]) -> String? {
        for url in stems.values.sorted(by: { $0.path < $1.path }) {
            if let id = candidateBundleID(forStemURL: url) { return id }
        }
        return nil
    }

    /// C-9 rules 2 + 3, PURE: which bundle id the consumer registers.
    ///
    /// Rule 2: the consumer MUST prefer the producer's id (`BundleProducingEngine`).
    /// Rule 3: when the producer does not conform (or names nothing usable),
    /// the consumer MAY derive the id from a stem URL.
    /// Rule 1: an id is only usable once the bundle is COMPLETE (`song.json`
    /// is the completion marker, C-2.2) — a half-written bundle is never
    /// registered, no matter who named it.
    ///
    /// - Returns: the id to register, or nil when no complete bundle can be
    ///   named.
    public static func resolve(
        producerID: String?,
        derivedID: String?,
        producerBundleIsComplete: Bool,
        derivedBundleIsComplete: Bool
    ) -> String? {
        if let producerID, isValidBundleID(producerID), producerBundleIsComplete {
            return producerID
        }
        if let derivedID, isValidBundleID(derivedID), derivedBundleIsComplete {
            return derivedID
        }
        return nil
    }
}
