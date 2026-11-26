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

- Status: **CLOSING** (opened 2026-11-24 by Leto at L-204; the close is L-304,
  running under **D-48** — the human's order that Leto finishes M3 itself). **M2
  CLOSED** (the whole M2 stack is on `main`, the M2 gate run was green with all
  8 jobs, contracts were at v1.0.3, `m2` is tagged).
- Contract: **v1.1.1** on `main` (D-47's additive gaps: C-15 `corrections/song.json`,
  C-16 `corrections/score.json`, the C-13.2 optional `partMapping`, C-11's optional
  split confidence, the MusicXML document type + the two exported UTIs in `project.yml`).
- Gate (PLAN.md M3): P-301…P-306, J-301…J-304, L-301…L-304; `basicpitch-spike` green
  AND blocking; `logic-tests` green; `build-ipa` green; BENCHMARKS v2 honest report;
  D10/D12 ruled; `m3` tagged.
- **Honesty rail for this milestone (AGENTS §11 — binding):** heuristic assignment +
  score alignment ship here; fine-tuned per-singer separation is post-v1 (X-301/X-302
  prep only). **Do NOT promise perfect 5-way separation** — design for bleed (focus
  mixes, confidence, note-track grading, score alignment) and say so in the UI.
- **The M2 device demo (L-205) rides along with the M3 one (J-210) — ONE trip, and
  it is NOT RUN.** M2 is NOT device-verified and must never be described as such.
- **THE D-30 TIER B SIGN-OFF IS OUTSTANDING — TWO weight sets only:** `htdemucs`
  (D-30) and the `dettatto` transcriber/evidence weights (D-45). **`nmp.onnx`
  (basic-pitch) IS TIER C (D-46) and NO sign-off can promote it** — MAESTRO +
  MedleyDB-pitch (CC BY-NC-SA 4.0) and iKala (academic-only EULA) were training
  data. That blocks COMMERCIAL DISTRIBUTION only: not the M3 code path, not `m3`,
  not sideloading. **Do not stall on it.**
- **M3 DEVICE DEMO (J-210 / L-205) — HUMAN, NOT RUN.** It needs an iPhone 12 Pro
  Max, the 84 MB `htdemucs` weights and a human: real SDA FLAC import → staged
  progress → cancel leaves NO partial bundle → re-import → VOCALS/INSTRUMENTAL →
  mixer (solo / focus mix / mute / fader glide) → seek + region loop → a detuned
  recording shows the tuning offset AND the ribbon reference adjusts → the 5-part
  roll with confidence shading → correct a note → import a hymn MusicXML →
  alignment improves → export UltraStar `.txt` → **play it in an external
  UltraStar-family player** → storage + delete → airplane mode AFTER the one-time
  model download. **LOG THE DEVICE RTF / PEAK RSS / THERMAL — the only source of
  AGENTS §8's device numbers.** If the human does not run it, **waive it
  explicitly** (D-48 §4) — never let it pass silently.

### M3 gate checklist — row → evidence (Leto keeps this current)

| row | status | evidence |
|---|---|---|
| P-301 basicpitch.cpp + the REAL spike | merged (paul) | `basicpitch-spike` real, 24 checks — run 45513314284@426dd45 (Paul's row) |
| P-302 multi-f0 salience | merged (paul) | local EngineCore 245/245 (Paul's row) |
| P-303 voice assignment engine | **code merged; the SWIFT TEST is the last leg** | Paul's measurement 344/344 frames, macro part accuracy 1.000 (his Python mirror + the committed artifact) |
| P-304 MusicXML parser + DTW | **WAIVED — explicitly** (see below) | Jess's consumer side is in and ships the honest "parser not in this build" state |
| P-305 NoteTrack v1.1 metadata + cross-check | merged (paul) | the cross-check artifact + its Swift mirror test |
| P-306 bench v2 (the honest report) | **DOING — Leto under D-48** | the `bench-v2` CI job exists and is RED BY DESIGN until the harness lands |
| J-301 per-part piano roll | merged (jess) | run 45893306197@c944d79 (logic-tests + build-ipa green) |
| J-302 calibration + correction overlay | merged (jess) | + D-47's device-local nudge (J-302 in Jess's lane, under D-48) |
| J-303 UltraStar codec | merged (jess) | the round-trip unit tests are in the green run |
| J-304 score review UI | merged (jess) | the CONSUMER side; its engine side (P-304) is waived |
| L-301 contract v1.1 | DONE | CONTRACTS v1.1.1 on `main` (D-47) |
| L-302 CI (the real basicpitch job + bench v2) | DONE | both jobs exist; the REAL runner + the harness land with P-301/P-306 |
| L-303 D10 / D12 / the score-alignment reading | DONE | D-39, D-40, D-41, D-42 in DECISIONS.md |
| L-304 the M3 close | DOING | this session: merge → gate run → tag `m3` → open M4 |

### M3 explicit waivers (D-48 §5 — a waiver is NEVER a silent scope drop)

- **[P-304] WAIVED — the MusicXML PARSER + DTW ALIGNER (the engine side of score
  alignment) does NOT ship in M3.** Jess's J-304 consumer ships the honest
  `ScoreImportError.parserUnavailable` state, so the no-score path is unaffected and
  **nothing claims that score alignment works**. **CARRIED INTO M4** (it stays on
  the board as an open P-304 row — it is NOT dropped).
  **Why:** the M3 window is the human's D-48 close-out; a parser + DTW aligner
  landed blind (no local Swift toolchain, CI-only verification) would put an
  unverified feature into the milestone rather than an honest gap. The M3 claim is
  therefore **"per-part note tracks + the salience + the correction overlay"** — and
  **NOT** "score alignment works" and **NOT** "perfect 5-way separation".

---

## Milestone: M4 — Learner Mode & Grading (opens at the `m3` tag)

- **NOT OPEN YET.** It opens when L-304 tags `m3` after the green gate run. Jess
  withdrew her premature J-401 claim for exactly this reason. **M4's board is
  seeded from PLAN.md's M4 table verbatim (J-401…J-405, P-401…P-403, L-401…L-403).**

---

## Paul (Paul edits ONLY this section)

_— M0/M1/M2 rows are closed: see `Docs/QUEUE-ARCHIVE.md` (search by task ID) —_

- [P-301] DONE (merged to `main`) | basicpitch.cpp (MIT, sevagh) vendored + the REAL spike runner + the manifest entry + the mono/poly fixtures | branch:paul | dep:P-204,L-008 | build:45513314284@426dd45 (the real job, 24 checks) | ac:`basicpitch-spike` green on mono+poly synthetic fixtures; onset/offset within 50 ms; RTF logged | note:the code + the REAL runner are on `origin/paul`; the manifest entry carries D-46's TIER C wording
- [P-302] DONE (merged to `main`) | Multi-f0 salience: the per-frame pitch posterior + the peak picker + the C ABI's salience output + the five-voice SATB fixture | branch:paul | dep:P-301 | build:local EngineCore 245/245 | ac:synthetic SATB fixture shows 3–5 peaks; peak-picking unit test | note:the peak options are `minimum_salience 0.3`, local-max window 2 semitones
- [P-303] DOING (Leto under D-48) | Voice assignment engine: the frame DP + the no-crossing ordering + the subset handling + the unison rule + the temporal beam Viterbi + D-41 §1's confidence | branch:paul | dep:P-302,P-105 | build:45897044406@4c77d52 (the fixture fix, in flight) | ac:≥70 % of the frames correctly assigned on the clean synthetic fixture (Paul measured 344/344 = 1.000); the Swift test asserts the Swift engine agrees with the committed Python mirror | note:PAUL'S CODE IS LANDED @23f7a14 (VoiceAssignment.swift, 820 lines) + the committed artifact `Tests/Spikes/Fixtures/assignment_satb5.json`. **THE MISSING PIECE WAS THE FIXTURE, NOT THE CODE** — `satb5_prog_22050.wav` was registered in `gen.py` but never committed, so the fixture-integrity preflight failed EVERY spike job (runs 45884541092 + 45890555205). **LETO GENERATED AND COMMITTED IT UNDER D-48 @4c77d52** (352,844 B, sha 5ea7b042…, `gen.py --check` exits 0). **PAUL: `git pull --rebase origin paul` — your branch has Leto's commit on top.**
- [P-304] WAIVED (explicit, D-48 §5) → CARRIED INTO M4 | Score-informed alignment hook: the MusicXML parser + the DTW aligner + the `score.musicxml` bundle entry | branch:paul | dep:P-303,L-303 | ac:synthetic score+audio aligns ≤50 ms; alignment improves assignment on synthetic | note:**NOT IN M3** — the engine side of score alignment does not ship; Jess's consumer shows the honest "parser not in this build" state; **the row stays OPEN and moves to M4**; **nothing claims score alignment works**
- [P-305] DONE (merged to `main`) | NoteTrack v1.1 metadata: the per-note confidence, the part-presence, the unison flags, the engineVersion + the V16/V17/V18 validators + the SwiftF0 cross-check | branch:paul | dep:P-301,P-101 | build:the cross-check artifact + its Swift mirror test | ac:schema v1.1 ratified; the cross-check metric logged | note:the artifact `crosscheck_swiftf0_vs_basicpitch.json` carries the measured disagreement per fixture
- [P-306] DOING (Leto under D-48) | Benchmark harness v2: the note onset/offset F1, the part-aware macro F1 (PawCT-style), the multi-f0 P/R/F1 → the BENCHMARKS v2 honest report | branch:main (Leto's D-48 work) | dep:P-303,P-304 | ac:the report committed; the real part-aware F1 stated WITHOUT overclaim; the part-AGNOSTIC and the part-AWARE metrics reported SEPARATELY, citing dettato's Dagstuhl ChoirSet row (onset 55.9 / frame 82.0 / offset 44.4) as the external part-agnostic reference | note:**the `bench-v2` CI job ALREADY EXISTS and is RED BY DESIGN until the harness lands** — it is the last M3 gate leg; **the harness MUST write `Tests/Spikes/bench_report_v2.json` with a part-agnostic AND a part-aware section**
- [P-307] TODO (M4/M6 seed, non-gating for M3) | Port dettato transcriber to ONNX+Swift — Apache-2.0 CODE, TIER B WEIGHTS (D-45): ship only with the recorded risk + the human sign-off, NEVER described as clean | branch:paul | dep:P-301,P-208 | ac:parity within the documented tolerance; the benchmark report committed; the RTF/RSS logged honestly | note:D-45's soundfont-provenance caveat is binding; the grouper/drums weights are NC and banned
- [P-308] TODO (seed) | Retune-before-transcribe (D-22): consume `tuning_cents`; retune IN MEMORY only; the stored audio is never mutated | branch:paul | dep:P-207,P-307 | ac:a detuned synthetic (±35c) transcribes at ≈true-pitch quality; the times map back within tolerance
- [P-309] TODO (seed, license-gated on X-310) | The evidence-repairer-style note repair, ELSE the grouper-decode cleanup heuristics (drop low-confidence notes, fix the boundaries, merge the same-pitch notes within 30 ms) | branch:paul | dep:P-307,X-310 | ac:the repair improves the onset/offset F1 on synthetic; the fallback ships regardless of X-310
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
- [J-210] TODO (HUMAN — rides with L-205's ONE device trip) | **THE M3 DEVICE DEMO CHECKLIST — the same device, the same weights, one trip.** The human runs it on an iPhone 12 Pro Max with the `htdemucs` weights and logs the result IN THIS ROW, verbatim: real SDA FLAC import → staged progress → cancel leaves NO partial bundle → re-import → VOCALS/INSTRUMENTAL → mixer (solo / focus mix / mute / fader glide) → seek + region loop → a detuned recording shows the tuning offset AND the ribbon reference adjusts → the 5-part roll with confidence shading → correct a note → import a hymn MusicXML → alignment improves → export UltraStar `.txt` → **play it in an external UltraStar-family player** → storage + delete → airplane mode AFTER the one-time model download. **LOG THE DEVICE RTF / PEAK RSS / THERMAL.** | ac:the checklist is walked end-to-end ON THE DEVICE, the honest assignment quality is recorded, and the device numbers are in the row | note:**NOT RUN. M2 is NOT device-verified and must never be described as such.** If the human does not run it, waive it EXPLICITLY (D-48 §4)

---

## Leto (Leto edits ONLY this section)

_— M0/M1/M2 rows are closed: see `Docs/QUEUE-ARCHIVE.md` (search by task ID) —_

- [L-205] TODO (HUMAN — carried from M2 by D-38) | **THE M2 DEVICE DEMO (UX §10.2) — DEFERRED to M3, NOT DONE.** It rides with J-210's ONE trip; the human logs the result in this row | ac:the checklist is walked on the device; the device RTF/RSS/thermal are logged | note:**NOT RUN — M2 is NOT device-verified**
- [L-301] DONE | Contract v1.1 (the additive NoteTrack metadata + the correction overlay + the optional salience) | branch:leto | dep:P-305 | ac:ratified; both lanes ack | ac-met:**v1.1 ratified @cd909c6 (D-44) and then v1.1.1 by D-47 (the additive C-15/C-16/C-13.2/C-11 gaps + the MusicXML UTI) — both on `main`**
- [L-302] DONE | CI: the `basicpitch-spike` job REAL + the extended synthetic SATB fixture generator + the `bench-v2` job | branch:leto | dep:P-301,P-001 | ac:green; the fixtures ≤1 MB | ac-met:both jobs exist on `main`; the REAL runner lands with P-301 (the job was RED BY DESIGN until then, which is the designed dependency signal — never a fix task)
- [L-303] DONE | DECISIONS: D10 (the MusicXML parser), D12 (the assignment confidence thresholds), the score alignment is OPTIONAL-not-required for grading | branch:leto | dep:— | ac:the rulings recorded in DECISIONS.md | ac-met:D-39, D-40, D-41, D-42 recorded
- [L-304] DOING | **THE M3 CLOSE: merge `jess`→`main` + `paul`→`main`; flip `basicpitch-spike` AND `bench-v2` to blocking; finish or explicitly waive P-303/P-304/P-306; fire the gate run; tag `m3`; open M4; seed its board** | branch:leto | dep:all M3 | ac:the gate run is green with ALL the blocking jobs; the `m3` tag exists; the M4 board is seeded in the FRESH `QUEUE.md` | note:running under D-48 (the human's order); the board was ROTATED first (D-49) — the closed M0/M1/M2/M3 history is in `Docs/QUEUE-ARCHIVE.md`, VERBATIM
- [L-211] DOING | **THE M3 CLOSE — under D-48.** Land D-47/D-48 + the MusicXML UTI; merge the two lanes; flip the two CI jobs to blocking; finish or explicitly waive the remaining M3 rows VISIBLY; fire the gate run; tag `m3`; open M4 + seed its board | branch:leto | dep:— | ac:all of L-304 | note:superseded in practice by L-304 (the same work, the same session) — kept as the umbrella row so the D-48 deviation stays findable
- [X-302] TODO (STRETCH, non-gating) | The per-singer model evaluation memo (SepACap / jaCappella MRDST / HTDemucs fine-tune on synthetic data); the license verification; the post-v1 pursue/drop ruling | branch:leto | dep:X-301 | ac:a memo in DECISIONS; no shipping without the license + the benchmark
- [L-602] TODO | **THE APP STORE MEMO — it has a REAL GAP (D-46):** the basic-pitch `nmp.onnx` weights are TIER C ⇒ a commercial build MUST exclude them or name a replacement (the X-301 synthetic-SATB path, or a differently-trained transcription model) | branch:leto | dep:X-217,D-46 | ac:the memo names the excluded weights or the replacement; it never calls them clean | note:**the Tier B sign-off (htdemucs + dettatto) is a separate, still-outstanding human action**
- [X-214] SEED (owner: paul; non-gating) | The streaming stem writer — the Swift driver still accumulates the blended stems for the whole song in memory | branch:paul | dep:P-202 | ac:the driver streams the blended stems to disk

---

## BLOCKED / DECISIONS PENDING (anyone appends; Leto resolves)

- **THE M3 DEVICE DEMO (L-205 + J-210) — HUMAN, NOT RUN.** It needs an iPhone 12
  Pro Max, the 84 MB `htdemucs` weights and a human. It is the ONLY source of the
  device RTF / peak RSS / thermal numbers (AGENTS §8). **M2 is NOT device-verified.**
  If the human does not run it, **waive it EXPLICITLY** (D-48 §4) — a silent
  omission is not a waiver.
- **THE D-30 TIER B SIGN-OFF — OUTSTANDING, TWO weight sets only:** `htdemucs`
  (D-30) and the `dettatto` transcriber/evidence weights (D-45). **`nmp.onnx`
  (basic-pitch) IS TIER C (D-46) AND CANNOT BE SIGNED OFF** — no sign-off promotes a
  NC-trained weight set; it blocks COMMERCIAL DISTRIBUTION only, not `m3` and not
  sideloading. The in-app licenses screen (J-FIX-105) states the NC provenance and
  NEVER says "clean".
- **[P-304] — WAIVED FOR M3, CARRIED INTO M4** (see the M3 waiver block above). The
  score-alignment ENGINE side does not ship in M3; the row stays open.

---

## LOG (append-only, everyone; newest at TOP)

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
