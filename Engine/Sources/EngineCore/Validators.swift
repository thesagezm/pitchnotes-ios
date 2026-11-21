import Foundation

// CONTRACTS.md v0.0 validator rules V1–V13. Numbered IDs are contractual so
// J-004 unit tests and engine code can reference them by ID (see CONTRACTS header).
// Two layers:
//   1. Pure-struct validators (no I/O) — usable on decoded objects.
//   2. `BundleValidator.validate(bundleDirectory:)` — file-level rules (V1, V2,
//      V3 stem reality, V10 filename match). Foundation-only; WAV stems are
//      channel-checked via a minimal header parse (real ALAC verification arrives
//      with the real engine writer, P-204).

public struct ContractViolation: Equatable, Sendable, CustomStringConvertible {
    /// Rule ID, e.g. "V5".
    public let rule: String
    public let message: String

    public init(_ rule: String, _ message: String) {
        self.rule = rule
        self.message = message
    }

    public var description: String { "[\(rule)] \(message)" }
}

public struct ValidationResult: Equatable, Sendable {
    public let violations: [ContractViolation]
    /// True when no V-rule fired. Empty structures are valid unless a rule
    /// requires content (none do in v0.0 — an all-unvoiced track is legitimate).
    public var isValid: Bool { violations.isEmpty }

    public init(violations: [ContractViolation]) { self.violations = violations }
}

public enum BundleValidator {

    // MARK: - V1–V6: song.json manifest

    public static func validate(manifest: SongManifest) -> ValidationResult {
        var v: [ContractViolation] = []

        // V4: duration_s > 0, sampleRate == 44100.
        if !(manifest.duration_s > 0) {
            v.append(ContractViolation("V4", "duration_s must be > 0 (got \(manifest.duration_s))"))
        }
        if manifest.sampleRate != 44100 {
            v.append(ContractViolation("V4", "sampleRate must be 44100 (got \(manifest.sampleRate))"))
        }

        // V5: sourceHash.algo == "blake3", hex is 64 lowercase hex chars.
        if manifest.sourceHash.algo != "blake3" {
            v.append(ContractViolation("V5", "sourceHash.algo must be \"blake3\" (got \"\(manifest.sourceHash.algo)\")"))
        }
        let hex = manifest.sourceHash.hex
        if hex.count != 64 || hex.contains(where: { !(($0.isNumber && $0.isASCII) || ("a"..."f").contains($0)) }) {
            v.append(ContractViolation("V5", "sourceHash.hex must be 64 lowercase hex chars"))
        }

        // V6: every part is a C-1 rawValue (decode enforces) and unique; also
        // non-empty parts[] — a bundle with zero parts cannot render any UI.
        if manifest.parts.isEmpty {
            v.append(ContractViolation("V6", "parts[] must not be empty"))
        }
        var seen = Set<Part>()
        for p in manifest.parts {
            if !seen.insert(p.part).inserted {
                v.append(ContractViolation("V6", "duplicate part \(p.part.rawValue) in parts[]"))
            }
            // V3 (declared policy, D-8): voice stems mono, INSTRUMENTAL stereo.
            let expected = p.part == .instrumental ? 2 : 1
            if p.channels != expected {
                v.append(ContractViolation("V3", "part \(p.part.rawValue) declares channels=\(p.channels), D-8 expects \(expected)"))
            }
            if p.noteConfidence < 0 || p.noteConfidence > 1 {
                v.append(ContractViolation("V9", "parts[].noteConfidence must be in [0,1] (got \(p.noteConfidence))"))
            }
        }

        return ValidationResult(violations: v)
    }

    // MARK: - V7–V10: NoteTrack

    public static func validate(noteTrack: NoteTrack) -> ValidationResult {
        var v: [ContractViolation] = []

        // V7 + V8 + V9.
        var previousEnd: Double = -.infinity
        for (i, note) in noteTrack.notes.enumerated() {
            if !(note.start_s < note.end_s) {
                v.append(ContractViolation("V7", "note \(i): start_s (\(note.start_s)) must be < end_s (\(note.end_s))"))
            }
            if note.start_s < previousEnd {
                v.append(ContractViolation("V8", "note \(i): start_s (\(note.start_s)) overlaps/precedes previous note end (\(previousEnd)); notes must be sorted by start_s and non-overlapping"))
            }
            previousEnd = max(previousEnd, note.end_s)

            if note.midi < 24 || note.midi > 96 {
                v.append(ContractViolation("V9", "note \(i): midi must be in 24–96 (got \(note.midi))"))
            }
            if note.cents_ref < -50 || note.cents_ref > 50 {
                v.append(ContractViolation("V9", "note \(i): cents_ref must be in [-50,+50] (got \(note.cents_ref))"))
            }
            if note.confidence < 0 || note.confidence > 1 {
                v.append(ContractViolation("V9", "note \(i): confidence must be in [0,1] (got \(note.confidence))"))
            }
        }

        return ValidationResult(violations: v)
    }

    // MARK: - V11–V13: PitchFrames

