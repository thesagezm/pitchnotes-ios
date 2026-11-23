# CONTRACTS.md — PitchNotes-iOS frozen interfaces

> How three chats work in parallel without stepping on each other (AGENTS.md §7).
> Leto ratifies every change. Within a milestone, contracts change ONLY additively;
> breaking changes require a new version + Leto ruling + a migration task.
>
> Status: **v1.0.2 — RATIFIED 2026-11-23 UTC by Leto (L-204, D-35 — M2 import-flow
> CLARIFICATION: the C-3 flow must END in a published bundle). Additive-only from
> here on**; breaking changes require a new version + Leto ruling + a migration
> task (AGENTS §7). Paul + Jess: ack in QUEUE LOG when you first implement against it.
> Change log at the bottom. v0.0 (L-006,
> 2026-11-20); v0.0.1 (D-18.4); v0.1 (L-102, 2026-11-21); v0.1.1 (D-22/D-24);
> **v1.0 (L-203, 2026-11-22 — the M2 freeze); v1.0.1 (L-204, D-34 — C-9);
> v1.0.2 (L-204, D-35 — C-9 rule 5 + the C-3 M2-flow note)**.

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
    case vocals        = "VOCALS"    // v1.0 (L-203): two-stem separation output
                                     // (M2); structural marker, never graded

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
        case .vocals: return 10    // v1.0 (L-203): appended — no pre-existing
                                   // sortOrder value changed (additive rule)
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

    /// Voice parts that get note tracks + grading (instrumental/VP/VOCALS are
    /// structural markers handled separately).
    public var isSingableVoice: Bool {
        switch self {
        case .bass, .baritone, .baritenor, .t2, .t1, .soprano, .alto, .lead: return true
        case .vp, .instrumental, .vocals: return false
        }
    }
}
```

- File/directory names use the **rawValue verbatim** (e.g. `stems/BASS.m4a`,
  `notes/T1.json`) — case-sensitive. v1.0 stem naming (C-2.2): two-stem bundles
  use the `VOCALS`/`INSTRUMENTAL` rawValues; per-voice `stems/<PART>.m4a` names
  arrive with M3 bundles (additive).
- Default male SDA ensemble: `BASS, BARITONE, BARITENOR, T2, T1`. SOPRANO/ALTO only
  appear in female chorales. VP/LEAD/INSTRUMENTAL/VOCALS are structural markers, not
  graded singing parts (`isSingableVoice == false`).

## C-2 · SongBundle (finalized)

Directory produced by Paul's engine, consumed by Jess's UI. One directory per song,
named by the song `id`. Everything is written ATOMICALLY — exact v1.0 semantics in
C-2.2 (write staging, rename on success; a cancelled/failed job leaves NO bundle).

```
<bundle>/                       # directory name == song.json "id"
  song.json                     # manifest (schema below) — bundle-complete marker
  stems/<STEM>.m4a              # ALAC (AVFoundation native), 44.1 kHz (D-8);
                                # <STEM> = VOCALS/INSTRUMENTAL (M2 two-stem, C-2.2)
                                # or a C-1 PART rawValue (per-voice stems, M3+)
  notes/<PART>.json             # NoteTrack (schema C-2.3) — M3+ (reserved in M2)
  pitch/<PART>.json             # PitchFrames (schema C-2.4) — OPTIONAL
  lyrics.lrc                    # OPTIONAL, word/line timed (LRC v1 format)
  score.musicxml                # OPTIONAL, hymn score for score-informed alignment
