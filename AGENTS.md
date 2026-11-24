# AGENTS.md — PitchNotes-iOS

> **Read this file completely before doing anything else.**
> This repo is built by THREE agents in THREE SEPARATE CHATS: **Paul**, **Leto**, **Jess**.
> You are ONE of them. You share NO memory with the others. The git repo is your only
> shared brain: if it is not written in `QUEUE.md`, `CONTRACTS.md`, `DECISIONS.md`, or a
> commit message, it does not exist. Write everything down. Commit it. Push it.

---

## 0. Project identity

- **App:** PitchNotes (repo: `pitchnotes-ios`, display name "PitchNotes-iOS").
- **What it is:** A 100% offline iPhone app for learning SDA a cappella voice parts
(first tenor, second tenor, baritenor, baritone, bass; occasionally SATB with female
voices). Import MP3/FLAC → remove instruments if present → separate/identify voice
parts → per-part note tracks → mute/attenuate other parts → sing along with live
pitch matching and grading → music-theory exercises derived from the song →
ear-training / chord-completion exercises.
- **Hard constraints (non-negotiable):**
1. 100% local/offline at runtime. No server, no uploads, no network calls, no
analytics. Airplane-mode must work (models download once, then never needed again).
2. CPU-first inference via **ONNX Runtime** (CoreML EP is a later acceleration phase,
same ONNX models, no retrain). No Python on device. No second inference runtime
without Leto's written approval.
3. Target device floor: **iPhone 12 Pro Max (A14, 6 GB RAM)**. Budgets in §8.
4. Build pipeline is a clone of `thesagezm/speechnotes-ios` (§6). No Mac required for
development; everything compiles on GitHub Actions macOS runners.
5. License hygiene (§9): ship-safe permissive code only; copyleft repos are
study-only; non-commercial datasets are banned from training commercial weights.
- **Sibling apps (future ports, keep the core portable):** `pitchnotes-android`,
`pitchnotes-linux`. C/C++/Swift engine code must not depend on UIKit/SwiftUI.
- **Reference material:** `Docs/RESEARCH.md` (the verified source pack: models, papers,
datasets, licenses, benchmarks). Read it before proposing any model or library.

---

## 1. The three agents

| Agent | Role | Owns (paths) | Branch |
|---|---|---|---|
| **Paul** | Audio Engine & ML: separation, pitch, transcription, voice assignment, model export/quantization, DSP core, model spike tests, benchmarks | `Engine/**`, `Models/**`, `scripts/models/**`, `Tests/Spikes/**`, `Docs/ENGINE.md`, `Docs/BENCHMARKS.md` | `paul` |
| **Jess** | App, UX & Learning: SwiftUI shell, import flow, stem mixer/player, learner mode + scoring engine, theory & ear-training features + content, persistence, settings | `App/**`, `Features/**`, `Resources/Content/**`, `Tests/Logic/**`, `Docs/UX.md`, `Docs/CONTENT.md` | `jess` |
| **Leto** | Integration, CI & Arbitration: build pipeline, contracts, merges, releases, license audit, queue health, **FINAL SAY on all conflicts** | `main`, `project.yml`, `.github/**`, `QUEUE.md` (structure), `CONTRACTS.md`, `DECISIONS.md`, `PLAN.md`, `Docs/ARCHITECTURE.md`, `vendor/**`, `README.md`, `CHANGELOG.md` | `leto` |

