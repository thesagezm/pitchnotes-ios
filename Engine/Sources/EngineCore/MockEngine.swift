import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MockEngine (CONTRACTS.md v0.0 C-3 requirement, P-001): deterministic,
// hardware-free EngineAPI implementation for Jess's UI/tests (J-002/J-004) and
// for engine-contract tests. NO AVFoundation/ORT — portable Foundation only.
//
// Scenarios (seeded, all feeding Jess's ribbon now and scoring tests J-401 later):
// perfect, flat (-30c), sharp (+35c), octave error, silent, breathy, late onset,
// vibrato. Scenario selection is a MockEngine init parameter — it does NOT touch
// the frozen EngineAPI surface (no contract addition needed for v0.0).
//
// Determinism: same-platform byte-identical outputs for a given (scenario, seed).
// NOTE: cross-OS byte identity is NOT guaranteed (libm sin/pow may differ by ULPs
// between glibc and Darwin); determinism tests compare runs on one machine.
//
// Honesty notes (documented, not silent):
// - `sourceHash.hex` is a deterministic PSEUDO-hash (seed-derived), NOT real
//   BLAKE3. Real BLAKE3 lands with the real importer (P-203). The field exists so
//   bundles pass the V5 shape rule (algo == "blake3", 64 lowercase hex).
// - Stems are written as PCM WAV, not ALAC .m4a — WAV is writable/verifiable in
//   portable Foundation (channel-count V3 checks work via header parse). The REAL
//   engine writes ALAC per C-2/D-8 at P-204. WAV is played by AVAudioPlayer
//   without UI changes, so the swap stays zero-cost for Jess.
// - `id` is a ULID-format string derived from the seed (fixed timestamp + seeded
//   random bits) so bundles are byte-identical across runs. Real ULIDs with wall
//   clock arrive with the real importer (P-203).

/// Scripted deviation scenarios for the MockEngine singer.
public enum MockScenario: String, CaseIterable, Sendable {
    /// On-pitch, on-time, high confidence.
    case perfect
    /// Every sung pitch 30 cents flat (within grading tolerance ±50).
    case flat
    /// Every sung pitch 35 cents sharp (within grading tolerance ±50).
    case sharp
    /// Sings one octave ABOVE the target (classic tuner error).
    case octaveError
    /// No voiced output at all (silence between phrases too).
    case silent
    /// Voiced and on-pitch but low confidence, low loudness, small jitter.
    case breathy
    /// On-pitch but note onsets start 120 ms late (grading grace-window input).
    case lateOnset
    /// On-pitch mean with ±25 cents vibrato at 5.5 Hz.
    case vibrato
}

public final class MockEngine: EngineAPI, @unchecked Sendable {

    // MARK: - Scripted song (C-major hymn-style progression, 5-part male ensemble)

    static let engineVersion = "engine-mock-0.0.0"
    /// 4 chords × 3 s; each note ends 0.2 s before the next onset (V8 gaps).
    static let duration_s: Double = 12.0

    struct ScriptNote: Sendable { let start_s: Double; let end_s: Double; let midi: Int }

    /// I–Am–F–G in close-position male voicings, all MIDI in contract range 24–96
    /// and all voiced hz within the V11 band (lowest: F2 = 87.3 Hz > 46.9 Hz).
    static let script: [Part: [ScriptNote]] = [
        .bass:      [initNote(0.0, 2.8, 48), initNote(3.0, 5.8, 45), initNote(6.0, 8.8, 41), initNote(9.0, 11.8, 43)],
        .baritone:  [initNote(0.0, 2.8, 52), initNote(3.0, 5.8, 48), initNote(6.0, 8.8, 45), initNote(9.0, 11.8, 47)],
        .baritenor: [initNote(0.0, 2.8, 55), initNote(3.0, 5.8, 52), initNote(6.0, 8.8, 48), initNote(9.0, 11.8, 50)],
        .t2:        [initNote(0.0, 2.8, 60), initNote(3.0, 5.8, 57), initNote(6.0, 8.8, 53), initNote(9.0, 11.8, 55)],
        .t1:        [initNote(0.0, 2.8, 64), initNote(3.0, 5.8, 60), initNote(6.0, 8.8, 57), initNote(9.0, 11.8, 59)],
    ]

    static func initNote(_ start: Double, _ end: Double, _ midi: Int) -> ScriptNote {
        ScriptNote(start_s: start, end_s: end, midi: midi)
    }

