# QUEUE.md — PitchNotes-iOS task board

> The ONLY task board (AGENTS.md §2). Every agent: edit ONLY your own section,
> append to LOG (newest at TOP). Queue edits are tiny standalone commits
> (`queue: <claim/done/build> <task-id>`) — never bundled with code, pushed immediately.
>
> **THE BOARD WAS ROTATED on 2026-11-27 (D-49).** The closed M0/M1/M2/M3 history
> (983 lines / 598 KB) is archived **VERBATIM** in **`Docs/QUEUE-ARCHIVE.md`** —
> search it by task ID (`P-303`, `J-301`, `X-219`, …) or by `LOG`. **This board
> carries the LIVE work only.** The human owner asked for the rotation: *"the old
> one seems to be filled"*. Nothing was deleted; every closed row is still findable.

Task row format (one line per task, keep it short):

```
- [P-014] DOING | swiftf0 ONNX spike on macOS runner | branch:paul | dep:— | build:<run-url>@<sha> | ac:spike asserts pitch+confidence on 3 fixtures | note:<handoff/next-step>
```

- IDs: `P-###` Paul, `J-###` Jess, `L-###` Leto, `X-###` cross-cutting (Leto assigns owner).
- Status lifecycle: `TODO → DOING → REVIEW → DONE`, plus `BLOCKED(reason)`;
  `BUILD_PENDING` is a *flag on the row*, never a reason to stop working.
- `ac:` = acceptance criteria. A task without `ac:` is not claimable; write one first.
- `note:` = handoff. EVERY finished task ends with a note telling the next reader
  exactly what exists, where, and what's next.
- Max one DOING coding task per agent; unlimited pending CI builds (tracked on the
  row via `build:`, not in your head).

---

## Milestone: M3 — Per-Voice Note Tracks (Leto maintains this header + gate status)