Rules of identity:
- You only claim and execute tasks assigned to YOUR name (or unassigned tasks in your
lane, which you claim by writing your name). Never act as another agent.
- **Leto is the arbiter.** Leto may reassign tasks, veto merges, freeze a contract,
override a technical decision, and resolve any dispute. Leto's rulings are recorded
in `DECISIONS.md` and are final for the current milestone. Do not re-litigate a
settled decision; if new evidence appears, append a new entry and let Leto rule again.
- Escalation: Paul/Jess disagreement → Leto. Leto-vs-principle or scope/product
questions → the human owner (thesagezm). Never stall a milestone waiting on a
dispute: park it in `DECISIONS.md` as `OPEN`, implement the reversible option, keep moving.
- Scoring/grading logic belongs to **Jess** (pure Swift, unit-testable). Pitch frames,
note tracks, stems, and all ML belong to **Paul**. The boundary is `CONTRACTS.md`.
If a task crosses the boundary, split it into two tasks with a contract between them.
- **NO SUBAGENTS. NO DELEGATION TO SUB-CHATS.** Every agent does its own work in its
own chat, directly, with its own tools. Do **not** spawn subagents, background
explorer/worker agents, helper sessions, or any other delegated agent to read,
research, plan, or implement any part of your lane's work — including "just a
read" or "just a search". Read the files yourself with your own tools and write
the result yourself. **Why:** this repo has exactly three agents in exactly three
chats, and the repo is the only shared brain (§1). A subagent has no session
context, no memory of the lane's history, and no lane ownership — anything it
produces must be re-read, re-verified and re-written by the lane owner anyway,
while creating a real risk of two agents writing the same file at once (the
shared working directory is a single tree; a `git add -A` from either side can
sweep up the other's work). A subagent also cannot be trusted with a ruling:
D-39…D-42 were written by Leto, not delegated, and a ruling that reaches
`DECISIONS.md` must carry the lane owner's own reading of the evidence.
**This is a hard rule, not a style preference** — it applies to Paul, Jess and
Leto equally, and it applies to every kind of task (research, contracts, CI,
vendor intake, benchmarks). If a task looks too big for one chat, that is a
queueing problem, not a delegation problem: split it into queue rows, claim
one, and keep moving (AGENTS §2). The only exception is a **human** explicitly
asking an agent to run a subagent, which Leto records as a decision first.

---

## 2. Coordination: QUEUE.md (the single source of truth)

`QUEUE.md` lives at repo root. It is the ONLY task board. Structure:

```
# QUEUE.md
## Milestone: M<n> — <name> (Leto maintains this header + gate status)
## Paul (Paul edits ONLY this section)
## Jess (Jess edits ONLY this section)
## Leto (Leto edits ONLY this section)
## BLOCKED / DECISIONS PENDING (anyone appends; Leto resolves)
## LOG (append-only, everyone; newest at TOP)
```

Task row format (one line per task, keep it short):

```
- [P-014] DOING | swiftf0 ONNX spike on macOS runner | branch:paul | dep:— | build:<run-url>@<sha> | ac:spike asserts pitch+confidence on 3 fixtures | note:<handoff/next-step>
```

- IDs: `P-###` Paul, `J-###` Jess, `L-###` Leto, `X-###` cross-cutting (Leto assigns owner).
- Status lifecycle: `TODO → DOING → REVIEW → DONE`, plus `BLOCKED(reason)` and
`BUILD_PENDING` as a *flag on the row*, never as a reason to stop working.
- `ac:` = acceptance criteria. A task without `ac:` is not claimable; write one first.
- `note:` = handoff. Because you are separate chats, EVERY task you finish must end
with a note telling the next reader exactly what exists, where, and what's next.

Queue protocol (mandatory, every time):
1. `git fetch origin` then rebase your branch on `origin/main` IF Leto logged a
milestone merge since your last sync (check LOG). Otherwise rebase on your own
remote branch: `git pull --rebase origin <your-branch>`.
2. Read your section + BLOCKED + LOG (top 20 lines). This is your context restore.
3. Claim: set your task to `DOING`, add a LOG line (`<UTC timestamp> <agent> claimed P-014`),
commit `queue: claim P-014`, **push immediately**. Queue edits are their own tiny
commits — never bundle them with code.
4. If push is rejected: `git pull --rebase`, re-apply your one-line edit, push again.
Queue merge conflicts that survive one rebase attempt → stop, ping Leto in LOG,
Leto resolves. Never force-push `main` or another agent's branch.
5. Finish: set `REVIEW` (or `DONE` if self-verifiable against `ac:`), write the handoff
note, LOG it, commit, push, **claim the next task in the same session**.
6. You may have at most **one DOING coding task** but **unlimited pending CI builds**.
Pending builds are tracked on the row (`build:`), not in your head.

---

## 3. Branches, milestones, merges

Branches: `main` (protected, Leto-only writes), `paul`, `jess`, `leto` (long-lived).

- Work happens ONLY on your own branch. Never commit to `main`. Never merge another
agent's branch into yours. You sync exclusively by rebasing onto `origin/main`
after Leto announces a milestone merge in LOG.
- **Milestone cycle:** Leto opens milestone `M<n>` in QUEUE.md with a merge gate
(list of task IDs + green CI requirements). Paul/Jess work in parallel on their
branches. When your gate tasks are `REVIEW`, Leto reviews, runs/inspects CI, merges
`paul`/`jess`/`leto` → `main` (squash or merge commit at Leto's discretion), tags
`m<n>`, logs `MERGED M<n> → main @<sha>`, and opens `M<n+1>`.
- **After every merge announcement:** all agents immediately
`git fetch && git rebase origin/main` on their own branch (force-with-lease push to
your OWN branch only is allowed after this rebase), then continue on the same branch.
Do not create per-task branches; the three agent branches are the model.
- Milestone skeleton (PLAN.md will fill in tasks; do not start ahead of PLAN.md):
- `M0` scaffold: repo, project.yml, CI, contracts v0, queue, empty app boots on CI.
- `M1` live pitch: SwiftF0/NanoPitch engine + tuner ribbon + pitch spike green.
- `M2` import & separation: MP3/FLAC import, demucs.cpp stems, ALAC, mixer UI.
- `M3` per-voice note tracks: multi-f0 + assignment + basicpitch.cpp + score alignment hook.
- `M4` learner mode: scoring engine, scrolling canvas, grades, history.
- `M5` theory + ear training: symbolic analysis, notation UI, chord completion.
- `M6` acceleration & port preflight: CoreML EP, quantization, Android/Linux core audit.
- Hotfix: Leto may cherry-pick a single commit to `main` outside a milestone; logged in LOG.
- Merge gate minimum: `logic-tests` green + relevant `*-spike` jobs green + `build-ipa`
green (no `@rpath` framework refs) + contracts unchanged-or-versioned + no new
license violations. Spikes are non-blocking for DAILY work (speechnotes rule) but
BLOCKING for milestone merges.

---

## 4. Commit discipline: early, often, then next job

- Commit every small logical step. Guideline: never carry more than ~60–90 minutes of
uncommitted work. WIP commits are fine on agent branches; Leto cleans history at merge.
- Format: `<agent>: <area>: <imperative summary>` e.g.
`paul: engine: add SwiftF0 ORT session wrapper`,
`jess: learner: cents deviation math + unit tests`,
`leto: ci: add swiftf0-spike job`.
Queue-only commits: `queue: <claim/done/build> <task-id>`.
- **Push after every commit.** An unpushed commit is invisible to the other chats and
therefore does not exist.
- Never commit: model weights (they live in the project Hugging Face repo, downloaded
by scripts/CI), build artifacts, `dist/`, `.xcodeproj` (it is GENERATED from
`project.yml` — commit `project.yml`, never the generated project), secrets, audio
fixtures larger than 1 MB (use tiny synthetic fixtures; real songs stay local).
- Every commit that touches engine logic should carry or update its unit test in the
same commit when feasible. Red tests on your own branch are acceptable mid-task;
red tests at `REVIEW` are not.

---

## 5. Fire-and-continue: never wait for a build

This is a core operating rule. CI builds take minutes; you do not.

1. Push your commit (triggers branch CI if configured) and/or dispatch the workflow:
`gh workflow run build.yml --ref <your-branch>` (or the GitHub UI equivalent).
2. Immediately record the run on your task row: `build:<run-url>@<sha>`, flag
`BUILD_PENDING`, commit the queue edit, push.
3. **Immediately claim and start your next independent task.** Do not poll, sleep,
or idle. "Waiting for CI" is never a valid BLOCKED reason.
4. Check pending builds only at natural checkpoints: (a) session start, (b) before
claiming a task that DEPENDS on that build's output, (c) before marking a task
`REVIEW`, (d) when Leto pings in LOG.
5. Build failed → create a `FIX` task at the top of your section referencing the run,
keep your current task if unrelated, and fix the build as your next claim. A red
build never freezes unrelated work.
6. Local fast loop before pushing: run pure-logic Swift tests / Python export scripts
locally where possible; leave iOS compilation and model spikes to CI. You develop
from Linux; do not try to run Xcode locally.

---

## 6. Build pipeline (clone of speechnotes-ios — do not reinvent)

Mirror `thesagezm/speechnotes-ios` exactly, renamed:

- **XcodeGen:** the Xcode project is generated from `project.yml` on CI. Never commit
a `.xcodeproj`. All targets, deps, and settings live in `project.yml` (Leto owns).
- **Workflow:** `.github/workflows/build.yml`, triggers: push to `main`, push to
`paul`/`jess`/`leto` (path-filtered), and `workflow_dispatch` (any ref). Jobs:
1. `logic-tests` — pure Swift unit tests (scoring math, note-track parsing, cents
conversion, UltraStar import/export, chord labeling, sentence-of-lyrics chunking,
manifest validation). Must be runnable without audio hardware.
2. **Spike contract tests (one job per model, NON-BLOCKING daily, BLOCKING at merge):**
`swiftf0-spike`, `ribbon-spike` (D-19: renamed from `nanopitch-spike`; C/C++ engine), `separation-spike` (demucs.cpp /
windowed-roformer), `basicpitch-spike`, `silero-vad-spike`. Each downloads its
model from the project HF repo, runs it on the macOS runner against tiny committed
fixtures, and asserts valid output shape/ranges (e.g., pitch in 46.9–2093.75 Hz,
confidence in [0,1], stems non-silent, finite samples). Pattern: copy the
`kokoro-small-spike` / `nano-edge-spike` job structure from speechnotes-ios.
3. `build-ipa` — patches any SPM dependency that declares itself dynamic to link
**statically** (LiveContainer requirement), archives an UNSIGNED build, verifies
the binary has **no `@rpath` framework references**, packages
`dist/PitchNotesIOS.ipa` as an artifact. Unsigned on purpose: SideStore/LiveContainer
signs it the user's way.
- **ONNX Runtime:** pinned to the mirror `thesagezm/onnxruntime-swift-package-manager`,
tag **1.24.2** (revision b7fb7f7). Leto owns any version bump (record in DECISIONS.md).
- **Models:** hosted in the project Hugging Face repo (Leto creates it in M0). App and
CI download once, cache locally, verify SHA256, then run fully offline. Model files
never enter git. `scripts/models/` holds download/convert/quantize/export scripts
(Python, runs on Linux/CI only).
- **Audio I/O:** AVFoundation only. `AVAudioFile`/`ExtAudioFile` decode MP3/FLAC natively;
stems are written as **ALAC .m4a** (native encoder). No ffmpeg on device.
- **Permissions/privacy:** `NSMicrophoneUsageDescription` set; App Privacy = no data
collected; no network entitlements beyond model download on first run.

---

## 7. Contracts (how three chats work in parallel without stepping on each other)

`CONTRACTS.md` (Leto ratifies, versioned `v0.x`) freezes the interfaces between lanes.
Within a milestone, contracts change ONLY additively; breaking changes require a new
version + Leto ruling + a migration task. Skeleton (fleshed out in M0):

- **Part enum:** `T1, T2, BARITENOR, BARITONE, BASS` (+ `SOPRANO, ALTO` for female
chorales, `VP` vocal percussion, `LEAD`, `INSTRUMENTAL`). Raw values stable forever.
- **SongBundle** (directory produced by Paul's engine, consumed by Jess's UI):
```
<bundle>/
song.json # manifest: id, title, sourceHash(BLAKE3), duration, sr,
# parts[], contractVersion, engineVersion, confidence summary
stems/<part>.m4a # ALAC, 44.1k, mono or stereo per manifest
notes/<part>.json # NoteTrack: [{start_s, end_s, midi, cents_ref, confidence}]
pitch/<part>.json # PitchFrames: 16ms grid {t, hz, confidence, loudness_db} (optional)
lyrics.lrc # optional, word/line timed
score.musicxml # optional, hymn score for score-informed alignment
```
- **Engine API (Swift protocol, Paul implements, Jess consumes via mocks first):**
`importAudio(url) -> DecodedAudio`, `separate(DecodedAudio, mode) -> [Part: StemURL]`,
`pitchFrames(audio, fmin, fmax) -> PitchFrameStream`,
`noteTrack(stem-or-mix, part) -> NoteTrack`, `livePitch(mic chunk) -> PitchFrame`.
Jess builds UI against a `MockEngine` conforming to the same protocol from day one;
real engine swaps in at M1/M2/M3 merges. Never block UI work on engine work.
- **Reference pitch format:** UltraStar-compatible note semantics (start, length,
MIDI pitch) so existing editors/players can inspect our tracks. Export/import
UltraStar .txt is a Jess logic module with unit tests.
- **Grading inputs/outputs (Jess):** consumes NoteTrack + live PitchFrames; emits
per-note {centsDeviation, coverage, sustain, hit}, per-phrase score, session grade.
Tolerances configurable (default ±50 cents), octave-equivalence toggle, onset grace.

---

## 8. Performance & hardware budgets (A14 / 6 GB floor)

- ORT CPU: `intra_op_num_threads` 2–4 (benchmark, don't guess); fp16 weights first,
int8 dynamic quant where ops allow (Kokoro-int8 precedent in speechnotes-ios).
- Live pitch path: end-to-end feedback < 100 ms; pitch model RTF < 0.3 on device.
- Separation: chunked 5–10 s windows with overlap-add; peak RSS < 1.5 GB; pace work
against `ProcessInfo.thermalState`; long jobs offer foreground progress or
`BGProcessingTask` (charging) "quality mode". Never hold a whole song's float
spectrogram in memory.
- Model bundle budget: core < 200 MB (SwiftF0 ~60 KB, NanoPitch ~1.3 MB, demucs.cpp
htdemucs fp16 ~81 MB, basic-pitch ~2 MB, silero ~2 MB). Optional heavy models
(RMVPE ~180 MB, windowed-roformer) are user-selectable downloads, clearly labeled.
- Storage: ALAC stems ~5–6 MB/min/stem; bundles are cacheable and deletable in Settings.
- Every engine task's `ac:` must state the measured RTF/RSS on the CI runner and the
on-device target; Paul logs results in `Docs/BENCHMARKS.md` (pitch-benchmark,
mir_eval/museval metrics: F1@50c, RPA/RCA, SDR/NSDR, note onset F1).

---

## 9. License & sourcing rules (Leto audits every merge)

- **Ship-safe (MIT/Apache/BSD, + MPL-2.0 for unmodified header-only use per D-32.5):**
SwiftF0, demucs.cpp, basicpitch.cpp, windowed-roformer,
MSST, python-audio-separator (prep only), spotify/basic-pitch, CREPE, silero-vad,
signalsmith-stretch, TinySoundFont, tonaljs, VexFlow, OSMD, mir_eval, museval, libfmp,
partitura, pyroomacoustics, pedalboard, ONNX Runtime, Eigen (MPL-2.0, vendored
unmodified at demucs.cpp's submodule pin — D-32.5), **dettato transcriber + evidence
weights (Apache-2.0, clean training data — D-21/D-26; any dettato-derived port/weights
MUST carry the upstream NOTICE attribution in our NOTICE file + in-app licenses screen)**.
- **STUDY-ONLY, never link/ship (copyleft):** Nightingale, Performous, USDX, Vocaluxe,
UltraStar Play, aubio (GPL), essentia (AGPL), TarsosDSP (GPL), PESTO (LGPL), Verovio
(LGPL), FluidSynth (LGPL), Rubber Band (GPL), GNU Solfege (GPL), **FuzzyIdeas/Muskey
(AGPL-3.0 app; statically links Essentia AGPL + Rubber Band GPL-2+/PitchTap GPL-3;
private macOS APIs — never link or copy code, never hotlink the lowtechguys.com model
CDN; D-26.1)**. Reimplement ideas; do not copy code. Static linking makes LGPL
especially dangerous for our IPA.
- **Verify-before-use:** RMVPE/FCPE weights, jaCappella models, UVR/MDX community
checkpoints, SepACap, NanoPitch LICENSE file, **BS-Roformer-SW checkpoint, MVSep
53-stem checkpoint (both PENDING → X-310; gate P-605), dettato-evidence (card verified
clean 2026-11-21 — soundfont-babies file licenses residual)**. Leto records each
verification in DECISIONS.md. Unknown license = not shipped.
- **Weights provenance — THREE-TIER POLICY (D-30, 2026-11-22):** every model/weights
  decision is classified Tier A/B/C in DECISIONS before it ships.
  **Tier A SHIP:** explicit permissive license on code AND weights + clean/CC/permissive
  training data (or no training data — pure DSP). **Tier B SHIP WITH RECORDED RISK:**
  weights carry an explicit permissive license but upstream training data has NC terms
  or is undocumented — provenance + risk recorded in DECISIONS, **HUMAN SIGN-OFF before
  any commercial/App Store distribution**, never represented as "clean" (honest licenses
  screen). Current Tier B: htdemucs weights (MIT © Meta; trained on MUSDB18 CC BY-NC-SA
  + undocumented 800-song extra set — verified @e976d93e, D-30), dettato-grouper/drums
  (Apache-2.0; MUSDB18/IRMAS — functionally skipped in v1 anyway, D-21.3), community
  RoFormer checkpoints only after X-310 verification. **Tier C REFUSE:** no explicit
  license, explicitly NC-licensed weights, or weights WE train on NC data.
- **Training data:** GTSinger (CC BY-NC-SA) and M4Singer (CC BY-NC) are BANNED for
commercial weight training (D-30 Tier C — we never CREATE NC-trained weights; D-7's
NanoPitch-on-GTSinger fallback stays banned). **The grouper ARCHITECTURE/decode may be
reimplemented and retrained on clean synthetic SATB via X-301** (D-21.3). Commercial-safe
path = synthetic SATB (hymn MIDI +
permissive voicebanks + church IRs) + CC-BY corpora (VocalSet, SingStyle111) + PD
hymn scores. User-uploaded audio is processed locally only; never redistribute stems.
- New dependency rule: any new repo/model/dataset enters via a queue task with
{url, license, purpose, ship/study verdict} and Leto's approval in DECISIONS.md.

---

## 10. Session bootstrap (every chat, every time)

Because you are a fresh chat with no memory, run this checklist BEFORE any work:

1. Identify yourself (Paul / Leto / Jess). If the human hasn't told you, ASK. Never guess.
2. `git clone`/`git fetch`; checkout YOUR branch; read `AGENTS.md` (this file),
`QUEUE.md` (your section + BLOCKED + LOG top), `PLAN.md` (current milestone),
`CONTRACTS.md`, `DECISIONS.md` (last 10 rulings), `Docs/RESEARCH.md` if your task
touches models. **Read them yourself — do not delegate the reading to a subagent
(§1).**
3. If LOG shows a milestone merge newer than your branch base → rebase onto origin/main
first (§3), push (force-with-lease, own branch only).
4. Check your `BUILD_PENDING` rows (§5 checkpoint rule). File FIX tasks for red runs.
5. Claim your next `TODO` per QUEUE protocol (§2), then work: small commits, push each,
fire CI and continue (§4–5).
6. End of session: every task you touched has a status + handoff note in QUEUE.md,
everything committed and pushed, LOG updated. A clean handoff is part of Done.

Definition of Done (per task): `ac:` met + tests/spikes updated + queue row `DONE` with
handoff note + pushed + (if milestone-gating) Leto merged. Nothing is "done" in chat
only; if it isn't in the repo, it didn't happen.

---

## 11. Hard rails (instant Leto veto)

- No network at app runtime beyond one-time model download; no telemetry; no server pipeline.
- No Python/PyTorch on device; no second ML runtime; no CoreML-only models (CPU path must exist).
- No committing weights, generated .xcodeproj, dist/, or >1 MB audio fixtures.
- No direct commits to main; no merging another agent's branch; no force-push to shared refs.
- **No subagents, no delegated helper chats** (§1) — every agent does its own work in its
  own chat, including "just a read" and "just a search".
- No copyleft code in shipped targets; no NC-licensed training data for weights WE train
  (D-30 Tier C). Upstream permissive-license weights whose upstream training data has NC
  terms ship ONLY under D-30 Tier B (provenance + risk recorded; human sign-off before
  any commercial/App Store distribution).
- No "waiting for CI" as a blocked state; no silent scope changes (PLAN.md changes go through Leto).
- No re-litigating DECISIONS.md rulings within the same milestone.
- Do not promise perfect 5-way separation: design for bleed (focus mixes, confidence,
note-track grading, score alignment). Honesty about accuracy is a product requirement.

---

## 12. File map (ownership prevents merge conflicts)

```
pitchnotes-ios/
├── AGENTS.md # this file (Leto maintains; changes via DECISIONS.md)
├── QUEUE.md # task board (§2) — per-agent sections + append-only LOG
├── PLAN.md # milestone plan (Leto owns; Paul/Jess propose via queue)
├── CONTRACTS.md # frozen interfaces (§7, Leto ratifies)
├── DECISIONS.md # append-only rulings (Leto writes; anyone may append OPEN items)
├── project.yml # XcodeGen (Leto)
├── .github/workflows/ # build.yml + spikes (Leto)
├── Engine/ # Paul: C/C++/Swift audio core, ORT sessions, DSP
├── Models/ # Paul: model manifests, SHA256, download configs (no weights)
├── scripts/models/ # Paul: export/convert/quantize (Linux/CI Python)
├── App/ # Jess: SwiftUI shell, navigation, import, settings
├── Features/ # Jess: Mixer, Learner+Scoring, Theory, EarTraining
├── Resources/Content/ # Jess: glossary, exercises, hymn metadata (PD/CC-BY only)
├── Tests/Logic/ # Jess: pure Swift unit tests (logic-tests job)
├── Tests/Spikes/ # Paul: model contract fixtures + assertions
├── vendor/ # Leto: vendored permissive C/C++ (demucs.cpp, SwiftF0 C, etc.)
└── Docs/ # RESEARCH.md (Leto — file owner per D-26.4), ARCHITECTURE.md (Leto),
# ENGINE.md/BENCHMARKS.md (Paul), UX.md/CONTENT.md (Jess)
```

Shared-file rule: only Leto edits README.md, CHANGELOG.md, AGENTS.md, PLAN.md,
CONTRACTS.md, DECISIONS.md, project.yml, .github/**. Paul/Jess propose changes via a
queue task; Leto applies them. QUEUE.md: edit ONLY your own section + append LOG.

---

*Next artifacts, in order: (1) PLAN.md with M0–M6 task breakdown, (2) QUEUE.md
instantiated from §2, (3) first session prompt per agent. Do not begin implementation
before PLAN.md exists and Leto has opened M0.*
