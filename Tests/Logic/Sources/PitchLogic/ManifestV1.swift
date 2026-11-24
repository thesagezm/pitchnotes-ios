import Foundation
import EngineCore

// Lane-local manifest v1.0 decoder (J-205, interim until Paul's EngineCore
// lands the v1.0 types — pre-ordained swap, delete this file at that merge).
//
// CONTRACTS v1.0 (L-203, @c7e2072): `channels`, `tuning_cents`, and
// `hasInstrumental` are REQUIRED in a `v1.x` manifest (V14), and the
// `INSTRUMENTAL` part entry must agree with `hasInstrumental` (V15). v0.x
// manifests remain valid under their era rules (permanent back-compat) —
// this decoder REJECTS them so callers can fall back to "unknown".

public enum ManifestV1DecodeError: Error, Equatable, Sendable {
    /// `contractVersion` is not v1.x — v0-era bundles go through the v0 path.
    case notV1(found: String)
    /// V14: a v1.x manifest is missing a required field (or unparseable shape).
    case missingRequiredField(String)
    /// V14: range violation (channels ∉ {1,2} or tuning_cents ∉ [−50,+50]).
    case rangeViolation(String)
    /// V15: INSTRUMENTAL entry ⇔ hasInstrumental disagrees.
    case instrumentalInconsistent
}

/// The v1.0-only fields, decoded STRICTLY (non-optional synthesized Codable
/// makes absence itself a decode failure → `missingRequiredField`).
public struct ManifestV1: Equatable, Sendable {
    /// The common v0-shape fields (decodes fine on the v0 EngineCore struct).
    public let manifest: SongManifest
    /// Channel count of the DECODED MIX (V14: 1|2; stems have their own).
    public let channels: Int
    /// D-22 estimate in cents, [−50, +50], + = sharp, 0 when weak.
    public let tuning_cents: Int
    /// false ⇔ acapella (V15: governs the INSTRUMENTAL stem's existence).
    public let hasInstrumental: Bool

    private struct Extras: Codable {
        let channels: Int
        let tuning_cents: Int
        let hasInstrumental: Bool
    }

    /// Decodes and validates a v1.0 manifest (V14 required fields + ranges,
    /// V15 instrumental consistency). Throws `notV1` for v0-era manifests.
    public static func decode(_ data: Data) throws -> ManifestV1 {
        let manifest: SongManifest
        do {
            manifest = try JSONDecoder().decode(SongManifest.self, from: data)
        } catch {
            throw ManifestV1DecodeError.missingRequiredField("song.json core fields (\(error))")
        }
        guard manifest.contractVersion.hasPrefix("v1") else {
            throw ManifestV1DecodeError.notV1(found: manifest.contractVersion)
        }
        let extras: Extras
        do {
            extras = try JSONDecoder().decode(Extras.self, from: data)
        } catch {
            throw ManifestV1DecodeError.missingRequiredField("v1.0 required fields (\(error))")
        }
        guard extras.channels == 1 || extras.channels == 2 else {
            throw ManifestV1DecodeError.rangeViolation("channels \(extras.channels)")
        }
        guard (-50...50).contains(extras.tuning_cents) else {
            throw ManifestV1DecodeError.rangeViolation("tuning_cents \(extras.tuning_cents)")
        }
        let hasInstrumentalPart = manifest.parts.contains { $0.part == .instrumental }
        guard extras.hasInstrumental == hasInstrumentalPart else {
            throw ManifestV1DecodeError.instrumentalInconsistent
        }
        return ManifestV1(manifest: manifest, channels: extras.channels,
                          tuning_cents: extras.tuning_cents,
                          hasInstrumental: extras.hasInstrumental)
    }

    /// Convenience for consumers that only need the D-22 offset: nil for
    /// v0-era manifests (or anything invalid) — callers treat nil as 0/unknown.
    public static func tuningCents(in data: Data) -> Int? {
        (try? decode(data))?.tuning_cents
    }
}
