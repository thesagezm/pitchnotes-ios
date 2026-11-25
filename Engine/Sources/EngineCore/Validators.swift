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

    /// Manifest contract era. `nil` = unparseable version string (caller reports).
    /// Known majors: 0 (v0.x, V1–V13) and 1 (v1.x, +V14/V15). Anything else is an
    /// unknown MAJOR — consumers reject it (C-2.1 field rule).
    static func manifestEra(_ contractVersion: String) -> Int? {
        // Format "v<major>.<minor>".
        guard contractVersion.hasPrefix("v") else { return nil }
        let parts = contractVersion.dropFirst().split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let major = Int(parts[0]), Int(parts[1]) != nil else { return nil }
        return major
    }

    // MARK: - V1–V6: song.json manifest (+ V14/V15, era-scoped v1.x)

    public static func validate(manifest: SongManifest) -> ValidationResult {
        var v: [ContractViolation] = []

        // contractVersion: parseable "v<major>.<minor>" and a KNOWN major.
        // Unknown majors are rejected by consumers (C-2.1 field rule).
        let era = BundleValidator.manifestEra(manifest.contractVersion)
        if era == nil || era! > 1 {
            v.append(ContractViolation("V1", "contractVersion \"\(manifest.contractVersion)\" has an unknown major (supported: v0.x, v1.x)"))
        }

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
            // V3 (declared policy, D-8): voice/VOCALS stems mono, INSTRUMENTAL stereo.
            let expected = p.part == .instrumental ? 2 : 1
            if p.channels != expected {
                v.append(ContractViolation("V3", "part \(p.part.rawValue) declares channels=\(p.channels), D-8 expects \(expected)"))
            }
            if p.noteConfidence < 0 || p.noteConfidence > 1 {
                v.append(ContractViolation("V9", "parts[].noteConfidence must be in [0,1] (got \(p.noteConfidence))"))
            }
        }

        // V14/V15 — era-scoped to v1.x (C-2.2 back-compat: v0.x bundles stay
        // valid under V1–V13 only).
        if let era, era >= 1 {
            // V14 — v1.0 required fields: channels (1|2) and tuning_cents
            // (int, [−50,+50]). hasInstrumental is non-optional in the model.
            if manifest.channels == nil {
                v.append(ContractViolation("V14", "v1.x manifest requires channels (decoded mix, 1|2)"))
            } else if let channels = manifest.channels, channels != 1 && channels != 2 {
                v.append(ContractViolation("V14", "v1.x manifest channels must be 1 or 2 (got \(channels))"))
            }
            if manifest.tuning_cents == nil {
                v.append(ContractViolation("V14", "v1.x manifest requires tuning_cents (int, [−50,+50]; D-22)"))
            } else if let tuning = manifest.tuning_cents, tuning < -50 || tuning > 50 {
                v.append(ContractViolation("V14", "v1.x manifest tuning_cents must be in [−50,+50] (got \(tuning))"))
            }

            // V15 — instrumental consistency (D-9): INSTRUMENTAL entry in parts[]
            // ⇔ hasInstrumental == true.
            let hasInstrumentalPart = manifest.parts.contains { $0.part == .instrumental }
            if hasInstrumentalPart != manifest.hasInstrumental {
                v.append(ContractViolation("V15", "parts[] \(hasInstrumentalPart ? "contains" : "lacks") an INSTRUMENTAL entry but hasInstrumental is \(manifest.hasInstrumental) (D-9: they must agree)"))
            }
        }

        return ValidationResult(violations: v)
    }

    // MARK: - V7–V10: NoteTrack (+ V16–V18, era-scoped to v1.1)

    /// The note-file contract era. `nil` = unparseable version string.
    ///
    /// Known majors: 0 (v0.x — the v0.0 note file, V7–V10 ONLY) and 1 (v1.x —
    /// v1.1 adds V16–V18). Anything else is an unknown MAJOR, which C-10.0
    /// says a consumer MUST reject.
    static func noteEra(_ contractVersion: String) -> Int? {
        guard contractVersion.hasPrefix("v") else { return nil }
        let parts = contractVersion.dropFirst().split(separator: ".", maxSplits: 1)
        guard parts.count == 2, let major = Int(parts[0]), Int(parts[1]) != nil else { return nil }
        return major
    }

    public static func validate(noteTrack: NoteTrack) -> ValidationResult {
        var v: [ContractViolation] = []

        // The era gate (C-10.0): "A consumer MUST accept "v0.0", "v1.0" and
        // "v1.1"; it MUST reject an unknown MAJOR."
        //
        // NOTE (P-305): the contract names no V-rule for the era gate itself,
        // so it is reported under V16 — the rule family that owns the v1.1
        // note-file semantics. Leto may rename it in a future additive
        // contract revision; the BEHAVIOUR (reject the unknown major) is
        // C-10.0's, not this implementation's.
        let era = noteEra(noteTrack.contractVersion)
        if era == nil {
            v.append(ContractViolation("V16", "note file contractVersion \"\(noteTrack.contractVersion)\" is not a parseable \"v<major>.<minor>\" version (supported: v0.0, v1.0, v1.1)"))
            return ValidationResult(violations: v)
        }
        if era != 0 && era != 1 {
            v.append(ContractViolation("V16", "note file contractVersion \"\(noteTrack.contractVersion)\" has an unknown major (supported: v0.0, v1.0, v1.1)"))
            return ValidationResult(violations: v)
        }

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

        // V16–V18 apply to the v1.1 era ONLY. A v0.0/v1.0 note file is
        // validated under V7–V10 ONLY and MUST keep being accepted (C-10.1).
        if era == 1 {
            v.append(contentsOf: validateV11Fields(noteTrack))
        }

        return ValidationResult(violations: v)
    }

    /// V16 + V17 + V18 — the v1.1 note-file rules (C-10.1).
    ///
    /// - V16: the per-note v1.1 fields — `salience` in [0,1] and
    ///   `assignmentBand` one of the three exact spellings. (`unison` is a
    ///   bool by type, and `confidence` is REQUIRED per note in v1.1 — a
    ///   note file without it cannot decode at all, which is a rejection, not
    ///   a silent default.)
    /// - V17: `partPresence[]` consistency — ascending `phraseIndex`,
    ///   `start_s < end_s`, `meanConfidence` in [0,1], `noteCount >= 0`, and
    ///   `present == (noteCount >= 1 && meanConfidence >= 0.60)`. A
    ///   `present == false` entry is NEVER an error.
    /// - V18: band/presence coherence — a note's `assignmentBand` MUST agree
    ///   with its `confidence` under D-41's thresholds. A mismatch is a
    ///   CONTRACT VIOLATION that is REPORTED, never silently repaired.
    static func validateV11Fields(_ track: NoteTrack) -> [ContractViolation] {
        var v: [ContractViolation] = []

        for (i, note) in track.notes.enumerated() {
            if let salience = note.salience, (salience < 0 || salience > 1) {
                v.append(ContractViolation("V16", "note \(i): salience must be in [0,1] (got \(salience))"))
            }
            if let raw = note.assignmentBand {
                if AssignmentBand(rawValue: raw) == nil {
                    v.append(ContractViolation("V16", "note \(i): assignmentBand \"\(raw)\" is not one of CONFIRMED / PROVISIONAL / UNASSIGNED"))
                } else {
                    // V18 — coherence with the confidence (D-41 §1).
                    let expected = AssignmentBand.band(forConfidence: note.confidence)
                    let actual = AssignmentBand(rawValue: raw)!
                    if expected != actual {
                        v.append(ContractViolation("V18", "note \(i): assignmentBand \(actual.rawValue) disagrees with confidence \(note.confidence) (D-41 §1 implies \(expected.rawValue)); a mismatch is a contract violation, not something to repair silently"))
                    }
                }
            }
        }

        if let presence = track.partPresence {
            var previousIndex = -1
            for (i, entry) in presence.enumerated() {
                if entry.phraseIndex <= previousIndex {
                    v.append(ContractViolation("V17", "partPresence[\(i)]: phraseIndex (\(entry.phraseIndex)) must be strictly ascending (previous \(previousIndex))"))
                }
                previousIndex = entry.phraseIndex
                if !(entry.start_s < entry.end_s) {
                    v.append(ContractViolation("V17", "partPresence[\(i)]: start_s (\(entry.start_s)) must be < end_s (\(entry.end_s))"))
                }
                if entry.meanConfidence < 0 || entry.meanConfidence > 1 {
                    v.append(ContractViolation("V17", "partPresence[\(i)]: meanConfidence must be in [0,1] (got \(entry.meanConfidence))"))
                }
                if entry.noteCount < 0 {
                    v.append(ContractViolation("V17", "partPresence[\(i)]: noteCount must be >= 0 (got \(entry.noteCount))"))
                }
                let expectedPresent = entry.noteCount >= 1
                    && entry.meanConfidence >= PartPresence.presenceThreshold
                if entry.present != expectedPresent {
                    v.append(ContractViolation("V17", "partPresence[\(i)]: present (\(entry.present)) disagrees with noteCount (\(entry.noteCount)) and meanConfidence (\(entry.meanConfidence)) — D-41 §2 implies \(expectedPresent)"))
                }
            }
        }

        return v
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

            // Notes file (if declared — OPTIONAL since v1.0, C-2.1) must parse
            // and validate; V10 filename match.
            if let notesRel = p.notesFile {
                let notesURL = bundleDirectory.appendingPathComponent(notesRel)
                if let nd = try? Data(contentsOf: notesURL),
                   let track = try? JSONDecoder().decode(NoteTrack.self, from: nd) {
                    v.append(contentsOf: validate(noteTrack: track).violations)
                    // V10: `part` matches filename PART (case-sensitive rawValue).
                    let expectedName = "notes/\(p.part.rawValue).json"
                    if notesRel != expectedName {
                        v.append(ContractViolation("V10", "notesFile \(notesRel) does not follow notes/<PART>.json (expected \(expectedName))"))
                    }
                    if track.part != p.part {
                        v.append(ContractViolation("V10", "notes file \(notesRel) declares part \(track.part.rawValue), manifest says \(p.part.rawValue)"))
                    }
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
