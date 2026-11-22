# Docs/UX.md — PitchNotes UX spec (Jess)

> **Owner:** Jess. **Version:** v0.1 (M1, J-104 — ribbon finalized as built;
> M4 session storyboard expanded; latency spec added; M1 device demo §10.1).
> v0 (M0, J-003) is the baseline. Companion docs: `AGENTS.md`,
> `PLAN.md`, `CONTRACTS.md` (schemas/engine types referenced here), `Docs/RESEARCH.md`
> (evidence pack), `Docs/CONTENT.md` (content schemas & licensing).
> **Change protocol:** edits land as `jess:` commits on branch `jess`; anything that
> touches engine-side behavior or shared types goes through an X-task first.
>
> v0 scope: (1) design tokens for the app shell, (2) the **learner ribbon spec —
> complete enough for J-101 to implement without asking questions**, (3) flow
> storyboards for M1–M5, (4) grading *display* spec (scoring formulas are M4/J-401
> and CONTRACTS v1.2), (5) accessibility matrix, (6) M0 device-demo checklist.

---

## 0. Design principles (binding for all screens)

1. **Offline-first, calm by default.** Nothing in the UI waits on a network; long
   engine jobs (import, separation) show staged progress + cancel and never block the
   main thread (AGENTS §0/§8, D-14 threading model).
2. **Honesty is a feature.** Separation of close male harmony WILL bleed
   (RESEARCH: per-part NSDR 4.05–10.50 dB; part-aware note F1 ≈ 0.225). Every
   engine-derived view shows confidence and offers correction. We say "focus mix",
   never "solo" — default attenuates others to **−12 dB**, it does not mute them.
3. **The singer's eyes stay on the ribbon.** During a session the ribbon is the
   screen; controls collapse to one row. Feedback latency budget **< 100 ms**
   (AGENTS §8) — the ribbon never renders stale frames ahead of newer ones.
4. **One-hand portrait-first.** Primary actions live in the bottom third.
   Target size ≥ 44 pt. iPad is not a v1 target (`TARGETED_DEVICE_FAMILY: 1`).
5. **Accessibility from day one** (§8 matrix): VoiceOver labels everywhere, Dynamic
   Type, WCAG AA contrast in both modes, reduced-motion fallback for the ribbon.
6. **Graceful degradation over failure states.** A missing pitch track, a low-
   confidence part, or a failed import each have a designed screen, not an error dump.

---

## 1. Design tokens v0 (consumed by J-001)

Single source: `App/Sources/Design/Token.swift` (J-001 creates it). Values here are
the contract; refine visually in M2 without re-designing structure.

### 1.1 Color (semantic; light / dark)

| Token | Light | Dark | Used for |
|---|---|---|---|
| `bg` | `#F7F7F8` | `#0E0F12` | window background |
| `surface` | `#FFFFFF` | `#1B1D22` | cards, rows |
| `surfaceElevated` | `#F0F1F4` | `#26292F` | inspector, sheets |
| `textPrimary` | `#17181C` | `#EDEEF2` | headings, lyrics (AA on bg) |
| `textSecondary` | `#5A5E6B` | `#A3A8B5` | captions, meta |
| `accent` | `#3B6FE0` | `#6E9BFF` | brand, active tab, links |
| `inTune` (success) | `#2E9E5B` | `#4CCB82` | cursor inside tolerance band |
| `flat` | `#D97E00` | `#FFA940` | cursor below target (raise ↑) |
| `sharp` | `#7A5CD0` | `#A48CF0` | cursor above target (lower ↓) |
| `octaveWarn` | `#C24343` | `#E56A6A` | octave-error badge / off-window |
| `referenceBar` | `#9AA0AC` | `#6E7480` | reference note bars |
| `toleranceBand` | `accent @ 22%` | `accent @ 30%` | band fill inside bars |
| `unvoiced` | `#8E939E @ 45%` | `#7C828E @ 45%` | unvoiced cursor/trace |
| `track` | `#E3E5EA` | `#2A2D34` | separators, progress track |

Contrast: `textPrimary`/`textSecondary` ≥ 4.5:1 on `bg`/`surface` in both modes;
`inTune`/`flat`/`sharp` are paired with arrows (↑↓) so state never relies on hue
alone (colorblind-safe + reduced-colors setting).

### 1.2 Typography

System font (SF Pro) + Dynamic Type everywhere; **no fixed sizes** — use text styles.

| Token | Text style | Use |
|---|---|---|
| `type.title` | `.largeTitle` bold | screen titles |
| `type.heading` | `.title3` semibold | section headers, part names |
| `type.body` | `.body` | rows, lyrics on reference bars |
| `type.caption` | `.caption` | meta (confidence %, time, part range) |
| `type.numeric` | `.body` + `.monospacedDigit` | cents readout, scores, BPM |

Lyrics inside ribbon bars: `.caption` semibold, clipped to one line, full text in
the lyric strip under the ribbon.

### 1.3 Spacing, shape, motion

- Spacing grid: 4 pt base; tokens `s1=4, s2=8, s3=12, s4=16, s5=24, s6=32`.
- Corner radius: cards 12, chips 8, sheets 16.
- Hit targets ≥ 44 pt (Apple HIG); chips are 36 pt tall but 44 pt tappable.
- Motion: ≤ 250 ms, `easeOut`; honor Reduce Motion (ribbon uses cross-fade, not slide).
- Haptics: `.light` on beat during count-in, `.success`/`.warning` on phrase end
  (configurable off in Settings).

---

## 2. Information architecture (app shell, J-001)

Five tabs (order fixed; raw values are UI-only, not contractual):

```
TabView
├── Learn      # M4: session launcher + recent sessions; M1: live tuner entry point
├── Library    # imported songs; bundle inspector (debug); storage management
├── Theory     # M5: key/chords of current song + glyph glossary
├── Ear        # M5: ear-training exercises (chord completion)
└── Settings   # part calibration, grading prefs, audio/latency, storage, about
```

- M0 shells are functional placeholders with VoiceOver labels and a "coming in M<n>"
  caption — no dead-end empty states.
- Navigation: `NavigationStack` per tab; Library → Song detail (M2) pushes Mixer,
  Learner, Inspector as one flow (§5.2/5.3).

---

## 3. Learner ribbon spec (implementation contract for J-101)

The ribbon is a scrolling two-axis view: **x = time (reference scrolls right→left),
y = pitch (linear in cents — semitones are evenly spaced)**. A fixed vertical
**playhead cursor** sits at 30% from the left; the live pitch trace renders at the
playhead; future notes are visible to the right (look-ahead), sung notes trail left.

### 3.1 Inputs (all from CONTRACTS v0.0)

