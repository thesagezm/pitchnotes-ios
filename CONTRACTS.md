# CONTRACTS.md — PitchNotes-iOS frozen interfaces

> How three chats work in parallel without stepping on each other (AGENTS.md §7).
> Leto ratifies every change. Within a milestone, contracts change ONLY additively;
> breaking changes require a new version + Leto ruling + a migration task.
>
> Status: **v0.0 — RATIFIED 2026-11-20 UTC by Leto** (M0, L-006). Paul + Jess: ack in
> QUEUE LOG when you first implement against it. Change log at the bottom.

Naming rules for this document:
- **Units:** seconds fields end in `_s` (float, decimal); milliseconds in `_ms` (int);
  beats are ints. All JSON field names are camelCase. Timestamps `t`/`start_s` are
  seconds from song start (0.0 = first sample of the decoded mix).
- **Raw values are stable forever** (AGENTS §7): nothing below may change its raw
  string/int values, only add new ones (additive).
- **Validators** (V-rules) are numbered so J-004 unit tests and Paul's engine can
  reference them by ID.

---

## C-1 · Part enum (finalized)

Swift, one definition, no lane-local copies:

```swift
/// Stable raw values FOREVER (CONTRACTS v0.0). Ordering `sortOrder` is also
/// contractual: bass < baritone < baritenor < T2 < T1 (no-crossing constraint
/// for voice assignment, P-303) and SOPRANO < ALTO for female chorales.
public enum Part: String, Codable, CaseIterable, Sendable, Comparable {
    case bass          = "BASS"
    case baritone      = "BARITONE"
    case baritenor     = "BARITENOR"
    case t2            = "T2"
    case t1            = "T1"
    case soprano       = "SOPRANO"   // female chorales only
    case alto          = "ALTO"      // female chorales only
    case vp            = "VP"        // vocal percussion
    case lead          = "LEAD"      // featured soloist within a song
    case instrumental  = "INSTRUMENTAL"

    /// Contractual display/assignment order (see above).
    public var sortOrder: Int {
        switch self {
        case .soprano: return 0
        case .alto: return 1
        case .t1: return 2
        case .t2: return 3
        case .baritenor: return 4
        case .baritone: return 5
        case .bass: return 6
        case .vp: return 7
        case .lead: return 8
        case .instrumental: return 9
        }
    }
    public static func < (l: Part, r: Part) -> Bool { l.sortOrder < r.sortOrder }

    // v0.0.1 CLARIFICATION (Leto, D-18.4): there are TWO contractual orderings.
    // 1. NUMERIC `sortOrder` — canonical for UI/display sorting (soprano first …
    //    instrumental last). `Comparable` uses it, so `Part.bass < Part.t1` is FALSE.
    // 2. VOICE RANK — the prose "bass < baritone < baritenor < T2 < T1" (lowest→
    //    highest singable voice) = DESCENDING sortOrder restricted to the seven
    //    singable voices. P-303's no-crossing constraint and any "pitch order"
    //    logic use VOICE RANK, not Comparable.

    /// Voice parts that get note tracks + grading (instrumental/VP handled separately).
    public var isSingableVoice: Bool {
        switch self {
        case .bass, .baritone, .baritenor, .t2, .t1, .soprano, .alto, .lead: return true
        case .vp, .instrumental: return false
        }
    }
}
```

- File/directory names use the **rawValue verbatim** (e.g. `stems/BASS.m4a`,
  `notes/T1.json`) — case-sensitive.
- Default male SDA ensemble: `BASS, BARITONE, BARITENOR, T2, T1`. SOPRANO/ALTO only
  appear in female chorales. VP/LEAD/INSTRUMENTAL are structural markers, not graded
  singing parts (`isSingableVoice == false`).

## C-2 · SongBundle (finalized)

Directory produced by Paul's engine, consumed by Jess's UI. One directory per song,
named by the song `id`. Everything is written ATOMICALLY (write `.tmp`, then rename)
so a cancelled job never leaves a partial bundle (P-202).

```
<bundle>/                       # directory name == song.json "id"
  song.json                     # manifest (schema below)
  stems/<PART>.m4a              # ALAC (AVFoundation native), 44.1 kHz (D-8)
  notes/<PART>.json             # NoteTrack (schema C-2.3)
  pitch/<PART>.json             # PitchFrames (schema C-2.4) — OPTIONAL
  lyrics.lrc                    # OPTIONAL, word/line timed (LRC v1 format)
  score.musicxml                # OPTIONAL, hymn score for score-informed alignment
```

- `stems/`: voice parts are **MONO**; `INSTRUMENTAL` stem is **STEREO** (D-8).
  When the source is acapella, `hasInstrumental == false` and NO
  `stems/INSTRUMENTAL.m4a` exists (D-9).
- `notes/` and `pitch/` exist only for parts listed with those files in the manifest.
- No file in the bundle may exceed the durations implied by `duration_s`.