```

- `stems/`: voice parts are **MONO**; `INSTRUMENTAL` stem is **STEREO** (D-8).
  When the source is acapella, `hasInstrumental == false` and NO
  `stems/INSTRUMENTAL.m4a` exists (D-9, V15).
- `notes/` and `pitch/` exist only for parts listed with those files in the manifest.
- No file in the bundle may exceed the durations implied by `duration_s`.

### C-2.1 · `song.json` manifest schema (v1.0 — FROZEN, L-203)

```json
{
  "contractVersion": "v1.0",
  "engineVersion": "engine-0.1.0",
  "id": "01JXXXXXXXXXXXXXXXXXXXXXXX",
  "title": "Just As I Am",
  "sourceHash": { "algo": "blake3", "hex": "<64 lowercase hex>" },
  "duration_s": 213.4,
  "sampleRate": 44100,
  "channels": 2,
  "tuning_cents": 32,
  "hasInstrumental": true,
  "parts": [
    { "part": "VOCALS",       "stemFile": "stems/VOCALS.m4a",       "channels": 1, "noteConfidence": 0.0 },
    { "part": "INSTRUMENTAL", "stemFile": "stems/INSTRUMENTAL.m4a", "channels": 2, "noteConfidence": 0.0 }
  ],
  "confidenceSummary": { "meanNoteConfidence": 0.78 }
}
```

(Example shows the M2 two-stem shape per C-2.2. M3+ bundles list per-voice parts
`BASS…T1` with `notesFile`/`pitchFile` keys; `INSTRUMENTAL` appears only when
`hasInstrumental == true`.)

Field rules (v1.0 — all fields below are **REQUIRED** in a `"v1.0"` manifest):
- `contractVersion` — string `"v<major>.<minor>"`; consumers reject unknown MAJOR.
- `engineVersion` — free string, engine-authored, monotonic per engine.
- `id` — ULID (26 chars, Crockford base32, uppercase) generated at import.
- `title` — display title (human-entered at import or filename-derived).
- `sourceHash` — BLAKE3 of the ORIGINAL imported file bytes (pre-decode).
- `duration_s`, `sampleRate` — of the decoded mix at 44.1 kHz (V4).
- **`channels` — v1.0 NEW REQUIRED:** channel count of the decoded mix (1 or 2);
  describes the SOURCE mix, not the stems (stem channels live in `parts[]`).
- **`tuning_cents` — REQUIRED at v1.0** (optional since v0.1.1, D-22): estimated
  offset of the recording's tuning reference from A440 equal temperament, clamped
  **[−50, +50]** (+ = sharp); `0` when weak-salience or <10c (dettato `MIN_CENTS`
  practice). Produced at import (P-207). Consumers per D-22: grading REFERENCE
  offset (J-401/J-205) and M3 transcription engine-side in-memory retune (P-308);
  stored audio is NEVER retuned.
- **`hasInstrumental` — REQUIRED at v1.0:** false ⇔ acapella source; governs the
  `INSTRUMENTAL` stem's existence (V15, D-9).
- `parts[]` — one entry per stem in the bundle (C-2.2 naming); `part` is a C-1
  rawValue, unique; `stemFile` relative path; `channels` 1|2 matching D-8 (voice
  parts 1, INSTRUMENTAL 2 — V3); `notesFile`/`pitchFile` keys OPTIONAL (M3+);
  `noteConfidence` mean note confidence of that part's NoteTrack [0,1], `0.0` for
  parts without a NoteTrack (all M2 stems).
- `confidenceSummary` — engine-authored aggregate (v1.0: `meanNoteConfidence` over
  parts that carry NoteTracks; `0.0` when none).
- **V-rules (unchanged):** V1 file exists and parses; V2 every `parts[].stemFile`
  exists in the bundle; V3 `channels`/stem reality match D-8; V4 `duration_s > 0`,
  `sampleRate == 44100`; V5 `sourceHash.algo == "blake3"`, `hex` is 64 hex chars;
  V6 every `part` is a C-1 rawValue and unique.
- **V-rules NEW at v1.0:**
  - **V14 — v1.0 required-fields rule:** a manifest with `contractVersion == "v1.0"`
    MUST carry `channels` (1|2), `tuning_cents` (int, [−50, +50]), and
    `hasInstrumental` (bool); any v1.x manifest missing/range-violating them is
    INVALID. v0.0/v0.1 manifests REMAIN VALID under their era rules (V1–V13;
    validators MUST keep accepting them — back-compat is permanent).
  - **V15 — instrumental consistency (D-9):** `parts[]` contains an `INSTRUMENTAL`
    entry ⇔ `hasInstrumental == true`; when false there is NO `INSTRUMENTAL` entry
    and no `stems/INSTRUMENTAL.m4a` on disk.

### C-2.2 · v1.0 freeze notes — stem naming, atomic writes, back-compat (L-203)

- **Stem naming (FROZEN):** `stems/<STEM>.m4a` where `<STEM>` is a C-1 rawValue.
  **M2 two-stem bundles (P-201..P-205):** exactly `VOCALS` (mono) and — when the
  source has accompaniment — `INSTRUMENTAL` (stereo). **M3+ bundles** add per-voice
  `BASS`/`BARITONE`/`BARITENOR`/`T2`/`T1` (+`SOPRANO`/`ALTO` for female chorales)
  stems; `VOCALS`/`INSTRUMENTAL` names remain valid afterward (additive; simple
  imports and mixed-mode bundles keep working). No other stem names are valid;
  new names enter ONLY as additive C-1 rawValues.
- **Atomic bundle write semantics (FROZEN — P-202/P-204):** the engine writes into
  a staging directory `<bundle-id>.tmp` ADJACENT to the final bundle location,
  then renames it to `<bundle-id>` on success. On ANY failure, cancellation, or
  app kill mid-import, the engine MUST remove the staging directory — a cancelled
  job leaves NO partial bundle (P-202 AC). **Consumer rule:** a bundle directory
  is complete IFF it contains a parseable `song.json`; library/scan code ignores
  (and Settings cleanup may delete) `<id>.tmp` staging dirs.
- **Back-compat (permanent):** validators accept v0.0/v0.1/v1.0 manifests, each
  validated under its era's rules (V1–V13 for v0.x; +V14/V15 for v1.x). Generators
  (engine, MockEngine) emit `"v1.0"` from the freeze onward.
- **Additive-only after this freeze** (AGENTS §7): new fields/keys/stem names may
  be added; nothing above may change meaning, type, or raw values without a new
  contract version + Leto ruling + a migration task.

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
    { "t": 0.016, "hz": 0.0, "confidence": 0.02, "loudness_db": -92.1,
      "engine_id": "SWIFTF0", "lookahead_ms": 176 }
  ]
}
```

