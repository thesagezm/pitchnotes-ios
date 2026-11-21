// ContractValidator — CONTRACTS.md v0.0 schema enforcement at the JSON surface.
//
// These validators check the raw JSON of a SongBundle (song.json manifest,
// notes/<PART>.json NoteTrack, pitch/<PART>.json PitchFrames) against the V-rules
// ratified in CONTRACTS v0.0 (C-2). They intentionally validate JSON — not typed
// Swift models — so the contract surface is enforced independently of the engine's
// Codable implementation (Paul's models are the single typed source; X-003 wires
// them in). Pure Foundation; runs in `swift test` on CI and in the app's debug
// bundle inspector (J-002).

import Foundation

/// One contract violation: the V-rule ID it breaks (CONTRACTS v0.0 numbering)
/// plus a human-readable message. `rule` values are stable (additive only).
public struct ContractViolation: Equatable, Hashable, Sendable {
    public let rule: String
    public let message: String

    public init(rule: String, message: String) {
        self.rule = rule
        self.message = message
    }
}

/// C-1 Part rawValues (stable forever). Kept here ONLY for validation; the typed
/// enum is Paul's (CONTRACTS C-1 "one definition") — do not build UI off this.
public enum ContractParts {
    public static let all: Set<String> = [
        "BASS", "BARITONE", "BARITENOR", "T2", "T1",
        "SOPRANO", "ALTO", "VP", "LEAD", "INSTRUMENTAL",
    ]
    /// D-8 channel policy: voice stems mono, instrumental stereo.
    public static let instrumental = "INSTRUMENTAL"
}

public enum ContractValidator {

    // MARK: - song.json manifest (C-2.1)

    /// Validate a `song.json` manifest. `parsed` false ⇒ V1 violation carries the
    /// decode error; all other rules best-effort on parse success.
    public static func validateManifest(_ data: Data) -> [ContractViolation] {
        var violations: [ContractViolation] = []
        let json: [String: Any]
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = obj as? [String: Any] else {
                return [ContractViolation(rule: "V1", message: "manifest root is not a JSON object")]
            }
            json = dict
        } catch {
            return [ContractViolation(rule: "V1", message: "manifest does not parse: \(error.localizedDescription)")]
        }

        // contractVersion: "v<major>.<minor>" string (consumers reject unknown MAJOR).
        if let cv = json["contractVersion"] as? String {
            if !(cv.hasPrefix("v") && cv.dropFirst().contains(".")) {
                violations.append(ContractViolation(rule: "V1", message: "contractVersion '\(cv)' is not 'v<major>.<minor>'"))
            }
        } else {
            violations.append(ContractViolation(rule: "V1", message: "contractVersion missing or not a string"))
        }

        // V4: duration_s > 0, sampleRate == 44100.
        if let duration = json["duration_s"] as? Double {
            if duration <= 0 {
                violations.append(ContractViolation(rule: "V4", message: "duration_s must be > 0, got \(duration)"))
            }
        } else {
            violations.append(ContractViolation(rule: "V4", message: "duration_s missing or not a number"))
        }
        if let rate = json["sampleRate"] as? Int {
            if rate != 44_100 {
                violations.append(ContractViolation(rule: "V4", message: "sampleRate must be 44100 (D-8), got \(rate)"))
            }
        } else {
            violations.append(ContractViolation(rule: "V4", message: "sampleRate missing or not an integer"))
        }

        // V5: sourceHash.algo == "blake3", hex is 64 lowercase hex chars.
        if let hash = json["sourceHash"] as? [String: Any] {
            let algo = hash["algo"] as? String
            let hex = hash["hex"] as? String
            if algo != "blake3" {
                violations.append(ContractViolation(rule: "V5", message: "sourceHash.algo must be \"blake3\", got \(algo ?? "nil")"))
            }
            if let hex {
                if hex.count != 64 || hex.lowercased() != hex || !hex.allSatisfy({ $0.isHexDigit }) {
                    violations.append(ContractViolation(rule: "V5", message: "sourceHash.hex must be 64 lowercase hex chars"))
                }
            } else {
                violations.append(ContractViolation(rule: "V5", message: "sourceHash.hex missing"))
            }
        } else {
            violations.append(ContractViolation(rule: "V5", message: "sourceHash missing"))
        }