### C-2.1 · `song.json` manifest schema

```json
{
  "contractVersion": "v0.0",
  "engineVersion": "engine-0.0.0",
  "id": "01JXXXXXXXXXXXXXXXXXXXXXXX",
  "title": "Just As I Am",
  "sourceHash": { "algo": "blake3", "hex": "<64 lowercase hex>" },
  "duration_s": 213.4,
  "sampleRate": 44100,
  "hasInstrumental": true,
  "parts": [
    {
      "part": "BASS",
      "stemFile": "stems/BASS.m4a",
      "channels": 1,
      "notesFile": "notes/BASS.json",
      "pitchFile": "pitch/BASS.json",
      "noteConfidence": 0.82
    }
  ],
  "confidenceSummary": { "meanNoteConfidence": 0.78 }
}
```

Field rules:
- `contractVersion` — string `"v<major>.<minor>"`; consumers reject unknown MAJOR.
- `engineVersion` — free string, engine-authored, monotonic per engine.
- `id` — ULID (26 chars, Crockford base32, uppercase) generated at import.
- `sourceHash` — BLAKE3 of the ORIGINAL imported file bytes (pre-decode).
- `duration_s`, `sampleRate` — of the decoded mix at 44.1 kHz.
- `parts[].part` — C-1 rawValue.
- `parts[].channels` — 1 or 2; must match D-8 policy (voice=1, INSTRUMENTAL=2).
- `parts[].pitchFile` — key may be OMITTED (contract v0.0: pitch tracks optional).
- `parts[].noteConfidence` — mean note confidence of that part's NoteTrack, [0,1];
  parts without a NoteTrack use 0.0.
- **V-rules:** V1 file exists and parses; V2 every `parts[].stemFile` exists in the
  bundle; V3 `channels`/stem reality match D-8; V4 `duration_s > 0`,
  `sampleRate == 44100`; V5 `sourceHash.algo == "blake3"`, `hex` is 64 hex chars;
  V6 every `part` is a C-1 rawValue and unique.

### C-2.2 · (reserved for v1.0 — SongBundle manifest FREEZE at M2, L-203)

### C-2.3 · `notes/<PART>.json` — NoteTrack schema

```json
{
  "contractVersion": "v0.0",
  "part": "BASS",
  "notes": [
    { "start_s": 1.232, "end_s": 2.500, "midi": 48, "cents_ref": 12, "confidence": 0.9 }
  ]
}
```

- `midi` — int, equal-tempered MIDI note number (A440, C4 = 60). Range 24–96.
- `cents_ref` — int, deviation of the note's center pitch from equal temperament,
  clamped [-50, +50] (+ = sharper).
- `confidence` — float [0,1].
- **V-rules:** V7 `start_s < end_s`; V8 notes sorted by `start_s` and NON-overlapping
  within a part; V9 ranges above; V10 `part` matches filename PART.

### C-2.4 · `pitch/<PART>.json` — PitchFrames schema (optional file)

```json
{
  "contractVersion": "v0.0",
  "part": "BASS",
  "hopMs": 16,
  "frames": [
    { "t": 0.016, "hz": 0.0, "confidence": 0.02, "loudness_db": -92.1 }
  ]
}
```

- Fixed 16 ms grid (`hopMs == 16` in v0.0); `frames[i].t == i * 0.016`.
- `hz` — `0.0` = UNVOICED. Voiced range: **46.9–2093.75 Hz** (V11).
- `confidence`, `loudness_db` — [0,1] and dBFS respectively.
- **V-rules:** V11 as above; V12 confidence in [0,1]; V13 `t` strictly increasing,
  uniform 16 ms grid within 1 ms tolerance.

## C-3 · Engine API (finalized signatures; implementation = P-001)

Swift protocol in `Engine/`. Paul implements (`EngineAPI` + real engines); Jess
consumes via `MockEngine` from day one (J-002). The protocol must not import UIKit/
SwiftUI (portability, AGENTS §0); AVFoundation types stay OUT of the protocol
signatures except plain value types.