| Input | Source | Used for |
|---|---|---|
| `NoteTrack` (C-2.3): `notes[{start_s,end_s,midi,cents_ref,confidence}]` | `notes/<PART>.json` | reference bars |
| `PitchFrames` (C-2.4): 16 ms grid `{t,hz,confidence,loudness_db}` | `pitch/<PART>.json` (optional) | pre-rendered reference trace, shaded by confidence |
| live `PitchFrame` from `livePitch(_:)` (C-3) | mic pipeline | cursor + trace, real time |
| `Part` + range presets (§3.6, X-001) | settings/calibration | y-window, part chips |
| `lyrics.lrc` (optional) | bundle | lyric strip under bars |

Ribbon NEVER reads audio files or runs the engine on the main thread; it consumes
published frame values from the engine queue (< 100 ms budget, AGENTS §8).

### 3.2 Time model & zoom

- Pixels-per-second: `pps` token, default **90 px/s** (≈ 1 s ≈ 90 px); tune once in
  `Token.swift`, never per-screen.
- Visible window: **10 s total** — 3 s history (left of playhead), 7 s look-ahead.
- Scroll: reference timeline advances so that `t_now` sits at the playhead; no user
  scrolling during a session (scrub-to-rehearse is a paused-state affordance, M4).
- Count-in beats render as vertical gridlines at the tempo from the note track's
  derived beat grid (P-402 later; M1 uses constant tempo from settings).

### 3.3 Vertical (pitch) mapping — exact rules

- Scale: **cents, linear**. One semitone = 100 ¢ = fixed pixel height `barH` = 22 px
  (token). An octave = 12·`barH`.
- **Follow window:** the view centers on the current reference note's pitch
  (`midi*100 + cents_ref`); if no current note (gap/rest), it holds the last center
  and dims. Re-centering animates ≤ 250 ms; never jumps mid-note.
- Window height: **2 octaves (±1200 ¢)** around center on an iPhone 12 Pro Max
  ribbon area (~440 px); `barH` scales down only if layout height < 480 px.
- Semitone gridlines at every 100 ¢; octave lines (C notes) are heavier and labeled
  ("C3", "C4" — scientific pitch notation, C4 = MIDI 60 = 261.63 Hz).
- Reference bar y: `midi` row, nudged by `cents_ref` (clamped ±50 ¢ per C-2.3).
  Bar height = 1 semitone; the **tolerance band** is drawn inset from the top/bottom
  (§3.4). Bar length = `end_s − start_s`. Confidence < 0.6 → bar rendered at 70%
  opacity + dashed border (honesty, §3.7).
- **Live cursor y:** `1200·log2(hz/C4_HZ)` relative to window center, exactly the
  cents math of `PitchMath.cents(from:to:)` (J-004 test). A trailing trace renders
  the last 2 s of frames, connecting gaps where unvoiced.

### 3.4 Tolerance band & deviation states

- Tolerance `tol`: default **±50 ¢**; presets ±25 / ±10 ¢ (Settings → Grading,
  M4). Band = horizontal strip of height `2·tol` centered on each reference bar.
- Deviation `dev` = live cents − reference cents (reference = `midi*100 + cents_ref`).

| State | Condition | Cursor color | Readout | Haptic/audio |
|---|---|---|---|---|
| **inTune** | `|dev| ≤ tol` | `inTune` | `E3 +12¢` | none |
| **flat** | `dev < −tol` | `flat` + ↑ arrow | `E3 −23¢` | none (no nagging) |
| **sharp** | `dev > +tol` | `sharp` + ↓ arrow | `E3 +41¢` | none |
| **unvoiced** | `hz == 0.0` or `confidence < 0.5` | `unvoiced` (45%) | hidden | gap in trace |
| **lowConfidence** | `0.5 ≤ confidence < 0.75` | state color at 70%, trace dashed | shown | — |
| **octaveError** | fold-match in-tune but `|dev ± 1200| ≤ tol` | state color + dashed outline | `E4 (8va?)` | none |

Numeric readout: `type.numeric`, top-right of ribbon, always same position (no
layout shift); arrows above/below the number indicate the correction direction
(flat → sing higher ↑, sharp → sing lower ↓). Colors never carry meaning alone.

### 3.5 Octave-equivalence toggle (default ON, Settings → Grading)

- ON: if the singer lands an exact octave away (|dev−1200| or |dev+1200| ≤ tol),
  treat as in-tune for the *cursor color* but ALWAYS show the `8va`/`8vb` badge in
  `octaveWarn` — silent folding would lie about what happened (honesty rule).
- OFF: octave deviations are plain flat/sharp states.
- The graded value is M4's business (C-5 config); the ribbon only displays the state.

### 3.6 Part selector & range presets

- Horizontal chip row above the ribbon, ordered per C-1 `sortOrder`:
  `T1 · T2 · Baritenor · Baritone · Bass` (+ `Soprano/Alto` when the manifest has
  them; `LEAD` chip when present). Chips show part display name + range
  ("Bass E2–G3").
- Selecting a part re-centers the follow window on that part's range and switches
  the reference NoteTrack/pitch track; selection is per-session, remembered per song
  (M4 settings).
- **Range presets are NOT in CONTRACTS v0.0** → filed as **X-001** (§9). Proposed
  display+search presets (MIDI, scientific name):

| Part | Proposed preset | MIDI | Hz |
|---|---|---|---|
| Bass | E2–G3 | 40–55 | 82.4–196.0 |
| Baritone | A2–D4 | 45–62 | 110.0–293.7 |
| Baritenor | C3–F4 | 48–65 | 130.8–349.2 |
| T2 | E3–A4 | 52–69 | 164.8–440.0 |
| T1 | G3–E5 | 55–76 | 196.0–659.3 |
| Soprano | C4–G5 | 60–79 | 261.6–784.0 |
| Alto | G3–D5 | 55–74 | 196.0–587.3 |

- **Calibration:** Settings → Parts → per-part ± semitone nudge (integer −2…+2,
  default 0) and mic-profile offset; stored locally, applied to the follow window
  AND passed as `fmin/fmax` to `pitchFrames(_:_:fmin:fmax:)`/`livePitch` ranges
  (hence contract-worthy → X-001).

### 3.7 Bleed-awareness affordances (binding product rule)

- **Confidence shading:** bars/trace at confidence < 0.6 are 70% opacity + dashed
  (§3.2/3.4). Never render a hard-edged "fact" from a soft signal.
- **Unison badge:** when ≥ 2 parts' reference notes overlap in time AND pitch
  (|Δcents| ≤ 100), show a chip above the ribbon: `Unison with T2 — this passage
  can't be isolated by pitch`. Tapping shows a one-line explainer (RESEARCH:
  unison is physically inseparable; NSDR 4–14 dB published).
- **Correction affordances:** in the post-session heatmap (§6.3) each note tap opens
  Note Detail: reference pitch, my mean deviation, coverage, and (J-302, M3+) an
  editable cents_ref/nudge for wrong reference notes. Wrong references are a
  first-class user state, not an error.

### 3.8 Wireframe (portrait, iPhone 12 Pro Max)

