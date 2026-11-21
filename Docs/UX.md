# Docs/UX.md — PitchNotes UX spec (Jess)

> **Owner:** Jess. **Version:** v0 (M0, J-003). Companion docs: `AGENTS.md`,
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

### 5.1 Import flow (M2, J-201/J-202)

```
Library (+) → Document picker (MP3/FLAC/WAV/M4A per Info.plist CFBundleDocumentTypes)
  → Import Setup sheet: title (prefilled), detected format, size
  → "Remove instruments?" toggle (default ON; D-9 two-stem always runs;
     if instrumental ends near-silent it is hidden later — explain that here in one line)
  → Separation progress (BLOCKING screen, engine-owned):
       stages: 1 Decode ✓ → 2 Instrumental removal → 3 Part separation → 4 Notes & bundles
       each stage: percent + elapsed + throughput; overall ETA from measured RTF
       [Cancel] — engine honours cooperative cancellation; bundle written atomically
       (C-2) so a cancel never leaves a partial song in Library
  → Done → Song detail (5.2)
Failure states: decode failure (suggest WAV/FLAC), unsupported codec, out-of-memory
  (suggest "Quality mode: charge + Wi-Fi OFF not required — runs offline overnight"
  → BGProcessingTask, AGENTS §8).
```

### 5.2 Library & Song detail (M2)

```
Library: list rows [title · parts chips · duration · meanNoteConfidence badge]
  swipe: Delete (confirm; deletes bundle dir), Settings→Storage shows totals.
Song detail: parts overview with confidence bars (0–100%), honesty caption
  ("T1/T2 may bleed into each other — see Unison notes"), actions:
  [Listen (mixer)] [Learn a part (session)] [Notes inspector (debug, J-002)]
Debug inspector (ships hidden behind Settings → Developer): renders song.json,
  per-part stem/notes/pitch file presence, V-rule validation summary, schema
  contractVersion — J-002 delivers this; it stays the first stop for bug reports.
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

### 5.4 Learner session (M4, J-402) — state machine

```
READY: part chip + tolerance + count-in picker (0/2/4 beats) + [Start]
COUNT-IN: 4 visual/haptic beats (configurable; mic NOT grading during count-in)
ACTIVE: ribbon §3; transport minimal (pause only); guide level slider reachable
PAUSED: freeze both timelines; [Resume] [Restart phrase] [Quit]
PHRASE-END: micro-summary banner (phrase score + worst note), no modal
DONE → Results (§6.3): grade + heatmap + [Retry weak phrases] [Retry all] [History]
Latency screen (Settings→Audio→Calibrate): loopback test — play click, mic hears it,
  reports round-trip ms, sets offset; manual slider 0–300 ms always available.
```

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

| ID | Asks | Why UI needs it |
|---|---|---|
| **X-001** | Ratify part vocal-range presets (§3.6 table) + per-part calibration field as CONTRACTS C-1 additive block | part chips + follow-window + engine `fmin/fmax` ranges |
| **X-002** | Ratify MockEngine named scenarios (perfect / flat −30¢ / sharp +35¢ / octave error / silent / breathy / late onset / vibrato) as C-3 additive note | deterministic ribbon/grading previews (J-002) |
| **X-003** | Wire Paul's Engine into `project.yml` when P-001 lands: app target needs EngineAPI+MockEngine; PitchLogic needs contract Codable types WITHOUT ONNX Runtime (proposal: pure `PitchEngineContracts` target vs `PitchEngine` target) | J-002/J-004 consume; schema tests import Paul's models |
| — | Portable logic-test package | **already satisfied** (PitchLogic Package.swift, `swift test` on CI) |

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