    static let scriptedParts: [Part] = [.bass, .baritone, .baritenor, .t2, .t1]

    // MARK: - Configuration

    public let scenario: MockScenario
    public let seed: UInt64
    /// Part whose frames `pitchFrames(_:fmin:fmax:)` returns for the mix
    /// (monophonic mock "dominant voice"; configurable so Jess can preview any part).
    public let referencePart: Part
    /// Where `separate`/`makeBundle` materialize the mock SongBundle.
    public let bundleDirectory: URL

    /// Deterministic ULID-format song id (26 chars, Crockford base32, uppercase).
    public let songID: String

    public init(scenario: MockScenario = .perfect,
                seed: UInt64 = 0x5017,
                referencePart: Part = .bass,
                bundleDirectory: URL? = nil) {
        self.scenario = scenario
        self.seed = seed
        self.referencePart = referencePart
        let id = MockEngine.ulid(seed: seed)
        self.songID = id
        self.bundleDirectory = bundleDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pitchnotes-mock-\(id)", isDirectory: true)
    }

    // MARK: - EngineAPI

    public func importAudio(url: URL) async throws -> DecodedAudio {
        // The mock does not decode audio; it validates the input exists (real
        // import semantics: importing a missing file fails) and describes a
        // deterministic 44.1 kHz mono mix. P-203 (real decode) replaces this.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.importFailed("MockEngine: input file does not exist at \(url.path)")
        }
        return DecodedAudio(url: url, sampleRate: 44100, channels: 1, duration_s: MockEngine.duration_s)
    }

    public func separate(_ audio: DecodedAudio, mode: SeparationMode) async throws -> [Part: URL] {
        // Mock song is a cappella (D-9): no INSTRUMENTAL stem either way; both
        // modes return the five voice parts (mock does not model separation bleed).
        let manifest = try makeBundle(to: bundleDirectory)
        var stems: [Part: URL] = [:]
        for p in manifest.parts {
            stems[p.part] = bundleDirectory.appendingPathComponent(p.stemFile)
        }
        return stems
    }

    public func pitchFrames(_ audio: DecodedAudio, fmin: Double, fmax: Double) async throws -> PitchFrameStream {
        guard fmin >= 0, fmin < fmax else {
            throw EngineError.contractViolation("fmin must be >= 0 and < fmax (got fmin=\(fmin), fmax=\(fmax))")
        }
        let frames = self.frames(for: referencePart, fmin: fmin, fmax: fmax)
        return PitchFrameStream(AsyncStream<PitchFrame>(bufferingPolicy: .unbounded) { continuation in
            // Precomputed table streamed out with cooperative cancellation checks.
            for frame in frames {
                if Task.isCancelled { break }
                continuation.yield(frame)
            }
            continuation.finish()
        })
    }

    public func noteTrack(_ source: NoteSource, part: Part) async throws -> NoteTrack {
        guard MockEngine.script[part] != nil else {
            throw EngineError.separationFailed("MockEngine: part \(part.rawValue) is not in the mock song")
        }
        return noteTrack(for: part)
    }

    public func livePitch(_ chunk: MicChunk) -> PitchFrame {
        // Position = captureTime_s wrapped into the mock song timeline. The
        // unfiltered frame table is generated once (750 frames) and cached, so
        // steady-state calls are an array index — non-allocating-heavy per §8
        // (<100 ms feedback budget). Lock-guarded; built off the audio path.
        var t = chunk.captureTime_s
        if t < 0 || t.isNaN || t.isInfinite { t = 0 }
        t.formTruncatingRemainder(dividingBy: MockEngine.duration_s)
        let frames = cachedFrames(for: referencePart)
        let index = min(Int(t / EngineContract.hopSeconds), frames.count - 1)
        return frames[max(index, 0)]
    }

    private let cacheLock = NSLock()
    private var framesCache: [Part: [PitchFrame]] = [:]

    private func cachedFrames(for part: Part) -> [PitchFrame] {
        cacheLock.lock()
        if let cached = framesCache[part] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let built = unfilteredFrames(for: part)
        cacheLock.lock()
        framesCache[part] = built
        cacheLock.unlock()
        return built
    }

    // MARK: - Bundle materialization (C-2 layout, V1–V13 valid)

    /// Writes the complete mock SongBundle (song.json + stems/*.wav +
    /// notes/<PART>.json + pitch/<PART>.json) atomically (tmp dir + rename).
    /// Returns the manifest. Re-running overwrites the SAME mock bundle (matched
    /// by song id); refuses to replace a directory that holds a different song.
    @discardableResult
    public func makeBundle(to directory: URL? = nil) throws -> SongManifest {
        let dir = directory ?? bundleDirectory
        let fm = FileManager.default

        if fm.fileExists(atPath: dir.appendingPathComponent("song.json").path) {
            // Only replace bundles we own (same id) — never clobber foreign data.
            if let data = try? Data(contentsOf: dir.appendingPathComponent("song.json")),
               let existing = try? JSONDecoder().decode(SongManifest.self, from: data) {
                guard existing.id == songID else {
                    throw EngineError.importFailed("MockEngine.makeBundle: \(dir.path) holds a different song (\(existing.id)); refusing to replace")
                }
                try fm.removeItem(at: dir)
            } else {
                throw EngineError.importFailed("MockEngine.makeBundle: \(dir.path) contains an unparseable song.json; refusing to replace")
            }
        } else if fm.fileExists(atPath: dir.path) && (try? fm.contentsOfDirectory(atPath: dir.path).isEmpty) == false {
            throw EngineError.importFailed("MockEngine.makeBundle: \(dir.path) exists and is not empty; refusing to replace")
        }

        let tmp = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".tmp", isDirectory: true)
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // C-2 bundle layout subdirectories (stems/, notes/, pitch/).
        for sub in ["stems", "notes", "pitch"] {
            try fm.createDirectory(at: tmp.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }

        var partInfos: [PartInfo] = []
        var confidences: [Double] = []

        for part in MockEngine.scriptedParts {
            let stemRel = "stems/\(part.rawValue).wav"
            let stemData = Self.wavData(for: part, scenario: scenario, seed: seed)
            try stemData.write(to: tmp.appendingPathComponent(stemRel))

            let track = noteTrack(for: part)
            let notesRel = "notes/\(part.rawValue).json"
            try Self.jsonData(track).write(to: tmp.appendingPathComponent(notesRel))

            let pitchRel = "pitch/\(part.rawValue).json"
            let frames = PitchFramesFile(part: part, frames: self.frames(for: part, fmin: 0, fmax: .infinity))
            try Self.jsonData(frames).write(to: tmp.appendingPathComponent(pitchRel))

            let noteConf = track.notes.isEmpty ? 0.0 : track.notes.map(\.confidence).reduce(0, +) / Double(track.notes.count)
            confidences.append(noteConf)
            partInfos.append(PartInfo(part: part, stemFile: stemRel, channels: 1,
                                      notesFile: notesRel, pitchFile: pitchRel, noteConfidence: noteConf))
        }

        let meanConf = confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Double(confidences.count)
        let manifest = SongManifest(
            engineVersion: MockEngine.engineVersion,
            id: songID,
            title: "Mock Hymn (\(scenario.rawValue))",
            sourceHash: SourceHash(hex: Self.pseudoHashHex(seed: seed, scenario: scenario)),
            duration_s: MockEngine.duration_s,
            sampleRate: 44100,
            hasInstrumental: false, // D-9 acapella path: no INSTRUMENTAL stem
            parts: partInfos,
            confidenceSummary: ConfidenceSummary(meanNoteConfidence: meanConf)
        )
        try Self.jsonData(manifest).write(to: tmp.appendingPathComponent("song.json"))

        // Atomic swap: rename the fully written tmp directory over the target.
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.moveItem(at: tmp, to: dir)

        // Paul's responsibility (C-3): bundled output MUST validate against C-2.
        let result = BundleValidator.validate(bundleDirectory: dir)
        guard result.isValid else {
            throw EngineError.contractViolation("MockEngine produced an invalid bundle: \(result.violations)")
        }
        return manifest
    }

    // MARK: - Deterministic generation

    /// NoteTrack for a part under the scenario (V7–V10 valid by construction).
    public func noteTrack(for part: Part) -> NoteTrack {
        guard let scriptNotes = MockEngine.script[part] else { return NoteTrack(part: part, notes: []) }
        if scenario == .silent { return NoteTrack(part: part, notes: []) }

        let confidence = Self.noteConfidence(for: scenario)
        let notes = scriptNotes.map { sn in
            var start = sn.start_s
            if scenario == .lateOnset { start += 0.12 } // grading grace-window input
            var midi = sn.midi
            if scenario == .octaveError { midi += 12 }
            var cents = 0
            if scenario == .flat { cents = -30 }
            if scenario == .sharp { cents = 35 }
            return Note(start_s: start, end_s: sn.end_s, midi: midi, cents_ref: cents, confidence: confidence)
        }
        return NoteTrack(part: part, notes: notes)
    }

    /// 16 ms-grid frames for a part under the scenario (V11–V13 valid by
    /// construction); `fmin`/`fmax` band-filter like SwiftF0 (outside ⇒ unvoiced).
    public func frames(for part: Part, fmin: Double, fmax: Double) -> [PitchFrame] {
        unfilteredFrames(for: part).map { frame in
            var f = frame
            if fmax.isFinite && f.hz != 0.0 && (f.hz < fmin || f.hz > fmax) {
                f.hz = 0.0
                f.confidence = min(f.confidence, 0.02)
            }
            return f
        }
    }

    /// Full-duration 16 ms-grid frame table for a part, unfiltered (the cached
    /// source for `frames(for:fmin:fmax:)` and `livePitch`).
    func unfilteredFrames(for part: Part) -> [PitchFrame] {
        let scriptNotes = MockEngine.script[part] ?? []
        let frameCount = Int((MockEngine.duration_s / EngineContract.hopSeconds).rounded())
        var rng = SeededRandom(seed: seed &+ Self.partSeedSalt(part))
        var out: [PitchFrame] = []
        out.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            let t = Double(i) * EngineContract.hopSeconds
            var note: ScriptNote?
            for sn in scriptNotes {
                var effStart = sn.start_s
                if scenario == .lateOnset { effStart += 0.12 }
                if t >= effStart && t < sn.end_s { note = sn; break }
            }

            guard let sn = note, scenario != .silent else {
                let conf: Double = scenario == .silent ? 0.0 : rng.nextDouble(in: 0.0 ..< 0.03)
                out.append(PitchFrame(t: t, hz: 0.0, confidence: conf, loudness_db: scenario == .silent ? -120.0 : -95.0))
                continue
            }

            var midi = Double(sn.midi)
            if scenario == .octaveError { midi += 12 }
            var cents: Double = 0
            switch scenario {
            case .flat: cents = -30
            case .sharp: cents = 35
            case .vibrato: cents = 25.0 * sin(2.0 * .pi * 5.5 * t)
            case .breathy: cents = rng.nextDouble(in: -10.0 ... 10.0)
            default: break
            }

            let hz = EngineContract.detune(hz: EngineContract.hzForMidi(midi), cents: cents)
            var confidence: Double
            var loudness: Double
            switch scenario {
            case .breathy:
                confidence = rng.nextDouble(in: 0.15 ... 0.35)
                loudness = rng.nextDouble(in: -50.0 ... -42.0)
            case .silent:
                confidence = 0.0
                loudness = -120.0
            default:
                confidence = 0.9 + rng.nextDouble(in: 0.0..<0.07)
                loudness = -28.0 + rng.nextDouble(in: -3.0 ... 3.0)
            }

            out.append(PitchFrame(t: t, hz: hz, confidence: confidence, loudness_db: loudness))
        }
        return out
    }

    static func noteConfidence(for scenario: MockScenario) -> Double {
        switch scenario {
        case .perfect: return 0.95
        case .flat, .sharp, .lateOnset: return 0.90
        case .octaveError: return 0.85 // confidently wrong — realistic tuner error
        case .breathy: return 0.30
        case .vibrato: return 0.85
        case .silent: return 0.0
        }
    }

    static func partSeedSalt(_ part: Part) -> UInt64 {
        UInt64(abs(part.sortOrder)) &+ 0x9E37
    }

    // MARK: - Deterministic encoders

    static func jsonData<T: Codable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// Deterministic ULID-format id: fixed 48-bit timestamp block (derived from
    /// seed — NOT wall clock, for byte-identical bundles) + 80 seeded random bits,
    /// Crockford base32 uppercase, 26 chars.
    static func ulid(seed: UInt64) -> String {
        let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var rng = SeededRandom(seed: seed &+ 0x1D1E)
        let bits: [UInt64] = [rng.nextUInt64(), rng.nextUInt64(), rng.nextUInt64()]
        var bitIndex = 0
        func nextBits(_ count: Int) -> UInt64 {
            let word = bits[bitIndex / 64]
            let offset = bitIndex % 64
            bitIndex += count
            var chunk = (word >> UInt64(offset)) & ((1 << UInt64(count)) - 1)
            if offset + count > 64 && bitIndex / 64 < bits.count {
                let nextWord = bits[bitIndex / 64]
                chunk |= (nextWord & ((1 << UInt64(offset + count - 64)) - 1)) << UInt64(64 - offset)
            }
            return chunk
        }
        var chars: [Character] = []
        // 48 "timestamp" bits (10 chars) — fixed per seed, not wall clock.
        for _ in 0..<10 { chars.append(alphabet[Int(nextBits(5))]) }
        // 80 "randomness" bits (16 chars).
        for _ in 0..<16 { chars.append(alphabet[Int(nextBits(5))]) }
        return String(chars)
    }

    /// Deterministic 64-char lowercase hex PSEUDO-hash (NOT BLAKE3 — see class docs).
    /// Salt comes from the scenario's rawValue bytes (NOT hashValue, which is
    /// process-randomized and would break byte-identical determinism).
    static func pseudoHashHex(seed: UInt64, scenario: MockScenario) -> String {
        var salt: UInt64 = 0
        for ch in scenario.rawValue.unicodeScalars { salt = (salt &* 31) &+ UInt64(ch.value) }
        var rng = SeededRandom(seed: seed &+ salt)
        var hex = ""
        for _ in 0..<8 { hex += String(format: "%08x", UInt32(truncatingIfNeeded: rng.nextUInt64())) }
        return hex
    }

    // MARK: - Mock stem synthesis (PCM WAV, 44.1 kHz mono 16-bit, D-8 policy)

    /// PCM WAV bytes for a part's stem: pure-tone synthesis of the script with
    /// harmonics + 10 ms fades; scenario deviations applied like frames(for:).
    static func wavData(for part: Part, scenario: MockScenario, seed: UInt64) -> Data {
        let sampleRate = 44100
        let count = Int(Double(sampleRate) * duration_s)
        var samples = [Double](repeating: 0, count: count)
        let fadeN = sampleRate / 100 // 10 ms

        if scenario != .silent {
            var rng = SeededRandom(seed: seed &+ partSeedSalt(part))
            _ = rng.nextDouble() // warm the stream exactly like frames(for:) consumption
            for sn in script[part] ?? [] {
                var midi = Double(sn.midi)
                if scenario == .octaveError { midi += 12 }
                var cents: Double = 0
                switch scenario {
                case .flat: cents = -30
                case .sharp: cents = 35
                case .vibrato: cents = 12.5 * sin(2.0 * .pi * 5.5 * (sn.start_s + sn.end_s) / 2.0)
                case .breathy: cents = rng.nextDouble(in: -10.0 ... 10.0)
                default: break
                }
                let f0 = EngineContract.detune(hz: EngineContract.hzForMidi(midi), cents: cents)
                let harmonics: [(Double, Double)] = [(1.0, 1.0), (2.0, 0.35), (3.0, 0.18)]
                let startI = Int(sn.start_s * Double(sampleRate))
                let endI = min(Int(sn.end_s * Double(sampleRate)), count)
                for i in startI..<endI {
                    let t = Double(i - startI) / Double(sampleRate)
                    let phase = 2.0 * .pi * f0 * t
                    var v = 0.0
                    for (mult, amp) in harmonics { v += amp * sin(phase * mult) }
                    // 10 ms linear fades at both ends (click-free).
                    let position = i - startI
                    let length = endI - startI
                    let fade = min(1.0, Double(min(position, length - position)) / Double(fadeN))
                    samples[i] += 0.4 * v * fade
                }
            }
        }

        // Interleave PCM16 header + data (little-endian, deterministic bytes).
        var pcm = [UInt8]()
        pcm.reserveCapacity(44 + count * 2)
        let dataSize = count * 2
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        pcm.append(contentsOf: Array("RIFF".utf8)); appendU32(UInt32(36 + dataSize))
        pcm.append(contentsOf: Array("WAVE".utf8))
        pcm.append(contentsOf: Array("fmt ".utf8)); appendU32(16)
        appendU16(1); appendU16(1) // PCM, mono (V3/D-8 voice stems)
        appendU32(UInt32(sampleRate)); appendU32(UInt32(sampleRate * 2))
        appendU16(2); appendU16(16)
        pcm.append(contentsOf: Array("data".utf8)); appendU32(UInt32(dataSize))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            // appendU16 itself writes little-endian — pass the host value through.
            appendU16(UInt16(bitPattern: Int16((clamped * 32767.0).rounded())))
        }
        return Data(pcm)
    }
}