        // V6 + V3: parts present, C-1 rawValues, unique; channels match D-8 policy.
        if let parts = json["parts"] as? [[String: Any]] {
            var seen = Set<String>()
            for (index, part) in parts.enumerated() {
                guard let name = part["part"] as? String else {
                    violations.append(ContractViolation(rule: "V6", message: "parts[\(index)].part missing or not a string"))
                    continue
                }
                if !ContractParts.all.contains(name) {
                    violations.append(ContractViolation(rule: "V6", message: "parts[\(index)].part '\(name)' is not a C-1 rawValue"))
                }
                if !seen.insert(name).inserted {
                    violations.append(ContractViolation(rule: "V6", message: "duplicate part '\(name)'"))
                }
                let expectedChannels = (name == ContractParts.instrumental) ? 2 : 1
                if let channels = part["channels"] as? Int {
                    if channels != expectedChannels {
                        violations.append(ContractViolation(rule: "V3", message: "part '\(name)' must have channels=\(expectedChannels) (D-8), got \(channels)"))
                    }
                } else {
                    violations.append(ContractViolation(rule: "V3", message: "part '\(name)' channels missing or not an integer"))
                }
                if (part["stemFile"] as? String) == nil {
                    violations.append(ContractViolation(rule: "V2", message: "part '\(name)' stemFile missing (consumer cannot locate stem)"))
                }
                if let confidence = part["noteConfidence"] as? Double, !(0.0...1.0).contains(confidence) {
                    violations.append(ContractViolation(rule: "V12", message: "part '\(name)' noteConfidence \(confidence) outside [0,1]"))
                }
            }
            if parts.isEmpty {
                violations.append(ContractViolation(rule: "V6", message: "parts[] is empty — a bundle must contain at least one part"))
            }
        } else {
            violations.append(ContractViolation(rule: "V6", message: "parts[] missing or not an array"))
        }