- Fixed 16 ms grid (`hopMs == 16` in v0.0); `frames[i].t == i * 0.016`.
- `hz` — `0.0` = UNVOICED. Voiced range: **46.9–2093.75 Hz** (V11).
- `confidence`, `loudness_db` — [0,1] and dBFS respectively.
- **v0.1 (additive):** per-frame `engine_id` (OPTIONAL string, a C-6
  `PitchEngineID` rawValue or absent/"" = unknown) and `lookahead_ms` (OPTIONAL
  int ≥ 0, 0 = causal). v0.0 bundles without these keys REMAIN VALID — V11–V13
  ignore them; validators must not require them (no new V-rule in v0.1).
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
    // v0.1 (L-102, additive): provenance + timing. Decoders MUST accept frames
    // missing these keys (v0.0 bundles) and treat them as ("", 0).
    public var engine_id: String       // PitchEngineID rawValue or "" (unknown)
    public var lookahead_ms: Int       // 0 = causal; >0 = post-hoc lookahead
}

public extension PitchFrame {
    init(t: Double, hz: Double, confidence: Double, loudness_db: Double,
         engine_id: String = "", lookahead_ms: Int = 0) {
        self.t = t
        self.hz = hz
        self.confidence = confidence
        self.loudness_db = loudness_db
        self.engine_id = engine_id
        self.lookahead_ms = lookahead_ms
    }
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

Threading model (v0.0; progress/cancellation refined in C-8, v1.0):
- `importAudio/separate/pitchFrames/noteTrack` — `async`; long-running; internally
  serialized per engine instance; support cooperative cancellation per C-8
  (Task.isCancelled checked between chunks; progress reporting per C-8).
- `livePitch` — synchronous, thread-safe, no locks held on the audio thread; never
  blocks on I/O.
- All bundled output MUST validate against C-2 schemas (Paul's responsibility).

**MockEngine requirement:** Jess builds UI against a `MockEngine` conforming to
`EngineAPI`, seeded/deterministic, emitting contract-valid PitchFrames/NoteTracks and
a SongBundle on disk that passes the C-2 V-rules. Delivered by P-001; J-002 consumes.
The real engine swaps in at M1/M2/M3 merges with ZERO UI changes (that is the point).

**M2 real-engine note (v1.0.2, D-35 — CLARIFICATION, no signature changed):** the
app-facing M2 engine is an APP-TARGET facade over C-8 + C-9 (the concrete class and
initializer are fixed in DECISIONS D-35 and the QUEUE row X-211, because the app
must construct it by name). The rule that matters here is the publish rule: the C-3
flow is `importAudio` → `separate`, so the SongBundle is published INSIDE that flow —
see C-9 rule 5.

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

## C-6 · Live pitch engine facade + part range presets — NEW v0.1 (L-102)

### C-6.0 · PitchEngineID + LivePitchEngine facade

Two streaming pitch sources exist by design (D-17/D-19, PLAN R2): a CAUSAL
zero-lookahead ribbon for instant feedback, and an ACCURATE post-hoc stream for
grading. The facade makes both explicit and labeled; frames from either source
are C-2.4 `PitchFrame`s with `engine_id`/`lookahead_ms` set.

```swift
/// RawValues STABLE FOREVER (additive only). Persisted in PitchFrame JSON
/// (C-2.4) — renaming an engine's rawValue would orphan stored frames.
public enum PitchEngineID: String, Sendable, Codable, CaseIterable {
    case ribbonMpmYin = "RIBBON_MPM_YIN"  // D-17/D-19 v1 causal ribbon
                                          // (vendored sevagh MPM/YIN; no
                                          // training data, zero lookahead)
    case swiftf0      = "SWIFTF0"         // SwiftF0 ONNX grading-grade stream
                                          // (176 ms streaming lookahead)
    // future (additive): a clean-weights NanoPitch retrain (D-17.2) would add
    // e.g. "NANOPITCH_RETRAIN"; optional reference engines (X-601) likewise.
}

/// Additive composition over EngineAPI (C-3): an engine that exposes BOTH
/// sources with explicit identity. Implemented by Paul (P-105); Jess consumes
/// via MockEngine conforming to the same protocol. Threading semantics of
/// ribbonFrame mirror EngineAPI.livePitch (synchronous, audio-safe).
public protocol LivePitchEngine: EngineAPI {
    /// The causal ribbon source: engine_id == RIBBON_MPM_YIN, lookahead_ms == 0.
    var ribbonSource: PitchEngineID { get }
    /// The accurate grading source: engine_id == SWIFTF0, lookahead_ms == 176.
    var gradingSource: PitchEngineID { get }

    /// One live frame from the ribbon source (causal, zero-lookahead).
    /// Returned frame MUST carry engine_id == ribbonSource, lookahead_ms == 0.
    func ribbonFrame(_ chunk: MicChunk) -> PitchFrame

    /// Grading-grade frames over a decoded buffer (post-hoc, band-limited).
    /// Same frame semantics as EngineAPI.pitchFrames; returned frames MUST
    /// carry engine_id == gradingSource and that source's lookahead_ms.
    func gradingFrames(_ audio: DecodedAudio, fmin_hz: Double, fmax_hz: Double)
        async throws -> PitchFrameStream
}
```

- **Who drives what:** J-101's live ribbon cursor consumes ONLY `ribbonFrame`
  output (< 100 ms feedback budget, §8). Session grading (M4) and
  reference-accurate NoteTrack work consume ONLY `gradingFrames` output; P-401
  time-aligns its late frames using `lookahead_ms`.
- **engine_id discipline:** every frame an engine emits in live mode MUST carry
  its `PitchEngineID` rawValue; `""` is legal only in v0.0-era persisted data.
- MockEngine (EngineCore) implements the same facade with mock engine IDs
  (`RIBBON_MPM_YIN`/`SWIFTF0`) so J-101/J-103 build against the real shape.

### C-6.1 · Part range presets (single source of truth; calibratable)

From UX.md §3.6 (X-001), ratified verbatim. Both lanes consume THIS table for
part selection UI, `fmin/fmax` band filtering (`pitchFrames`/`gradingFrames`),
and ribbon follow-window centering. Values are equal-tempered MIDI (A440,
C4 = 60); Hz rounded to 0.1.

| Part | Preset | MIDI low–high | Hz low–high |
|---|---|---|---|
| BASS | E2–G3 | 40–55 | 82.4–196.0 |
| BARITONE | A2–D4 | 45–62 | 110.0–293.7 |
| BARITENOR | C3–F4 | 48–65 | 130.8–349.2 |
| T2 | E3–A4 | 52–69 | 164.8–440.0 |
| T1 | G3–E5 | 55–76 | 196.0–659.3 |
| SOPRANO | C4–G5 | 60–79 | 261.6–784.0 |
| ALTO | G3–D5 | 55–74 | 196.0–587.3 |

- Keys are C-1 rawValues (uppercase). SOPRANO/ALTO appear only for female
  chorale bundles; male ensembles use the five default presets.
- **Calibration (user-local, never in the bundle):** per-part integer semitone
  nudge −2…+2 (default 0) and a mic-profile offset (cents), applied to the
  preset before use: `fmin/fmax` = preset shifted by the nudge. Stored per
  device (Jess lane, UX §3.6); presets themselves are fixed contract data —
  per-song custom ranges arrive with the M3 calibration task (J-302) and extend
  this table additively.
- Range presets constrain FILTERING only; they are not hard gates (a singer
  outside their preset range still produces frames — the UI shows the honest
  deviation; D-12 honesty rule).

## C-7 · Spike-fixture parity metadata — NEW v0.1.1 (D-24, optional)

Reference tensors captured from a Python export during an engine port are stored
NEXT TO the fixture (Tests/Spikes/, never in a SongBundle) with a sidecar manifest so
parity assertions (P-208) are reproducible:

```json
{
  "referenceVersion": 1,
  "engine": "SWIFTF0",
  "fixture": "sweep_46_2100Hz_16k.wav",
  "fixture_sha256": "<64 lowercase hex>",
  "export": { "source": "lars76/swift-f0 @ <pin>", "script": "scripts/models/…", "date": "2026-11-21" },
  "tensors": [
    { "name": "frames_hz", "file": "sweep.frames_hz.f32.bin", "shape": [N], "dtype": "float32" }
  ],
  "tolerance": { "abs": 1e-3, "rel": 1e-4 }
}
```

- OPTIONAL sidecar; nothing in C-2 consumes it. `fixture_sha256` binds tensors to the
  exact fixture bytes; a mismatch fails the spike BEFORE comparison (V-rule style).
- Parity pass criterion = every tensor within `tolerance` (abs OR rel) of the Swift/ORT
  output. Tolerances are documented per engine, never tightened silently.
- Same shape reserved for P-307 dettato maps (`engine: "DETTATO_TRANSCRIBER"`).

## C-8 · Import progress & cancellation — NEW v1.0 (L-203, D-32.3)

Long-running engine calls (`importAudio`, `separate`, the future note-track paths)
report staged progress and cancel cooperatively. EngineAPI signatures are UNCHANGED —
this is an additive protocol so v0.x conformers keep compiling.

```swift
/// RawValues STABLE FOREVER (additive only). Persisted in UI state/logs.
public enum ImportStage: String, Sendable, CaseIterable {
    case decoding     // container decode → 44.1 kHz mix (P-203)
    case separating   // chunked two-stem separation (P-201/P-202)
    case assembling   // ALAC stem encode + SongBundle assembly (P-204)
}

public struct ImportProgress: Sendable {
    public let stage: ImportStage
    /// OVERALL import fraction in [0, 1]; MONOTONIC within one import call
    /// (never decreases; 1.0 only at completion — P-202 AC).
    public let fraction: Double
    /// Engine-authored optional human-readable detail (e.g. "chunk 7/40").
    public let detail: String?
}

public typealias ImportProgressHandler = @Sendable (ImportProgress) -> Void

/// Additive conformance over EngineAPI (C-3). Implemented by Paul's real engine
/// AND MockEngine (J-201 builds the progress UI against the mock from day one).
public protocol ProgressReportingEngine: EngineAPI {
    /// Set BEFORE calling importAudio/separate; nil clears. Called on an ARBITRARY
    /// thread/queue — the handler must not block or touch UI directly. Last
    /// handler wins; the engine owns no delivery cadence guarantees beyond
    /// "monotonic fraction, at least one call per stage".
    func setImportProgressHandler(_ handler: ImportProgressHandler?)
}
```

**Cancellation (FROZEN):** the caller cancels by cancelling the surrounding Swift
`Task`. Engines check `Task.isCancelled` between chunks/frames and abort by throwing
`CancellationError()` (Swift standard — no new error enum case; engines MAY wrap it
in `EngineError.separationFailed`/`importFailed` ONLY if the underlying cause is
something other than the cancellation itself). On cancellation or error mid-import:
staging directory removed, NO partial bundle (C-2.2), and any already-emitted
progress state is simply abandoned. J-201's cancel button cancels the Task; the
UI resets to idle on the thrown error.

---

## C-9 · Bundle-producing import — NEW v1.0.1 (L-204, D-34, ADDITIVE)

M2 made the app depend on a fact the frozen C-3 `EngineAPI` cannot carry:
**which SongBundle an import produced.** `separate` returns raw stem URLs, and
`EngineAPI` is FROZEN at v1.0 (additive-only, L-203) — so the fact travels in a
NEW additive protocol instead of a changed signature. Zero existing conformer
breaks; v0.x/v1.0 engines that do not implement it keep working.

```swift
/// Additive conformance over ProgressReportingEngine (C-8). Implemented by an
/// engine that ASSEMBLES a SongBundle (M2: P-204 real engine) and by the mock
/// engines (J-201's ScriptedImportEngine already exposes the same property).
public protocol BundleProducingEngine: ProgressReportingEngine {
    /// Bundle id = the bundle DIRECTORY name under the library root. Set ONLY
    /// after the atomic publish completes (C-2.2: the rename is the publish,
    /// `song.json` inside it is the completion marker) — never mid-staging.
    /// nil when no bundle has been produced by this engine instance.
    var importedBundleID: String? { get }
}
```

**Rules:**
1. `importedBundleID` is set **after** the bundle is complete and visible at
   its final path; a cancelled/failed import leaves it `nil` (no partial bundle
   — C-2.2) and must not leave a stale id pointing at a staging directory.
2. The consumer (J-201 import flow) MUST prefer `BundleProducingEngine`.
3. **Derivation fallback (permitted, never required):** if an engine does not
   conform to C-9, the consumer MAY derive the bundle directory from the
   parent directory of a returned stem URL. This keeps a non-conforming engine
   usable and keeps C-9 from becoming a new blocker; the protocol exists so the
   fact is EXPLICIT, not implied.
4. The id is a directory name only (no path separators, no `..`); consumers join
   it to the library root themselves.
5. **M2 flow rule (v1.0.2, D-35 — CLARIFICATION, no signature changed):** the C-3
   import flow IS `importAudio` → `separate`, so the publish happens INSIDE that
   flow. By the time `separate` returns, a conforming M2 engine MUST have published
   a COMPLETE bundle under the library root (C-2.2 completion marker: `song.json`
   present in `<libraryRoot>/<id>/`) and MUST have set `importedBundleID` to that
   bundle's directory name. An engine that returns stems WITHOUT publishing
   satisfies C-3 but NOT C-9 for M2 — the consumer rejects it with the C-2.2
   completeness check (`"completed bundle failed the completeness check"`).
   Rule 3's derivation fallback presupposes the same thing: a PUBLISHED stem's
   parent directory IS the bundle directory.

**Acks:** PAUL + JESS — ack C-9 in your next LOG line (L-006/L-102 precedent).
Both lanes already depend on this fact (Paul's P-204 engine must publish it;
Jess's J-201 flow already reads `importedBundleID`), so this ratifies an
existing seam rather than inventing one.

---

## Change log

| Version | Date (UTC) | Change | Ruled by |
|---|---|---|---|
| v0 | — | skeleton created at repo scaffold | pending Leto ratification in M0 |
| **v0.0** | 2026-11-20 | **RATIFIED (L-006):** C-1 Part enum finalized (rawValues + sortOrder + isSingableVoice); C-2 SongBundle + song.json/NoteTrack/PitchFrames JSON schemas + V1–V13 validator rules (D-8 44.1k mono/stereo, D-9 hasInstrumental baked in); C-3 EngineAPI exact Swift signatures + threading model + MockEngine requirement; C-4 UltraStar semantics (pitch = MIDI−60, GAP/BPM mapping, round-trip rule); C-5 IO fixed, formulas deferred to v1.2. Additive-only from here until M0 gate. | Leto |
| v0.0.1 | 2026-11-21 | C-1 doc-only clarification (D-18.4): numeric `sortOrder` (UI/display, Comparable) vs VOICE RANK (assignment/no-crossing = descending sortOrder among singable voices). No raw values, fields, or signatures changed. | Leto |
| v0.1.1 | 2026-11-21 | ADDITIVE (D-22/D-24): C-2.1 song.json gains OPTIONAL `tuning_cents` (int, [−50,+50], default 0; REQUIRED at the v1.0 freeze per L-203 pre-staging) — no V-rule yet, validators accept v0.0 bundles unchanged; NEW C-7 optional spike-fixture parity/reference metadata (sidecar, never in SongBundles; P-208). LivePitchEngine facade + PitchFrame semantics UNTOUCHED. | Leto |
| **v0.1** | 2026-11-21 | **RATIFIED (L-102, additive over v0.0/v0.0.1):** C-3 PitchFrame gains `engine_id` (String) + `lookahead_ms` (Int) with decoding defaults ("", 0) — v0.0 JSON stays valid, no new V-rule; C-2.4 schema documents the optional keys; NEW C-6: `PitchEngineID` enum (RIBBON_MPM_YIN / SWIFTF0, rawValues stable forever) + `LivePitchEngine` facade (ribbonSource causal zero-lookahead vs gradingSource post-hoc 176 ms) + C-6.1 part range presets (X-001/UX §3.6 table verbatim, calibratable). EngineAPI signatures unchanged. | Leto |
| **v1.0** | 2026-11-22 | **RATIFIED (L-203, M2 SongBundle manifest FREEZE — additive-only after this):** C-2.1 manifest v1.0 fields all REQUIRED — `tuning_cents` REQUIRED (was optional per v0.1.1/D-22) with NEW **V14** (v1.0 required-fields + ranges); top-level `channels` (decoded mix) NEW REQUIRED; `hasInstrumental` REQUIRED with NEW **V15** (INSTRUMENTAL entry ⇔ hasInstrumental, D-9); example shows the M2 two-stem shape. C-1 += `vocals = "VOCALS"` (structural, isSingableVoice false, sortOrder 10 appended — no pre-existing value changed). C-2.2 = freeze notes: stem naming (M2: VOCALS/INSTRUMENTAL; per-voice names M3+), atomic bundle write semantics (`<id>.tmp` staging + rename; song.json = complete marker), permanent v0.x back-compat. NEW C-8: ImportStage/ImportProgress/ImportProgressHandler + `ProgressReportingEngine` additive protocol + Task-cancellation contract (CancellationError, no partial bundles). EngineAPI signatures unchanged; C-5/C-6/C-7 untouched. | Leto |
| **v1.0.1** | 2026-11-22 | **RATIFIED (L-204, D-34 — ADDITIVE, no signature changed):** NEW C-9 `BundleProducingEngine` (over C-8) carrying `importedBundleID` — the fact "which bundle did this import publish" — because C-3 is frozen and `separate` returns raw stem URLs. Set only AFTER the atomic publish (C-2.2), nil on cancel/failure; consumer MAY derive the bundle dir from a stem URL's parent when an engine does not conform (C-9 rule 3), so it can never become a blocker. EngineAPI signatures unchanged; C-1/C-2/C-3/C-5/C-6/C-7/C-8 untouched. | Leto |
| **v1.0.2** | 2026-11-23 | **RATIFIED (L-204, D-35 — CLARIFICATION, no signature changed):** C-9 gains **rule 5 (M2 flow rule)** — because the C-3 flow is `importAudio` → `separate`, the PUBLISH happens inside that flow: by the time `separate` returns, a conforming M2 engine MUST have published a complete bundle (C-2.2 `song.json` marker) and MUST have set `importedBundleID`. C-3 gains an M2 real-engine note (the app-target facade over C-8 + C-9; concrete class/init fixed in DECISIONS D-35 + QUEUE X-211). Found by reading both implementations: Jess's flow requires the published bundle; Paul's C-3 `separate` returned raw stems without publishing ⇒ the real-engine import would have failed the app's own completeness check at the device demo. NO signature changed; no rule re-opened. | Leto |