```
┌──────────────────────────────────────────────────────┐
│ ‹ Back   "Just As I Am" — Bass        ⚙  ⏸           │  nav row (collapses in session)
│ [T1] [T2] [Baritenor] [●Bass E2–G3]                  │  part chips (X-001 ranges)
│                                                      │
│  E3 ─────────────────────────────────────────────    │  octave lines labeled
│      ┌──────┐   ┌────────╌╌┐      ┌─────┐            │  reference bars (dashed = low conf)
│  C3 ─┼──────┼───┼────────┼──────┼─────┼────────    │
│      │  LY- │   │ lyric  │      │ ric │            │
│  A2 ─────────────────────────────────────────────    │
│                ┊                                     │
│                 ●───●──●──●     ← live trace         │
│ ┆c┆ ┆c┆ ┆c┆  ▲playhead                               │  count-in gridlines (M1: tempo const)
│ └────────────────────────────────────────────────────┘
│  E3 +12¢  ✓                                          │  readout (fixed position)
│  Unison with T2 — pitch can't isolate this passage ⓘ │  unison chip (when applicable)
│  just as I  ▸ am  ▸ without  ▸ one plea              │  lyric strip (lrc, optional)
│ ▶ 0:42 / 3:33   Focus mix: Bass 100% · others −12dB  │  transport + focus-mix status
└──────────────────────────────────────────────────────┘
```

M1 renders this with the SwiftF0/NanoPitch live path only (no reference bars yet);
M3+ adds bars/tracks from bundles. J-101 must keep rendering decoupled from
scheduling: frames arrive on the engine queue; drawing consumes the latest complete
frame (never queues stale frames — < 100 ms rule).

### 3.9 Ribbon as-built (v0.2, M1 — J-101 + J-105 swap; supersedes the M1 note above)

**Supersession:** M1 DOES render reference bars — the MockEngine script provides
C-2.3 NoteTracks, so bars render whenever a track exists (real bundles from M2
onward reuse the same path). The "no reference bars in M1" note in §3.8 is void.

**Two reference modes** (the §3.4 state table only means something against a
reference):

| Mode | Reference | Semantics |
|---|---|---|
| REFERENCE (default) | the active note of the part's NoteTrack at `t` (`NoteTrackQuery.currentNote`, C-2.3 `midi`+`cents_ref`) | full §3.4 table: inTune/flat/sharp + §3.5 octave badge |
| TUNER (fallback) | nearest equal-tempered semitone of the sung hz | gap/rest or no track: `|dev| ≤ 50¢` is structural — the nearest semitone re-centers, so out-of-tune flat/sharp CANNOT occur without a reference (tested: `testStandaloneTunerNeverExceedsHalfSemitoneDeviation`) |

**J-105 swap executed (2026-11-22, on main @6ddc159 base):** the C-6.0 zero-UI
contract holds — the swap touched sources and glue only; the Canvas, state
table, mapping, and a11y code are untouched.

- `RibbonFrameSource` (the C-6 seam) now has TWO conformers:
  - `MockRibbonFrameSource` — scripted MockEngine singer (unchanged).
  - `LivePitchEngineRibbonSource` — **the REAL causal source**:
    `LivePitchFacade.ribbonFrame(_:)` ONLY (engine_id `RIBBON_MPM_YIN`,
    lookahead_ms 0, D-17/D-19 Swift MPM via EngineCore `RibbonEngine`). The
    SwiftF0 176 ms `gradingSource` is NEVER a live-ribbon source (C-6.0).
- `RibbonModel.SourceMode` (`demo` | `liveMic`, default `demo`) picks the
  conformer; the selector sits next to the demo menu in the tuner controls.
  `liveMic` = TUNER semantics (no reference track — empty NoteTrack, honest
  free-singing per D-12).
- Mic chunks flow through `MicChunkProviding` (push seam, hop-aligned 16 kHz
  chunks): `MicCaptureChunkSource` (Paul's P-104 `MicCaptureEngine` — its doc
  names `facade.ribbonFrame(chunk)` as the intended body) is compiled behind
  `#if canImport(MicCapture)` and activates with ZERO code changes when Leto
  re-wires the package into the app target (X-011a; X-013 compile fixes live
  on origin/paul). Until then `SilenceMicChunkSource` feeds hop-aligned
  silence: REAL ribbon DSP cost and RTF, honest unvoiced output — never fake
  signal.
- Demo-singer menu: KEPT until X-011a lands (the M1 device demo runs before
  mic capture wires in); removal is then a one-line change recorded here.
- `PitchLogic.PartRangePresets` (interim C-6.1 table) is DELETED —
  `EngineCore.PartRangePresets` (P-105) is the single contract source;
  `PitchLogic.PartRangeChips` derives the UI rows (chip labels, C-1 order,
  follow-window center). The verbatim C-6.1 doc-value tests now pin the
  EngineCore table through the adapter (`LivePitchEngineSwapTests`).

**Implementation map** (J-101 + J-105; logic-tests cover every decision):

- `PitchLogic` (pure, tested): `RibbonMapper` (state table + octave folding +
  unvoiced gate `hz == 0 || confidence < 0.5`; low-confidence flag
  `0.5 ≤ conf < 0.75`), `PartRangeChips` (UI layer over the EngineCore C-6.1
  table), `NoteTrackQuery` (active note + window), `PitchMath`
  (cents/fold/note names), `PartDisplay`.
- `App/Features/Tuner` (render + source glue): `RibbonFrameSource` protocol +
  the two conformers above (C-6.0 swap DONE); `LivePitchEngineRibbonSource`
  (facade + `MicChunkProviding`; C-6.0 identity READ OFF FRAMES, never
  rewritten); `RibbonModel` (reference resolution, 2 s trace, follow window,
  ≤ 1 Hz VoiceOver summary, source mode). `TunerRibbonView` (Canvas; §3.8
  wireframe + source/demo menu).
- `App/Features/Audio` (J-102): `AudioSessionController` (permission/
  interruption/route glue over `MicPermissionFlow`), `MicAccessBanners`,
  `MicMeterRow`, `LatencyStubRow` (§5.8).

**As-built constants** (§3.2/§3.3 values confirmed; refine only via this doc):

- `pps` 90 px/s · playhead 30% from left · window 3 s history / 7 s look-ahead ·
  `barH` 22 px scaled by `min(22, height/24)` · trace 2 s (unvoiced = break) ·
  follow-window re-center ≈ 100 ms exponential (snap under Reduce Motion; the
  §1.3 250 ms ceiling holds) · held window dims to 85%.
- Tolerance presets ±50/±25/±10 (segmented control; default ±50, C-5).
- Colors/states exactly per §1.1/§3.4; 8va/8vb badge in `octaveWarn`, never
  color-only (arrow + words accompany).
- Part chips: C-1 display order, selected chip shows "Bass E2–G3" (C-6.1
  `displayName`); 44 pt hit targets.