        return violations
    }

    // MARK: - notes/<PART>.json NoteTrack (C-2.3)

    /// Validate a NoteTrack. `expectedPart` is the filename PART (V10).
    public static func validateNoteTrack(_ data: Data, expectedPart: String) -> [ContractViolation] {
        var violations: [ContractViolation] = []
        let json: [String: Any]
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return [ContractViolation(rule: "V1", message: "NoteTrack root is not a JSON object")]
            }
            json = dict
        } catch {
            return [ContractViolation(rule: "V1", message: "NoteTrack does not parse: \(error.localizedDescription)")]
        }

        // V10: the "part" field matches the filename PART.
        if let part = json["part"] as? String {
            if part != expectedPart {
                violations.append(ContractViolation(rule: "V10", message: "NoteTrack.part '\(part)' does not match filename PART '\(expectedPart)'"))
            }
        } else {
            violations.append(ContractViolation(rule: "V10", message: "NoteTrack.part missing"))
        }

        guard let notes = json["notes"] as? [[String: Any]] else {
            violations.append(ContractViolation(rule: "V1", message: "NoteTrack.notes missing or not an array"))
            return violations
        }

        var previousStart = -Double.infinity
        var previousEnd = -Double.infinity
        for (index, note) in notes.enumerated() {
            // V7: start_s < end_s (also covers missing/non-numeric fields).
            guard let start = note["start_s"] as? Double, let end = note["end_s"] as? Double else {
                violations.append(ContractViolation(rule: "V7", message: "notes[\(index)] start_s/end_s missing or not numbers"))
                continue
            }
            if start >= end {
                violations.append(ContractViolation(rule: "V7", message: "notes[\(index)] start_s \(start) >= end_s \(end)"))
            }

            // V8: sorted by start_s and non-overlapping within the part.
            if start < previousStart {
                violations.append(ContractViolation(rule: "V8", message: "notes[\(index)] start_s \(start) out of order (previous \(previousStart))"))
            } else if index > 0 && start < previousEnd {
                violations.append(ContractViolation(rule: "V8", message: "notes[\(index)] overlaps the previous note (start \(start) < previous end \(previousEnd))"))
            }
            previousStart = start
            previousEnd = end

            // V9: midi int 24–96; cents_ref int [-50, +50]; confidence [0,1].
            if let midi = note["midi"] as? Int {
                if !(24...96).contains(midi) {
                    violations.append(ContractViolation(rule: "V9", message: "notes[\(index)].midi \(midi) outside 24–96"))
                }
            } else {
                violations.append(ContractViolation(rule: "V9", message: "notes[\(index)].midi missing or not an integer"))
            }
            if let cents = note["cents_ref"] as? Int {
                if !(-50...50).contains(cents) {
                    violations.append(ContractViolation(rule: "V9", message: "notes[\(index)].cents_ref \(cents) outside [-50, +50]"))
                }
            } else {
                violations.append(ContractViolation(rule: "V9", message: "notes[\(index)].cents_ref missing or not an integer"))
            }
            if let confidence = note["confidence"] as? Double {
                if !(0.0...1.0).contains(confidence) {
                    violations.append(ContractViolation(rule: "V9", message: "notes[\(index)].confidence \(confidence) outside [0,1]"))
                }
            } else {
                violations.append(ContractViolation(rule: "V9", message: "notes[\(index)].confidence missing or not a number"))
            }
        }

        return violations
    }

    // MARK: - pitch/<PART>.json PitchFrames (C-2.4)

    /// Validate PitchFrames: fixed 16 ms grid, hz 0.0 or 46.9–2093.75, confidence
    /// [0,1], `t` strictly increasing and uniform within 1 ms.
    public static func validatePitchFrames(_ data: Data, expectedPart: String) -> [ContractViolation] {
        var violations: [ContractViolation] = []
        let json: [String: Any]
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return [ContractViolation(rule: "V1", message: "PitchFrames root is not a JSON object")]
            }
            json = dict
        } catch {
            return [ContractViolation(rule: "V1", message: "PitchFrames does not parse: \(error.localizedDescription)")]
        }

        if let part = json["part"] as? String, part != expectedPart {
            violations.append(ContractViolation(rule: "V10", message: "PitchFrames.part '\(part)' does not match filename PART '\(expectedPart)'"))
        }
        if let hop = json["hopMs"] as? Int {
            if hop != 16 {
                violations.append(ContractViolation(rule: "V1", message: "hopMs must be 16 in contract v0.0, got \(hop)"))
            }
        } else {
            violations.append(ContractViolation(rule: "V1", message: "hopMs missing or not an integer"))
        }

        guard let frames = json["frames"] as? [[String: Any]] else {
            violations.append(ContractViolation(rule: "V1", message: "PitchFrames.frames missing or not an array"))
            return violations
        }

        var previousT: Double = -1
        for (index, frame) in frames.enumerated() {
            let t = frame["t"] as? Double

            // V11: hz == 0.0 (unvoiced) or voiced range 46.9–2093.75.
            if let hz = frame["hz"] as? Double {
                if hz != 0.0 && !(46.9...2093.75).contains(hz) {
                    violations.append(ContractViolation(rule: "V11", message: "frames[\(index)].hz \(hz) outside voiced range 46.9–2093.75 (or 0.0)"))
                }
            } else {
                violations.append(ContractViolation(rule: "V11", message: "frames[\(index)].hz missing or not a number"))
            }

            // V12: confidence in [0,1].
            if let confidence = frame["confidence"] as? Double {
                if !(0.0...1.0).contains(confidence) {
                    violations.append(ContractViolation(rule: "V12", message: "frames[\(index)].confidence \(confidence) outside [0,1]"))
                }
            } else {
                violations.append(ContractViolation(rule: "V12", message: "frames[\(index)].confidence missing or not a number"))
            }

            if let loudness = frame["loudness_db"] as? Double {
                if loudness.isNaN || loudness.isInfinite {
                    violations.append(ContractViolation(rule: "V12", message: "frames[\(index)].loudness_db not finite"))
                }
            } else {
                violations.append(ContractViolation(rule: "V12", message: "frames[\(index)].loudness_db missing or not a number"))
            }

            // V13: t strictly increasing, uniform 16 ms grid within 1 ms tolerance.
            guard let t else {
                violations.append(ContractViolation(rule: "V13", message: "frames[\(index)].t missing or not a number"))
                continue
            }
            if let previous = previousT >= 0 ? previousT : nil {
                if t <= previous {
                    violations.append(ContractViolation(rule: "V13", message: "frames[\(index)].t \(t) not strictly increasing (previous \(previous))"))
                } else if abs((t - previous) - 0.016) > 0.001 {
                    violations.append(ContractViolation(rule: "V13", message: "frames[\(index)].t not on the uniform 16 ms grid (Δ=\(t - previous)s)"))
                }
            } else if index == 0 && abs(t - 0.0) > 0.001 {
                // C-2.4: frames[i].t == i * 0.016 ⇒ the first frame is t = 0.0.
                violations.append(ContractViolation(rule: "V13", message: "frames[0].t \(t) is off-grid (expected 0.0)"))
            }
            previousT = t
        }

        return violations
    }

    /// Convenience: aggregate verdict for UI display.
    public static func isValid(_ violations: [ContractViolation]) -> Bool {
        violations.isEmpty
    }
}
