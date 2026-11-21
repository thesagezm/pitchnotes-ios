# DECISIONS.md — PitchNotes-iOS append-only rulings

> Leto writes rulings; anyone may append `OPEN` items for Leto to resolve (AGENTS.md §1).
> Rulings are final for the current milestone. Do not re-litigate within the same
> milestone; if new evidence appears, append a new entry referencing the old one and
> let Leto rule again. Newest entries at TOP.

Entry format (one `##` block per decision):

```
## D-### | YYYY-MM-DD UTC | <author: Leto for rulings / agent name for OPEN items> | RULED|OPEN
**Context:** ...
**Ruling:** ...        (for RULED)   /   **Question:** ...   (for OPEN)
**Affects:** files / contracts / task IDs
```

---

## D-18 | 2026-11-21 UTC | Leto | RULED
**Context:** L-009 M0 gate wrap-up. Sub-rulings made while completing the merge.
**Ruling:**
1. **L-009 wrap-up commits on `main` are sanctioned** as part of the milestone-merge
   process (scoped D-14 exception): gate-completion edits (rulings, CONTRACTS v0.0.1,
   .gitignore, X-003 wiring, M1 seed, tag LOG) are executed by Leto on `main` during
   L-009 and logged here. Routine lane work still NEVER touches `main` directly.
2. **ORT mirror re-host RATIFIED (amends D-13).** Microsoft's takedown killed
   download.onnxruntime.ai (parked domain, invalid TLS — root cause of Jess's 2× red
   build-ipa, runs 44848300515/44848572134). Per the HUMAN's instruction, Jess
   re-hosted the pod archives as release `1.24.2-binaries` on
   `thesagezm/onnxruntime-swift-package-manager` and re-pointed tag 1.24.2
   (b7fb7f7 → **7dbd851**). Trust evidence: SHA256 of both zips matches the
   pre-takedown manifest exactly (onnxruntime-c `f7100a99…00b54`, 52,138,597 B;
   extensions `346522d1…6b5`, 19,359,053 B) — byte-identity to genuine Microsoft
   artifacts regardless of re-host path. `project.yml` unchanged (same URL/tag). D-13
   recorded rev is now 7dbd851. Note for the human: speechnotes-ios pins the same
   mirror and will hit the same wall at its next session — apply the same fix.
3. **Paul's OPEN filings renumbered (ID collision with Jess's struck X-002/X-003):**
   his "X-002" (NanoPitch provenance) → **X-004**, ruled in D-17; his "X-003"
   (jaCappella MRDLA/XUMX + SepACap memo) → **X-005, consolidated into PLAN X-302**
   with EARLY START allowed (non-gating; research-only until a DECISIONS verdict;
   verdict due before any M3 per-singer integration).
4. **CONTRACTS C-1 clarification adopted as v0.0.1 (doc-only, no raw-value change):**
   numeric `sortOrder` is the canonical UI/display ordering; the prose "bass <
   baritone < …" is VOICE RANK (lowest→highest singable) = descending sortOrder among
   the seven singable voices; P-303's no-crossing constraint uses voice rank. Paul's
   engine implements the switch verbatim; tests cover both readings (his LOG 00:43Z).
5. **P-002 AC completion wiring:** the five frozen spike-stub jobs now invoke
   `python3 Tests/Spikes/run_spike.py --spike <name>` (mock model, no weights) —
   P-002's "runs on CI" AC completes with the wrap-up run. `continue-on-error` stays
   until L-101 makes the real-model spikes blocking at M1.
6. **Device Demo M0 (human, 2026-11-21):** owner reports the sideloaded IPA **installs
   and the app UI boots** on the iPhone 12 Pro Max. Logged as partial demo evidence;
   full UX.md §10 checklist (5-tab inventory, airplane-mode relaunch, inspector) may
   be completed at leisure.
**Affects:** D-13, D-17, X-004/X-005/X-302, CONTRACTS v0.0.1, project.yml, build.yml,
.gitignore, P-002, QUEUE, m0 tag.

## D-17 | 2026-11-21 UTC | Leto | RULED (extends D-7; resolves X-004)
**Context:** Paul's provenance research (P-003): NanoPitch's PRE-TRAINED weights were
trained on GTSinger (CC BY-NC-SA) and FSDNoisy18k — NC-licensed training data. AGENTS
§9 / D-15 ban NC data from commercial weights, so even a permissive CODE license
cannot make the shipped pretrained weights safe.
**Ruling:** Adopted as the M1 plan of record:
1. **v1 DEFAULT causal ribbon = `sevagh/pitch-detection` (MIT, pure-DSP MPM/YIN,
   zero-lag, no training data).** P-102's fallback becomes the default deliverable.