- Status: **CLOSED** (opened 2026-11-24 by Leto at L-204; closed 2026-11-27 by
  Leto at L-304 under **D-48** — the human's order that Leto finishes M3 itself).
  **M3 CLOSED: the code gate is GREEN with BOTH `basicpitch-spike` AND `bench-v2`
  BLOCKING (run 45910600056@b24ce9a), `m3` IS TAGGED, and M4 IS OPEN below.**
  **M2 CLOSED** (the whole M2 stack is on `main`, the M2 gate run was green with all
  8 jobs, contracts were at v1.0.3, `m2` is tagged).
- Contract: **v1.1.1** on `main` (D-47's additive gaps: C-15 `corrections/song.json`,
  C-16 `corrections/score.json`, the C-13.2 optional `partMapping`, C-11's optional
  split confidence, the MusicXML document type + the two exported UTIs in `project.yml`).
- Gate (PLAN.md M3): P-301…P-306, J-301…J-304, L-301…L-304; `basicpitch-spike` green
  AND blocking; `logic-tests` green; `build-ipa` green; BENCHMARKS v2 honest report;
  D10/D12 ruled; `m3` tagged. **P-304 is WAIVED (D-50) and CARRIED INTO M4; the
  M2+M3 device demo is EXPLICITLY WAIVED (D-51) — it was NOT RUN.**
- **Honesty rail for this milestone (AGENTS §11 — binding):** heuristic assignment +
  score alignment ship here; fine-tuned per-singer separation is post-v1 (X-301/X-302
  prep only). **Do NOT promise perfect 5-way separation** — design for bleed (focus
  mixes, confidence, note-track grading, score alignment) and say so in the UI.
- **THE M2 DEVICE DEMO (L-205) rode along with the M3 one (J-210) — ONE trip, and
  it was NOT RUN.** M2 is NOT device-verified and must never be described as such —
  and neither is M3.
- **THE D-30 TIER B SIGN-OFF IS OUTSTANDING — TWO weight sets only:** `htdemucs`
  (D-30) and the `dettatto` transcriber/evidence weights (D-45). **`nmp.onnx`
  (basic-pitch) IS TIER C (D-46) and NO sign-off can promote it** — MAESTRO +
  MedleyDB-pitch (CC BY-NC-SA 4.0) and iKala (academic-only EULA) were training
  data. That blocks COMMERCIAL DISTRIBUTION only: not the M3 code path, not `m3`,
  not sideloading. **Do not stall on it.**
- **THE DEVICE DEMO (J-210 / L-205) — HUMAN, NOT RUN, EXPLICITLY WAIVED (D-51).**
  It needs an iPhone 12 Pro Max, the 84 MB `htdemucs` weights and a human: real
  SDA FLAC import → staged progress → cancel leaves NO partial bundle → re-import →
  VOCALS/INSTRUMENTAL → mixer (solo / focus mix / mute / fader glide) → seek +
  region loop → a detuned recording shows the tuning offset AND the ribbon
  reference adjusts → the 5-part roll with confidence shading → correct a note →
  import a hymn MusicXML → alignment improves → export UltraStar `.txt` → **play
  it in an external UltraStar-family player** → storage + delete → airplane mode
  AFTER the one-time model download. **LOG THE DEVICE RTF / PEAK RSS / THERMAL —
  the only source of AGENTS §8's device numbers.** It was NOT run, so **AGENTS
  §8's device budgets remain UNMEASURED** and every number in `Docs/BENCHMARKS.md`
  is a runner / dev-box number. **D-51 forbids any fabricated device result.**
  The rows that need a device (J-206, J-207, L-205, J-210) stay **OPEN**.

### M3 gate checklist — row → evidence (Leto keeps this current)

| row | status | evidence |
|---|---|---|
| P-301 basicpitch.cpp + the REAL spike | DONE (merged) | `basicpitch-spike` real, 24 checks — run 45513314284@426dd45 (Paul's row); the job is now BLOCKING and green on `main` (45904236220@c3f245e, 45910600056@b24ce9a) |
| P-302 multi-f0 salience | DONE (merged) | local EngineCore 245/245 (Paul's row) |
| P-303 voice assignment engine | **DONE (merged)** | Paul's measurement 344/344 frames, macro part accuracy 1.000 (his Python mirror + the committed artifact); the Swift test is in and the fixture `satb5_prog_22050.wav` is committed (sha 5ea7b042…) |
| P-304 MusicXML parser + DTW | **WAIVED — explicitly (D-50)** | Jess's consumer side is in and ships the honest "parser not in this build" state; **CARRIED INTO M4 as an OPEN row** |
| P-305 NoteTrack v1.1 metadata + cross-check | DONE (merged) | the cross-check artifact + its Swift mirror test |
| P-306 bench v2 (the honest report) | **DONE** | the harness `Tests/Spikes/bench_v2.py` + `bench_report_v2.json`; the `bench-v2` job is GREEN and now BLOCKING (45906329503@2d6f50e, 45910600056@b24ce9a); the human-readable section is `Docs/BENCHMARKS.md` §5.3 |
| J-301 per-part piano roll | DONE (merged) | run 45893306197@c944d79 (logic-tests + build-ipa green) |
| J-302 calibration + correction overlay | DONE (merged) | + D-47's device-local nudge (J-302 in Jess's lane, under D-48) |
| J-303 UltraStar codec | DONE (merged) | the round-trip unit tests are in the green run |
| J-304 score review UI | DONE (merged) | the CONSUMER side; its engine side (P-304) is waived |
| L-301 contract v1.1 | DONE | CONTRACTS v1.1.1 on `main` (D-47) |
| L-302 CI (the real basicpitch job + bench v2) | DONE | both jobs exist, are REAL and are **BLOCKING** as of b24ce9a |
| L-303 D10 / D12 / the score-alignment reading | DONE | D-39, D-40, D-41, D-42 in DECISIONS.md |
| L-304 the M3 close | **DONE** | the gate run 45910600056@b24ce9a is GREEN with both flipped jobs blocking; `m3` is tagged; M4 is open below |

### M3 explicit waivers (D-48 §5 — a waiver is NEVER a silent scope drop)

- **[P-304] WAIVED (D-50) — the MusicXML PARSER + DTW ALIGNER (the engine side of
  score alignment) does NOT ship in M3.** Jess's J-304 consumer ships the honest
  `ScoreImportError.parserUnavailable` state, so the no-score path is unaffected and
  **nothing claims that score alignment works**. **CARRIED INTO M4** (it stays on
  the board as an open P-304 row — it is NOT dropped).
  **Why:** the M3 window is the human's D-48 close-out; a parser + DTW aligner
  landed blind (no local Swift toolchain, CI-only verification) would put an
  unverified feature into the milestone rather than an honest gap. The M3 claim is
  therefore **"per-part note tracks + the salience + the correction overlay"** — and
  **NOT** "score alignment works" and **NOT** "perfect 5-way separation".
- **[THE DEVICE DEMO] WAIVED (D-51) — the M2+M3 device demo was NOT RUN.** It needs
  an iPhone 12 Pro Max, the 84 MB `htdemucs` weights and a human. **M2 is NOT
  device-verified and neither is M3; AGENTS §8's device RTF / peak RSS / thermal
  remain UNMEASURED.** No device number may ever be fabricated. The rows stay open.

---

## Milestone: M4 — Learner Mode & Grading (opened 2026-11-27 at the `m3` tag, by L-304)

- Status: **OPEN** (opened by Leto at L-304 the moment `m3` was tagged; Jess
  withdrew her premature J-401 claim, and the board is now seeded from PLAN.md's
  M4 table verbatim). **M3 is CLOSED** — the code gate is green, `m3` is tagged,
  the waivers are D-50 (P-304) + D-51 (the device demo).
- Contract: **v1.2** — `SessionResult`, `GradingConfig`, the transposed note-track
  mapping (L-401's job).
- CI jobs: the scoring `logic-tests` suite expanded; the synthetic
  sung-stream-vs-reference session fixture; `build-ipa` (L-402's job).
- **CARRIED IN FROM M3: [P-304]** — the MusicXML parser + the DTW aligner.
  **WAIVED for M3 by D-50, NOT dropped** — and **CLAIMED BY PAUL as an M4 row
  (@e1bd6bb, D-52)**: it is now `DOING` in the Paul section below, with its
  original acceptance criteria intact. **Its end-state lane migration is
  [J-406]** (the Jess-lane score-contract typealias).
- **Merge Gate M4 (PLAN.md, verbatim):** J-401…J-405, P-401…P-403, L-401…L-403
  `DONE`; scoring logic-tests green; spikes green; build-ipa green; contracts v1.2.
- **Device Demo M4 (PLAN.md, verbatim):** full learn-a-part loop: pick Bass →
  focus mix → count-in → sing → live hits → grade A–F + heatmap → retry weak
  phrase → view history trend → shift key +2 → re-sing → grade still aligned. Log
  latency compensation result.

### M4 board — PLAN.md's M4 table, VERBATIM

| ID | Owner | Task & AC | Deps | Size |
|---|---|---|---|---|
| J-401 | Jess | Scoring engine (pure Swift): cents deviation; tolerance ±50 default (±25/±10 presets); octave-equivalence fold; onset grace 80–120 ms; sustain (continuous in-tune ms); vibrato tolerance (mean-centered ±extent); breath gate (loudness_db/RMS); per-note {hit,coverage,sustain,centsDev}; phrase aggregation; golden-note bonus; A–F grade + heatmap; configurable weights. **AC:** ≥30 unit tests (silence, octave error, vibrato, late onset, breath); deterministic; property test: closer pitch→higher score; grading MUST consume `tuning_cents` (D-22) — include a detuned-recording unit test proving a faithful singer is never marked flat. | P-305, J-101 | L |
| J-402 | Jess | Learner session flow: select song+part → focus mix → count-in → live ribbon over scrolling reference → real-time hit feedback → post-session grade (per-phrase, heatmap, sustain) → retry/loop weak phrases. **AC:** end-to-end with real engine; interrupt/resume; weak-phrase loop works. | J-401, P-401, J-203 | L |
| J-403 | Jess | Latency compensation: loopback calibration (play click→mic detect→offset) + manual slider; applies to grading alignment. **AC:** synthetic loopback offset within ±10 ms; slider persists per device. | P-104, J-401 | M |
| J-404 | Jess | History & progress: GRDB (MIT, per D4) sessions table (song/part/date/grade/metrics), trends chart, best/worst phrases, export session JSON. **AC:** persists+migrates; trends render; delete session. | J-402, L-201 | M |
| J-405 | Jess | Customization settings: tolerance, octave equiv, vibrato, onset grace, grade weights, guide level, count-in, metronome. **AC:** all persist; scoring reads config; config-effect tests. | J-401 | S |
| P-401 | Paul | Grading-grade pitch path: SwiftF0 accurate stream (176 ms lookahead OK post-hoc) for scoring; NanoPitch for ribbon; time-align both to bundle timeline; aligned PitchFrame batch for session. **AC:** alignment offset stable; grading uses SwiftF0; ribbon NanoPitch; consumes J-403 offset. | P-105, J-403 | M |
| P-402 | Paul | Reference playback sync + key/tempo: sample-accurate stem sync (AVAudioEngine scheduling), seamless loop, AVAudioUnitTimePitch shift **with NoteTrack transposition/time-scale mapping so grading stays aligned**. **AC:** key/tempo shift keeps grading aligned; loop seamless; drift <20 ms over 4 min; confirm varispeed pitch compensation = −12·log2(speed) semitones on top of any key change (Muskey-verified, RESEARCH Addendum A.2.8). | P-204, J-203 | M |
| P-403 | Paul | Session recording (optional, local-only, default OFF): mic→ALAC for replay, aligned to session, deletable. **AC:** optional/off default; replay aligns; delete purges; privacy copy. | P-401 | S |
| L-401 | Leto | Contract v1.2: SessionResult, GradingConfig, transposed NoteTrack mapping. **AC:** ratified; ack. | J-401, P-402 | S |
| L-402 | Leto | CI: scoring logic-tests expanded; synthetic sung-stream-vs-reference session fixture; build-ipa green. **AC:** green. | J-401 | S |
| L-403 | Leto | M4 merge + Device Demo; tag `m4`; open M5; seed queue. **AC:** demo logged (sing bass part→grade→history→shift key +2→re-sing→still aligned); `m4` tagged. | all M4 | S |

---

## Paul (Paul edits ONLY this section)

_— M0/M1/M2 rows are closed: see `Docs/QUEUE-ARCHIVE.md` (search by task ID) —_

- [P-301] DONE (merged to `main`) | basicpitch.cpp (MIT, sevagh) vendored + the REAL spike runner + the manifest entry + the mono/poly fixtures | branch:paul | dep:P-204,L-008 | build:45513314284@426dd45 (the real job, 24 checks) | ac:`basicpitch-spike` green on mono+poly synthetic fixtures; onset/offset within 50 ms; RTF logged | note:the code + the REAL runner are on `origin/paul`; the manifest entry carries D-46's TIER C wording
- [P-302] DONE (merged to `main`) | Multi-f0 salience: the per-frame pitch posterior + the peak picker + the C ABI's salience output + the five-voice SATB fixture | branch:paul | dep:P-301 | build:local EngineCore 245/245 | ac:synthetic SATB fixture shows 3–5 peaks; peak-picking unit test | note:the peak options are `minimum_salience 0.3`, local-max window 2 semitones
- [P-303] DONE (merged to `main` @c3f245e) | Voice assignment engine: the frame DP + the no-crossing ordering + the subset handling + the unison rule + the temporal beam Viterbi + D-41 §1's confidence | branch:paul | dep:P-302,P-105 | build:45897044406@4c77d52 (green snapshot) + the gate run 45910600056@b24ce9a | ac:≥70 % of the frames correctly assigned on the clean synthetic fixture (Paul measured 344/344 = 1.000); the Swift test asserts the Swift engine agrees with the committed Python mirror | note:PAUL'S CODE + THE SWIFT TEST are both on `main` (`VoiceAssignment.swift`, the committed artifact `Tests/Spikes/Fixtures/assignment_satb5.json` with TWO cases: the frozen chord 344 frames + the MOVING progression 688 frames). **THE MISSING PIECE HAD BEEN THE FIXTURE, NOT THE CODE** — `satb5_prog_22050.wav` was registered in `gen.py` but never committed; **LETO GENERATED AND COMMITTED IT UNDER D-48 @4c77d52** (352,844 B, sha 5ea7b042…). The moving progression's macro part accuracy is **0.988953** — but its **STEADY** frames are **1.000** and its **TRANSITION** frames are **0.4074074074074074**: **both** are reported (`Docs/BENCHMARKS.md` §5.3). **This is a SYNTHETIC number and NOT a real-acapella claim.**
- [P-304] DOING (M4 — **CLAIMED BY PAUL @e1bd6bb**, carried from M3) | Score-informed alignment hook: the MusicXML parser + the DTW aligner + the `score.musicxml` bundle entry | branch:paul | dep:P-303,L-303 | build:— | ac:synthetic score+audio aligns ≤50 ms; alignment improves assignment on synthetic | note:**NOT IN M3** — the engine side of score alignment does not ship in M3 (it is WAIVED there by D-50); **as an M4 row it is CLAIMED and DOING by Paul** on the human's session order. **D-52 §3 CORRECTS D-50's rationale:** the local Docker Swift loop (`docker run … swift:6.0 swift test`) DOES exist, so the row is **verified locally BEFORE it is pushed** — the waiver's remaining substance was the M3 close-out window, not verifiability. **D-52 §4: the score-contract types are NAMESPACED under `ScoreContract.*` in EngineCore with the IDENTICAL JSON (C-13.1/C-13.2); the same-name option is DEAD** (Paul measured the *"ambiguous for type lookup"* failure that would turn `logic-tests` + `build-ipa` red in files outside his lane). **The end-state migration is J-406 (JESS's lane — Paul must NOT make that edit).** **The work lands on `origin/paul` and is merged by Leto like any lane snapshot — INTO M4, not into M3. Paul: `main` already carries your accepted claim, so on rebase TAKE `main`'s P-304 row — do not re-land this hunk.**
- [P-305] DONE (merged to `main`) | NoteTrack v1.1 metadata: the per-note confidence, the part-presence, the unison flags, the engineVersion + the V16/V17/V18 validators + the SwiftF0 cross-check | branch:paul | dep:P-301,P-101 | build:the cross-check artifact + its Swift mirror test | ac:schema v1.1 ratified; the cross-check metric logged | note:the artifact `crosscheck_swiftf0_vs_basicpitch.json` carries the measured disagreement per fixture
- [P-306] DONE (merged to `main` @2d6f50e + 70e10c9) | Benchmark harness v2: the note onset/offset F1, the part-aware macro F1 (PawCT-style), the multi-f0 P/R/F1 → the BENCHMARKS v2 honest report | branch:main (Leto's D-48 work) | dep:P-303,P-304 | build:45906329503@2d6f50e (green) + the gate run 45910600056@b24ce9a | ac:the report committed; the real part-aware F1 stated WITHOUT overclaim; the part-AGNOSTIC and the part-AWARE metrics reported SEPARATELY, citing dettato's Dagstuhl ChoirSet row (onset 55.9 / frame 82.0 / offset 44.4) as the external part-agnostic reference | ac-met:**the harness `Tests/Spikes/bench_v2.py` + `Tests/Spikes/bench_report_v2.json` are committed; the `bench-v2` CI job is GREEN and is now BLOCKING; the human-readable report is `Docs/BENCHMARKS.md` §5.3 (written by Leto under D-48, in Paul's lane).** Part-agnostic: frame F1 0.91465 (frozen) / 0.927265 (moving); note-event onset F1 1.000 / 0.974359, offset F1 1.000 / 0.947368. Part-aware: macro part accuracy 1.000 / 0.988953, with the STEADY 1.000 vs TRANSITION 0.4074074074074074 split. **SYNTHETIC fixtures only — not a real-acapella claim; no promise of perfect 5-way separation (AGENTS §11).**
- [P-307] TODO (M4/M6 seed, non-gating for M3) | Port dettato transcriber to ONNX+Swift — Apache-2.0 CODE, TIER B WEIGHTS (D-45): ship only with the recorded risk + the human sign-off, NEVER described as clean | branch:paul | dep:P-301,P-208 | ac:parity within the documented tolerance; the benchmark report committed; the RTF/RSS logged honestly | note:D-45's soundfont-provenance caveat is binding; the grouper/drums weights are NC and banned
- [P-308] TODO (seed) | Retune-before-transcribe (D-22): consume `tuning_cents`; retune IN MEMORY only; the stored audio is never mutated | branch:paul | dep:P-207,P-307 | ac:a detuned synthetic (±35c) transcribes at ≈true-pitch quality; the times map back within tolerance
- [P-309] TODO (seed, license-gated on X-310) | The evidence-repairer-style note repair, ELSE the grouper-decode cleanup heuristics (drop low-confidence notes, fix the boundaries, merge the same-pitch notes within 30 ms) | branch:paul | dep:P-307,X-310 | ac:the repair improves the onset/offset F1 on synthetic; the fallback ships regardless of X-310
- [P-401] TODO (M4) | Grading-grade pitch path: SwiftF0 accurate stream (176 ms lookahead OK post-hoc) for scoring; NanoPitch for ribbon; time-align both to the bundle timeline; the aligned PitchFrame batch for the session | branch:paul | dep:P-105,J-403 | ac:the alignment offset is stable; grading uses SwiftF0 and the ribbon uses NanoPitch; it consumes J-403's offset | note:the M4 grading path — the ribbon and the scorer must read DIFFERENT estimators (D-22's tuning reference feeds both)
- [P-402] TODO (M4) | Reference playback sync + key/tempo: sample-accurate stem sync (AVAudioEngine scheduling), seamless loop, AVAudioUnitTimePitch shift **with the NoteTrack transposition/time-scale mapping so grading stays aligned** | branch:paul | dep:P-204,J-203 | ac:the key/tempo shift keeps grading aligned; the loop is seamless; drift <20 ms over 4 min; confirm varispeed pitch compensation = −12·log2(speed) semitones on top of any key change (Muskey-verified, RESEARCH Addendum A.2.8) | note:the M4 long pole on Paul's side — it is independent of J-401, so it can be fired early
- [P-403] TODO (M4) | Session recording (optional, local-only, default OFF): mic→ALAC for replay, aligned to the session, deletable | branch:paul | dep:P-401 | ac:optional/off by default; the replay aligns; delete purges; the privacy copy is present | note:local-only by contract (AGENTS §1's offline rail) — the recording never leaves the device
- [X-301] TODO (STRETCH, non-gating) | The synthetic SATB data pipeline: hymn MIDI/MusicXML → permissively-licensed voicebanks → 5 stems + mix + church IR → the power-set subsets → the training manifest | branch:paul | dep:P-303,L-007 | ac:the spec + 1 synthetic song end-to-end on Linux/CI; the license verdicts; the training deferred post-v1 | note:the commercial-safe data path — GTSinger/M4Singer stay BANNED (D-30 Tier C)
- [X-311] TODO (SEED, non-gating) | Read the soundfont technique + the dettato benchmark dataset → apply it to X-301 + the M3 eval harness | branch:paul | dep:— | ac:the notes filed | note:D-21/X-310 context
- [P-206] TODO (STRETCH, non-gating) | windowed-reformer (MIT) ONNX export + the benchmark vs demucs.cpp | branch:paul | dep:P-201 | ac:the evaluation report in BENCHMARKS.md
- [P-605] TODO (STRETCH, M6, license-gated) | BS-RoFormer-SW CoreML quality-mode separation, benchmarked vs demucs.cpp/windowed-reformer | branch:paul | dep:P-601,X-310 | ac:the evaluation report; a swap only via DECISIONS | note:**the checkpoint is TIER C (D-26/X-310) — it may not ship until it is verified**

---

## Jess (Jess edits ONLY this section)

_— M0/M1/M2 rows are closed: see `Docs/QUEUE-ARCHIVE.md` (search by task ID) —_

- [J-301] DONE (merged to `main` @c944d79) | The per-part piano roll: the scrolling canvas, the notes coloured by part, the confidence shading, the unison badge, the part toggles, the zoom, tap-note→detail | branch:jess | dep:P-305,J-202 | build:45893306197@c944d79 (logic-tests + build-ipa green) | ac:renders the real NoteTrack; smooth on a 4-min song; accessible | note:MUSKEY's notes-UX patterns were reimplemented AGPL-safe (D-26) — no code was copied
- [J-302] DONE (merged to `main` @c944d79) | The part calibration + the correction UI: the per-song range editor (the presets + the custom range), the part rename, the assignment correction (drag a note to a part / delete / split) → the corrected NoteTrack overlay (additive) | branch:jess | dep:P-303,J-301 | build:45893306197@c944d79 | ac:the corrections persist; the re-grade uses the corrected track; the correction-op unit tests | note:**PLUS D-47's MOVE (made in Jess's lane under D-48): the persisted `nudgeSemitones` is GONE from `corrections/song.json` — the writer never emits it and the reader ignores it; the nudge's home is `DeviceCalibration` (UserDefaults); the resolver applies the device nudge on top of the song's range; a CUSTOM range is NOT moved**
- [J-303] DONE (merged to `main` @c944d79) | The UltraStar `.txt` import/export logic module + the export sheet + the tests | branch:jess | dep:P-305,L-006 | build:45893306197@c944d79 | ac:the round-trip NoteTrack↔UltraStar is lossless within the schema; logic-tests green | note:**the external UltraStar-player check is HUMAN and rides with the device demo (J-210) — it is NOT verified yet**
- [J-304] DONE (merged to `main` @c944d79) | The score import + the alignment review UI: import MusicXML, show the aligned score vs the detected, accept/reject, the manual nudge | branch:jess | dep:P-304,J-301 | build:45893306197@c944d79 | ac:the flow works with P-304; the no-score path is unaffected | note:**THE CONSUMER SIDE ONLY.** P-304 (the parser + DTW) is **WAIVED for M3** ⇒ this ships the honest `parserUnavailable` state; **PLUS D-47's MOVE (under D-48): the NEW `corrections/score.json` (C-16 — a missing target is REPORTED, never clamped), the `partMapping` read from the C-13.2 JSON (absent ⇒ no score note enters ANY part), `CorrectionStore` no longer quarantines `score.json`, and the picker uses the STATIC `com.recordare.musicxml` UTI**
- [J-FIX-105] DONE (merged to `main` @c944d79) | The in-app licenses screen must state the NC provenance of the basic-pitch WEIGHTS (D-46) | branch:jess | dep:X-219 | build:45893306197@c944d79 | ac:the screen names MAESTRO / MedleyDB-pitch / iKala and NEVER says "clean" | note:J-219's manifest wording + this screen are the same verdict, stated in two places
- [J-206] REVIEW (the device-metrics readout) | The separation wall-time → RTF, the PEAK resident footprint (Darwin `task_info phys_footprint`) + the thermal state during the import | branch:jess | dep:P-603 | ac:the readout shows the honest numbers | note:**it closes on the DEVICE DEMO (J-210/L-205) — the runner's numbers are not device numbers**
- [J-207] REVIEW (the runtime model download) | The URLSession fetch of the manifest entry → SHA256-verify → the cache under the existing scheme | branch:jess | dep:P-104 | ac:the download verifies and the offline path works | note:closes on the device demo (the airplane-mode leg)
- [J-208] REVIEW (the real-engine swap seam) | The REAL engine behind a factory; the mock retained for the previews; ZERO UI change (the J-105 precedent) | branch:jess | dep:P-204 | ac:the import flow runs the real engine | note:the binding was rewritten per D-36 and it now compiles (the green build-ipa)
- [J-210] TODO (HUMAN — rides with L-205's ONE device trip; **NOT RUN — EXPLICITLY WAIVED (D-51)**) | **THE M3 DEVICE DEMO CHECKLIST — the same device, the same weights, one trip.** The human runs it on an iPhone 12 Pro Max with the `htdemucs` weights and logs the result IN THIS ROW, verbatim: real SDA FLAC import → staged progress → cancel leaves NO partial bundle → re-import → VOCALS/INSTRUMENTAL → mixer (solo / focus mix / mute / fader glide) → seek + region loop → a detuned recording shows the tuning offset AND the ribbon reference adjusts → the 5-part roll with confidence shading → correct a note → import a hymn MusicXML → alignment improves → export UltraStar `.txt` → **play it in an external UltraStar-family player** → storage + delete → airplane mode AFTER the one-time model download. **LOG THE DEVICE RTF / PEAK RSS / THERMAL.** | ac:the checklist is walked end-to-end ON THE DEVICE, the honest assignment quality is recorded, and the device numbers are in the row | note:**NOT RUN — explicitly waived by D-51. M2 is NOT device-verified, M3 is NOT device-verified, and neither may ever be described as such. AGENTS §8's device RTF / peak RSS / thermal remain UNMEASURED.** The row STAYS OPEN so a human with the device can still run it; **no device number may ever be fabricated (D-51 §5).**
- [J-401] TODO (M4) | Scoring engine (pure Swift): cents deviation; tolerance ±50 default (±25/±10 presets); octave-equivalence fold; onset grace 80–120 ms; sustain (continuous in-tune ms); vibrato tolerance (mean-centered ±extent); breath gate (loudness_db/RMS); per-note {hit,coverage,sustain,centsDev}; phrase aggregation; golden-note bonus; A–F grade + heatmap; configurable weights | branch:jess | dep:P-305,J-101 | ac:≥30 unit tests (silence, octave error, vibrato, late onset, breath); deterministic; a property test that closer pitch→higher score; grading MUST consume `tuning_cents` (D-22) — including a detuned-recording unit test proving a faithful singer is never marked flat | note:**THE M4 LONG POLE.** Jess's withdrawn premature J-401 claim stands — the row was opened by L-304 at the `m3` tag; **pure Swift, unit-testable, no UI** (AGENTS §1: scoring belongs to Jess)
- [J-402] TODO (M4) | Learner session flow: select song+part → focus mix → count-in → live ribbon over the scrolling reference → real-time hit feedback → the post-session grade (per-phrase, heatmap, sustain) → retry/loop the weak phrases | branch:jess | dep:J-401,P-401,J-203 | ac:end-to-end with the real engine; interrupt/resume works; the weak-phrase loop works | note:depends on J-401 + P-401 — the first session the user can actually sing against
- [J-403] TODO (M4) | Latency compensation: loopback calibration (play click→mic detect→offset) + a manual slider; the offset applies to the grading alignment | branch:jess | dep:P-104,J-401 | ac:the synthetic loopback offset is within ±10 ms; the slider persists per device | note:the offset feeds BOTH P-401 (the grading pitch path) and J-401 (the scoring alignment) — agree the sign convention early
- [J-404] TODO (M4) | History & progress: a GRDB (MIT, per D4) sessions table (song/part/date/grade/metrics), the trends chart, the best/worst phrases, the session JSON export | branch:jess | dep:J-402,L-201 | ac:it persists+migrates; the trends render; a session can be deleted | note:D4's ruling — the JSON index is M2, GRDB is M4; **the history is local-only**
- [J-405] TODO (M4) | Customization settings: tolerance, octave equivalence, vibrato, onset grace, the grade weights, the guide level, the count-in, the metronome | branch:jess | dep:J-401 | ac:all persist; the scoring reads the config; there are config-effect tests | note:the config is the `GradingConfig` of contract v1.2 (L-401) — **the settings must not be able to make the scoring dishonest**
- [J-406] TODO (M4 — **filed by Leto at D-52, requested by Paul**) | The score-contract typealias migration: PitchLogic re-exports the engine-side score types as `public typealias ScoreNote = ScoreContract.Note` (etc., one line per type), so the two modules never export the same public name | branch:jess | dep:P-304 | ac:the EngineCore suite + `logic-tests` + `build-ipa` are green with the namespaced `ScoreContract.*` types in place; `ScoreReviewTests.swift` + `ScoreReviewView.swift` compile **UNCHANGED**; the JSON shape stays byte-identical to C-13.1/C-13.2 (pinned by a test) | note:**PAUL MEASURED WHY THIS ROW EXISTS:** two imported modules exporting the same public type name make an unqualified reference *"ambiguous for type lookup in this context"*, which would turn `logic-tests` AND `build-ipa` RED in files Paul may not touch ⇒ the same-name option is DEAD. The typealias makes it literally ONE type (D-33's "one semantic, never two" residue → zero) and the app's call sites do NOT change. **If Jess's lane is closed, the human may run this under D-48.** Until it lands, the two type sets agree BY JSON — the wire format that crosses the lane boundary.

---

## Leto (Leto edits ONLY this section)

_— M0/M1/M2 rows are closed: see `Docs/QUEUE-ARCHIVE.md` (search by task ID) —_

- [L-205] TODO (HUMAN — carried from M2 by D-38) | **THE M2 DEVICE DEMO (UX §10.2) — DEFERRED to M3, NOT DONE.** It rides with J-210's ONE trip; the human logs the result in this row | ac:the checklist is walked on the device; the device RTF/RSS/thermal are logged | note:**NOT RUN — M2 is NOT device-verified**
- [L-301] DONE | Contract v1.1 (the additive NoteTrack metadata + the correction overlay + the optional salience) | branch:leto | dep:P-305 | ac:ratified; both lanes ack | ac-met:**v1.1 ratified @cd909c6 (D-44) and then v1.1.1 by D-47 (the additive C-15/C-16/C-13.2/C-11 gaps + the MusicXML UTI) — both on `main`**
- [L-302] DONE | CI: the `basicpitch-spike` job REAL + the extended synthetic SATB fixture generator + the `bench-v2` job | branch:leto | dep:P-301,P-001 | ac:green; the fixtures ≤1 MB | ac-met:both jobs exist on `main`; the REAL runner lands with P-301 (the job was RED BY DESIGN until then, which is the designed dependency signal — never a fix task)
- [L-303] DONE | DECISIONS: D10 (the MusicXML parser), D12 (the assignment confidence thresholds), the score alignment is OPTIONAL-not-required for grading | branch:leto | dep:— | ac:the rulings recorded in DECISIONS.md | ac-met:D-39, D-40, D-41, D-42 recorded
- [L-304] DONE | **THE M3 CLOSE: merge `jess`→`main` + `paul`→`main`; flip `basicpitch-spike` AND `bench-v2` to blocking; finish or explicitly waive P-303/P-304/P-306; fire the gate run; tag `m3`; open M4; seed its board** | branch:leto | dep:all M3 | build:45910600056@b24ce9a (the gate run, GREEN with both flipped jobs blocking) | ac:the gate run is green with ALL the blocking jobs; the `m3` tag exists; the M4 board is seeded in the FRESH `QUEUE.md` | ac-met:**the merges are in (#21 @c944d79, #22 @c3f245e, + the P-306 harness @2d6f50e); `basicpitch-spike` AND `bench-v2` lost `continue-on-error` @8563920; the gate run 45910600056@b24ce9a is GREEN (9 jobs, 8 blocking); `m3` is TAGGED; M4 is OPEN below with PLAN.md's M4 table verbatim (J-401…J-405, P-401…P-403, L-401…L-403) + the carried P-304; the waivers are D-50 (P-304) + D-51 (the device demo).**
- [L-211] DONE | **THE M3 CLOSE — under D-48.** Land D-47/D-48 + the MusicXML UTI; merge the two lanes; flip the two CI jobs to blocking; finish or explicitly waive the remaining M3 rows VISIBLY; fire the gate run; tag `m3`; open M4 + seed its board | branch:leto | dep:— | build:45910600056@b24ce9a | ac:all of L-304 | ac-met:**same work as L-304 (the same session) — the umbrella row is kept so the D-48 deviation stays findable. The lane deviation is bounded to M3 and ENDS with the `m3` tag: the M4 board is seeded with NORMAL ownership restored (AGENTS §1/§12).**
- [L-401] TODO (M4) | Contract v1.2: `SessionResult`, `GradingConfig`, the transposed note-track mapping | branch:leto | dep:J-401,P-402 | ac:ratified; both lanes ack | note:the M4 contract — additive where possible (D-47's precedent); the transposed-note-track mapping is the piece P-402's key/tempo shift needs
- [L-402] TODO (M4) | CI: the scoring `logic-tests` expanded; the synthetic sung-stream-vs-reference session fixture; `build-ipa` green | branch:leto | dep:J-401 | ac:green | note:the M4 CI — the scoring suite is pure Swift and needs no hardware (AGENTS §6's `logic-tests` job); the session fixture is the new artifact
- [L-403] TODO (M4) | M4 merge + Device Demo; tag `m4`; open M5; seed queue | branch:leto | dep:all M4 | ac:the demo is logged (sing bass part→grade→history→shift key +2→re-sing→still aligned); `m4` is tagged | note:the M4 close — **the M4 device demo is a HUMAN leg; D-51's precedent applies (it may be waived ONLY explicitly, and no device number may be fabricated)**
- [X-302] TODO (STRETCH, non-gating) | The per-singer model evaluation memo (SepACap / jaCappella MRDST / HTDemucs fine-tune on synthetic data); the license verification; the post-v1 pursue/drop ruling | branch:leto | dep:X-301 | ac:a memo in DECISIONS; no shipping without the license + the benchmark
- [L-602] TODO | **THE APP STORE MEMO — it has a REAL GAP (D-46):** the basic-pitch `nmp.onnx` weights are TIER C ⇒ a commercial build MUST exclude them or name a replacement (the X-301 synthetic-SATB path, or a differently-trained transcription model) | branch:leto | dep:X-217,D-46 | ac:the memo names the excluded weights or the replacement; it never calls them clean | note:**the Tier B sign-off (htdemucs + dettatto) is a separate, still-outstanding human action**
- [X-214] SEED (owner: paul; non-gating) | The streaming stem writer — the Swift driver still accumulates the blended stems for the whole song in memory | branch:paul | dep:P-202 | ac:the driver streams the blended stems to disk

---

## BLOCKED / DECISIONS PENDING (anyone appends; Leto resolves)

- **THE M3 DEVICE DEMO (L-205 + J-210) — HUMAN, NOT RUN, EXPLICITLY WAIVED (D-51).**
  It needs an iPhone 12 Pro Max, the 84 MB `htdemucs` weights and a human. It is
  the ONLY source of the device RTF / peak RSS / thermal numbers (AGENTS §8), and
  **those numbers REMAIN UNMEASURED**. **M2 is NOT device-verified, M3 is NOT
  device-verified, and neither may ever be described as such.** Every separation
  and note-tracking number in `Docs/BENCHMARKS.md` is a **runner / dev-box**
  number. **No device result may ever be fabricated (D-51 §5).** The rows that
  need a device reading — **J-206**, **J-207**, **L-205**, **J-210** — stay
  **OPEN** so a human with the device can still run them and log the truth.
- **THE D-30 TIER B SIGN-OFF — OUTSTANDING, TWO weight sets only:** `htdemucs`
  (D-30) and the `dettatto` transcriber/evidence weights (D-45). **`nmp.onnx`
  (basic-pitch) IS TIER C (D-46) AND CANNOT BE SIGNED OFF** — no sign-off promotes a
  NC-trained weight set; it blocks COMMERCIAL DISTRIBUTION only, not `m3` and not
  sideloading. The in-app licenses screen (J-FIX-105) states the NC provenance and
  NEVER says "clean".
- **[P-304] — WAIVED FOR M3 (D-50), CARRIED INTO M4 as an OPEN row.** The
  score-alignment ENGINE side (the MusicXML parser + the DTW aligner) does not
  ship in M3; Jess's consumer shows the honest `parserUnavailable` state, and
  **nothing claims score alignment works**. It is **NOT dropped** — it is a live
  M4 row in the Paul section.
- **[L-602] — THE APP STORE MEMO HAS A REAL GAP (D-46):** a **commercial** build
  MUST **exclude the basic-pitch `nmp.onnx` weights** or **name a replacement**
  (the X-301 synthetic-SATB path, or a differently-trained transcription model).
  This blocks **commercial distribution only** — not the M3/M4 code path, not
  `m3`, not `m4`, not sideloading. The memo must **never** call those weights
  clean.

---

## LOG (append-only, everyone; newest at TOP)

- 2026-11-27T00:0xZ leto: **D-52 RULED — PAUL'S P-304 CLAIM IS ACCEPTED (AS AN M4 ROW), D-50's RATIONALE IS CORRECTED, AND THE SCORE-CONTRACT TYPE COLLISION IS RULED.** **Paul claimed P-304** on the human's session order (`origin/paul` @`e1bd6bb`, *"queue: claim P-304"*) and says it supersedes the D-48 §5 waiver, because **the waiver's stated rationale does not hold: the local Docker Swift loop (`docker run … swift:6.0 swift test`) DOES exist**, so P-304 is **verified locally BEFORE it is pushed**. **That is new evidence about a ruling I made minutes ago, so I ruled again (AGENTS §1) rather than re-litigating — and D-50 is NOT edited (append-only).**
  **(1) P-304 DOES NOT SHIP IN M3 — D-50 §1/§2 STAND.** `m3` is tagged at
  `b24ce9a`, the gate run is green, and the M3 claim is unchanged (**"per-part
  note tracks + the salience + the correction overlay"** — **NOT** "score
  alignment works"). The waiver stays visible in the M3 header, in PLAN.md and
  on the board, because it is what the M3 milestone's claim boundary was.
  **(2) P-304 IS CLAIMED AND `DOING` — AS AN M4 ROW** (D-52 §2). **Paul: `main`
  now carries your accepted claim, so on `git pull --rebase origin main` TAKE
  `main`'s P-304 row — do NOT re-land your queue hunk (it would conflict with
  the M4 seed).**
  **(3) D-50 §3's RATIONALE IS CORRECTED** (D-50 itself is untouched): the
  waiver's REAL and narrower reason was the **M3 close-out window**, not
  verifiability — which is exactly the reason that applies to M4, where the row
  is built with local verification available.
  **(4) THE SCORE-CONTRACT TYPE COLLISION IS RULED.** **The same public type
  names in EngineCore and PitchLogic are DEAD** — Paul's measurement (two
  imported modules exporting the same name ⇒ *"ambiguous for type lookup"* ⇒
  `logic-tests` AND `build-ipa` red in files outside his lane) is the deciding
  evidence, and it is the failure D-33's "one semantic, never two" exists to
  prevent. **ADOPTED: EngineCore's OWN namespaced `ScoreContract.*` types with
  the IDENTICAL JSON (C-13.1/C-13.2), pinned by a unit test asserting the exact
  JSON.** Until the end-state migration lands, the two type sets agree **BY
  JSON** — the wire format that crosses the lane boundary.
  **(5) THE END-STATE MIGRATION IS NOW [J-406] — A JESS-LANE ROW** (one line per
  type: `public typealias ScoreNote = ScoreContract.Note` etc.), after which the
  app's call sites change NOTHING and the D-33 residue collapses to zero. Paul
  does NOT make that edit (it is Jess's lane); **if Jess's lane is closed, the
  human may run it under D-48.**
  **(6) `CONTRACTS.md` IS UNCHANGED — v1.1.1 stands.** It pins the JSON shape
  and the score's optionality and names **no Swift type**, so the namespacing is
  an implementation detail, not a wire change (Leto owns CONTRACTS.md).
  **(7) THE MERGE PATH IS UNCHANGED AND IS AN M4 MERGE:** the work lands on
  `origin/paul` and Leto merges it like any lane snapshot — **INTO M4, NOT INTO
  M3.** **M3 IS CLOSED; ITS GATE IS GREEN; `m3` IS TAGGED; M4 IS OPEN.**

- 2026-11-27T00:0xZ leto: **M3 IS CLOSED. `m3` IS TAGGED. M4 IS OPEN AND SEEDED.**
  **THE GATE RUN: 45910600056@b24ce9a IS GREEN** — https://github.com/thesagezm/pitchnotes-ios/actions/runs/45910600056
  — **9 jobs, 8 BLOCKING, 1 informational (pitch-bench v1)**, with the two
  **flipped** jobs now blocking: **`basicpitch-spike` (the REAL vendored
  basicpitch.cpp path) and `bench-v2` (the P-306 harness)** both PASS.
  **WHAT LANDED THIS SESSION, ALL ON `main`:** `70e10c9` the BENCHMARKS v2
  section (`Docs/BENCHMARKS.md` §5.3 — written under D-48 in **PAUL's lane**;
  every number copied from `Tests/Spikes/bench_report_v2.json`, all 28 asserted
  figures cross-checked against the artifact); `8563920` **THE GATE FLIP**
  (`continue-on-error` removed from `basicpitch-spike` + `bench-v2` — both are
  green for real: 45904236220@c3f245e and 45906329503@2d6f50e);
  `b24ce9a` **D-50 + D-51** (the two waivers, as rulings).
  **THE WAIVERS — VISIBLE, NEVER SILENT (D-48 §5):**
  **(1) [P-304] WAIVED (D-50) — the MusicXML parser + the DTW aligner (the
  ENGINE side of score alignment) DOES NOT SHIP IN M3.** Jess's J-304 consumer
  ships the honest `ScoreImportError.parserUnavailable` state, so the no-score
  path is unaffected and **NOTHING CLAIMS SCORE ALIGNMENT WORKS**. It is
  **CARRIED INTO M4 as an OPEN row — NOT dropped.** Visible in the PLAN.md M3
  header + the merge-gate line + the P-304 row + the M4 "carried in" line, in
  this board's M3 header + the P-304 row + the BLOCKED section, and in DECISIONS
  D-50. **(2) THE M2+M3 DEVICE DEMO IS EXPLICITLY WAIVED (D-51) — IT WAS NOT
  RUN.** It needs an iPhone 12 Pro Max, the 84 MB `htdemucs` weights and a
  human. **M2 is NOT device-verified and M3 is NOT device-verified**; AGENTS
  §8's device RTF / peak RSS / thermal remain **UNMEASURED**, so every
  separation + note-tracking number in `Docs/BENCHMARKS.md` is a **runner /
  dev-box** number and §6 stays empty. **NO DEVICE RESULT MAY EVER BE
  FABRICATED.** J-206 / J-207 / L-205 / J-210 stay **OPEN**.
  **THE M3 CLAIM, HONESTLY:** *"per-part note tracks + the salience + the
  correction overlay"* — **NOT** "score alignment works"; **NOT** "voice
  assignment works on real acapella" (the numbers are **SYNTHETIC**: macro part
  accuracy **1.000** on the frozen chord and **0.988953** on the moving
  progression, whose **STEADY** frames are **1.000** and whose **TRANSITION**
  frames are **0.4074074074074074** — **both** are reported, and the lower one
  is the honest one); and **NOT** "perfect 5-way separation" (AGENTS §11 — the
  app is designed for bleed: focus mixes, per-note confidence, note-track
  grading, score alignment).
  **M4 IS NOW OPEN** with PLAN.md's M4 table **VERBATIM** (J-401…J-405,
  P-401…P-403, L-401…L-403) + the M4 merge gate + the M4 device-demo text, and
  the carried **P-304** inside it. **The board was ROTATED first (D-49)** — the
  closed M0/M1/M2/M3 history is in `Docs/QUEUE-ARCHIVE.md`, VERBATIM. **Jess
  withdrew her premature J-401 claim for exactly this reason, and it is now
  seeded here properly.** **D-48 IS BOUNDED TO M3 AND ENDS WITH THE TAG** — the
  M4 board is seeded with **normal ownership restored**.
  **STILL OUTSTANDING, VISIBLY:** the **D-30 Tier B sign-off** (TWO weight sets
  only — `htdemucs` D-30 + the `dettatto` transcriber/evidence weights D-45;
  the basic-pitch `nmp.onnx` is **TIER C (D-46) and CANNOT BE SIGNED OFF** —
  MAESTRO + MedleyDB-pitch = CC BY-NC-SA 4.0 and iKala = academic-only were
  TRAINING data; it blocks **COMMERCIAL DISTRIBUTION only**, not `m3` and not
  sideloading) and the **L-602 App Store memo gap** (a commercial build MUST
  exclude the basic-pitch weights or name a replacement).
- 2026-11-27T00:0xZ leto: **THE BOARD IS ROTATED (D-49).** The human owner asked for

- 2026-11-27T00:0xZ leto: **THE BOARD IS ROTATED (D-49).** The human owner asked for
  a fresh `QUEUE.md` — *"the old one seems to be filled"* (983 lines / 598 KB, the
  closed M0/M1/M2 history dominating). **The closed history is archived VERBATIM in
  `Docs/QUEUE-ARCHIVE.md`** — Part A is the old board byte-for-byte (`main` @c944d79),
  Part B is Jess's branch board delta verbatim (the merge did NOT apply her
  `QUEUE.md` hunk — the board is mine). **This board now carries the LIVE work only.**
  Every closed row stays findable: search the archive by task ID.
  **ALSO IN THIS SESSION:** (1) `jess` → `main` merged (#21, @c944d79) — the run
  **45893306197@c944d79 IS GREEN** (all the blocking jobs); (2) Jess's branch was RED
  for ONE reason — `ScoreAlignment` implemented `init(from:)`/`encode(to:)` without
  declaring `Codable`, so `ScoreAlignmentFile: Codable` could not synthesize; fixed
  under D-48 in her lane @164998e, and **run 45892290881@164998e IS GREEN**;
  (3) **PAUL'S RED WAS NOT HIS CODE:** `satb5_prog_22050.wav` was REGISTERED in
  `gen.py` but never committed, so the fixture-integrity preflight failed EVERY spike
  job (runs 45884541092@a3a1829 + 45890555205@23f7a14). **I generated and committed it
  under D-48 in his lane @4c77d52** (352,844 B, sha 5ea7b042…, `gen.py --check` exits
  0) and pushed it to `origin/paul`; run 45897044406@4c77d52 is in flight.
  **PAUL: `git pull --rebase origin paul` — Leto's fixture commit is on top of yours.**
  **WHAT IS NEXT:** merge `paul`→`main` from a green snapshot; write P-306's bench-v2
  harness (the last M3 gate leg); write P-303's Swift test; flip `basicpitch-spike`
  AND `bench-v2` to blocking; the gate run; tag `m3`; open M4 + seed its board.
- 2026-11-25T09:0xZ leto: **D-47 RULED (THE M3 CONTRACT GAPS: X-216 + X-221 CLOSED)
  + D-48 (THE HUMAN'S ORDER: NO MORE JESS SESSIONS FOR M3 — LETO FINISHES M3 ITSELF)
  + THE MUSICXML UTI SETTLED EMPIRICALLY. `CONTRACTS.md` IS NOW v1.1.1 (ADDITIVE ONLY)
  AND `project.yml` CARRIES THE MusicXML DOCUMENT TYPE.** The full entry: the archive
  (`Docs/QUEUE-ARCHIVE.md`, Part A, the 2026-11-25T09:0xZ LOG entry) + DECISIONS
  D-47/D-48. **THE SUBSTANCE:** the calibration home = `corrections/song.json`
  (C-15); the preset vocabulary = C-6.1's own range label (DISPLAY-ONLY); the ±2
  nudge STAYS DEVICE-LOCAL (C-6.1: "never in the bundle") ⇒ a writer MUST NOT write
  `nudgeSemitones`; the score-nudge home = `corrections/score.json` (C-16); the
  score-part→C-1-part mapping rides in the C-13.2 JSON (absent ⇒ no score note
  enters any part); the C-14 "improved agreement" reading is fixed.
  **D-48 IN FORCE:** Leto may complete the remaining M3 work in ANY lane; every such
  commit is prefixed `leto:` and says in its body that it was made under D-48 and in
  whose lane. **D-43: NO SUBAGENTS.**
- 2026-11-24T22:1xZ leto: **D-46 RULED — THE BASIC-PITCH ICASSP-2022 WEIGHTS ARE TIER
  C (STUDY-ONLY FOR COMMERCIAL DISTRIBUTION).** MAESTRO + MedleyDB-pitch (CC
  BY-NC-SA 4.0) and iKala (academic-only EULA) were TRAINING data ⇒ the shipped
  `nmp.onnx` may not be commercially distributed. **NO human sign-off can promote
  them.** The CODE stays ship-safe. **This does NOT block the M3 code path, `m3` or
  sideloading.** The full entry: the archive + DECISIONS D-46.
