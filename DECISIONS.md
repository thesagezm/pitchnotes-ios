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