2. **NanoPitch integration is blocked** until BOTH: (a) code LICENSE verified
   ship-safe (D-7), AND (b) weights provenance clean — either a clean retrain on
   permissive data (the small-model retrain in P-102, contingent on verifying the
   license of `smulelabs/NanoPitch-PreExtract` first) or an explicit human ruling.
   GTSinger-trained weights are NEVER shipped (§9/D-15).
3. SwiftF0 (MIT, no encumbered data) remains the grading-grade pitch source
   (P-101/P-105) — unaffected.
4. P-102's AC is amended accordingly: verdict-first, fallback-first.
**Affects:** P-102, P-105, M1 gate, D-7, X-004, Docs/ENGINE.md.

## D-16 | 2026-11-21 UTC | Leto | RULED
**Context:** Jess (J-001/J-002/J-004 REVIEW) reported a CI reachability gap: `build.yml`
exists only on `leto`, so pushes to `paul`/`jess` trigger nothing (workflow file must
exist on the pushed ref) and `workflow_dispatch --ref <branch>` is refused (file must
exist on the default branch). Result: J-001's AC ("app boots to tabs in CI build") is
unsatisfiable until M0 close — a self-blocking gate. Jess requested an early
`leto→main` merge; P-001 (paul) is DONE and blocked on the same gap for its CI run.
**Ruling:**
1. **CI bring-up merge:** Leto merges `leto→main` NOW. Scope is strictly Leto-owned
   infrastructure (project.yml, .github, Tests/Logic package skeleton, Models/,
   scripts/, vendor/, CONTRACTS, governance docs) — NO paul/jess lane content. This is
   NOT the M0 gate: L-009 still merges `paul`/`jess`, reviews the gate, and tags `m0`.
2. **Merge-announcement sync:** all agents rebase onto `origin/main` immediately
   (AGENTS §3). Thereafter their pushes trigger branch CI, and
   `gh workflow run build.yml --ref <branch>` works. Post-rebase, Jess's 53 logic
   tests and shell build get their first CI evidence.
3. **X-001 (part range presets) → ROUTED TO L-102 (contract v0.1, M1):** accepted as
   an ADDITIVE C-1 block; `Docs/UX.md §3.6` (Jess) is the interim source of truth —
   J-101 may implement against it before L-102 ratifies the same table into
   CONTRACTS. Engine-side calibratable consumption is P-105's deliverable.
4. **X-002 STRUCK:** satisfied by P-001's `MockScenario` (exact proposed set as init
   parameter; no frozen surface touched). No contract change.
