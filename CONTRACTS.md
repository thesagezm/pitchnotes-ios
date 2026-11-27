# CONTRACTS.md — PitchNotes-iOS frozen interfaces

> How three chats work in parallel without stepping on each other (AGENTS.md §7).
> Leto ratifies every change. Within a milestone, contracts change ONLY additively;
> breaking changes require a new version + Leto ruling + a migration task.
>
> Status: **v1.2 — RATIFIED 2026-11-27 UTC by Leto (D-58 — ADDITIVE ONLY over v1.1.1;
> v1.1.1 is NOT re-opened and every v1.1/v1.1.1 clause, every v1.0.3 field and every
> V-rule V1–V18 stays exactly as it is). v1.2 adds: NEW **C-17** (the C-14 adoption
> gate — v1.2 amendment: the CORROBORATION branch + the pinned `Agreement` metric —
> answering Paul's measured C-14 finding) · NEW **C-18** (`SessionResult` — the
> grading output, C-5's deferred schema) · NEW **C-19** (`GradingConfig` — the
> user-tunable grading configuration, C-5's deferred config) · NEW **C-20** (the
> transposition & tempo mapping + the latency offset + the `tuningCents`
> preservation rule). The grading formulas stay implementation-owned (Jess's);
> v1.2 pins the SHAPES, the ranges, the determinism requirement and the D-54
> policy fields (D-54: confidence is reported, never a weight).
> The on-disk `contractVersion` string stays `"v1.1"` for every pre-existing file —
> the string identifies the v1.1 schema FAMILY, and an additive clause inside that
> family does not change it; the NEW C-18/C-19 files carry `"v1.2"`.
> Additive-only from
> here on**; breaking changes require a new version + Leto ruling + a migration
> task (AGENTS §7). Paul + Jess: ack in QUEUE LOG when you first implement against it.
> Change log at the bottom. v0.0 (L-006,
> 2026-11-20); v0.0.1 (D-18.4); v0.1 (L-102, 2026-11-21); v0.0.1 (D-22/D-24);
> **v1.0 (L-203, 2026-11-22 — the M2 freeze); v1.0.1 (L-204, D-34 — C-9);
> v1.0.2 (L-204, D-35 — rule 5, over-specified, withdrawn by v1.0.3);
> v1.0.3 (L-204, D-36 — C-9.1 + rule 5 restated);
> v1.1 (L-301, 2026-11-24 — the M3 additive delta; v1.0.3 semantics UNCHANGED);
> v1.1.1 (D-47, 2026-11-25 — the M3 contract-gap delta: C-15 + C-16 + the C-13.2
> `partMapping` + the C-11 split `confidence`; v1.1 semantics UNCHANGED);
> v1.2 (D-58, 2026-11-27 — the M4 grading delta: the C-14 adoption-gate amendment +
> the Agreement metric pin + C-18 SessionResult + C-19 GradingConfig + C-20
> transposition/tempo/latency; v1.1.1 semantics UNCHANGED)**.

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
- **v1.1 NOTE-TRACK METADATA EXISTS — see C-2.5.** C-2.3 above stays the **v0.0**
  schema, unchanged and permanently valid; v1.1 only ADDS.

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
- **Which track is the reference — NEW v1.1: see C-14** (correction overlay →
  else score-informed if alignment confidence ≥ 0.70 AND agreement improved →
  else heuristic; UNASSIGNED notes excluded from grading by default; unison
  grades per-part; absent parts are dimmed, never hidden).
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
5. **M2 flow rule (v1.0.3, D-36 — RESTATED, shape-agnostic, no signature changed):**
   what the contract requires is the OUTCOME — the import flow the app drives
   MUST END with a COMPLETE published bundle under the library root (C-2.2
   completion marker: `song.json` present in `<libraryRoot>/<id>/`) and with
   `importedBundleID` set to that bundle's directory name. HOW the engine gets
   there is the engine's business: the M2 real engine's whole-import call
   (C-9.1) OR a C-3 pair whose `separate` publishes. (The v1.0.2 wording — "by
   the time `separate` returns" — over-specified the call shape and is
   withdrawn.) An engine that returns stems WITHOUT ever publishing satisfies
   C-3 but NOT C-9 for M2 — the consumer rejects it with the C-2.2 completeness
   check (`"completed bundle failed the completeness check"`). Rule 3's
   derivation fallback presupposes the same thing: a PUBLISHED stem's parent
   directory IS the bundle directory.

---

## C-9.1 · The M2 whole-import entry point — NEW v1.0.3 (L-204, D-36, ADDITIVE)

M2's app-facing engine ASSEMBLES a SongBundle, and the manifest needs facts that
only the DECODE stage produces (the source hash, the decoded duration, the
normalised mix). Splitting the flow into `importAudio` → `separate` would force a
SECOND decode/hash to build the manifest and would split the all-or-nothing
guarantee (C-8: no partial bundle, NO residue) across two calls with the app in
between. The M2 real engine therefore exposes ONE whole-import call:

```swift
/// The M2 bundle-producing engine's whole-import entry point (D-36).
/// Concrete implementation: `SongBundleImportEngine.importSong(source:title:)`
/// in `Engine/ImportKit`. A RENAME IS A CONTRACT CHANGE.
func importSong(source: URL, title: String) async throws -> ImportOutcome
```

**Rules:**
1. The call owns the whole import: decode → separate → assemble → ATOMIC publish
   (C-2.2). It is all-or-nothing (C-8): on throw/cancel it leaves NO bundle and NO
   residue, and `importedBundleID` stays nil.
2. It returns the PUBLISHED bundle — the bundle id, its directory and its manifest
   (`ImportOutcome`, in EngineCore). The same id is available as `importedBundleID`
   (C-9 rule 1).
3. **Consumer rule:** an engine that exposes this call is driven THROUGH it; an
   engine that does NOT (J-201's mock) is driven with the frozen C-3 pair. The app
   implements both behind its factory — no signature is changed, no conformer
   breaks, and C-9 rule 3's derivation fallback stays available.
4. **No new Swift protocol is REQUIRED.** The app-side seam (one closure that runs
   the import and translates its outcome) IS the interface. A protocol in EngineCore
   is an optional additive nicety, not a gate item.

**Acks:** PAUL + JESS — ack C-9 in your next LOG line (L-006/L-102 precedent).
Both lanes already depend on this fact (Paul's P-204 engine must publish it;
Jess's J-201 flow already reads `importedBundleID`), so this ratifies an
existing seam rather than inventing one.

---

## C-10 · NoteTrack v1.1 metadata — NEW v1.1 (L-301, D-41, ADDITIVE)

M3 produces per-voice note tracks that are **honest about how sure the engine
is** (D-41), can be **corrected by the user** (J-302), and can be **aligned to a
score** (P-304). C-2.3 froze the v0.0 note shape; this section **ADDS** to it.
**Nothing in C-2.3 changes meaning, type, or raw value.** A v0.0 note file
(`contractVersion: "v0.0"`) REMAINs VALID, unchanged, forever — and a consumer
that meets one MUST behave exactly as it does today.

### C-10.0 · The v1.1 NoteTrack file

`notes/<PART>.json` at v1.1:

```json
{
  "contractVersion": "v1.1",
  "part": "BASS",
  "engineVersion": "basicpitch-0.3.0",
  "notes": [
    { "start_s": 1.232, "end_s": 2.500, "midi": 48, "cents_ref": 12,
      "confidence": 0.91, "unison": false, "salience": 0.88,
      "assignmentBand": "CONFIRMED" }
  ],
  "partPresence": [
    { "phraseIndex": 0, "start_s": 0.0, "end_s": 4.0,
      "present": true, "meanConfidence": 0.87, "noteCount": 6 }
  ],
  "assignmentSummary": { "confirmed": 5, "provisional": 1, "unassigned": 0 }
}
```

**Field rules (v1.1 — every key below is OPTIONAL except `contractVersion`,
`part` and `notes`):**

- **`contractVersion`** — `"v1.1"`. A consumer MUST accept `"v0.0"`, `"v1.0"` and
  `"v1.1"`; it MUST reject an unknown MAJOR.
- **`engineVersion`** (OPTIONAL, string) — the engine that produced THIS track.
  Free string, engine-authored. **ABSENT ⇒** treat as `"unknown"`; a consumer
  MUST NOT invent a value and MUST NOT refuse the file for its absence.
- **`confidence`** (per note, OPTIONAL at the file level but REQUIRED per note
  when the file is v1.1) — the note's confidence in [0,1]. **THIS IS THE SAME
  FIELD C-2.3 ALREADY DEFINED** — its meaning is unchanged. The v1.1 addition is
  the **`assignmentBand`** beside it, not a redefinition of `confidence`.
- **`unison`** (per note, OPTIONAL, bool) — **D-41 §3**: this note shares its
  MIDI pitch (within **±25 cents**) with a note of another part in the same
  phrase. **ABSENT ⇒** treat as `false`.
- **`salience`** (per note, OPTIONAL, float [0,1]) — **P-302**'s per-note
  salience (how strongly the multi-f0 posterior supported this note).
  **ABSENT ⇒ the consumer MUST behave EXACTLY as it does today** — i.e. no
  salience-based filtering, weighting, or rendering. This field is
  **additive-and-optional on purpose**: a consumer written before salience
  existed must keep working, unchanged, on a file that carries it.
- **`assignmentBand`** (per note, OPTIONAL, string) — **D-41 §1**: one of
  `"CONFIRMED"` (c ≥ 0.80), `"PROVISIONAL"` (0.50 ≤ c < 0.80), `"UNASSIGNED"`
  (c < 0.50). **ABSENT ⇒** the consumer MUST derive the band from `confidence`
  using those same thresholds. **PRESENT ⇒** it MUST be one of the three exact
  spellings above (raw values are stable forever).
- **`partPresence[]`** (OPTIONAL array) — **D-41 §2**, one entry per phrase for
  THIS part: `{phraseIndex, start_s, end_s, present, meanConfidence, noteCount}`.
  A part is **PRESENT** in a phrase iff it has ≥ 1 note there AND the mean
  assignment confidence of its notes in that phrase is ≥ **0.60**; otherwise
  **ABSENT**. A phrase is a contiguous **4.0 s** span, or **bar-aligned** when
  a score is present (the score's bar map defines the spans).
  **ABSENT ⇒** the consumer MUST NOT dim or hide anything; it MUST behave as
  it does today.
- **`assignmentSummary`** (OPTIONAL) — `{confirmed, provisional, unassigned}`
  counts for this part. **ABSENT ⇒** the consumer MAY compute the counts from
  the notes; it MUST NOT fail.

**The ABSENCE RULE, stated once and binding:** *every field in this section is
OPTIONAL, and a consumer MUST behave exactly as it did before v1.1 when the
field is absent.* Absent metadata is never a validation error, never a reason
to reject a bundle, and never a reason to fail an import.

### C-10.1 · New V-rules (v1.1) — V16, V17, V18

- **V16 — v1.1 note fields:** for a file with `contractVersion == "v1.1"`, every
  note carries `confidence` in [0,1] (V9); `unison`, if present, is a bool;
  `salience`, if present, is in [0,1]; `assignmentBand`, if present, is one of
  the three exact strings. **A v0.0/v1.0 note file is validated under V7–V10
  ONLY — V16 does not apply to it, and validators MUST keep accepting it.**
- **V17 — part presence consistency:** `partPresence[]`, if present, is ordered
  by `phraseIndex` ascending, `start_s < end_s` per entry, `meanConfidence` in
  [0,1], `noteCount` ≥ 0, and `present == (noteCount >= 1 && meanConfidence >=
  0.60)`. A `present == false` entry MUST NOT be treated as an error.
- **V18 — band/presence coherence:** if `assignmentBand` is present on a note,
  it MUST agree with `confidence` under D-41's thresholds (≥0.80 CONFIRMED,
  0.50–0.80 PROVISIONAL, <0.50 UNASSIGNED). **A mismatch is a CONTRACT
  VIOLATION, not something to silently repair** — the engine fixes it, the
  consumer reports it.

### C-10.2 · `engineVersion` and the manifest

C-2.1 already defines a top-level manifest `engineVersion`. **The NoteTrack's
own `engineVersion` (C-10.0) is ADDITIONAL and does not replace it:** the
manifest's is the bundle's producer; the track's is the producer of THAT track
(a track may be re-derived by a later engine). **A consumer that sees only the
manifest's `engineVersion` (a v0.0/v1.0 bundle) MUST behave exactly as it does
today.** P-305 produces the per-track `engineVersion`.

---

## C-11 · Correction overlay — NEW v1.1 (L-301, D-41 §4, ADDITIVE)

The user corrects the assignment (J-302: drag a note to another part, delete a
note, split a note). **THE HEURISTIC TRACK IS NEVER MUTATED IN PLACE.** The
engine's `notes/<PART>.json` stays exactly as the engine wrote it — that file is
the **truth about what the engine heard**, and it stays reproducible. The user's
corrections live in a **SEPARATE, ADDITIVE** overlay that the consumer applies
AT GRADING TIME (D-41 §4: the overlay wins).

The overlay is stored **beside** the bundle's notes, in the bundle directory, as
`corrections/<PART>.json` (one file per corrected part; a part with no
corrections has NO file — absence means "no corrections", never "unknown").

```json
{
  "contractVersion": "v1.1",
  "part": "T2",
  "engineVersion": "corrections-0.1.0",
  "operations": [
    { "op": "reassign", "fromPart": "T2", "toPart": "T1",
      "noteIndex": 3, "midi": 62 },
    { "op": "delete", "fromPart": "T2", "noteIndex": 7 },
    { "op": "split", "fromPart": "T2", "noteIndex": 9,
      "splitAt_s": 2.5, "toParts": ["T1", "T2"] }
  ]
}
```

**Field rules:**
- `contractVersion` — `"v1.1"`.
- `part` — the C-1 rawValue of the part this overlay describes.
- `engineVersion` (OPTIONAL) — the writer of the overlay (Jess's UI); ABSENT ⇒
  `"unknown"`, and the consumer MUST NOT refuse the file.
- `operations[]` — an ordered list. **The order is the application order**, and
  it MUST be applied in order.
- `op` — one of the three exact strings `"reassign"`, `"delete"`, `"split"`.
- `noteIndex` — the index of the target note **in the engine's original
  `notes[]` array for `fromPart`** (0-based, the order the engine wrote). This
  is deliberately an index into the IMMUTABLE engine array, so an overlay stays
  meaningful even as the consumer re-derives the track.
- `reassign` — `toPart` (C-1 rawValue) and, OPTIONALLY, `midi` (the corrected
  pitch). A reassign moves the note; it does not duplicate it.
- `delete` — removes the note from the corrected track.
- `split` — `splitAt_s` (a time strictly inside the note) and `toParts` (2
  parts). The note becomes two notes in the named parts, each keeping the
  original note's `confidence` unless the operation overrides it.
  **v1.1.1 clarification (D-47 §5):** `toParts` names **exactly two** C-1 parts and is
  **ORDERED — the first half goes to `toParts[0]`, the second to `toParts[1]`**;
  `splitAt_s` MUST be **strictly inside** the note (`start_s < splitAt_s < end_s`), and a
  split outside the note is a **CONTRACT VIOLATION that is REPORTED, never silently
  clamped**; the operation MAY carry an **OPTIONAL `confidence`** (float, [0,1]) that
  overrides **both** halves' confidence — ABSENT ⇒ both halves keep the original note's
  confidence.

**Rules:**
1. **The overlay is separate and additive; the heuristic track is NEVER mutated
   in place.** A consumer MUST NOT write back to `notes/<PART>.json`.
2. **Overlay wins at grading time** (D-41 §4): the corrected track is the
   grading reference when the overlay is present.
3. **The overlay is OPTIONAL.** **ABSENT ⇒ the consumer MUST behave exactly as
   it does today** (the heuristic track is the reference). An overlay file that
   fails its own rules MUST be reported as a problem, not silently applied.
4. **A correction does not erase the engine's doubt.** A corrected note keeps
   the engine's `confidence` unless the operation overrides it, and the UI must
   still be able to show that this note was **user-corrected** (not
   engine-confirmed). The overlay file records the correction; the consumer
   reports it.

---

## C-12 · Optional salience field — NEW v1.1 (L-301, P-302, ADDITIVE)

**The salience field is defined in C-10.0 (per note). This section fixes its
consumer rule, which is the whole point of making it optional.**

- `salience` (OPTIONAL, per note, [0,1]) — P-302's per-note salience: how
  strongly the multi-f0 posterior supported that note.
- **ABSENT ⇒ the consumer MUST behave EXACTLY as it does today.** No salience
  filtering, no salience weighting, no salience-driven rendering, no
  salience-driven grading change. A consumer written before salience existed
  MUST work unchanged on a file that carries it.
- **PRESENT ⇒** the consumer MAY use it, and if it does, it MUST NOT change
  which notes are graded (D-41's bands govern grading, not salience) and MUST
  NOT hide a note that salience alone would drop (the honesty rail — AGENTS
  §11). **Salience is a DISPLAY/ANALYSIS hint, never a silent filter.**

---

## C-13 · Score-note list + alignment metadata — NEW v1.1 (L-301, D-40 §4, ADDITIVE)

D-40 rules that the MusicXML parser outputs the contract's **score-note list**.
This section fixes that shape. **The score is OPTIONAL end-to-end** — every
artifact here is OPTIONAL, and absent ⇒ heuristic-only, the import still
succeeds, and the UI says why.

### C-13.1 · The score-note list

Produced by the ONE parser (D-40: Foundation `XMLParser`, in the portable engine
core) and consumed by P-304's alignment and by J-304's review UI.

```json
{
  "contractVersion": "v1.1",
  "scoreNotes": [
    { "midi": 60, "start_s": 0.000, "end_s": 0.500,
      "measure": 1, "part_id": "P1", "voice": 1 }
  ]
}
```

- `midi` — int, equal-tempered MIDI (A440, C4 = 60).
- `start_s`, `end_s` — seconds **at the score's own tempo, BEFORE any alignment
  to audio** (D-40 §4). `start_s < end_s`.
- `measure` — int ≥ 1 (the measure index within the score).
- `part_id` — the score's own part identifier (e.g. `"P1"`), NOT a C-1 `Part`
  rawValue: the score does not know our part naming. The mapping from
  `part_id` to a C-1 part is the alignment's business.
- `voice` — int ≥ 1 (the voice within the part).

### C-13.2 · Score-alignment result metadata

```json
{
  "contractVersion": "v1.1",
  "alignment": {
    "confidence": 0.82,
    "used": true,
    "barMap": [
      { "measure": 1, "start_s": 0.0, "end_s": 2.0 }
    ],
    "method": "DTW",
    "partMapping": { "P1": "T1", "P2": "T2", "P5": "BASS" }
  }
}
```

- `confidence` — float [0,1]. **D-41 §4's threshold: the score-informed track
  is used ONLY IF `confidence >= 0.70` AND it improved note agreement.**
- `used` — bool: whether this alignment was actually applied to the graded
  track. **A consumer MUST NOT assume `used == true`** — read it.
- `barMap[]` — `{measure, start_s, end_s}` per measure; this is the **bar map**
  that turns D-41 §2's phrases from fixed 4.0 s spans into **bar-aligned**
  spans when a score is present.
- `method` — free string (e.g. `"DTW"`); ABSENT ⇒ `"unknown"`.
- `partMapping` (OPTIONAL, **NEW v1.1.1 — D-47 §8**) — the **score `part_id` →
  C-1 `Part` rawValue** map (e.g. `{"P1":"T1","P2":"T2","P5":"BASS"}`). The keys are
  the score's own `part_id` values (C-13.1); **the values are C-1 rawValues, which are
  stable forever (§C-1)**. **ABSENT ⇒ no score note is placed into any part** — the
  honest "unmapped" state; a score part with no mapping is placed **in time** but enters
  **no** part's track. **A consumer MUST NOT invent, infer or guess a mapping** (guessing
  a part is exactly what C-13/D-41 forbid), and the mapping MUST NOT be applied to a
  `part_id` that is absent from this object.

**Rules:**
1. **Everything here is OPTIONAL.** Absent ⇒ heuristic-only; the import
   succeeds; the UI states that no score was used and why (D-40 §3).
2. **The parser NEVER aligns by itself** (D-40 §5) — parsing and alignment are
   separate steps, and only alignment produces C-13.2.
3. **A score-informed track NEVER replaces the heuristic track on disk.** The
   score-informed result is derived; the engine's own track stays reproducible.
4. **v1.1.1 (D-47 §9): "it improved note agreement" means STRICTLY BETTER — `after >
   before`**, where `before` is the RAW score's agreement with the detected notes and
   `after` is the ALIGNED score's. "Not worse" (`after >= before`) is **NOT** the
   contract: it would let a score with **zero** agreement (`before = after = 0`) be
   adopted whenever the alignment reports confidence ≥ 0.70. **A consequence, stated
   plainly:** a score that ALREADY matches the recording exactly is **not** adopted as the
   grading reference (the alignment improved nothing ⇒ the heuristic track stays), and in
   that case the UI **MUST say so**. **(v1.2 AMENDED by D-58/C-17: the strict rule
   remains the IMPROVEMENT branch and is now joined by a CORROBORATION branch — a
   score that already matches at ≥ 0.90 IS adopted. The pinned `Agreement` metric and
   the exact gate live in C-17; the sentence above stays on file as the v1.1.1
   reading it superseded. D-47 is not edited.)**

---

## C-14 · Grading input order — NEW v1.1 (L-301, D-41 §4, ADDITIVE)

C-5 froze the grading INPUTS and deferred the formulas to v1.2 (L-401). This
section fixes **which track is the grading reference** — the one ordering fact
both lanes must agree on. **No formula changes here.**

**The grading reference is chosen in this order, and the FIRST match wins:**

1. **The correction overlay** (C-11), if present — the overlay is
   **authoritative**.
2. **Else the score-informed track**, if an alignment (C-13.2) succeeded with
   `confidence >= 0.70` **AND** it improved note agreement.
3. **Else the heuristic track** (C-2.3 / C-10.0).

**In case 3 the UI MUST say the assignment is heuristic and MUST report the
CONFIRMED / PROVISIONAL / UNASSIGNED split** (D-41 §4). A consumer MUST NOT
present a heuristic assignment as a confirmed one (AGENTS §11 — the honesty
rail).

**Also fixed by D-41, and binding on the grader:**
- Notes with band **UNASSIGNED** are **excluded from grading by default**;
  the user can force-assign them (J-302) and then they grade.
- **UNISON notes keep their own per-part confidence, and grading stays
  per-part** — a unison never double-counts one singer.
- **ABSENT parts are DIMMED, never hidden** (D-41 §2).

**Acks:** PAUL + JESS — ack C-10…C-14 in your next LOG line (L-006/L-102
precedent). If a lane does not answer, this is **RATIFIED by the arbiter**
(L-006 precedent) and the ack is recorded as OUTSTANDING — the milestone does
not stall for it.

---

## C-15 · Per-song calibration + display overlay — NEW v1.1.1 (D-47 §2–§4, ADDITIVE)

C-11 covers **NOTE OPERATIONS** against the engine's notes. The user's **part
RENAMES** and **per-song RANGE OVERRIDES** are not note operations, and they are
**per-song** (a rename would be duplicated in five per-part files), so they live in
their own file **beside** C-11's per-part files, in the bundle directory.

```json
{
  "contractVersion": "v1.1",
  "engineVersion": "corrections-0.1.0",
  "partRenames": { "T1": "Tenor 1", "BARITENOR": "Bari" },
  "rangeOverrides": {
    "T1": { "preset": "E2–G3" },
    "BASS": { "custom": { "minMidi": 40, "maxMidi": 60 } }
  }
}
```

- `contractVersion` — `"v1.1"` (the on-disk string is the v1.1 family; D-47 §10).
- `engineVersion` (OPTIONAL) — the writer of the overlay; ABSENT ⇒ `"unknown"`, and the
  consumer MUST NOT refuse the file.
- `partRenames` (OPTIONAL) — a map from a **C-1 `Part` rawValue** to a display string.
  **The C-1 raw values NEVER change — a rename is a DISPLAY layer only.**
- `rangeOverrides` (OPTIONAL) — a map from a **C-1 `Part` rawValue** to exactly ONE of
  the two range shapes below (the two are **mutually exclusive** within one entry):
  - `{ "preset": "<C-6.1 range label>" }` — e.g. `"E2–G3"`. **The label is
    DISPLAY-ONLY and the AUTHORITATIVE BOUNDS COME FROM C-6.1's ROW FOR THAT PART,
    LOOKED UP BY THE C-1 rawValue KEY** — never from the stored string. **A `preset`
    string that is unknown, stale or spelled differently (e.g. `"TENOR_1"`) is NOT a
    contract violation and NOT an error**: the bounds still come from the table and the
    consumer MUST NOT reject the file over it. **There is no second preset vocabulary**
    (C-6.1 is the single source of truth).
  - `{ "custom": { "minMidi": 40, "maxMidi": 60 } }` — both ints, `minMidi <= maxMidi`,
    both clamped into **V9's 24…96**.

**Rules:**
1. **THE FILE IS OPTIONAL.** **ABSENT ⇒ no renames and no range overrides ⇒ the consumer
   behaves EXACTLY as it does today** (the same binding absence rule as C-10/C-11/C-12).
   An empty `partRenames`/`rangeOverrides` ⇒ the same.
2. **THE ±2 SEMITONE NUDGE IS NOT HERE.** C-6.1 fixes the per-part nudge (−2…+2) and the
   mic-profile offset as **device-local, "never in the bundle"**. The per-song file
   therefore carries the **RANGE** only. **A WRITER MUST NOT write `nudgeSemitones` into
   this file; a READER that meets it MUST ignore it** (never a validation error, never a
   reason to quarantine the file). The device-local nudge is applied **on top of** the
   effective range, exactly as C-6.1 describes ("applied to the preset before use").
3. **A RANGE IS A FILTER, NOT A GATE** (C-6.1): a note outside the effective range is
   still shown and still graded, with the honest deviation marked (D-12 honesty rule).
4. **THIS FILE NEVER MUTATES ANYTHING ELSE.** It MUST NOT touch `notes/<PART>.json`
   (C-11 rule 1) and MUST NOT touch `song.json`'s frozen v1.0 fields (C-2.1).

---

## C-16 · Score-edit overlay — NEW v1.1.1 (D-47 §7, ADDITIVE)

A manual **time nudge of a SCORE note** has no home in C-11: C-11's ops address the
**engine's** notes by index, and the score is a **different artifact in a different
coordinate space**. Mixing the two index spaces into one file would make them
ambiguous, so the score's edits live in their own file, beside C-11's and C-15's.

```json
{
  "contractVersion": "v1.1",
  "scoreEdits": [ { "scoreIndex": 12, "offset_s": -0.025 } ]
}
```

- `contractVersion` — `"v1.1"` (the on-disk string is the v1.1 family; D-47 §10).
- `scoreEdits[]` — an ordered list of the user's score-note time offsets:
  - `scoreIndex` — the index of the target note in **C-13.1's `scoreNotes` array**.
  - `offset_s` — an **additive** offset in seconds (may be negative).

**Rules:**
1. **THE FILE IS OPTIONAL.** **ABSENT ⇒ no nudges ⇒ the consumer behaves EXACTLY as it
   does today** (same binding absence rule).
2. **IT MOVES THE SCORE'S TIMES, NEVER THE ENGINE'S NOTES.** The engine's
   `notes/<PART>.json` is immutable (C-11 rule 1) and the score-informed track stays
   **derived** (C-13 rule 3) — a nudge never writes either of them.
3. **IT IS NOT A C-11 OP.** There is deliberately no `nudge` op in C-11: the engine's
   note index and the score's note index are different spaces and MUST NOT be mixed.
4. **A MISSING TARGET IS REPORTED, NEVER CLAMPED** (same posture as C-11's split): a
   `scoreIndex` that does not exist in the score-note list is skipped and reported.

---

## C-17 · The C-14 adoption gate — v1.2 AMENDMENT (D-58, ADDITIVE)

**Why this exists (the measured finding):** P-304 landed with the v1.1.1 strict
rule implemented exactly, and the implementation **measured** its consequence on
the committed fixture: the raw 96 BPM score already agrees with the detected
notes at the contract metric (`before = after = 1.000000`), so the score is
**refused** — even though the score-informed track is measurably BETTER where it
matters for grading (688/688 frames correct vs the heuristic's 672/688; it fixes
exactly the 16 transition frames) and its bar map errs by 7.0 ms. The v1.1.1
rule conflated "**did not degrade**" with "**improved nothing observable at this
metric's granularity**" and over-refuses the case where the score is MOST
trustworthy: near-unanimous corroboration of the engine's own hearing.

**The pinned metric (was implementation-owned until v1.2 — now contractual):**
`Agreement` between a score-note list and the detected tracks:

- A **match** is: same `midi` (integer equality — **no octave fold**) AND the
  two intervals overlap once **both** are extended by `tolerance_s`
  (default **0.25** s; `scoreStart − tol < detectedEnd && detectedStart − tol <
  scoreEnd`).
- Matching is **one-to-one** (an index may be claimed once per side).
- **`ratio = (matchedScoreNotes + matchedDetectedNotes) / (scoreNoteCount +
  detectedNoteCount)`** — a two-sided Dice. **0 when there is nothing to
  compare** (either side empty).
- `before` = the RAW score's agreement with the detected notes; `after` = the
  ALIGNED score's.

**The v1.2 gate (supersedes the v1.1.1 rule 4 consequence BY REFERENCE — the
improvement branch is unchanged):**

```
used = (confidence >= 0.70)  AND  (after >= before)  AND
       (after > before  OR  after >= 0.90)
```

- **The IMPROVEMENT branch (`after > before`)** is D-47 §9's rule, unchanged and
  still sufficient alone. It covers "the alignment fixed something measurable".
- **The CORROBORATION branch (`after >= 0.90`, NEW)** covers "the score already
  matches the engine's hearing near-unanimously at the pinned metric". The
  score is consistent evidence; refusing it would discard its real grading
  value (exact times, `partMapping`, the bar map) exactly when it is most
  trustworthy. **0.90 is a ruling, not a derivation** — adoption replaces the
  grading reference wholesale, and wholesale replacement requires
  near-unanimous corroboration. Lowering it is a future ruling with evidence.
- **`after >= before` (never degrades) applies to BOTH branches:** an alignment
  that made the agreement WORSE than the raw score is never adopted, at any
  absolute level.
- **The zero-agreement refusal is preserved:** `after = 0` passes neither
  branch — D-47 §9's degenerate case (`before = after = 0`) stays refused.
- **On refusal the UI MUST say so, with the reason** (confidence short of the
  gate, degraded agreement, or no improvement AND corroboration short of 0.90).

**What this gate deliberately does NOT see:** the frame-level part-assignment
delta (e.g. 688/688 vs 672/688). It stays a **REPORTED** metric (ENGINE.md,
BENCHMARKS), never a gate input — a gate must be recomputable by any consumer
from the C-13.2 JSON alone, and coupling adoption to the assignment engine
would make it neither cheap nor portable.

**Ack duty:** PAUL implements the corroboration branch (P-404: `used =
confidence ≥ 0.70 AND after ≥ before AND (after > before OR after ≥ 0.90)` with
tests pinning both branches and the refusal case). JESS reads `used` — she MUST
NOT re-derive the gate. D-47 stays on file, unedited.

## C-18 · `SessionResult` — NEW v1.2 (D-58 + D-54, ADDITIVE)

C-5 froze the grading IO and deferred the schema to v1.2. This is that schema —
**JSON shapes, not Swift type names** (D-52's rule: the contract pins the wire
format; each lane owns its types). `SessionResult` is **LOCAL-ONLY** (AGENTS
§0): it lives in J-404's GRDB history (schema = Jess's lane, D-55) and is the
shape of the user-triggered session-JSON export. **It never leaves the device
except through that explicit export.**

```json
{
  "contractVersion": "v1.2",
  "sessionId": "6f0e2b1a-…",
  "bundleId": "sweet-hour-of-prayer-…",
  "part": "BASS",
  "createdAt": "2026-11-27T12:00:00Z",
  "duration_s": 132.4,
  "gradingReference": { "source": "heuristic", "alignmentConfidence": null },
  "config": { "…C-19 GradingConfig, embedded by value…" },
  "latencyOffset_ms": 0,
  "tuningCents": 32,
  "transpositionSemitones": 0,
  "tempoScale": 1.0,
  "perNote": [
    { "noteIndex": 0, "hit": true, "centsDeviation": 8.0, "coverage": 0.93,
      "sustain_ms": 410, "confidenceBand": "CONFIRMED", "unison": false,
      "transitional": false, "notAssessable": false, "notAssessableReason": null }
  ],
  "perPhrase": [ { "phraseIndex": 0, "score": 0.87 } ],
  "accuracy": { "overall": 0.88, "steady": 0.92, "transition": 0.41 },
  "notAssessable": { "total": 3, "byReason": { "unassigned": 3, "noLiveFrames": 0 } },
  "grade": "B",
  "engineVersion": "grading-0.1.0"
}
```

**Field rules (every field OPTIONAL except `sessionId`, `bundleId`, `part`,
`createdAt`; absent ⇒ the consumer behaves as before v1.2 — the binding absence
rule):**

- **`perNote[]`** — one entry per GRADED reference note, ordered by `noteIndex`
  (the index into the grading-reference `notes[]`):
  - `{centsDeviation, coverage, sustain, hit}` — **C-5's four outputs, names
    FROZEN as written there** (`centsDeviation` = signed cents, live minus
    reference; `coverage` ∈ [0,1]; `sustain_ms` ≥ 0; `hit` bool).
  - `confidenceBand` — the reference note's C-10 band
    (`CONFIRMED`/`PROVISIONAL`/`UNASSIGNED`) or absent for a v0.0-era track.
    **D-54 §2: the band is REPORTED here, and NEVER a scoring weight.**
  - `unison` — the reference note's C-10 flag (D-54 §3: per-part grading, no
    math change).
  - `transitional` — **D-54 §4's class**: `true` when this note starts within
    **50 ms** after the preceding note of the SAME part ends, else `false`
    (the first note of a part is `false`).
  - `notAssessable` / `notAssessableReason` — when `true` the note contributed
    NO score: `reason` is one of the exact strings `"unassigned"` (C-14's
    excluded band) or `"noLiveFrames"` (no live pitch frames covered the note).
    **The exclusion is VISIBLE, never silent (D-54 §1).**
- **`accuracy`** — `{overall, steady, transition}`, each ∈ [0,1] or `null` when
  that class has no members. **BOTH classes are reported whenever an accuracy
  number is published (D-54 §4) — the lower one is the honest one.** Every M4
  accuracy number is **synthetic until real fixtures land, labelled synthetic
  where it appears (D-54 §5)**.
- **`notAssessable`** — `{total, byReason{unassigned, noLiveFrames}}`; counts
  agree with the `perNote` flags.
- **`gradingReference.source`** — one of `"correctionOverlay"`,
  `"scoreInformed"`, `"heuristic"` (C-14's order, first match wins). The UI
  MUST state which reference graded the session (C-14 §case-3 duty).
- **`latencyOffset_ms` / `tuningCents` / `transpositionSemitones` /
  `tempoScale`** — the session's C-20 environment, recorded so any grade is
  **reproducible** (same inputs + config + environment ⇒ byte-identical
  result — J-401's determinism AC).
- **`grade`** — one of `"A"`, `"B"`, `"C"`, `"D"`, `"F"` (exact strings; no
  `"E"`). The letter is the UI band over `accuracy.overall` (and `perPhrase`);
  the bands' thresholds are Jess's implementation (configurable weights are in
  C-19), with the J-401 property test (closer pitch ⇒ higher score) as the
  standing invariant.
- **`config`** — the C-19 `GradingConfig` **by value**: the session must record
  what it was graded against, or a later config change rewrites history.

## C-19 · `GradingConfig` — NEW v1.2 (D-58 + D-54, ADDITIVE)

The user-tunable grading configuration (J-405). **"The settings must not be
able to make the scoring dishonest"** — so every tunable is bounded, and the
bounds are contractual:

```json
{
  "contractVersion": "v1.2",
  "toleranceCents": 50,
  "octaveEquivalence": true,
  "onsetGrace_ms": 100,
  "vibratoExtentCents": 50,
  "breathGate_db": -60.0,
  "weights": { "pitch": 0.5, "timing": 0.3, "sustain": 0.2 },
  "goldenNoteBonus": 1.1,
  "guideLevel": "ribbon+notes",
  "countIn_beats": 4,
  "metronome": false
}
```

- **`toleranceCents`** — int, **[10, 50]** (the D-22 ±50 default; the ±25/±10
  presets are the canonical stops). A value outside the range is CLAMPED for
  grading and reported as clamped — the UI cannot widen the tolerance past the
  loosest preset, because a tolerance that grades every off note a hit is a
  dishonest grade (D-12 honesty).
- **`octaveEquivalence`** — bool, default **true** (C-5): a pitch an exact
  octave from the reference folds to it (equivalence classes, not tolerance
  widening — fold THEN measure cents).
- **`onsetGrace_ms`** — int, **[80, 120]**, default 100 (C-5's 80–120 band):
  pitch deviation in the first `onsetGrace_ms` of a note is not scored against
  `centsDeviation` (the sung glide through a note boundary is physiology, not
  error).
- **`vibratoExtentCents`** — int, **[10, 100]**, default 50: vibrato is
  measured MEAN-CENTERED (D-12/D-41's dettato lineage) — the note's mean pitch
  is the reference for its deviation; the extent is the accepted ± swing.
- **`breathGate_db`** — float, **[-90.0, -30.0]**, default **-60.0**: frames
  below this `loudness_db` are UNVOICED for grading (C-2.4's loudness) — a
  breath is silence, not a sung pitch.
- **`weights`** — the three named components `pitch`/`timing`/`sustain`, each
  ∈ [0,1], **summing to 1.0 ± 0.001**; a config that does not sum is rejected
  (never silently normalized — a silently rewritten config is a lie about what
  graded the session).
- **`goldenNoteBonus`** — float, **[1.0, 1.5]**, default 1.1: the multiplier on
  a golden note's contribution (C-4: UltraStar `*` notes).
- **`guideLevel`** — one of the exact strings `"ribbon+notes"`, `"ribbon"`,
  `"notes"`, `"none"` (how much help the session shows; a UI concern with a
  contractual vocabulary so a session's difficulty is comparable).
- **`countIn_beats`** — int, **[0, 8]**, default 4. **`metronome`** — bool,
  default false.
- **Defaults are FIXED by this contract** (the C-5 v0.0 defaults where one was
  already fixed); `ABSENT ⇒ the default applies` for every field (a v1.2
  config file may carry a subset).
- **`GradingConfig` is DEVICE-LOCAL user data** (like C-6.1's calibration and
  C-15's nudge rule): it is never written into a SongBundle and never
  changes a bundle file. `SessionResult.config` records a COPY.

## C-20 · Transposition & tempo mapping + the latency offset — NEW v1.2 (D-58, ADDITIVE)

P-402 shifts the reference playback (key via `AVAudioUnitTimePitch` pitch,
tempo via its rate — pitch-preserved) and J-403 calibrates the live-path
latency. Grading must stay aligned through BOTH. This section fixes the
mapping; **P-402 implements it; J-401/J-402 consume it.**

1. **THE TRANSFORM IS A VIEW, NEVER A REWRITE.** The bundle's files
   (`notes/<PART>.json`, `corrections/<PART>.json`, `corrections/score.json`,
   `song.json`) are NEVER mutated by a key/tempo shift. The transform applies
   AT LOAD to the **composed grading reference** (the C-14 pipeline's output),
   uniformly:
   - `midi' = midi + transpositionSemitones` (int; the reference's MIDI moves
     with the key shift).
   - `t' = start + (t − start) / tempoScale` for every time `t` in
     `[start, start + duration/tempoScale]` — the whole composed reference
     (note times AND phrase/bar spans) scales about the session start by the
     SAME factor. (`tempoScale` = the playback speed factor; 1.0 = unchanged;
     a 1.25× tempo renders a 4.0 s phrase as 3.2 s.)
2. **THE OVERLAY TRANSFORMS IDENTICALLY TO THE TRACK IT CORRECTS.** C-11's ops
   address the engine's `notes[]` by INDEX (unchanged by transposition — the
   transform never adds, removes or reorders notes), and its time-carrying
   fields (`splitAt_s`) and C-16's `offset_s` are expressed in **untransposed
   bundle time** and are mapped by the SAME transform as the note times they
   address. A corrected split stays corrected under any key/tempo; an overlay
   file on disk never changes.
3. **`tuningCents` IS PRESERVED UNDER TRANSPOSITION.** A semitone shift adds
   exactly `100·n` cents to the reference; the recording's deviation from
   equal temperament is invariant under it. **The reference pitch for grading
   is: `cents(midi') + tuningCents`** — D-22's rule (the grader offsets the
   REFERENCE, never the stored audio) composed with the shift. A faithful
   singer of a +32c recording shifted +2 semitones is still graded against
   +32c, not against A440. (A ±50c-clamped `tuningCents` and the J-205 user
   override compose BEFORE this point; `SessionResult.tuningCents` records
   the resolved value.)
4. **THE LATENCY OFFSET — sign convention (pinned):** `latencyOffset_ms ≥ 0`
   means **the live path is LATE by that much** (output → air → mic →
   processing). The grader compares the live frame captured at `t` against the
   reference at **`t − latencyOffset_ms`** (per C-18 the applied value is
   recorded per session). **Its HOME is device-local** (J-403's calibration +
   slider, per device — the C-6.1/C-15 device-local precedent): it is NEVER
   written into a bundle, and C-18 records only the value APPLIED.
5. **RANGES:** `transpositionSemitones` int **[−12, +12]**; `tempoScale` float
   **[0.5, 2.0]**. A shift outside the range is refused by the UI, never
   clamped into silent wrongness (a clamped key change would re-grade against
   a key the user did not hear).

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
| **v1.0.2** | 2026-11-23 | **RATIFIED (L-204, D-35 — CLARIFICATION, no signature changed):** C-9 gains **rule 5 (M2 flow rule)** — because the C-3 flow is `importAudio` → `separate`, the PUBLISH happens inside that flow: by the time `separate` returns, a conforming M2 engine MUST have published a complete bundle (C-2.2 `song.json` marker) and MUST have set `importedBundleID`. C-3 gains an M2 real-engine note (the app-target facade over C-8 + C-9; concrete class/init fixed in DECISIONS D-35 + QUEUE X-211). Found by reading both implementations: Jess's flow requires the published bundle; Paul's C-3 `separate` returned raw stems without publishing ⇒ the real-engine import would have failed the app's own completeness check at the device demo. NO signature changed; no rule re-opened. **SUPERSEDED IN PART by v1.0.3 (D-36): rule 5's call-shape wording is withdrawn (the finding stands), and the facade is not the ratified shape.** | Leto |
| **v1.0.3** | 2026-11-23 | **RATIFIED (L-204, D-36 — ADDITIVE, no signature changed):** NEW **C-9.1 (the M2 whole-import entry point)** — the M2 bundle-producing engine exposes `importSong(source:title:) -> ImportOutcome`, ONE call that owns decode → separate → assemble → atomic publish (all-or-nothing per C-8); the app drives an engine that has it through that call and an engine that does not (the mock) with the frozen C-3 pair. **C-9 rule 5 is RESTATED shape-agnostically: the contract requires the OUTCOME (the flow ends with a complete published bundle + `importedBundleID` set), not a particular call shape.** Rationale: the manifest needs the decode stage's facts (source hash, duration), so splitting decode from publish forces a second decode/hash and splits C-8's no-residue guarantee across two calls with the app in between. Jess's rewritten binding (probe-v5, build-ipa SUCCESS with the real classes) already implements exactly this and is the ratified shape. NO new Swift protocol required; no EngineAPI signature changed. | Leto |
| **v1.1** | 2026-11-24 | **RATIFIED (L-301 — the M3 ADDITIVE delta; v1.0.3 semantics UNCHANGED, every v1.0.3 field and validator still valid):** NEW **C-10 (NoteTrack v1.1 metadata)** — per-note `unison` (D-41 §3), `salience` (P-302, OPTIONAL), `assignmentBand` (D-41 §1, three exact strings), per-phrase `partPresence` (D-41 §2, 4.0 s spans or bar-aligned), `assignmentSummary`, and a per-track `engineVersion` (C-10.2 — additional to the manifest's, never replacing it); **NEW V16/V17/V18** (v1.1 note fields; presence consistency; band/presence coherence — **a mismatch is a CONTRACT VIOLATION, not silently repaired**). NEW **C-11 (correction overlay)** — a SEPARATE additive file `corrections/<PART>.json` with ordered `reassign`/`delete`/`split` operations against the engine's immutable `notes[]` indices; **the heuristic track is NEVER mutated in place**, and the overlay wins at grading time (D-41 §4). NEW **C-12 (optional salience)** — absent ⇒ the consumer behaves EXACTLY as it does today; present ⇒ a DISPLAY/ANALYSIS hint, never a silent filter and never a change to what is graded. NEW **C-13 (score-note list + alignment metadata)** — the D-40 §4 list `{midi, start_s, end_s, measure, part_id, voice}` (times at the score's own tempo, BEFORE alignment) + alignment `{confidence, used, barMap, method}`; the score is OPTIONAL end-to-end and the parser NEVER aligns by itself. NEW **C-14 (grading input order)** — correction overlay → else score-informed (alignment confidence ≥ **0.70** AND agreement improved) → else heuristic (and the UI must say "heuristic" + report the CONFIRMED/PROVISIONAL/UNASSIGNED split); UNASSIGNED excluded from grading by default; unison grades per-part; absent parts DIMMED, never hidden. **C-2.3's `confidence` field is NOT redefined** — v1.1 adds `assignmentBand` beside it. **The ABSENCE RULE is binding: every new field is OPTIONAL, and absent ⇒ behave exactly as before v1.1.** | Leto |
| **v1.1.1** | 2026-11-25 | **RATIFIED (D-47 — ADDITIVE ONLY over v1.1; v1.1 is NOT re-opened, every v1.1 clause, every v1.0.3 field and V1–V18 stay as they are):** NEW **C-15 (per-song calibration + display overlay)** — the file `corrections/song.json` beside C-11's per-part files: OPTIONAL `partRenames` (C-1 rawValue → display string) + OPTIONAL `rangeOverrides` (C-1 rawValue → `{preset}` where the **label is display-only and the bounds come from C-6.1 by part key** — **there is no second preset vocabulary** — or `{custom:{minMidi,maxMidi}}` clamped into 24…96); **the ±2 semitone nudge stays DEVICE-LOCAL (C-6.1 unchanged) and MUST NOT be written into this file (a reader MUST ignore it)**. NEW **C-16 (score-edit overlay)** — the file `corrections/score.json`: `{scoreEdits:[{scoreIndex, offset_s}]}` shifting the **score's** times (never the engine's notes; the score-informed track stays derived); **deliberately NOT a C-11 op** (the engine's and the score's index spaces are different). C-13.2 gains the OPTIONAL `partMapping` (score `part_id` → C-1 rawValue; ABSENT ⇒ no score note enters any part; a consumer MUST NOT guess a mapping) and C-13.2 rule 4 fixes **"improved note agreement" = STRICTLY BETTER (`after > before`)**. C-11's `split` gains the OPTIONAL `confidence` override + the ordered `toParts` / strictly-inside `splitAt_s` clarification. **The on-disk `contractVersion` string stays `"v1.1"`** (the v1.1 family); the absence rule still governs every new field; nothing is breaking and no migration is owed. | Leto |
| **v1.2** | 2026-11-27 | **RATIFIED (D-58 — ADDITIVE ONLY over v1.1.1; every v1.1/v1.1.1 clause, every v1.0.3 field and V1–V18 stay as they are; the on-disk `contractVersion` string of every PRE-EXISTING file stays `"v1.1"`/`"v1.0"`; the NEW C-18/C-19 files carry `"v1.2"`):** NEW **C-17 (the C-14 adoption gate — v1.2 amendment)** — the pinned `Agreement` metric (same-MIDI integer equality, no octave fold; interval overlap with both sides extended by tolerance, default **0.25 s**; one-to-one; two-sided Dice ratio; 0 when nothing to compare) + the gate `used = confidence ≥ 0.70 AND after ≥ before AND (after > before OR after ≥ 0.90)` — D-47 §9's strict rule stays as the IMPROVEMENT branch; the NEW **CORROBORATION branch** adopts a score that already matches at ≥ 0.90 (P-304's measured finding: `before = after = 1.000000` refused a score that fixes exactly the 16 transition frames — 688/688 vs 672/688); `after ≥ before` (never degrades) binds BOTH branches; the zero-agreement refusal is preserved; the frame-level delta stays REPORTED, never a gate input. NEW **C-18 (`SessionResult`)** — the C-5-deferred grading output: per-note `{centsDeviation, coverage, sustain, hit}` (C-5's names FROZEN) + `confidenceBand`/`unison` (REPORTED, never a weight — D-54 §2/§3) + `transitional` (D-54 §4's 50 ms class) + `notAssessable`/`notAssessableReason` (`"unassigned"` | `"noLiveFrames"` — the exclusion is VISIBLE, D-54 §1) + `accuracy{overall,steady,transition}` (BOTH classes always, the lower one honest, synthetic-labelled until real fixtures) + `gradingReference.source` + the session's C-20 environment (`latencyOffset_ms`, `tuningCents`, `transpositionSemitones`, `tempoScale`) + `grade ∈ {A,B,C,D,F}` + `config` BY VALUE (determinism = J-401's AC); LOCAL-ONLY. NEW **C-19 (`GradingConfig`)** — the J-405 tunables, ALL BOUNDED: `toleranceCents [10,50]` (clamped-and-reported outside), `octaveEquivalence` (fold THEN measure), `onsetGrace_ms [80,120]`, `vibratoExtentCents [10,100]` (mean-centered), `breathGate_db [−90,−30]`, `weights{pitch,timing,sustain}` summing to 1.0 ± 0.001 (never silently normalized), `goldenNoteBonus [1.0,1.5]`, `guideLevel` four exact strings, `countIn_beats [0,8]`, `metronome`; defaults FIXED; absent ⇒ default; DEVICE-LOCAL. NEW **C-20 (transposition & tempo mapping + the latency offset)** — the transform is a VIEW, never a rewrite (bundle files never mutate; the composed C-14 reference transforms at load); `midi' = midi + transpositionSemitones`; times scale about the session start by `1/tempoScale`; **the overlay transforms IDENTICALLY to the track it corrects** (indices unchanged; `splitAt_s`/`offset_s` in untransposed bundle time mapped by the same transform); **`tuningCents` is preserved under transposition** (reference = `cents(midi') + tuningCents`; a +32c recording shifted +2 semitones grades against +32c); **latency sign pinned** (`≥ 0` = live is LATE; compare live `t` against reference `t − latencyOffset_ms`; home is DEVICE-LOCAL); ranges `transpositionSemitones [−12,+12]`, `tempoScale [0.5,2.0]` (refused outside, never clamped). | Leto |