```swift
public struct DecodedAudio: Sendable {
    public let url: URL          // decoded/normalized audio file on disk (44.1 kHz mix)
    public let sampleRate: Int   // 44100
    public let channels: Int
    public let duration_s: Double
}

public enum SeparationMode: String, Sendable { case twoStem, multiStem }   // D-9: twoStem is default/first

public enum NoteSource: Sendable { case stem(URL), mix(URL) }

public struct PitchFrame: Sendable, Codable {
    public let t: Double
    public let hz: Double
    public let confidence: Double
    public let loudness_db: Double
}

public struct MicChunk: Sendable {
    public let samples: [Float]   // mono, 16 kHz, ~10–40 ms
    public let sampleRate: Int    // 16000
    public let captureTime_s: Double
}

public enum EngineError: Error, Sendable {
    case importFailed(String)
    case unsupportedFormat(String)
    case separationFailed(String)
    case modelMissing(String)
    case contractViolation(String)
}

public protocol EngineAPI: Sendable {
    func importAudio(url: URL) async throws -> DecodedAudio
    func separate(_ audio: DecodedAudio, mode: SeparationMode) async throws -> [Part: URL]
    func pitchFrames(_ audio: DecodedAudio, fmin: Double, fmax: Double) async throws -> PitchFrameStream
    func noteTrack(_ source: NoteSource, part: Part) async throws -> NoteTrack
    /// Real-time path: synchronous, thread-safe, non-allocating-heavy. Called on
    /// the audio/engine queue; must return within the <100 ms feedback budget (§8).
    func livePitch(_ chunk: MicChunk) -> PitchFrame
}

/// AsyncSequence of PitchFrame on a 16 ms grid (C-2.4 values).
public struct PitchFrameStream: AsyncSequence, Sendable {
    public typealias Element = PitchFrame
    // iteration + cancellation; engine-owned implementation
}
```

Threading model (v0.0):
- `importAudio/separate/pitchFrames/noteTrack` — `async`; long-running; internally
  serialized per engine instance; support cooperative cancellation (Task.isCancelled
  checked between chunks); progress reporting arrives in contract v1.0 (L-203).
- `livePitch` — synchronous, thread-safe, no locks held on the audio thread; never
  blocks on I/O.
- All bundled output MUST validate against C-2 schemas (Paul's responsibility).

**MockEngine requirement:** Jess builds UI against a `MockEngine` conforming to
`EngineAPI`, seeded/deterministic, emitting contract-valid PitchFrames/NoteTracks and
a SongBundle on disk that passes the C-2 V-rules. Delivered by P-001; J-002 consumes.
The real engine swaps in at M1/M2/M3 merges with ZERO UI changes (that is the point).

## C-4 · Reference pitch format — UltraStar semantics (finalized)

NoteTrack ↔ UltraStar `.txt` mapping (Jess implements export/import as a logic
module with unit tests, J-303; Paul aligns engine outputs):

- UltraStar note token pitch is **MIDI − 60** (UltraStar 0 = C4 = MIDI 60), integer.
- Note `start`/`length` are BEATS (ints); timing derives from `#BPM` (beats per
  minute, quarter-note = 1 beat) and `#GAP` (ms from file start to beat 0):
  `start_s = GAP/1000 + start_beat * 60/BPM`.
- Round-trip rule ("lossless within schema"): `midi`, `start_s`, `end_s` are
  preserved exactly (subject to BPM/GAP quantization); `cents_ref` resets to 0 and
  `confidence` to 1.0 on import (UltraStar cannot carry them). Export must round
  `start_s`/`end_s` to the nearest beat under the chosen `#BPM`.
- Our importer accepts standard `F : * R G` note kinds; export emits `:` (normal)
  and `*` (golden) only in v0.0.

## C-5 · Grading inputs/outputs (Jess) — v0.0: IO fixed, formulas deferred

- **Inputs:** a reference `NoteTrack` (possibly corrected by J-302) + live
  `PitchFrame`s (grading-grade stream, P-401) + `GradingConfig`.
- **Outputs:** per-note `{centsDeviation, coverage, sustain, hit}`, per-phrase score,
  session grade (A–F) + heatmap.
- Config (defaults FIXED in v0.0; user-tunable from J-405): tolerance ±50 cents,
  octave-equivalence toggle (default ON), onset grace 80–120 ms, breath gate on
  `loudness_db`.
- Exact scoring formulas, weights, and `GradingConfig`/`SessionResult` schema:
  contract **v1.2 (L-401)** — deferred by design (M4), per PLAN M0 scope.

---

## Change log

| Version | Date (UTC) | Change | Ruled by |
|---|---|---|---|
| v0 | — | skeleton created at repo scaffold | pending Leto ratification in M0 |
| **v0.0** | 2026-11-20 | **RATIFIED (L-006):** C-1 Part enum finalized (rawValues + sortOrder + isSingableVoice); C-2 SongBundle + song.json/NoteTrack/PitchFrames JSON schemas + V1–V13 validator rules (D-8 44.1k mono/stereo, D-9 hasInstrumental baked in); C-3 EngineAPI exact Swift signatures + threading model + MockEngine requirement; C-4 UltraStar semantics (pitch = MIDI−60, GAP/BPM mapping, round-trip rule); C-5 IO fixed, formulas deferred to v1.2. Additive-only from here until M0 gate. | Leto |
| v0.0.1 | 2026-11-21 | C-1 doc-only clarification (D-18.4): numeric `sortOrder` (UI/display, Comparable) vs VOICE RANK (assignment/no-crossing = descending sortOrder among singable voices). No raw values, fields, or signatures changed. | Leto |