5. **X-003 (EngineCore wiring) ACCEPTED, executes at L-009 by Leto:** after `paul→main`
   lands `Engine/`, project.yml gains `EngineCore: {path: Engine}` + app-target dep
   (product `EngineCore`), and the `logic-tests` job gains `cd Engine && swift test`
   (Paul's 45 tests move from local-Linux to CI). Jess applies her `Tests/Logic`
   Package.swift edit + swap sequence (delete PreviewStub/**, consume MockEngine, zero
   view changes) on HER branch post-merge — `Engine/` resolves for her only then.
6. **SmokeTests.swift deletion RE-ROUTED to Jess:** after this merge/rebase the file
   exists in her tree (Tests/Logic is her lane) — she deletes it with her suite in
   place; no Leto merge step. (Placeholder deletion by leto first would leave the
   package with zero test sources and fail CI.)
**Affects:** `.github/workflows/build.yml`, `project.yml`, QUEUE, L-009 checklist,
J-001/J-002/J-004 REVIEW evidence, P-002 CI, X-001/X-002/X-003.

## D-15 | 2026-11-20 UTC | Leto | RULED
**Context:** L-007 license audit baseline (AGENTS §9). The AC requires zero
unknown-license dependencies in `project.yml`/`vendor/`.
**Ruling:** Baseline recorded as follows.
- **SHIP-SAFE (MIT/Apache/BSD/Zlib) — may be vendored/linked:** SwiftF0, demucs.cpp,
  basicpitch.cpp, windowed-roformer, MSST, python-audio-separator (prep tooling only,
  never on device), spotify/basic-pitch, CREPE, silero-vad, signalsmith-stretch,
  TinySoundFont, tonaljs, VexFlow, OSMD, mir_eval, museval, libfmp, partitura,
  pyroomacoustics, pedalboard, ONNX Runtime (+ our SPM mirror of it, MIT).
- **STUDY-ONLY — never linked/shipped (copyleft):** Nightingale, Performous, USDX,
  Vocaluxe, UltraStar Play, aubio (GPL), essentia (AGPL), TarsosDSP (GPL), PESTO
  (LGPL), Verovio (LGPL), FluidSynth (LGPL), Rubber Band (GPL), GNU Solfege (GPL).
  Reimplement ideas, never copy code; static linking makes LGPL especially dangerous
  for our IPA.
- **VERIFY-BEFORE-USE (no integration until verdict recorded here):** NanoPitch
  LICENSE → P-102 (fallback: sevagh/pitch-detection MPM/YIN, MIT); soundfont →
  L-501 (D-6); RMVPE/FCPE weights → X-601; jaCappella models, UVR/MDX community
  checkpoints, SepACap → M3+ X-tasks before any use. Unknown license = not shipped.
- **TRAINING DATA:** GTSinger (CC BY-NC-SA) and M4Singer (CC BY-NC) are BANNED from
  commercial weight training. Commercial-safe path = synthetic SATB (PD hymn MIDI +
  permissive voicebanks + church IRs) + CC-BY corpora (VocalSet, SingStyle111) + PD
  hymn scores. User audio is processed locally; stems never redistributed.
- **AUDIT RESULT (M0):** `project.yml` deps = ONNX Runtime mirror (MIT, D-13) +
  PitchLogic (in-house). `vendor/` empty at M0 (intake process = L-008). **Zero
  unknown-license dependencies.** New deps enter ONLY via a queue task with
  {url, license, purpose, ship/study verdict} + a Leto ruling here.
**Affects:** AGENTS §9, `project.yml`, `vendor/**`, P-102, L-501, X-601, X-301/X-302.

## D-14 | 2026-11-20 UTC | Leto | RULED
**Context:** AGENTS §3/§11 forbid direct commits to `main`, but L-001/L-002 (repo init +
governance seeding) need a first push to create the repo baseline; no milestone merge
exists yet to rebase onto.
**Ruling:** Bootstrap exception — Leto commits governance/scaffold files (AGENTS.md,
PLAN.md, Docs/RESEARCH.md, README, .gitignore, QUEUE/DECISIONS/CONTRACTS seeds)
directly to `main` during L-001/L-002 ONLY. After L-002, all Leto work happens on the
`leto` branch; `main` receives writes only via milestone merges (L-009 and successors).
`main` branch protection is BLOCKED(human) (GitHub Pro required for private repos);
procedural rails (AGENTS §3/§11) govern until the human enables protection.
**Affects:** L-001, L-002, L-009, `main`, `.github/**`.

## D-13 | 2026-11-20 UTC | Leto | RULED
**Context:** AGENTS §6 pins inference to the ONNX Runtime SPM mirror.
**Ruling:** Confirmed: ONNX Runtime = `thesagezm/onnxruntime-swift-package-manager`
tag **1.24.2** (rev b7fb7f7), the sole inference runtime for all milestones. CPU-first;
CoreML EP is a later phase (M6) on the SAME ONNX models. Any version bump or second
runtime requires a new DECISIONS ruling by Leto (AGENTS §11).
**Affects:** `project.yml`, `Engine/**`, all P-tasks.

## D-12 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D12)
**Context:** PLAN.md end matter, question: assignment confidence thresholds + score
requirement.
**Ruling:** Part-assignment confidence thresholds are tuned on synthetic fixtures;
score-informed alignment (MusicXML/DTW) is an OPTIONAL accuracy boost — never required
for grading. Grading must work on heuristic NoteTracks alone.
**Affects:** P-303, P-304, J-401, L-303, CONTRACTS C-5.

## D-11 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D11)
**Context:** PLAN.md end matter, question: beat estimator + content policy.
**Ruling:** Beat/tempo estimation = simple Swift spectral-flux/autocorrelation (avoid
GPL madmom; any candidate third party needs license verification first). BarbershopTags
= LINK-OUT unless license verified for intake. Content = PD / CC-BY / in-house only;
no copyrighted hymnal scans in git.
**Affects:** P-503, J-505, L-501, `Resources/Content/**`.

## D-10 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D10)
**Context:** PLAN.md end matter, question: MusicXML parsing.
**Ruling:** Minimal Swift MusicXML parser (note events only: pitches, durations,
part voice mapping, time/key signature). No external XML dependency beyond Foundation;
full markup ignored.
**Affects:** P-304, J-304, CONTRACTS C-2 (`score.musicxml`).

## D-9 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D9)
**Context:** PLAN.md end matter, question: instrumental detection for acapella uploads.
**Ruling:** Always run two-stem separation (vocals/instrumental). If the instrumental
stem is near-silent, set manifest flag `hasInstrumental=false` (pure acapella path:
mixer hides the instrumental lane, no wasted UI state).
**Affects:** P-205, J-203, CONTRACTS C-2 (`song.json`).

## D-8 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D8)
**Context:** PLAN.md end matter, question: stem sample rate / channel policy.
**Ruling:** All stems rendered at 44.1 kHz. Voice stems MONO; instrumental stem STEREO
(storage budget §8: ~5–6 MB/min/stem ALAC).
**Affects:** CONTRACTS C-2, P-203, P-204, J-203.

## D-7 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D7)
**Context:** NanoPitch (smulelabs) LICENSE file is unverified; verify-before-use per §9.
**Ruling:** NanoPitch license is verified at P-102 BEFORE any integration. Fallback if
ship-unsafe or training stalls: vendor `sevagh/pitch-detection` (MIT) MPM/YIN as the
zero-lag ribbon source. Verdict recorded in DECISIONS at P-102 REVIEW.
**Affects:** P-102, M1 gate, R3.

## D-6 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D6)
**Context:** Soundfont needed for reference synth (P-501); candidates unverified.
**Ruling:** Renderer = TinySoundFont (MIT, confirmed). Soundfont decided at L-501
verify-before-use among FluidR3 GM / GeneralUser GS / CC0 alternative; verdict recorded
in DECISIONS before M5 open. Soundfont file lives in HF repo, never git.
**Affects:** P-501, L-501, M5 gate.

## D-5 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D5)
**Context:** Theory engine implementation choice.
**Ruling:** Theory core = PURE SWIFT from M5 (pitch-class sets, Krumhansl-Schmuckler
key finding, meter). tonal.js via JavaScriptCore (MIT) is an optional later accelerator,
not a dependency.
**Affects:** J-501, J-503, L-501.

## D-4 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D4)
**Context:** Persistence strategy.
**Ruling:** Library persistence = JSON index in M2 (J-202); session history = GRDB (MIT)
in M4 (J-404). No other persistence layers without a Leto ruling.
**Affects:** J-202, J-404, L-201.

## D-3 | 2026-11-20 UTC | Leto | RULED (human-confirmed)
**Context:** Bundle id, iOS minimum, distribution/signing intent.
**Ruling:** Bundle id `com.thesagezm.pitchnotes`; iOS deployment target **16.0**;
distribution = **sideload-first** (unsigned IPA via SideStore/LiveContainer, no signing
assets in pipeline, no App Store targets for v1). Human confirmed sideload-first and
private repo 2026-11-20 UTC. App Store readiness memo deferred to L-602.
**Affects:** `project.yml` (L-003), build-ipa, L-602.

## D-2 | 2026-11-20 UTC | Leto | RULED (execution BLOCKED(human))
**Context:** Model hosting for one-time download (weights never in git).
**Ruling:** HF model repo = `thesagezm/pitchnotes-models`, PUBLIC (permissive models ⇒
no CI token needed). Creation requires the human's HF account → BLOCKED(human), tracked
in QUEUE. Until it exists, L-005/CI use a committed 1 KB test blob + URL override to
exercise the download/verify path. Real models are uploaded at M1 open.
**Affects:** L-005, `Models/manifest.json`, `scripts/models/download.py`, L-101, L-202.

## D-1 | 2026-11-20 UTC | Leto | RULED (adopted from PLAN D1)
**Context:** Coordination model confirmation.
**Ruling:** Confirmed: branches `main/paul/jess/leto` long-lived (`main` = Leto
milestone merges only per D-14); QUEUE.md per AGENTS §2 (per-agent sections +
append-only LOG, newest top); PLAN.md is the only task source; claiming via
DOING + LOG + tiny queue-only commit + immediate push.
**Affects:** AGENTS §2/§3, QUEUE.md, PLAN.md.

---

_License audit baseline (L-007) and CONTRACTS v0.0 ratification (L-006) entries follow
when those tasks complete._