    public static func validate(pitchFrames: PitchFramesFile) -> ValidationResult {
        var v: [ContractViolation] = []

        if pitchFrames.hopMs != PitchFramesFile.hopMs {
            v.append(ContractViolation("V13", "hopMs must be 16 in contract v0.0 (got \(pitchFrames.hopMs))"))
        }

        // V11: hz == 0 (unvoiced) or 46.9–2093.75. V12: confidence in [0,1].
        // V13: t strictly increasing, uniform 16 ms grid within 1 ms tolerance.
        var previousT: Double = -.infinity
        for (i, frame) in pitchFrames.frames.enumerated() {
            let expectedT = Double(i) * EngineContract.hopSeconds
            if !(frame.t > previousT) {
                v.append(ContractViolation("V13", "frame \(i): t (\(frame.t)) must be strictly increasing (previous \(previousT))"))
            }
            if abs(frame.t - expectedT) > 0.001 {
                v.append(ContractViolation("V13", "frame \(i): t (\(frame.t)) off the 16 ms grid (expected \(expectedT), tolerance 1 ms)"))
            }
            previousT = frame.t

            if frame.hz != 0.0 && (frame.hz < EngineContract.hzMin || frame.hz > EngineContract.hzMax) {
                v.append(ContractViolation("V11", "frame \(i): hz must be 0.0 (unvoiced) or in \(EngineContract.hzMin)–\(EngineContract.hzMax) Hz (got \(frame.hz))"))
            }
            if frame.confidence < 0 || frame.confidence > 1 {
                v.append(ContractViolation("V12", "frame \(i): confidence must be in [0,1] (got \(frame.confidence))"))
            }
        }

        return ValidationResult(violations: v)
    }

    // MARK: - Directory-level: V1, V2, V3 stem reality, V10

    /// Validates a SongBundle directory on disk: V1 (song.json exists + parses),
    /// V2 (every parts[].stemFile exists in the bundle), V3 (stem channel reality
    /// matches declaration for WAV stems), V10 (notes/<PART>.json `part` matches
    /// filename), plus re-running the struct validators on the parsed contents.
    public static func validate(bundleDirectory: URL) -> ValidationResult {
        var v: [ContractViolation] = []
        let fm = FileManager.default

        // V1: song.json exists and parses.
        let manifestURL = bundleDirectory.appendingPathComponent("song.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return ValidationResult(violations: [ContractViolation("V1", "song.json missing or unreadable at \(manifestURL.path)")])
        }
        let manifest: SongManifest
        do {
            manifest = try JSONDecoder().decode(SongManifest.self, from: data)
        } catch {
            return ValidationResult(violations: [ContractViolation("V1", "song.json does not parse as SongManifest: \(error)")])
        }

        let structResult = validate(manifest: manifest)
        v.append(contentsOf: structResult.violations)

        for p in manifest.parts {
            // V2: stemFile exists in the bundle.
            let stemURL = bundleDirectory.appendingPathComponent(p.stemFile)
            if !fm.fileExists(atPath: stemURL.path) {
                v.append(ContractViolation("V2", "stemFile \(p.stemFile) declared for \(p.part.rawValue) does not exist in bundle"))
                continue
            }
            // V3 stem reality: check actual WAV channels when parseable.
            if let actual = wavChannelCount(url: stemURL), actual != p.channels {
                v.append(ContractViolation("V3", "stem \(p.stemFile) has \(actual) channel(s), manifest declares \(p.channels)"))
            }

            // Notes file (if declared) must parse and validate; V10 filename match.
            let notesURL = bundleDirectory.appendingPathComponent(p.notesFile)
            if let nd = try? Data(contentsOf: notesURL),
               let track = try? JSONDecoder().decode(NoteTrack.self, from: nd) {
                v.append(contentsOf: validate(noteTrack: track).violations)
                // V10: `part` matches filename PART (case-sensitive rawValue).
                let expectedName = "notes/\(p.part.rawValue).json"
                if p.notesFile != expectedName {
                    v.append(ContractViolation("V10", "notesFile \(p.notesFile) does not follow notes/<PART>.json (expected \(expectedName))"))
                }
                if track.part != p.part {
                    v.append(ContractViolation("V10", "notes file \(p.notesFile) declares part \(track.part.rawValue), manifest says \(p.part.rawValue)"))
                }
            }

            // Pitch file (optional): if present, must parse and validate.
            if let pf = p.pitchFile {
                let pitchURL = bundleDirectory.appendingPathComponent(pf)
                if let pd = try? Data(contentsOf: pitchURL),
                   let frames = try? JSONDecoder().decode(PitchFramesFile.self, from: pd) {
                    v.append(contentsOf: validate(pitchFrames: frames).violations)
                }
            }
        }

        return ValidationResult(violations: v)
    }

    // MARK: - Minimal WAV header reader (V3 stem reality, mock bundles)

    /// Returns the channel count from a PCM WAV file's `fmt ` chunk, or nil when
    /// the file is not a parseable WAV (real ALAC/m4a stems are checked by the
    /// AVFoundation-based writer/validator in P-204).
    public static func wavChannelCount(url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), data.count >= 44 else { return nil }
        let bytes = [UInt8](data)
        func ascii(_ offset: Int, _ n: Int) -> String {
            String(bytes: bytes[offset..<(offset + n)], encoding: .ascii) ?? ""
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        guard ascii(0, 4) == "RIFF", ascii(8, 4) == "WAVE" else { return nil }
        var offset = 12
        while offset + 8 <= bytes.count {
            let chunkID = ascii(offset, 4)
            let chunkSize = Int(u32(offset + 4))
            if chunkID == "fmt " && offset + 8 + 16 <= bytes.count {
                return Int(u16(offset + 10)) // channels at fmt+2
            }
            offset += 8 + chunkSize + (chunkSize % 2) // chunks are word-aligned
        }
        return nil
    }
}
