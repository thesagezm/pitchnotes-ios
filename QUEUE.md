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
- **M4 RULINGS ARE IN (D-53…D-58, 2026-11-27):** the weights policy (D-53 —
  `nmp.onnx` stays Tier C; sideload unaffected; a commercial build excludes or
  replaces; **X-401 opened**, non-gating for M4, GATING for L-602), the grading
  confidence + honesty policy (D-54 — confidence is REPORTED, never a weight;
  UNASSIGNED excluded VISIBLY; steady vs transition reported separately on the
  M3 template; synthetic-only labelled), the GRDB pin (D-55 — 7.6.1, MIT, wired
  by Leto), the device-demo gate policy (D-56 — ONE human trip covering the
  M2+M3+M4 legs together; run-or-explicitly-waive; never fabricate), the
  sequencing (D-57 — P-304 merged INTO M4 @f159290, J-406 EARLY in Jess's
  sequence, P-404 filed), and **CONTRACTS v1.2 RATIFIED (D-58/L-401 @5b36be8:
  C-17 the adoption gate + the pinned Agreement metric — Paul's measured finding
  answered; C-18 SessionResult; C-19 GradingConfig; C-20
  transposition/tempo/latency)**.
- Contract: **v1.2** — RATIFIED @5b36be8. Additive over v1.1.1; every
  pre-existing file's on-disk `contractVersion` string is unchanged.
- CI: **the L-402 session fixtures are LANDED and ALWAYS blocking** (11
  scenarios in `Tests/Sessions/`, deterministic generator + integrity gate with
  a verified negative, @d0cf3c3); the **scoring-suite gate is RED BY DESIGN
  until J-401 lands** (`continue-on-error` now; flipped to BLOCKING at L-403);
  `build-ipa` is green WITH GRDB 7.6.1 linked (run 46067454452@92be390 — the
  D-55 static-link proof: otool -L shows system deps only).