- VoiceOver: ribbon exposes ONE element whose label is the spoken summary
  ("E3, 23 cents flat, sing higher" / "C4, in tune, one octave up" /
  "unvoiced") refreshed at ≤ 1 Hz with `.updatesFrequently`; the canvas plots
  are a11y-hidden (the numeric readout is the value).
- Demo-singer menu (mock scenarios: perfect/flat/sharp/octave/breathy/silent/
  late-onset/vibrato) — the M1 device demo exercises every §3.4 state without
  a human singing; KEPT while capture is unwired (X-011a pending), removed at
  that re-wiring (one-line change; J-105 keeps both sources selectable).

---

## 4. Design tokens → screens map (J-001 wiring)

| Screen family | Tokens in play | Notes |
|---|---|---|
| Shell/tabs | `bg surface accent type.title` | §2 |
| Library rows | `surface textPrimary track` | §5.2 |
| Import progress | `surface accent track` + staged rows | §5.1 |
| Mixer/focus mix | `surface accent inTune` + sliders | §5.3 |
| Ribbon | full palette + `barH pps` | §3 |
| Session results | `inTune flat sharp octaveWarn type.numeric` | §6 |
| Theory/Ear | `accent surface textPrimary` | §7 |

---

## 5. Flow storyboards (M1–M5) — so later milestones don't re-design

### 5.1 Import flow (M2, J-201/J-202) — **AS-BUILT v0.2 (J-201, 2026-11-22)**

The M0 drawing's 4-stage bar and the "Remove instruments?" toggle are both
**superseded** by CONTRACTS v1.0 (C-8) and D-9 as-built:

- **Stages fold onto C-8's THREE engine stages** (`decoding → separating →
  assembling` — rawValues frozen): the old "instrumental removal" is part of
  `separating` (two-stem demucs runs one pass), "notes & bundles" is part of
  `assembling` (ALAC + song.json). The progress screen renders
  `ImportProgress {stage, fraction, detail}` verbatim — the fraction is
  OVERALL (engine-weighted, monotonic; UI-side `ImportProgressTracker` clamps
  contract regressions and counts them, D-12 honesty).
- **The "Remove instruments?" toggle is NOT an M2 user choice.** D-9 always
  runs the two-stem path; whether an INSTRUMENTAL stem exists comes from the
  SOURCE (`hasInstrumental`, V15), not a checkbox. The setup screen carries
  ONE honest line instead: *"This song is processed on this iPhone only —
  voices and backing are separated automatically."* The M3 per-voice lanes
  arrive with the manifest (M3+), not with a M2 toggle.
- **Cancel = Task cancellation (C-8 FROZEN):** the sheet's Cancel cancels the
  Swift Task; the engine throws `CancellationError`, the staging directory
  (`<id>.tmp`, C-2.2) is removed, and the Library never shows a partial song
  (BundleStore.scan ignores `*.tmp`). UI resets to idle on the thrown error.
- **Interruption-safe:** backgrounding mid-import keeps the Task running with
  an honest hint ("import continues in background"); the scenePhase hint does
  not mutate engine behavior.
- **Accessibility:** every stage row has a combined VoiceOver label/value
  ("Separating, 43 percent, chunk 7 of 40"); dynamic type scales; the cancel
  button is a 44 pt target.
- **Recent imports** render from the bundle index (D-4 v0) newest-first;
  Library rows appear on completion via disk-truth reload (5.2 AS-BUILT).
- Seam: `ScriptedImportEngine` (paced mock, C-8-shaped) stands in for Paul's
  real engine until **P-204** — same `ProgressReportingEngine` protocol
  surface, ZERO view changes at the swap (M1 preset precedent).

Failure states (unchanged from the drawing, as shipped): unsupported file →
`.unsupportedFile`; permission denied → system prompt + retry hint; disk full
→ needed-vs-available bytes (ImportDiskBudget pre-flight); thermal → advice
banner (ImportThermalGate).

### 5.2 Library & Song detail (M2) — **AS-BUILT v0.2 (J-202, 2026-11-22)**

```
Library (disk truth first, J-202):
  rows: title · a cappella|backed chip (D-9: hasInstrumental false ⇒ "a cappella")
        · conf % chip (amber < 60% — D-12 bleed honesty) · parts chips (+ unison ×n)
          ⚠ the conf chip appears ONLY when the bundle carries note tracks:
          C-2.1 sets meanNoteConfidence to 0.0 when there are none (every M2
          two-stem bundle — note tracks arrive with M3), so an amber "conf 0%"
          on a healthy import would be a FALSE warning. Omitted, not shown.
        · imported rows: provenance line "source file · date · on-disk size"
        · demo rows (MockEngine, until P-204): "Demo: scenario" line, NOT deletable
  header: "<total> on device" (BundleStore.totalBytesOnDisk) + all-valid seal
  swipe (imported only): Delete → confirm dialog ("…and its stems are removed;
    the original file you imported is not touched") → BundleStore.delete
  empty state: "No songs yet — tap + … nothing leaves this iPhone"
  error banner: store/scan/delete failures render with [Retry] — never a silent
    empty list (D-12).
  merge order: BundleStore.scan() (C-2.2 complete-marker rule) THEN demo catalog.
Song detail (Bundle Inspector):
  song.json fields (contractVersion/engineVersion/sourceHash/confidence…)
  "Mean note confidence" reads "not yet — no note tracks in this bundle" when
    the bundle has none (same honesty rule as the row chip — never "0.00")
  Import section: source file · added at · on-disk size (per-song bytes)
  Tuning section: D-22 chip copy + override picker (Recording / Force A440 /
    Manual ±50c stepper) — persists per song in the index (J-205)
  Validation: per-file V-rules PASS/FAIL with expandable violations (disk truth)
  Parts: stem/notes/pitch paths, channels, note confidence, unison warnings
```

### 5.3 Mixer / focus mix (M2, J-203)

```
Per part: [chip] [slider 0…100%] [M] [confidence badge]
Defaults: selected part 100%, other voices −12 dB (≈ 25% slider), instrumental −12 dB
  when present; D-9: NO instrumental lane at all when hasInstrumental == false.
Presets: Focus (default) · All voices · Custom. "Focus" never hard-mutes other
  voices (bleed rule) — label it "others quieter", not "solo".
AirPlay/lock-screen playback via UIBackgroundModes [audio] (Info.plist, L-003).
```

### 5.4 Learner session (M4, J-402) — full storyboard (implementable without re-design)

**Data flow (CONTRACTS, no new interfaces):** reference `NoteTrack` (C-2.3,
optionally J-302-corrected) + live `PitchFrame`s from `gradingSource`
(P-401 aligns `lookahead_ms`) + `GradingConfig` (C-5: tolerance, octave
equivalence, onset grace 80–120 ms, breath gate on `loudness_db`) → per-note
`{centsDeviation, coverage, sustain, hit}` → phrase score → `SessionResult`
(schema CONTRACTS v1.2 / L-401). The M1 ribbon (§3.9) renders unchanged
inside the session — same components, different frame source.

**State machine** (one `SessionModel: ObservableObject`; states are a Swift
enum; every transition user-visible within 100 ms):

```
READY     sheet over song detail: part chip (C-6.1 presets) · tolerance picker
          (±50/±25/±10, default from J-405 config) · octave-equivalence toggle ·
          count-in picker (0/2/4 beats) · latency badge (§5.8: "calibrated ±N ms"
          or "uncalibrated") · [Start] · honesty caption ("focus mix, not solo;
          unison passages can't be isolated — §3.7")
COUNT-IN  metronome clicks + visual beat ring (1 beat = 1 pulse, .light haptic);
          mic input IS captured but NOT graded (frames buffered, scoring starts
          at beat 0); configurable 0 (off) → no ring, straight to ACTIVE
ACTIVE    ribbon §3.9 full-bleed, controls collapsed to ONE row (pause + guide
          level): reference bars + lyrics (lrc) scroll right→left at pps; the
          live cursor traces over them; per-note real-time hit marker — dot
          lands on the bar when the note's window closes: green (hit) /
          orange (miss, ±cents shown) / hollow (unvoiced-coverage miss);
          phone call / backgrounding → PAUSED (§ J-102 interruption path)
PAUSED    both timelines freeze; [Resume] [Restart phrase] [Quit (discard)];
          banner "graded frames held — latency unchanged"
PHRASE-END  non-modal micro-banner 2 s: phrase score + worst note ("82 · E3 −34¢");
            no navigation, ribbon keeps rolling
DONE      auto after last note + 1 s tail → Results (§6.3)
```

**Results screen (§6.3)** — grade letter + triad meters (Pitch/Rhythm/Sustain) +
per-note heatmap strip (one cell per note, colored by hit/deviation, tap →
Note Detail §6.1) + weakest-phrase list (≤ 3) + actions: [Retry weak phrases]
(queues only phrases scoring < threshold) · [Retry all] · [History] (§5.5) ·
"Latency felt early/late?" → Calibrate (§5.8).

**Components to build (M4):** `SessionLauncherView` (the READY sheet),
`SessionView` (hosts `TunerRibbonView` + transport + hit markers),
`PhraseBanner`, `ResultsView`, `HeatmapStrip`, `NoteDetailView` (§6.1),
`HistoryView` (§5.5, GRDB per D-4), `SessionModel` state machine, `ScoringEngine`
(J-401, pure Swift, logic-tests — consumes C-5 IO, emits v1.2 schema).

**Edge cases (design now, cheap in M4):** unvoiced long stretches → coverage
miss, no crash, ribbon holds (§3.3); late onsets → onset grace window from
config; vibrato → mean-centered wobble forgiven (config, J-405); octave errors
→ config-driven folding (§3.5 semantics shared with the ribbon); unison
passages → chip + softened grading expectation text (§3.7, honesty); wrong
reference notes → Note Detail correction entry (J-302) — user fixes win over
engine confidence; interruption mid-session → session preserved, resume
re-aligns time via latency offset (§5.8).

**Persistence:** session rows per D-4 (JSON v0 until GRDB in M4); config per
J-405; tolerance/octave defaults shared with the ribbon (one `GradingConfig`).

### 5.5 History (M4, J-404 — GRDB per D-4)

```
Sessions list: date · song/part · grade (A–F chip) · score · tolerance used
Song page: trend sparkline (score per session), weakest-phrase list → tap = Retry
No social features. All local.
```

### 5.6 Theory (M5, J-501/J-502)

```
Song theory page: key (Krumhansl-Schmuckler, D-5 pure Swift), chord timeline
  (clickable chord chips → chord detail), meter.
Glyph glossary (clickable, offline): treble = G clef, bass = F clef, key signature,
  time signature, accidentals (♯ ♭ ♮), ties, dots, dynamics (pp p mp mf f ff) —
  each glyph: tappable symbol card with name, what it does, one sung example.
Notation: score.musicxml rendered via OSMD/VexFlow in offline WKWebView (license
  gate via X-task before M5; D-10 minimal parser feeds it).
```

### 5.7 Ear training (M5, J-504)

```
Chord-completion drill: pick song/phrase → app plays N−1 voices (stems or
  TinySoundFont re-synth, D-6) → user sings the missing voice → live ribbon grades
  f0 vs target (±cents). Variants per RESEARCH (Functional Ear Trainer method):
  · Missing voice: any of the 5 parts
  · Octave: sing it up/down an octave (your "harmonics over/under an octave")
  · Keys: re-synthesize the phrase transposed (zero artifacts vs audio pitch-shift)
  · Tuning toggle: Equal temperament vs Just intonation (maj3 −14¢, 5th +2¢,
    dom7 −31¢) — shown on the ribbon as an alternate tolerance band
Progress: per-exercise-type streaks, no leaderboards.
Content: BarbershopTags = LINK-OUT ONLY until license verified (D-11); in-app
  content per Docs/CONTENT.md policy.
```

### 5.8 Latency compensation (M1 stub → M4 J-403)

**Why:** perceived feedback latency = mic capture + engine inference + render +
output path. AGENTS §8 budgets < 100 ms end-to-end; the compensation OFFSET
aligns the reference timeline with what the user actually heard, which matters
most on speaker mode (acoustic path) and Bluetooth headphones (variable buffer).

**M1 (J-102, shipped as a stub):** manual slider 0–300 ms in 10 ms steps
(`LatencyStubRow`, Settings disclosure + tuner), persisted locally
(`@AppStorage`), **NOT applied** — P-104 wires real capture; grading consumes
the offset from J-403. UI states the stub plainly ("Real loopback calibration
ships in M4").

**M4 (J-403) loopback calibration procedure:**

```
Settings → Audio → Calibrate latency
1. Quiet-room check: input level meter (J-102) below threshold? → proceed, else
   "find a quieter room" guidance (honest failure, not a fake number)
2. The app plays N=8 clicks (200 ms apart) through the CURRENT output route and
   records the mic simultaneously (P-104 capture path)
3. Onset detect each click on the mic signal (energy threshold on the raw tap;
   no ML); round-trip_i = t_detect_i − t_play_i
4. offset = median(round-trip) − known output buffer latency (AVAudioSession
   outputLatency + IOBufferDuration, read live per route)
5. Confidence: median absolute deviation ≤ 15 ms → AUTO-ACCEPT ("±N ms" badge);
   else → show measured value + "use anyway" / "calibrate again"; never write
   an untrusted number silently
6. Acceptance test (J-403 AC): loopback result within ±10 ms of a known delay
   fixture; re-run after route change (headphones ↔ speaker) prompts
```

**Manual slider always wins:** 0–300 ms, adjustable without calibration,
persisted per device (never in the bundle — C-6.1 calibration rule). The
session (§5.4) shows a latency badge; tapping it deep-links here.

**Consumption (grading):** `GradingConfig` carries `latencyOffsetMs`; P-401
aligns live `PitchFrame.captureTime_s` against reference note times with the
offset before coverage/hit math. The RIBBON does not shift (visual honesty —
only scoring compensates).

---


---

## 6. Grading display spec (display now; formulas M4)

Scoring formulas/weights are **deferred to CONTRACTS v1.2 (L-401, M4)** per C-5.
This section fixes what the user SEES so J-401 can target it.

### 6.1 Per-note card (heatmap tap)

`centsDeviation` (mean, signed, numeric) · `coverage` (% of note duration voiced
inside tolerance, 0–100%) · `sustain` (stability qualitative: Steady/Wobbly/Drifty)
· `hit` (Pass/Miss chip). Raw inputs shown small: my mean Hz vs target Hz.

### 6.2 Aggregation (display mapping only)

| Level | Shown as |
|---|---|
| Phrase | score 0–100 + grade letter chip; worst note linked |
| Session | **A ≥ 90, B ≥ 80, C ≥ 65, D ≥ 50, F < 50** (display thresholds; formulas M4) |
| Sub-scores | Pitch / Rhythm / Sustain triad (three small meters) |

### 6.3 Results screen (session end)

```
┌──────────────────────────────────────────┐
│ Bass · "Just As I Am" · ±50¢  A (93)     │
│ [Pitch 94] [Rhythm 95] [Sustain 90]      │
│ ┌ heatmap: per-note strip, colored by    │
│ │ hit/deviation; tap = note card §6.1 ┐  │
│ Weakest phrases: 2 → [Retry weak]       │
│ [Retry all]  [Session history]          │
│ Latency felt early/late? → Calibrate    │
└──────────────────────────────────────────┘
```

### 6.4 Customization (Settings → Grading; J-405)

tolerance (±50/±25/±10) · octave-equivalence toggle · vibrato tolerance
(mean-centered wobble forgiven) · onset grace **80–120 ms** slider · breath gate
(on `loudness_db`, C-5) · guide level (reference volume %) · count-in (0/2/4) ·
metronome on/off · haptics on/off. Defaults per CONTRACTS C-5; config persisted
M4 (JSON until GRDB per D-4).

---

## 7. Accessibility matrix (day-one binding)

| Area | VoiceOver | Dynamic Type | Other |
|---|---|---|---|
| Tabs/shell | label+hint per tab | all text styles | reduce-motion safe |
| Ribbon | **sonic + haptic equivalent**: state announced as summary ("in tune", "23 cents flat", "unvoiced") at ≤ 1 Hz cadence; bars described in Audit; the visual ribbon is optional, the audio feedback is the feature | readout uses `.body` min; ribbon pitch axis is graphic — never text | Reduce Motion: cross-fade scroll; Increase Contrast: band fill ↑ opacity |
| Import | stage-by-stage announcements via `UIAccessibility.Post` | stages wrap | progress also in VoiceOver rotor |
| Mixer | slider labels "Bass volume", value announcements | sliders scale | switch control order = part order |
| Results | heatmap read as list (not grid) | cards reflow | — |
| Ear training | exercise described fully in words before sound | — | captions for prompts |

VoiceOver + live pitch is a real use case (blind singers use tuners); the ≤ 1 Hz
spoken state cadence is the M1 minimum, refinement tracked in M4.

---

## 8. Evidence (from Docs/RESEARCH.md — do not re-derive)

- **Ribbon lineage:** Simply Sing/Smule scrolling pitch ribbon (learning UX north
  star); UltraStar/Performance note bars + grading (study-only, GPL — semantics
  adopted, zero code); Melodyne DNA / RipX = per-voice note editing north star
  (piano-roll + correction affordances §3.7/§6.1).
- **Live pitch feasibility:** SwiftF0 F1 0.781 @ 180× RT; NanoPitch causal, 20 ¢
  bins, RTF 0.1–0.3 → the < 100 ms budget is grounded, not aspirational.
- **Bleed honesty:** ACappellaSet fine-tuned HTDemucs NSDR S 4.05 / A 4.41 / T 7.91
  / B 10.50 dB; jaCappella MRDLA SI-SDR 8.7–22.1; part-aware note F1 0.225 (PawCT)
  → confidence shading, unison badges, focus mix −12 dB, note-track grading.
- **Ear training:** Functional Ear Trainer (miles.be) tonic-anchored method →
  scale-degree drills across keys (§5.7); barbershop JI offsets maj3 −14¢ /
  5th +2¢ / dom7 −31¢ (§5.7, §6 tuning toggle).
- **ACAMate workflow paper = this product's loop:** separate → custom mixes →
  visualization → feedback → iterative practice.

## 9. Open questions / X-task index (Jess → Leto)

| ID | Asks | Why UI needs it | Status |
|---|---|---|---|
| **X-001** | Ratify part vocal-range presets (§3.6 table) + per-part calibration field as CONTRACTS C-1 additive block | part chips + follow-window + engine `fmin/fmax` ranges | **RESOLVED → L-102**: C-6.1 ratified (v0.1); PitchLogic `PartRangePresets` consumed (EngineCore home at P-105) |
| **X-002** | Ratify MockEngine named scenarios (perfect / flat −30¢ / sharp +35¢ / octave error / silent / breathy / late onset / vibrato) as C-3 additive note | deterministic ribbon/grading previews (J-002) | **STRUCK (D-16)**: satisfied by P-001 `MockScenario` |
| **X-003** | Wire Paul's Engine into `project.yml` when P-001 lands: app target needs EngineAPI+MockEngine; PitchLogic needs contract Codable types WITHOUT ONNX Runtime (proposal: pure `PitchEngineContracts` target vs `PitchEngine` target) | J-002/J-004 consume; schema tests import Paul's models | **DONE (L-009 + X-006)**: EngineCore wired in project.yml; Tests/Logic path dep `../../Engine`; JSON shim deleted |
| — | Portable logic-test package | **already satisfied** (PitchLogic Package.swift, `swift test` on CI) | ✓ |
| **X-021** | ~~Add `UIBackgroundModes` = `[audio]` to project.yml app target (Info.plist)~~ | J-203 background playback + lock-screen transport (§5.3, §11 A.1) | **RESOLVED-AS-STALE (Leto review sweep 2, 2026-11-22T13:05Z; stale-premise note per 13:40Z): the key has been in project.yml since the M0 scaffold (L-003 @ba3182a) — filed without checking project.yml first; background playback + lock-screen transport worked in every build from M1 onward. No Leto action was ever needed. MixerPlayer's runtime `hasBackgroundAudioMode` detection stays as a plist drift guard; device verification = §10.2 step 6b. Lesson: check the built plist config before filing an X-task on it.** |

## 10. M0 device demo checklist (human runs; log results in QUEUE LOG)

1. Download `dist/PitchNotesIOS.ipa` from the green `build-ipa` run artifact.
2. Install via LiveContainer/SideStore (unsigned IPA, as configured).
3. App boots to **5 tabs** (Learn, Library, Theory, Ear, Settings) — no crash.
4. Each tab shows a placeholder with a caption; VoiceOver reads labels (spot-check
   one tab with VoiceOver on).
5. Dark mode: system-dark device renders dark palette.
6. Dynamic type: set largest text → shell text scales.
7. **Airplane mode ON → kill app → relaunch: still boots, no network prompts.**
8. Settings → About shows version 0.1.0 (build 1).
9. Log PASS/FAIL per step in QUEUE LOG (Leto records gate result).

### 10.1 M1 device demo checklist (human runs after billing fix + green build-ipa)

IPA: artifact of the first green `build-ipa` on `jess` after the CI billing fix
(≥ 61fc0c1 — ribbon + audio UX + debug screen included).

1. Install via LiveContainer/SideStore; app boots to 5 tabs; **Learn tab now
   shows the tuner ribbon** (mock singer scrolling, bars + cursor + readout).
2. **Demo singer menu** (bottom-right): cycle Perfect → Flat −30¢ → Sharp +35¢
   → Octave error → Breathy → Silent → Vibrato. Expect:
   Perfect = green "in tune" · Flat/Sharp @ ±50 = still in-tune, switch the
   tolerance picker to ±10 → orange ↑ "sing higher" / purple ↓ "sing lower" ·
   Octave error with **8va fold ON** = green + red "8va" badge; fold OFF =
   plain sharp ↓ · Breathy = dashed/dimmed trace (low-confidence honesty) ·
   Silent = hollow gray cursor, "unvoiced" readout · Vibrato = wobble around
   the bar.
3. **Part chips**: select Bass → follow window re-centers to E2–G3; chip reads
   "Bass E2–G3". All five chips (T1…Bass) present, C-1 order.
4. **Octave-equivalence toggle** ("8va fold") flips the §3.5 behavior live
   (step 2 octave case).
5. **Mic permission flow**: the mic UX appears on Learn — first visit shows
   "Enable microphone" prompt card. DENY it → denied card with [Open Settings]
   (no crash — AC). Grant later from Settings → re-open app → card gone, level
   meter animates. **J-102 (M1 demo finding, still open):** the meter still
   reads the MOCK level source (a 10 Hz wobble) even though the REAL P-104
   capture is live on the ribbon path — so the meter wiggles "hot" regardless
   of the singer, which reads as "the mic is very sensitive". The fix
   (PitchLogic `InputLevelTracker` from the frame's `loudness_db`, real level
   in liveMic mode, labeled mock kept for demo mode) is fully specified on the
   J-102 row and lands AFTER the M2 gate. **Treat the meter as a mock until
   then** — the ribbon's own pitch readout is the real capture.
6. **Headphone banner**: with no headphones connected (granted state) → orange
   speaker guidance banner; plug in wired/BT headphones → banner disappears
   (route-change observer).
7. **Interruption**: start a phone call (or Siri) while the tuner is up →
   "Audio paused — interrupted" banner; end call → auto-resume note or
   [Resume] per the .shouldResume option.
8. **VoiceOver**: focus the ribbon → spoken state ≤ 1 Hz ("E3, 23 cents flat,
   sing higher" / "unvoiced"). Dynamic Type largest: all text scales, readout
   never overlaps chips. Dark mode: palette flips. Reduce Motion: center
   snapping instead of glide.
9. **Debug screen** (Settings → Developer → Live pitch debug): RTF EMA + worst
   vs the ≤ 0.3 §8 target line — **J-105: this now measures the REAL ribbon**
   (RibbonEngine MPM/YIN via `ribbonFrame`, hop-aligned silence input, honest
   unvoiced strips — record the number in QUEUE LOG for BENCHMARKS.md; Paul's
   A14 reading). Identity rows show the C-6.0 sources: ribbon `RIBBON_MPM_YIN ·
   0 ms · live`, grading `SWIFTF0 · 176 ms · post-hoc`; `frame engine_id` /
   `frame lookahead_ms` read off the real frames (`RIBBON_MPM_YIN` / `0`).
   hz/confidence/loudness strips move (unvoiced = flat-zero lines until real
   capture wires in, X-011a), device/thermal rows.
10. **Airplane mode ON → kill → relaunch**: everything above still works (no
    network, no prompts).
11. Log PASS/FAIL per step + RTF/latency-feel notes in QUEUE LOG (L-103 gate
    evidence).

### 10.2 M2 device demo checklist (human runs at the M2 gate; import → mixer → storage)

IPA: artifact of the first ALL-GREEN `build-ipa` carrying the M2 Jess lane
(≥ J-202/J-205 merge).

> **GATE RULE (Leto, 2026-11-22T21:55Z — binding on this checklist): the MOCK
> path does NOT satisfy the M2 gate.** The demo MUST run the REAL engine
> (J-208's swap seam + P-204's assembled bundle): the L-204 AC says "import a
> real SDA FLAC → stems → mixer", and a scripted mock demo would be a D-12
> honesty failure at the gate (the mock cannot separate a real FLAC). The
> mock path stays valid for UI regression only, never for the gate. The import
> screen states which engine ran, so a mock run cannot be mistaken for a
> real one: it reads **"DEMO ENGINE (mock) — no real separation was run."**

0. **One-time model download (NEW — before step 1).** The separation weights
   (htdemucs fp16 ggml, 84 MB) are fetched ONCE, verified against the
   manifest's SHA256, and cached; after that the app works in airplane mode
   forever (AGENTS §0 rail — download once, then offline).
   - Path: Settings → Models → "One-time downloads" → **Download** (J-207).
     The screen states the outcome honestly: "Downloaded and verified — cached
     on this device." / a checksum mismatch says so and caches NOTHING.
   - **Fallback (only if the download path is not in the build):** the human
     places the ggml file in the app's Files container and taps "Use file from
     Files" — the checksum is still verified. The gate EXPECTS the download
     path.
   - **Then turn AIRPLANE MODE ON and leave it on for the rest of the demo.**
   - The import sheet must show the **"Real engine (htdemucs fp16)"** badge
     (J-208). A "DEMO ENGINE (mock)" badge means the demo is not a gate demo.
1. **Import a real SDA FLAC** (a short hymn, airplane mode ON): Library (+) →
   Files picker (FLAC selectable) → Import sheet shows title prefilled.
2. **Staged progress**: the three C-8 stages light in order — Decode ✓ →
   Separating (chunk detail, e.g. "chunk 7/40") → Assembling — fraction
   strictly rising, no jumps backward.
   **2b. RECORD THE DEVICE NUMBERS (J-206 surface — the L-204 AC's
   "RSS/thermal/RTF from device" and the human's P-603 ask).** The done
   screen shows one copyable line; write it into the QUEUE LOG VERBATIM (it
   feeds BENCHMARKS §6 / the M2 gate row):
   `Separation <m:ss> for <m:ss> source → RTF <n.nn>× · peak RSS <n> MB · thermal <start>→<end>`
   - separation wall-time, source duration, computed separation RTF
     (wall-time ÷ source duration — RTF < 1.0 = faster than real time);
   - **peak resident footprint** during the import (Darwin `task_info`
     phys_footprint — the §8 budget is peak RSS < 1.5 GB during separation);
   - **thermal state at the start and at the end** of the separation pass.
   - Honest readings: an unsampled peak reads "not sampled" (never 0 MB); an
     unknown RTF reads "—" (never "0.00×"). The live "Peak memory so far"
     line is visible during the import.
3. **Cancel integrity**: start a second import, cancel mid-separation → sheet
   resets; Library shows NO new song; Settings → Storage shows no growth from
   the cancelled run (stray `*.tmp` absent — C-2.2).
4. **Stems appear**: song row shows parts chips + a cappella/backed chip +
   provenance line (filename · date · size). **No conf % chip on an M2
   bundle** — a two-stem bundle carries no note tracks, so the confidence
   value is undefined (C-2.1 sets it to 0.0 when there are none); the chip is
   omitted rather than showing a false amber "conf 0%". The chip appears from
   M3 on, when note tracks exist (amber < 60%).
   [P: two-stem bundle with INSTRUMENTAL when source has backing.]
5. **Inspector**: Import section (source/added/size), Tuning section shows the
   D-22 estimate ("+32c sharp — reference adjusted" when P-207 landed; a
   manifest with no usable estimate shows the honest "— (no usable estimate in
   this manifest)" line — v0-era, or a v1.x manifest whose estimate is
   missing/out-of-range, with the V14/V15 violation named in Validation),
   per-file V-rules PASS.
6. **Mixer solo/focus/mute/loop** (J-203; skip if not merged at demo time):
   open mixer → focus preset default (target unity, others −12 dB — "others
   quieter", never "solo"); MUTE mutes; SOLO isolates honestly (label copy);
   seek is instant; region loop (A/B) holds.
6b. **Background + lock-screen transport** (J-203; the `audio` background
   mode ships since M0 — X-021 was stale): start
   playback → background the app (home screen, then lock) → audio continues;
   lock-screen controls appear (title/pause/seek) and respond. If the built
   plist ever lost the `audio` background mode, the mixer shows the honest
   foreground-only notice instead (runtime drift guard).
7. **Storage usage**: Settings → Storage shows per-song + total; delete the
   imported song (swipe + confirm) → total drops by the song's shown size;
   original file in Files untouched.
8. **Tuning override persists** (J-205): inspector → Force A440 → leave →
   return: selection still Force A440; chip reflects resolved offset.
9. **Airplane mode ON → kill → relaunch**: Library rows, index overrides, and
   storage totals all survive (index persistence).
10. VoiceOver spot-check one imported row (a cappella state, size, verdict) +
    one mixer fader label. Dynamic type largest: rows wrap, no clipping.
11. Log PASS/FAIL per step in QUEUE LOG (L-203/L-20x gate evidence) — plus
    the step-2b numbers line, verbatim.

## 11. Addendum A — as-built UX patterns & forward specs (Jess)

### A.1 M2 interaction patterns (as-built, with reasoning — reuse in M3+)

1. **Live-first, background-completion imports.** The import sheet is a
   blocking, foreground UX (staged progress, cancel). Backgrounding keeps the
   Task running with an honest hint instead of pausing — a killed app leaves
   only a `*.tmp` staging dir (C-2.2) that scan ignores and Settings can
   clean. Reasoning: separation is minutes-long on A14 (AGENTS §8); users
   should be able to leave the screen, but a BGProcessingTask "quality mode"
   (charge-only overnight) arrives with the real engine (P-204) — the mock
   would make the setting a lie (D-12).
2. **Instant seek.** Stems are precomputed files; seek = player node offset
   (J-203), never re-decode. No spinner on the transport. Reasoning: bleed-
   honest focus mixing makes users re-check parts frequently; every 100 ms of
   seek friction kills the sing-along loop.
3. **~15 ms gain glides.** Fader/mute/focus changes ramp linearly over
   ~15 ms — no zipper noise, no clicks, and slow enough to stay under the
   just-noticeable-difference threshold for level, fast enough to feel
   immediate. (J-203 implements with AVAudioEngine mixer output gain ramps.)
4. **LRU stem cache with a user-visible budget.** Bundles live in
   Application Support and count against the Storage screen's total; "cache
   limit + delete" UI ships in J-204 with honest per-song bytes
   (BundleStore.bytesOnDisk) — never silent eviction of user-imported bundles
   (only derived caches may auto-evict). Reasoning: re-import costs minutes;
   silent data loss is the one thing an offline-first app must never do.
5. **Focus mix, not hard solo (D-12 bleed honesty).** The default preset
   attenuates other lanes −12 dB (configurable) instead of muting: separation
   bleeds, so a "solo" that promised isolation would lie. Labels say "others
   quieter". A true MUTE exists per lane, and SOLO is labeled honestly.

### A.2.4 Notation display forward spec (M3/M5, J-501/J-502 — so it isn't re-designed)

Static engraved pages + a moving play line, NOT a scrolling staff:

- **Layout:** static page(s) engraved from `score.musicxml` (C-2 optional) or
  the NoteTrack-derived lead sheet (M3+). System breaks fixed at engrave
  time; the page turn splits **half** (top system(s) stay, bottom system(s)
  become the next page's top) so the eye never jumps mid-phrase.
- **Moving line:** a vertical cursor line interpolates by time between note
  x-positions (no reflow during playback). Notehead highlight for the current
  note; sung-note coloring (in-tune/flat/sharp) lands with M4 grading.
- **Click-note-to-seek:** tapping any notehead seeks the transport to that
  note's `start_s` (C-4 beat↔seconds mapping; same math as UltraStar import).
- **Drag-to-region-loop:** dragging along a system selects a beat range →
  A/B loop handles for the transport (J-203's region-loop, notation entry
  point). Cancel by tapping outside the range.
- **Arrows transpose:** ↑/↓ (or two buttons) transpose the DISPLAYED score
  and the reference tracks in semitones (reference transpose only — audio
  byte-true, D-22 sibling rule); persisted per song next to the tuning
  override; range-clamped so part ranges (C-6.1) stay singable.
- **Symbols:** treat this display as STUDY-ONLY-reimplementation territory —
  render with our own Canvas drawing (no OSMD/Verovio link: LGPL — AGENTS §9).
  data model stays ours: {start_s, midi, duration, voice, page, x, y}.
