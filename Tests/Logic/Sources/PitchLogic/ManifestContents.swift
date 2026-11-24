import Foundation
import EngineCore

// ManifestContents (J-202/J-205) — what a manifest ACTUALLY CONTAINS, read
// from EngineCore's model. The UI asks these questions before it renders a
// number, so the app never displays a value it does not have (D-12 honesty).
//
// Why this exists: C-2.1 defines `confidenceSummary.meanNoteConfidence` as the
// mean over the parts that carry NoteTracks, and **0.0 when none do**. The M2
// two-stem bundles (VOCALS / INSTRUMENTAL) carry NO note tracks at all — note
// tracks arrive with M3. Rendering that 0.0 as "conf 0%" in an amber
// "low confidence" chip would tell the user their healthy import failed. The
// honest UI omits the chip (row) and says "not yet" (inspector) instead.
//
// The `notesFile` read is written so it compiles against BOTH the pre-v1.0
// PartInfo (required `String`) and the v1.0 PartInfo (`String?`) — the same
// typed-local Optional normalization the J-201 library code uses (D-33).

public enum ManifestContents {

    /// C-2.1: does this bundle carry ANY note tracks? A part "carries" one
    /// when it declares a `notesFile`.
    ///
    /// - On a v1.x M2 two-stem bundle: false (no notesFile keys) → the
    ///   confidence value is undefined, NOT "0% low".
    /// - On a v0.x or M3+ bundle with note tracks: true → the confidence
    ///   summary is meaningful and may be shown.
    public static func hasNoteTracks(in manifest: SongManifest) -> Bool {
        manifest.parts.contains { partInfo in
            // Typed-local normalization: compiles against required (v0.x) and
            // optional (v1.0) `notesFile` alike.
            let notesFile: String? = partInfo.notesFile
            return notesFile != nil
        }
    }
}