- **CARRIED IN FROM M3: [P-304]** — the MusicXML parser + the DTW aligner.
  **DONE AND MERGED INTO M4** (paul→main #23 @f159290, evidence run
  46063008723@a65d0f8; D-57). Its follow-up **[P-404]** (the C-17 corroboration
  branch in the aligner's `used` predicate) is filed below and is M4-GATING.
  **Its end-state lane migration is [J-406]** (the Jess-lane score-contract
  typealias) and lands EARLY in Jess's M4 sequence (D-57 §2).
- **Merge Gate M4 (PLAN.md verbatim + the D-57/D-58 additions):** J-401…J-405,
  P-401…P-403, L-401…L-403, the carried **P-304 (DONE)**, **J-406** and
  **P-404** `DONE`; scoring logic-tests green (the scoring-suite gate flipped to
  BLOCKING); spikes green (`basicpitch-spike` + `bench-v2` stay BLOCKING;
  `pitch-bench` v1 stays informational); build-ipa green; contracts v1.2.
- **Device Demo M4 (PLAN.md, verbatim):** full learn-a-part loop: pick Bass →
  focus mix → count-in → sing → live hits → grade A–F + heatmap → retry weak
  phrase → view history trend → shift key +2 → re-sing → grade still aligned. Log
  latency compensation result. **Per D-56: ONE human trip is asked for, covering
  the M2+M3+M4 legs together (J-210 + L-205 + this loop); at gate time the leg
  is RUN (logged verbatim in the rows) or EXPLICITLY WAIVED with the human ask
  outstanding; no device number may ever be fabricated (D-51 §5 stands).**

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
- [P-304] DONE (on `origin/paul` @9438212 + the FIX @a65d0f8 — the M4 lane snapshot, merged by Leto INTO M4 per D-52 §7) | Score-informed alignment hook: the MusicXML parser + the DTW aligner + the `score.musicxml` bundle entry | branch:paul | dep:P-303,L-303 | build:46063008723@a65d0f8 **GREEN (all 9 jobs incl. logic-tests + build-ipa)** · 46060847003@9438212 (RED — logic-tests only: the C-13.2 JSON pin tripped a MEASURED macOS-vs-Linux double repr difference, 0.82 prints "0.81999999999999995" on macOS and "0.82" on Linux; fixed @a65d0f8) · 46055748633@bd4b5a5 (GREEN, the WIP files) | ac:synthetic score+audio aligns ≤50 ms; alignment improves assignment on synthetic | ac-met:**MEASURED + PINNED (EngineCore 316/316 locally, docker swift:6.0 — the 300 baseline + 16 new ScoreAlignmentTests):** bar-map max error **7.0 ms** (the AC is ≤ 50 ms), the alignment confidence **0.990145** (≥ D-41 §4's 0.70 gate), the score-informed frames **688/688** vs the heuristic's **672/688** — the score fixes EXACTLY the 16 transition frames; the ADOPTED branch of D-47 §9 demonstrated on a 60 BPM variant of the same truth (before 0.615385 → after 1.000000 ⇒ used=TRUE, 18.3 ms, 687/688). **SYNTHETIC fixtures only — not a real-acapella claim.** | note:**WHAT EXISTS (all on `origin/paul`):** `Engine/Sources/EngineCore/Transcription/ScoreAligner.swift` (the audio chroma = the MODEL'S salience candidates — no FFT in the portable core; the pitch-presence-only banded DTW, the salience is never a weight, C-12; the MEASURED duration-anchored warp — a path-read bar map is 58 ms and FAILS the AC, plain LSQ 23 ms, the anchor 7.0 ms; binned ≤ 2000 frames a side) + the WIP pair from bd4b5a5 (`MusicXMLScoreParser.swift`, the namespaced `ScoreContract.*` types with the IDENTICAL JSON, D-52 §4) + the fixture `Tests/Spikes/Fixtures/satb5_prog_score.musicxml` **DERIVED by `scripts/fixtures/gen.py` from `BP_SATB5_PROG_CHORDS`** (96 BPM 4/4, 4 measures = 10 s vs the recording's 8 s) with the `--check` re-derivation (a truth-vs-score drift FAILS the integrity gate — verified with a deliberate drift) + `Engine/Tests/EngineCoreTests/ScoreAlignmentTests.swift` + `Docs/ENGINE.md` §1.7 + the v1.10 row. **THE FIX @a65d0f8:** the C-13.2 exact-JSON pin's confidence example is now the binary-exact 0.75 (both Foundations print it identically) — the contract pins keys and values, not a platform's double formatting; the measurement is recorded in the test's comment. **THE HONEST FINDING (AGENTS §11): the used decision measures FALSE on the committed fixture BY DESIGN — before = after = 1.000000: the raw 96 BPM score ALREADY agrees with the detected notes at the contract metric's ±0.25 s tolerance, so D-47 §9's strict rule refuses (C-13 rule 4's own consequence clause) — the previous chat's handoff expected `after > before` here, MEASUREMENT says otherwise, and the aligner's `reason` string states it plainly. The alignment's real improvement shows in the FRAME accuracy (688 vs 672).** The score-informed tracks are DERIVED and never replace `notes/<PART>.json` on disk (C-13 rule 3); every score note carries the ALIGNMENT's confidence, never an invented per-note probability. **P-306 NOTE (the brief requires it explicit): I did NOT add the score-alignment fixture as a third part-aware input to `Tests/Spikes/bench_v2.py` — that file and the `bench-v2` job are LETO's on `main` (the D-48 lane note); the fixture is committed and deterministic, so adding it is a one-file change in Leto's lane whenever Leto wants it.** **STILL OPEN:** J-406 (JESS's typealias migration — until it lands the two type sets agree BY JSON); the bar map's single-time-scale limitation (a tempo-drifting score simply fails the agreement gate and is not adopted — stated in ENGINE.md §1.7 and in the aligner's header); **no real acapella recording exists in the repo (licensing) ⇒ NO real-world score-alignment number is claimed**; D-50's M3 waiver stands (P-304 ships INTO M4, not M3).
- [P-404] REVIEW BUILD_PENDING (M4-GATING — **filed by Leto at D-57 §4**) | The aligner's `used` predicate gains C-17's corroboration branch: `used = confidence ≥ 0.70 AND after ≥ before AND (after > before OR after ≥ 0.90)` | branch:paul | dep:P-304,L-401 | build:46080866877@55f3c12 (in flight) | ac:tests pin BOTH branches (improvement AND corroboration) AND the refusal case (no improvement AND after < 0.90); the committed fixture's `used` flips to TRUE with the `reason` string updated; the 60 BPM variant stays TRUE; EngineCore + `logic-tests` + `build-ipa` green | note:**D-58/C-17 is the ruling this implements** — the v1.1.1 strict rule over-refuses a perfectly-corroborating score (Paul's own measured finding: before = after = 1.000000 refused a score that fixes the 16 transition frames). One predicate + tests; the C-13.2 JSON gains NOTHING (agreementBefore/after already carry the numbers). Until it lands, the shipped predicate is the v1.1.1 rule and must not be described as the v1.2 rule. **LANDED @55f3c12 (REVIEW, run 46080866877):** the v1.2 gate is ONE predicate (`ScoreAligner.decideAdoption`) returning `AdoptionDecision` (improvement/corroboration/lowConfidence/degraded/insufficient — C-17's contractual refusal vocabulary); the 0.90 gate is `ScoreAlignerOptions.corroborationAgreementThreshold` (default 0.90, a ruling — never a quiet tune). The committed 96 BPM fixture flips `used` → TRUE via the CORROBORATION branch (before = after = 1.000000, confidence 0.990145 — the v1.1.1 over-refusal C-17 fixed); the 60 BPM variant stays TRUE via `.improvement`; the three refusal kinds are pinned directly on the predicate AND end-to-end (zero-agreement: a confident alignment of a score sharing NO MIDI with the detection stays refused). EngineCore 331/331 local (316 baseline + 3 score + 12 C-20). ENGINE.md §1.7 + v1.11 row updated. Jess reads `used` (+ MAY read the decision) — she never re-derives the gate. **The bench-v2 score-fixture extension remains PAUL's optional claim** (his Tests/Spikes lane — the file was authored by Leto under D-48, the directory is his).
- [P-306] DONE (merged to `main` @2d6f50e + 70e10c9) | Benchmark harness v2: the note onset/offset F1, the part-aware macro F1 (PawCT-style), the multi-f0 P/R/F1 → the BENCHMARKS v2 honest report | branch:main (Leto's D-48 work) | dep:P-303,P-304 | build:45906329503@2d6f50e (green) + the gate run 45910600056@b24ce9a | ac:the report committed; the real part-aware F1 stated WITHOUT overclaim; the part-AGNOSTIC and the part-AWARE metrics reported SEPARATELY, citing dettato's Dagstuhl ChoirSet row (onset 55.9 / frame 82.0 / offset 44.4) as the external part-agnostic reference | ac-met:**the harness `Tests/Spikes/bench_v2.py` + `Tests/Spikes/bench_report_v2.json` are committed; the `bench-v2` CI job is GREEN and is now BLOCKING; the human-readable report is `Docs/BENCHMARKS.md` §5.3 (written by Leto under D-48, in Paul's lane).** Part-agnostic: frame F1 0.91465 (frozen) / 0.927265 (moving); note-event onset F1 1.000 / 0.974359, offset F1 1.000 / 0.947368. Part-aware: macro part accuracy 1.000 / 0.988953, with the STEADY 1.000 vs TRANSITION 0.4074074074074074 split. **SYNTHETIC fixtures only — not a real-acapella claim; no promise of perfect 5-way separation (AGENTS §11).**
- [P-307] TODO (M4/M6 seed, non-gating for M3) | Port dettato transcriber to ONNX+Swift — Apache-2.0 CODE, TIER B WEIGHTS (D-45): ship only with the recorded risk + the human sign-off, NEVER described as clean | branch:paul | dep:P-301,P-208 | ac:parity within the documented tolerance; the benchmark report committed; the RTF/RSS logged honestly | note:D-45's soundfont-provenance caveat is binding; the grouper/drums weights are NC and banned
- [P-308] TODO (seed) | Retune-before-transcribe (D-22): consume `tuning_cents`; retune IN MEMORY only; the stored audio is never mutated | branch:paul | dep:P-207,P-307 | ac:a detuned synthetic (±35c) transcribes at ≈true-pitch quality; the times map back within tolerance
- [P-309] TODO (seed, license-gated on X-310) | The evidence-repairer-style note repair, ELSE the grouper-decode cleanup heuristics (drop low-confidence notes, fix the boundaries, merge the same-pitch notes within 30 ms) | branch:paul | dep:P-307,X-310 | ac:the repair improves the onset/offset F1 on synthetic; the fallback ships regardless of X-310
- [P-401] TODO (M4) | Grading-grade pitch path: SwiftF0 accurate stream (176 ms lookahead OK post-hoc) for scoring; NanoPitch for ribbon; time-align both to the bundle timeline; the aligned PitchFrame batch for the session | branch:paul | dep:P-105,J-403 | ac:the alignment offset is stable; grading uses SwiftF0 and the ribbon uses NanoPitch; it consumes J-403's offset | note:the M4 grading path — the ribbon and the scorer must read DIFFERENT estimators (D-22's tuning reference feeds both)
- [P-402] DOING (M4) | Reference playback sync + key/tempo: sample-accurate stem sync (AVAudioEngine scheduling), seamless loop, AVAudioUnitTimePitch shift **with the NoteTrack transposition/time-scale mapping so grading stays aligned** | branch:paul | dep:P-204,J-203 | ac:the key/tempo shift keeps grading aligned; the loop is seamless; drift <20 ms over 4 min; confirm varispeed pitch compensation = −12·log2(speed) semitones on top of any key change (Muskey-verified, RESEARCH Addendum A.2.8) | note:the M4 long pole on Paul's side — it is independent of J-401, so it can be fired early. **CLAIMED (DOING @55f3c12):** the PORTABLE core is landed — `EngineCore/Playback/PlaybackTransform.swift` (the ONE C-20 implementation: midi'/time/overlay/tuning/latency/ranges, 12 tests pinning every clause) + `VarispeedPitchCompensation` (−12·log2(speed)). NEXT: the Apple-only `Engine/PlaybackKit` package (the MicCapture pattern — per-part AVAudioPlayerNode → per-lane AVAudioUnitTimePitch pitch=+100·n cents / rate=tempoScale, sample-accurate A/B loop, host-time position) with the macOS offline-render measurement of the varispeed compensation + the loop-gap/drift render test; then the X-task for Leto's project.yml + CI wiring (MicCapture precedent). **LANDED @51f5430 (DOING — awaiting X-402 wiring):** (1) `EngineCore/Playback/PlaybackTransform.swift` — the ONE C-20 implementation (12 tests: every clause incl. the pinned latency sign and refused-not-clamped ranges) + `VarispeedPitchCompensation`; (2) **the varispeed AC is MEASURED** — `VarispeedCompensationTests` (4 tests, pure DSP, runs everywhere): a synthesized 440 Hz sine read at speed s measures a drift of +12·log2(s) UP (faster = sharper), the −12·log2(s) compensation cancels it exactly, and it composes additively with a key change ("on top of any key change"); (3) `Engine/PlaybackKit/` — the Apple-only reference player (per-part AVAudioPlayerNode → per-lane AVAudioUnitTimePitch pitch=+100·n cents / rate=tempoScale, the PRIMED sample-accurate A/B wrap — segments queued back-to-back on one render timeline, no callback race — and the playerTime-based position clock with the MEASURED unit fact bundle=sampleTime/sr, render=sampleTime/(sr·tempoScale)) + smoke tests. **HONEST LIMITS:** the AudioUnit-specific behaviour (TimePitch rate pitch-preservation) binds in PlaybackKit and confirms on the D-56 device leg like every §8 number — the <20 ms drift over 4 min has NO runner/device number yet; the scheduling math is sample-accurate by construction and pinned by the unit facts. PlaybackKit does NOT compile in CI until X-402 wires it (the ImportKit branch-state precedent).
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
- [L-401] DONE | Contract v1.2: `SessionResult`, `GradingConfig`, the transposed note-track mapping | branch:leto | dep:J-401,P-402 | ac:ratified; both lanes ack | ac-met:**RATIFIED @5b36be8 (D-58)** — C-17 (the C-14 adoption gate: the pinned `Agreement` metric + the corroboration branch, answering Paul's measured finding), C-18 (`SessionResult`), C-19 (`GradingConfig`), C-20 (transposition/tempo mapping + the latency offset + `tuningCents` preservation). **ADDITIVE over v1.1.1** (D-47's precedent): every pre-existing file's on-disk `contractVersion` string unchanged; the JSON shapes are pinned, NOT Swift type names (D-52's rule). **ACKS: the L-006 precedent applies — if a lane does not ack in its next LOG line, the ratification stands and the ack is recorded OUTSTANDING; the milestone does not stall for it.**
- [L-402] DOING (M4) | CI: the scoring `logic-tests` expanded; the synthetic sung-stream-vs-reference session fixture; `build-ipa` green | branch:leto | dep:J-401 | build:**46070286031@d0cf3c3 GREEN 9/9 (verified 2026-11-28)** — the RED-by-design scoring-suite gate step is NON-VACUOUS: it found 0 tests, errored, exit 1, and the job stayed green via continue-on-error (exactly the designed signal) | ac:green (pending J-401 + the L-403 flip) | note:**THE WIRING IS LANDED (@d0cf3c3):** (1) the 11-scenario session fixtures + the deterministic generator with an integrity gate and a VERIFIED NEGATIVE (`Tests/Sessions/`, ALWAYS blocking in `logic-tests`); (2) the scoring-suite gate — RED BY DESIGN until J-401 lands (`continue-on-error` now; **FLIPPED TO BLOCKING at L-403**), counting ≥30 `func test` in `Tests/Logic/Tests/PitchLogicTests/Scoring/` (the suite home is declared in its README); (3) `build-ipa` green WITH GRDB 7.6.1 linked (run 46067454452@92be390 — the D-55 static-link proof). **The row completes when J-401's suite exists (the gate goes green) and the flip is done at L-403.** The app-target compile proof is `build-ipa` on macOS — a Linux/docker green alone is NOT an app-target green (the M2 ManifestV1 seam-bug lesson); J-406 must land before Jess's first UI row touching score types (D-57 §2).
- [X-401] TODO (owner: Leto — **filed by D-53 §3**; non-gating for M4, **GATING for L-602**) | The commercial replacement path for the Tier C basic-pitch weights: evaluate (i) the dettato transcriber port (P-307, Tier B — recorded risk + human sign-off), (ii) a clean retrain on X-301's synthetic SATB (Tier A by construction), (iii) exclusion (the feature does not ship commercially); rule which path ships | branch:leto | dep:D-53,X-301,P-307 | ac:a DECISIONS ruling naming the path; it never calls the `nmp.onnx` weights clean | note:the standing honesty rail applies — the basic-pitch `nmp.onnx` weights are TIER C (D-46) with NO sign-off path; M4 is unaffected (sideload/research); only a COMMERCIAL build must exclude-or-replace.
- [L-403] TODO (M4) | M4 merge + Device Demo; tag `m4`; open M5; seed queue | branch:leto | dep:all M4 | ac:the demo is logged (sing bass part→grade→history→shift key +2→re-sing→still aligned); `m4` is tagged | note:the M4 close — **the M4 device demo is a HUMAN leg; D-51's precedent applies (it may be waived ONLY explicitly, and no device number may be fabricated)**
- [X-302] TODO (STRETCH, non-gating) | The per-singer model evaluation memo (SepACap / jaCappella MRDST / HTDemucs fine-tune on synthetic data); the license verification; the post-v1 pursue/drop ruling | branch:leto | dep:X-301 | ac:a memo in DECISIONS; no shipping without the license + the benchmark
- [L-602] TODO | **THE APP STORE MEMO — it has a REAL GAP (D-46):** the basic-pitch `nmp.onnx` weights are TIER C ⇒ a commercial build MUST exclude them or name a replacement (the X-301 synthetic-SATB path, or a differently-trained transcription model) | branch:leto | dep:X-217,D-46 | ac:the memo names the excluded weights or the replacement; it never calls them clean | note:**the Tier B sign-off (htdemucs + dettatto) is a separate, still-outstanding human action**
- [X-214] SEED (owner: paul; non-gating) | The streaming stem writer — the Swift driver still accumulates the blended stems for the whole song in memory | branch:paul | dep:P-202 | ac:the driver streams the blended stems to disk

---

## BLOCKED / DECISIONS PENDING (anyone appends; Leto resolves)

- **[X-402] FILED by Paul (2026-11-28) — LETO to assign/apply (AGENTS §12:
  project.yml + .github/** are Leto's; the MicCapture/X-011 precedent).**
  **Spec, exact:** (1) `project.yml` gains package `PlaybackKit` (path
  `Engine/PlaybackKit`, local path-package like MicCapture/ImportKit — NO
  remote deps; path-dep on the parent Engine package) + the app-target
  dependency (Jess's J-402 consumes the player; the graded-session flow needs
  it live in the app target). (2) `build.yml` gains a macOS step in the
  MicCapture X-011b pattern: `cd Engine/PlaybackKit && swift test` (BLOCKING
  where present) — 3 smoke tests, NO audio hardware needed (config math +
  time-mapping unit facts + the D-33 transform identity; no engine start).
  The Linux docker loop cannot build it (Apple-only) — the FIRST wiring run
  is its compile proof (the ImportKit branch-state precedent; a red there is
  a FIX task, not a design flaw). (3) No CI-minute risk: the suite is 3 fast
  tests. **Why:** P-402's player exists and must be consumable + compiled;
  without the wiring the package is dead code on every branch.
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
- **[P-304] — WAIVED FOR M3 (D-50), CARRIED INTO M4, NOW DONE AND MERGED
  (paul→main #23 @f159290, D-57).** The score-alignment ENGINE side (the
  MusicXML parser + the DTW aligner) did not ship in M3 — Jess's J-304
  consumer shipped the honest `parserUnavailable` state and **nothing claimed
  score alignment works in M3**. As an M4 row it is **DONE and MERGED**
  (measured + pinned: 7.0 ms bar map, confidence 0.990145, 688/688 vs 672/688 —
  see the Paul section's row). Its follow-up **[P-404]** (the C-17
  corroboration branch, D-58) is filed and M4-gating.
- **[L-602] — THE APP STORE MEMO HAS A REAL GAP (D-46/D-53):** a **commercial**
  build MUST **exclude the basic-pitch `nmp.onnx` weights** or **name a
  replacement**. **[X-401] is OPENED (D-53 §3)** for that replacement path —
  non-gating for M4, **GATING for L-602**. This blocks **commercial
  distribution only** — not the M3/M4 code path, not `m3`, not `m4`, not
  sideloading. The memo must **never** call those weights clean.
- **THE M4 DEVICE LEG (D-56):** ONE human trip is asked for, covering the
  M2+M3+M4 legs together (J-210's checklist + L-205's + the M4 learn-a-part
  loop, on the same iPhone 12 Pro Max with the 84 MB `htdemucs` weights). At
  gate time the leg is **RUN (logged verbatim in the rows)** or **EXPLICITLY
  WAIVED with the human ask outstanding** — D-51's precedent and its
  no-fabrication rule stand unchanged. J-206 / J-207 / L-205 / J-210 stay
  OPEN.

---

## LOG (append-only, everyone; newest at TOP)

- 2026-11-28T1:4xZ paul: **P-402's ENGINE SIDE IS LANDED (DOING — the wiring
  is X-402, filed for Leto).** (1) The portable C-20 core
  (`PlaybackTransform` + `VarispeedPitchCompensation`, 12 pinned tests —
  every C-20 clause incl. the latency sign and refused-not-clamped ranges);
  (2) **THE VARISPEED AC IS MEASURED** (`VarispeedCompensationTests`, 4
  tests, pure DSP, runs in the docker loop AND on the runner): a 440 Hz
  sine read at speed s measures **+12·log2(s) semitones UP** (faster =
  sharper — tape physics; A.2.8's −12·log2(s) is the COMPENSATION, and the
  test proves imposed + compensation == 0 and that it composes additively
  with a key change); (3) `Engine/PlaybackKit/` — the Apple-only reference
  player (per-lane AVAudioUnitTimePitch, the PRIMED sample-accurate A/B
  wrap, the playerTime position clock with the unit fact
  bundle=sampleTime/sr) + 3 smoke tests. **HONEST LIMITS:** the TimePitch
  rate pitch-preservation binds in PlaybackKit and confirms at the D-56
  device leg; **the <20 ms drift over 4 min has NO runner/device number
  yet** — the scheduling math is sample-accurate by construction (the wrap
  is primed back-to-back, not callback-rescheduled) and pinned by the unit
  facts. **X-402 is in the BLOCKED section with the EXACT spec** (project.yml
  package + app-target dep + a MicCapture-pattern blocking `swift test`
  step); PlaybackKit is dead code on every branch until it lands. **TO
  JESS:** J-402 consumes `ReferencePlaybackEngine` (built per session from
  the bundle's stems + ONE `PlaybackEnvironment`) and grades through
  `engine.transform` (the same `PlaybackTransform` the tests pin) — never a
  second mapping (D-33). EngineCore now **335/335** (331 + 4 varispeed)
  local. CI run 46080866877 (P-404's) still in flight — checked at the next
  natural checkpoint, never waited on (§5).

- 2026-11-28T1:1xZ paul: **P-404 LANDED @55f3c12 (REVIEW, BUILD_PENDING — run
  46080866877@55f3c12) + P-402 CLAIMED (its portable core landed in the same
  push).** P-404: the v1.2 adoption gate is one predicate
  (`decideAdoption` → `AdoptionDecision`), the committed fixture flips
  `used` → TRUE via the CORROBORATION branch (before = after = 1.000000,
  confidence 0.990145 ≥ 0.70, after ≥ 0.90 — D-47 §9's measured over-refusal
  is what C-17 fixed), the 60 BPM variant stays TRUE via `.improvement`, all
  three refusal kinds pinned (incl. the zero-agreement end-to-end case).
  EngineCore **331/331** local (docker swift:6.0; 316 baseline + 3 + 12).
  P-402: `PlaybackTransform` + `VarispeedPitchCompensation` (the ONE C-20
  implementation — 12 tests pinning every clause incl. the pinned latency
  sign and the refused-not-clamped ranges); the AVAudioEngine player is next
  as an Apple-only `Engine/PlaybackKit` package (MicCapture pattern) + an
  X-task for Leto's wiring. One arithmetic lesson for the board, honestly:
  three test-side constant errors (a pivot formula mis-substitution, a
  scaled-start expectation, a hand-computed log2 constant) — the docker loop
  caught ALL before the push; the implementation matched the contract
  formula throughout. **PAUL'S v1.2 ACK:** contract v1.2 (D-58) is read and
  acknowledged — C-17 implemented as P-404; C-20 implemented as the
  P-402 transform; C-18/C-19 are Jess's consumption.

- 2026-11-28T0:0xZ paul: **claimed P-404** (M4-gating, D-57 §4 — the C-17 corroboration branch in the aligner's `used` predicate). Rebase done FIRST: my branch fast-forwarded to origin/main @bcfb393 (P-304's merge f159290 is a true merge of my snapshot — nothing re-landed, per D-52 §2/D-57 §3; main's DONE P-304 row taken). Implementing now: the v1.2 gate as ONE predicate + named branches (improvement / corroboration / lowConfidence / degraded / insufficient) + tests pinning both branches and every refusal kind C-17 names; the committed fixture flips `used` to TRUE via the corroboration branch, the 60 BPM variant stays TRUE via the improvement branch. Docker Swift loop verification before any push (the D-52 §3 lesson).

- 2026-11-28T00:14Z leto: **CHECKPOINT (M4 session 3). (1) CI STATE VERIFIED:**
  the L-402 wiring run **46070286031@d0cf3c3 is GREEN 9/9** and the
  RED-by-design scoring-suite gate step is **NON-VACUOUS** (found 0 tests,
  errored, exit 1, the job stayed green via continue-on-error — the designed
  signal); run 46067454452@92be390 (the GRDB static-link proof) GREEN;
  46066301338@f159290 (the merge-push run) is **cancelled — an ARTIFACT of
  cancel-in-progress**, not a red. **(2) A DECISIONS GAP FIXED:** D-58's
  append-only ENTRY was omitted at ratification (5b36be8 carried the ruling's
  number; 57 `## D-` headings on disk) — **now RECORDED @37be01a**, late,
  unbackdated; C-17's full predicate (`after ≥ before` on BOTH branches) is
  stated authoritative over D-57 §4's inline abbreviation (D-57 unedited;
  the P-404 row already quotes the full form). **(3) LANE STATE — M4 CANNOT
  MOVE WITHOUT LANE WORK:** Jess's lane is CLOSED (origin/jess @164998e — no
  J-401/J-406 claim, **the v1.2 ack is recorded OUTSTANDING per the L-006
  precedent**, the ratification stands); Paul is idle since 20:45Z (P-404
  unclaimed). Gated on Jess: J-401 (THE LONG POLE) → J-402…J-405, J-406 early.
  Gated on Paul: P-404 (M4-gating), P-401…P-403. **D-48 is NOT renewed** —
  escalated to the human in-session (which rows are gated on which lane; the
  lanes own their code). **(4) HUMAN ASKS STILL OUTSTANDING (surfaced at
  L-403, not nagged):** the ONE device trip (D-56 — M2+M3+M4 legs, iPhone
  12 Pro Max, 84 MB htdemucs) and the Tier B sign-off (htdemucs D-30 +
  dettato D-45). X-401 (the Tier C replacement path) stays OPEN, non-gating
  for M4, GATING for L-602.

- 2026-11-27T23:40Z leto: **M4 IS UNDER WAY — THE RULINGS ARE IN (D-53…D-58), CONTRACTS v1.2 IS RATIFIED, P-304 IS MERGED INTO M4, THE GRDB PIN IS WIRED AND CI-PROVEN, AND THE L-402 CI IS LANDED.** To BOTH LANES — read this before your next claim:
  **(1) PAUL→MAIN #23 @f159290 — P-304 IS IN M4** (D-57 §1; evidence run
  46063008723@a65d0f8, 9/9 green; the merge was conflict-free because main had
  not moved since Paul branched). **PAUL: take main's P-304 row on rebase (it
  is DONE with your handoff note); your follow-up is [P-404]** — C-17's
  corroboration branch in the aligner's `used` predicate
  (`confidence ≥ 0.70 AND after ≥ before AND (after > before OR after ≥ 0.90)`),
  M4-gating, filed at D-57 §4. **YOUR MEASURED FINDING WAS RIGHT AND IS NOW
  CONTRACT:** D-58/C-17 pins the `Agreement` metric you implemented (same-MIDI,
  no octave fold, ±0.25 s extended-overlap, one-to-one, two-sided Dice) and
  adds the corroboration branch (`after ≥ 0.90`) beside D-47 §9's unchanged
  improvement branch, with `after ≥ before` (never degrades) on both and the
  zero-agreement refusal preserved. The frame-level 688-vs-672 delta stays
  REPORTED, never a gate input. D-47 is NOT edited (append-only).
  **(2) CONTRACTS v1.2 @5b36be8 (D-58/L-401), ADDITIVE over v1.1.1:** C-18
  `SessionResult` (per-note `{centsDeviation, coverage, sustain, hit}` — C-5's
  names FROZEN — + `confidenceBand`/`unison`/`transitional`/
  `notAssessable{Reason}` + `accuracy{overall,steady,transition}` +
  `gradingReference.source` + the C-20 environment + `grade ∈ {A,B,C,D,F}` +
  `config` BY VALUE; LOCAL-ONLY), C-19 `GradingConfig` (every tunable BOUNDED —
  `toleranceCents [10,50]` clamped-and-reported, `weights` must sum to 1.0,
  never silently normalized), C-20 (the transform is a VIEW, never a rewrite;
  the overlay maps IDENTICALLY to the track it corrects; **`tuningCents` is
  PRESERVED under transposition** — a +32c recording shifted +2 grades against
  +32c; **latency sign PINNED: ≥ 0 = live is LATE, compare live t against
  reference t − latencyOffset_ms**; home DEVICE-LOCAL). **JESS: ack v1.2 in
  your next LOG line (the L-006 precedent — an un-acked ratification stands,
  the ack is recorded OUTSTANDING).**
  **(3) THE D-54 GRADING POLICY (binding on J-401/J-402/J-405):** confidence is
  REPORTED, NEVER a scoring weight; UNASSIGNED notes are excluded VISIBLY
  (`notAssessable`, reason "unassigned" — a grade from a subset must never
  look like a grade of the whole); PROVISIONAL grades at full weight; unison
  grades per-part (C-14 unchanged); steady vs transition reported SEPARATELY
  (50 ms note-boundary window) on the M3 template — the lower number is the
  honest one; every M4 accuracy number is SYNTHETIC-labelled until real
  fixtures land.
  **(4) THE WEIGHTS POLICY (D-53):** `nmp.onnx` stays TIER C (no sign-off path
  exists); M4 proceeds for sideload/research unchanged; a COMMERCIAL build
  excludes Tier C weights or names a replacement; **[X-401] is OPENED** for
  that path (non-gating for M4, GATING for L-602); no new Tier C weights in
  M4. The Tier B sign-off (htdemucs + dettato) stays outstanding, human-owned.
  **(5) THE GRDB PIN (D-55): `exactVersion 7.6.1`** — MIT verified upstream;
  the newest release whose manifest is tools-6.0 (v7.7.0+ are tools-6.1,
  which the `swift:6.0` docker loop cannot parse); **WIRED BY ME in
  project.yml @92be390, and run 46067454452@92be390 IS GREEN — build-ipa
  resolved GRDB, linked it, and the otool -L verify shows system deps only
  (the LiveContainer static-link proof). JESS: add GRDB to YOUR
  Tests/Logic/Package.swift with the SAME pin spelled `exact: "7.6.1"` when
  J-404 starts (XcodeGen's key is `exactVersion:`, SwiftPM's is `exact:` —
  measured); never invent a second version; a bump is a Leto ruling.**
  **(6) THE DEVICE LEG (D-56):** ONE human trip covering the M2+M3+M4 legs
  together; at gate time it is RUN (logged verbatim) or EXPLICITLY WAIVED
  with the human ask outstanding; no device number may ever be fabricated
  (D-51 §5 stands). Pushed for, surfaced at L-403, not nagged.
  **(7) THE L-402 CI IS LANDED @d0cf3c3:** the 11-scenario session fixtures
  (steady, detuned ±35c, octave error, vibrato, late onset vs the grace,
  breath/silence/uncovered-span, the D-54 confidence/unison policy, a C-11
  overlay, the C-20 transform, the steady/transition class) live in
  `Tests/Sessions/` with a deterministic generator whose `--check` is ALWAYS
  blocking and carries a VERIFIED NEGATIVE; the scoring-suite gate is RED BY
  DESIGN until J-401 lands (continue-on-error now, BLOCKING at L-403) and
  counts ≥30 `func test` in `Tests/Logic/Tests/PitchLogicTests/Scoring/` —
  **JESS: that directory (declared in its README) is where J-401's suite
  lives, and the fixtures are #filePath-readable from your tests (the
  ImportKit pattern; no Package.swift resource declaration needed).** The
  app-target compile proof is build-ipa on macOS — a Linux/docker green alone
  is NOT an app-target green (the M2 ManifestV1 seam-bug lesson). J-406 lands
  BEFORE your first UI row touching score types (D-57 §2) — J-401's pure-Swift
  core is NOT blocked by it.
  **(8) BOARD HYGIENE:** the dangling duplicated lead-in line of the D-49 LOG
  entry (a rotation-rebuild residue) is removed in this commit; every other
  LOG line is untouched.

- 2026-11-27T20:45Z paul: **P-304 IS GREEN ON CI — run 46063008723@a65d0f8, ALL 9 JOBS SUCCESS (logic-tests + build-ipa + all the blocking spikes). The row stands DONE; the only remaining step is LETO's M4 lane merge (D-52 §7).** The one red leg (46060847003, logic-tests only) was the C-13.2 exact-JSON pin tripping the MEASURED macOS-vs-Linux double repr difference (0.82 → "0.81999999999999995" vs "0.82"); the pin now uses the binary-exact 0.75 and the measurement is recorded in the test's comment. Board lesson stands: an exact-JSON pin must use binary-exact doubles (or compare parsed structure) — an inexact double's repr is platform surface, not contract surface.
- 2026-11-27T20:22Z paul: **P-304 FIX PUSHED @a65d0f8 — run 46060847003@9438212 came back RED on `logic-tests` ONLY (the other 8 jobs, incl. `build-ipa`, GREEN).** The failure is the C-13.2 exact-JSON pin: **a MEASURED macOS-vs-Linux Foundation difference** — macOS %.17g-prints the INEXACT double 0.82 as `"0.81999999999999995"` where Linux prints `"0.82"`, so my exact-string pin of that value was not portable (the Linux Docker loop I verify with could never see it — the honest limit of a local loop). The contract pins the JSON's KEYS and VALUES, not a platform's double formatting, so the pin now uses the binary-exact 0.75 (both Foundations print it identically); the measurement is recorded in the test's comment; **no engine type, no contract surface touched**; the local suite is 16/16 again. The fix run is 46063008723@a65d0f8 (in flight); the P-304 row carries every run URL. Lesson for the board: **an exact-JSON pin must use binary-exact doubles (or compare parsed structure) — an inexact double's repr is platform surface, not contract surface.**
- 2026-11-27T20:05Z paul: **P-304 LANDED COMPLETE on `origin/paul` @9438212 —
  the aligner + the fixture + the pinned tests, row DONE (self-verifiable
  against its ac: per D-52 §2/§3 — verified locally BEFORE the push), waiting
  only on Leto's M4 lane merge.** **WHAT LANDED:** (1) `ScoreAligner.swift` —
  the audio chroma comes from the MODEL'S per-frame salience candidates (the
  same set P-303 assigns; no FFT in the portable core), the DTW uses the
  notes' PITCH PRESENCE ONLY (the salience is never a weight — C-12), the
  warp is the MEASURED duration-anchored single time-scale (a bar map read
  straight off the path is 58 ms and FAILS the ≤ 50 ms AC; plain least-squares
  23 ms; the anchor **7.0 ms**; not knife-edge — weight N/4 still gives
  688/688 at 16.5 ms), both sides binned to ≤ 2000 frames; (2) the committed
  fixture `satb5_prog_score.musicxml` is DERIVED by `gen.py` from
  `BP_SATB5_PROG_CHORDS` at the score's OWN tempo (96 BPM ⇒ 10 s vs the 8 s
  recording) and `gen.py --check` RE-DERIVES it — I verified a deliberate
  truth-table drift FAILS the integrity gate; (3) `ScoreAlignmentTests.swift`
  (16 tests) pins the parser rules (rests advance the timeline, mid-part
  divisions honoured, `<score-timewise>` rejected, excluded-features-only ⇒ an
  empty score + a notice, labels captured), the EXACT C-13.1/C-13.2 JSON
  (D-52 §4 — via the portable sortedKeys canonicalisation, since the encoder's
  key order is a dictionary-iteration detail I MEASURED on swift:6.0), the
  alias table ("tenor" alone resolves to NOTHING — never guessed, D-47 §8),
  the placement rule (mirrors `ScoreReview.align` exactly), the no-score path
  (succeeds, reason stated, C-13 rule 1), and the demonstration.
  **THE MEASURED NUMBERS, PINNED:** bar-map max error **7.0 ms** (AC ≤ 50),
  confidence **0.990145**, score-informed **688/688** vs heuristic **672/688**
  — the score fixes EXACTLY the 16 transition frames (661 steady frames were
  already 661/661; all 16 errors sit within ±4 frames / 46 ms of a chord
  change, where the audio physically carries both chords). Local suite
  **EngineCore 316/316** (the 300 baseline + 16 new), docker swift:6.0.
  **THE HONEST FINDING — READ THIS BEFORE ASSUMING THE DEMO IS GREEN:** the
  used decision measures **FALSE on the committed fixture, BY DESIGN**:
  before = after = **1.000000** — the raw 96 BPM score already agrees with the
  detected notes at the contract metric's ±0.25 s tolerance (the notes are
  seconds long, so the intervals overlap with room to spare), and D-47 §9's
  STRICT rule (C-13 rule 4) therefore REFUSES a score that "already matches"
  at the metric's tolerance. The previous chat's handoff predicted
  `after > before` for this fixture; **that was never measured** (it is not in
  the prototype script) and my measurement says otherwise. I did NOT
  re-litigate the rule or retune the metric inputs to force a TRUE: the rule
  is implemented exactly, the refusal is pinned, the `reason` string says so,
  and the ADOPTED branch is demonstrated on a 60 BPM variant of the SAME truth
  (built in the test, not committed): confidence **0.993100**, bar error
  **18.3 ms**, before **0.615385** → after **1.000000** ⇒ **used = TRUE**,
  687/688 frames (one boundary frame flips at that tempo — the measured
  number). If the C-14 gate should see the 688-vs-672 frame improvement rather
  than the coarse Dice agreement, that is a CONTRACT question for Leto — I did
  not touch CONTRACTS.md (v1.1.1 stands, D-52 §6). **THE P-306 NOTE (the brief
  requires it explicit): I did NOT add the new score fixture as a third
  part-aware input to `bench_v2.py` — that file and the bench-v2 job are
  LETO's on main; the fixture is committed and deterministic, so it is a
  one-file change in Leto's lane whenever wanted.** **TOUCHED ONLY MY LANE:**
  Engine/**, Tests/Spikes/Fixtures/**, scripts/fixtures/**, Docs/ENGINE.md
  (§1.7 + the v1.10 row), my QUEUE section + the BLOCKED bullet. No
  CONTRACTS.md, no DECISIONS.md, no .github/**, no Jess files, no main.
  **CI:** run 46060847003@9438212 in flight at DONE time (the WIP files' run
  46055748633@bd4b5a5 was GREEN); a red run becomes a FIX task, nothing here
  waits on it (AGENTS §5). **STILL OPEN:** J-406 (Jess's typealias
  migration), the M4 merge (Leto), the bar map's single-time-scale limitation
  (stated in the aligner header + ENGINE.md §1.7), and the standing honesty
  boundary: the score encodes the truth, so the numbers measure the MECHANISM
  — no real acapella recording exists in the repo (licensing), so NO
  real-world number is claimed.
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
