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

## D-42 | 2026-11-24 UTC | Leto | RULED (executes D-30 for the basic-pitch weights — **TIER B**, explicitly NOT Tier A)
**Context:** P-301 needs a note-event model. Where its weights come from — and what
their upstream training data is — decides the tier, and therefore what the app may say
about itself and what the human must sign off on. **Verified today (2026-11-24), not
recalled:**
- `spotify/basic-pitch` = **Apache-2.0** (LICENSE at the repo root; README §"Copyright
  and License": *"basic-pitch is Copyright 2022 Spotify AB … licensed under the Apache
  License, Version 2.0"*). The model ships **inside** that repo at
  `basic_pitch/saved_models/icassp_2022/nmp.onnx`.
- `sevagh/basicpitch.cpp` = **MIT** (LICENSE at the repo root, *"MIT License / Copyright
  (c) 2024 Sevag H"*), HEAD `e0cf072d59fc87846e5be6ee7841bf726552ce9b`, default branch
  `main`, last upstream push 2024-10-31. Its in-tree `ort-model/model.onnx` is
  **BYTE-IDENTICAL** to Spotify's `nmp.onnx` — both 230,444 B, both
  sha256 `2c3c1d144bfa61ad236e92e169c13535c880469a12a047d4e73451f2c059a0ec` (hashes
  computed today). So the wrapper repo does not change the provenance: it is Spotify's
  ICASSP-2022 model either way.
- **Training data (primary source: the ICASSP 2022 paper, arXiv:2203.09893, §4 Table 1,
  read via ar5iv):** the model is trained on a mixture including **MAESTRO (1154 train
  tracks), Slakh (1590), GuitarSet (648), iKala (252), MedleyDB (103)** (Molina and
  Phenicx appear in evaluation). The upstream repo's own `basic_pitch/data/datasets/`
  ships exactly these download scripts: `guitarset.py`, `ikala.py`, `maestro.py`,
  `medleydb_pitch.py`, `slakh.py`.
- **Verified license:** GuitarSet = `cc-by-4.0` (Zenodo API, record 3371780).
- **NOT VERIFIED TODAY — recorded as UNVERIFIED, not asserted:** the exact license
  strings for **MAESTRO**, **MedleyDB** (pitch-tracking subset, Zenodo 2620624 — the
  record the paper itself cites), **iKala** (Zenodo 3532214) and **Slakh**. The Zenodo
  API returns no license field for 2620624 / 3532214, `maestro.moz.de` does not resolve,
  and `medleydb.weebly.com/download.html` returns 404. MAESTRO and MedleyDB are widely
  documented as **CC BY-NC-SA (NonCommercial)**, but I did not verify the registry text
  today, so this entry records them as *unverified — not clean*, which is the safe side.
**Ruling:**
1. **The basic-pitch ICASSP-2022 weights are TIER B (D-30).** The weights carry an
   explicit permissive license (Apache-2.0 from Spotify; MIT in the mirror repo), **but
   their upstream training data includes datasets with NC terms or with terms I could
   not verify today** ⇒ D-30's Tier B definition applies exactly: *ship with the
   provenance and the risk recorded; **never** describe them as "clean"; HUMAN SIGN-OFF
   before any commercial / App Store distribution.* They are **NOT Tier A** (the training
   data is not clean) and **NOT Tier C** (the weights themselves are permissively
   licensed and we are not training on NC data).
2. **This does NOT block the M3 code path.** Sideloading / SideStore / LiveContainer
   needs nothing. The posture is identical to the htdemucs weights (also Tier B): **the
   human's Tier B sign-off now covers TWO weight sets — htdemucs AND basic-pitch — and
   both must be named in it.**
3. **The app ships ONE model file for the note engine:** `nmp.onnx`, 230,444 B,
   sha256 `2c3c1d144bfa61ad236e92e169c13535c880469a12a047d4e73451f2c059a0ec`, downloaded
   once from the project HF model repo with SHA256 verification (AGENTS §6: **weights
   never enter git**). Its `Models/manifest.json` entry carries `license: Apache-2.0`,
   `tier: B`, and `provenance: spotify/basic-pitch @ fa5997af0a8210982619003269994a1be25eddf3
   (ICASSP 2022 nmp.onnx)`.
4. **A verification task is REQUIRED before the App Store memo (L-602):** pin the exact
   license text of MAESTRO, MedleyDB-pitch, iKala and Slakh from their registries and
   record it here. **If any of them prohibits commercial use of derived weights, the
   weights become Tier C and basicpitch.cpp becomes STUDY-ONLY.** That is a real gate on
   commercial distribution, not paperwork.
5. **NC weights we train ourselves remain Tier C (D-30).** Nothing here licenses
   training on MAESTRO / MedleyDB / iKala: the X-301 synthetic-SATB path stays the only
   training path we may use.
6. **The in-app licenses screen must state Tier B with the provenance, never "clean"**
   (Jess's lane — J-204's `LicensesCatalog` gains the basic-pitch row).
**Affects:** P-301, P-302, P-307, `Models/manifest.json`, DECISIONS D-30, L-602, J-204
(licenses screen), the CI model-download verification.

## D-41 | 2026-11-24 UTC | Leto | RULED (executes D-12 — the assignment confidence thresholds, WITH THE NUMBERS, so P-303/P-304/J-302/J-304 build against ONE target)
**Context:** D-12 (M0) ruled the *principle* — thresholds tuned on synthetic fixtures,
score alignment optional — but published **no numbers**, so M3's long pole (P-303) and
the UI lanes (J-302/J-304) were building against nothing. This entry publishes the
initial contract values. **These are INITIAL values to be tuned on the synthetic
fixtures** (P-303's AC: ≥70 % of frames on clean synthetic 5-voice); the tuned numbers
land in BENCHMARKS v2 with their fixture results (P-306). **If the tuned numbers move,
that is a NEW appended decision (D-43+) recorded in CONTRACTS v1.1 — these thresholds
are contract-visible, not a silent tune.**
**Ruling — the numbers:**
1. **Per-note assignment confidence `c`** = the normalized posterior of the assigned part
   over the candidate part set produced by P-303's Viterbi/HMM. Three bands:
   - `c ≥ 0.80` → **CONFIRMED** (rendered solid; auto-accepted; graded).
   - `0.50 ≤ c < 0.80` → **PROVISIONAL** (rendered shaded; editable; graded, but the
     song reports a provisional assignment and the UI invites a correction).
   - `c < 0.50` → **UNASSIGNED** (**excluded from grading by default**; the user can
     force-assign it in J-302, and then it grades).
2. **Part presence per phrase.** A *phrase* is a contiguous **4.0 s** span of the note
   track (bar-aligned spans when a score is present — P-304's alignment defines the bar
   map). A part is **PRESENT** in a phrase iff it has ≥ 1 note there **and** the mean
   assignment confidence of its notes in that phrase is ≥ **0.60**; otherwise **ABSENT**.
   **ABSENT parts are DIMMED, never hidden**: the user must be able to see that we did
   not find that part (AGENTS §11 honesty rail; the same pattern as the existing D-9/D-12
   chip rules).
3. **Unison flag.** Two or more parts assigned the **same MIDI pitch within ±25 cents**
   in the same phrase ⇒ every one of those notes carries `unison: true`. Unison notes
   keep their own per-part confidence. **Grading stays per-part** (a live pitch frame is
   matched to the best-scoring part), so a unison never double-counts one singer.
4. **Which track grading uses, in order:** (a) the **correction overlay** (J-302) if
   present — the overlay is authoritative; (b) else the **score-informed / corrected
   track** if an alignment succeeded with confidence ≥ **0.70** *and* it improved note
   agreement; (c) else the **heuristic track**. In case (c) the UI must say the
   assignment is heuristic and report the CONFIRMED / PROVISIONAL / UNASSIGNED split.
5. **Tuning is a gate, not a preference:** P-306's BENCHMARKS v2 must publish a
   **reliability table** (confidence band → precision) so that a band which does not
   hold its promise is *visible* rather than assumed. A band whose measured precision is
   worse than the band below it is a tuning defect to fix before the M3 gate.
6. **Degradation, restated so nobody can misread it:** a missing score ⇒ heuristic-only;
   a failed or low-confidence assignment ⇒ heuristic-only; **neither may fail the
   import** (D-10/D-12).
**Affects:** P-303, P-304, P-305, P-306, J-301, J-302, J-304, J-401 (M4 grading),
CONTRACTS v1.1 (C-5 grading inputs + the NoteTrack metadata fields), BENCHMARKS v2.

## D-40 | 2026-11-24 UTC | Leto | RULED (executes D-10 — the MusicXML parser scope for M3, and the score's OPTIONAL status)
**Context:** D-10 ruled the principle (minimal Swift parser, note events only, no
external XML dependency) but not the *shape* of it. **P-304 (Paul) and J-304 (Jess)
both need the same parser**, and AGENTS §0 requires the core to stay portable (no
UIKit/SwiftUI in engine code) so `pitchnotes-android` / `-linux` can reuse it. Two
parsers would be two truths; a UI-layer parser would not be portable.
**Ruling:**
1. **ONE parser, in the portable engine core (Paul's lane, `Engine/**`), Foundation
   `XMLParser` only. NO new dependency** (no libxml, no MusicXML library). Jess's
   J-304 consumes the parsed result through the contract — **she does not write a
   parser.**
2. **Scope — NOTE EVENTS ONLY.** Input: `<score-partwise>`. Per `<part>`: `<measure>`
   index, and per `<note>`: `<pitch>` (step + alter + octave → MIDI), `<duration>`
   (in `<divisions>` units), `<voice>`; `<rest>` is skipped but its duration advances the
   timeline; `<part-list>/<score-part>/<part-name>` supplies the part label. A
   `<divisions>` change mid-part is honoured (the timeline stays honest). **Explicitly
   OUT of scope:** `<score-timewise>` (rejected with an honest error), engraving and
   layout (`<print>`, `<defaults>`, fonts), `<direction>`/lyrics text, harmony and chord
   symbols, `<backup>` handling beyond a linear timeline, and MusicXML 4.0 extensions.
   **A file that uses only excluded features yields an EMPTY score plus an honest
   "no note events parsed" notice — never a crash, never a failed import.**
3. **The score is OPTIONAL end-to-end.** A missing `score.musicxml`, an unreadable file,
   or a malformed score ⇒ **heuristic-only** note tracking; the import still succeeds and
   the UI states why the score was not used (D-12: score alignment is an accuracy boost,
   **never** a requirement for grading).
4. **Output shape = the contract's score-note list (CONTRACTS v1.1):**
   `{midi, start_s, end_s, measure, part_id, voice}` — times in seconds at the score's
   own tempo, **before** any alignment to audio. P-304's DTW hook consumes exactly this.
5. **Alignment is a separate step** (P-304) and is gated by D-41 §4's 0.70 confidence
   threshold. **The parser never aligns by itself.**
**Affects:** P-304, J-304, CONTRACTS v1.1 (the score-note list + `score.musicxml`
optionality), D-12.

## D-39 | 2026-11-24 UTC | Leto | RULED (the ORT runtime + the vendor scope for basicpitch.cpp — the ONE-runtime decision P-301 needs; the trimmed-ORT route is REJECTED and libremidi is DROPPED)
**Context:** PLAN P-301 and L-008's reference table assume *"basicpitch.cpp + ort-builder
minimal ORT (weights→.c/.h)"*. basicpitch.cpp's own build uses a **trimmed** ONNX
Runtime produced by ort-builder, with the model compiled into `model.ort.c/.h` (1.84 MB
of C source). **We already link ONNX Runtime 1.24.2 via SPM** (D-13; mirror
`thesagezm/onnxruntime-swift-package-manager`, tag 1.24.2, revision b7fb7f7). Linking a
second ORT inside one static IPA is a symbol/static-link hazard, and the CI gate's
no-@rpath + static-patch checks (§6) are exactly where that breaks. **Verified today:**
`olilarkin/ort-builder` = **MIT**, HEAD `61201bf3b9f4af0df6214d35609e7d18488be602`;
`celtera/libremidi` license reads **NOASSERTION** on GitHub (**unknown ⇒ not shipped**,
AGENTS §9); `sevagh/basicpitch.cpp` = **MIT**, HEAD
`e0cf072d59fc87846e5be6ee7841bf726552ce9b`.
**Ruling:**
1. **(a) IS RULED — basic-pitch runs under the EXISTING SPM ORT 1.24.2. ONE runtime.**
   P-301 loads `nmp.onnx` (D-42) through the ORT session we already link. **No second
   ORT, no duplicate ORT symbols, no second NOTICE obligation, no ORT version skew
   against 1.24.2.**
2. **(b) IS REJECTED for M3 — the ort-builder trimmed-ORT route** (second ORT +
   `model.ort.c/.h`). It stays a **documented** fallback, not a fallback we build: if
   L-302's IPA size check shows ORT's footprint is the blocker, that is a **NEW ruling**
   with its own no-@rpath + symbol proof — never a quiet switch.
3. **libremidi IS NOT NEEDED ⇒ EXCLUDED from the intake.** Paul emits NoteTrack JSON
   (C-2); Jess owns UltraStar text (J-303); a MIDI export, if ever needed, is Swift.
   (libremidi's own license also reads NOASSERTION.) The vendored `src/midi_notes.cpp`
   is patched to drop the MIDI writer and to **export** the note-event function
   (`output_to_notes_polyphonic`) that the bridge needs.
4. **The intake scope is EXACTLY:** `LICENSE` (MIT, verbatim), `README.md` (the L-008
   intake record), `patches.log`, `src/basicpitch.hpp`, `src/midi_notes.cpp`,
   `src/ort_inference.cpp` — all from the pinned SHA above. **NOT vendored:** `src_cli/`,
   `src_wasm/`, `web/`, `scripts/` (reference only), `ort-model/model.ort*` and
   `model.ort.c/.h` (**the compiled weights — weights never enter git**, AGENTS §6), and
   every submodule: `vendor/onnxruntime` (we use SPM ORT), `vendor/libremidi` (ruling 3),
   `vendor/libnyquist` (CLI-only audio loading; our decoder is AVFoundation/EngineCore),
   `vendor/oboe-resampler` (Android-only, not a current target), `vendor/ort-builder`
   (**reference only — MIT, HEAD 61201bf…, NO CODE COPIED**), `vendor/eigen` (ruling 5 —
   **we reuse the Eigen already vendored at `vendor/demucs.cpp/third_party/eigen`; no
   second copy is taken**).
5. **Eigen — REUSE THE COPY THAT IS ALREADY VENDORED. Do NOT vendor a second copy,
   and X-313 is NOT needed.** The core needs it (`Dense` +
   `unsupported/Eigen/CXX11/Tensor`). Eigen is MPL-2.0, header-only ⇒ shippable
   unmodified under D-32.5 **with attribution**. **Eigen is ALREADY in this repo** at
   `vendor/demucs.cpp/third_party/eigen` (upstream pin
   `dd8c71e62852b2fe429edb6682ac91fd1c578a26`, MPL-2.0, vendored unmodified under
   D-32.5), and that drop **already includes `unsupported/` — i.e. the exact
   `unsupported/Eigen/CXX11/Tensor` header this core needs.** So basicpitch.cpp
   compiles against `-Ivendor/demucs.cpp/third_party/eigen` — the **same headers,
   the same pin** — with **no new intake, no second copy in the repo, and no second
   attribution obligation**. The earlier text in this §5 (which recommended a
   minimal-tensor shim and told Paul to queue an intake X-313) was **STALE and is
   CORRECTED HERE**; it was written before the existing Eigen drop was checked
   against this requirement. **The minimal-tensor-shim route is withdrawn** — it
   would hand-reimplement an API the repo already ships, for no gain.
   *(Corrected 2026-11-24 UTC, before this ruling reached `main`; the correction is
   a factual fix to a same-session draft, not a re-litigation.)*
6. **The model-load patch is the only behavioural change upstream:** the session is
   created from a **file path** (`Ort::Session(env, model_path, options)`) instead of
   the embedded `model_ort_start` blob, and `ort_inference()` gains a model-path
   parameter. Everything else stays upstream-identical so a future re-drop is a small
   diff (patches.log).
7. **Compile proof is P-301's job, and a failure there is a FIX task on the LETO side**
   (`vendor/**` is mine per AGENTS §12): if the drop does not compile under the SPM ORT,
   Paul files the FIX and Leto re-applies the patch — **Paul does not edit `vendor/**`.**
**Affects:** P-301, P-302, P-307, L-302 (basicpitch-spike + IPA size check), L-303,
X-312, `vendor/README.md` (its reference table is amended by this ruling),
`Models/manifest.json`.

## D-38 | 2026-11-24 UTC | Leto | RULED (M2 gate session 11 — the HUMAN's close-out order: Leto finishes M2 alone; the gate closes on the CI + contract evidence; the two human legs are carried into M3, NOT claimed as done)
**Context:** The human owner (thesagezm) closed the M2 lane chats: *"no more Jess and Paul
sessions for M2… finish everything yourself… I want us to move to M3."* M2 had run for
days with the gate one step from closing: the whole engine lane was merged, the app lane
was merged, the swap seam was un-executed, and step 5(c) was blocked on Jess's binding
being on `main`. The handoff asked for a merge order that needed two other agents to
show up. The human's instruction removes that dependency. **AGENTS §1 sends
Leto-vs-principle and scope questions to the human owner; the human has now answered
one.** This entry records that answer openly rather than letting a lane-rule bend
happen silently.
**Ruling:**
1. **THE HUMAN'S ORDER IS THE RULING, AND IT IS RECORDED HERE.** Leto executes the
   remaining M2 work in this session, alone, and drives M2 to a tagged close so M3 can
   open. The order is not "skip the gate" — it is "do the gate yourself".
2. **LANE DISCIPLINE — ONE RECORDED, HUMAN-AUTHORIZED DEVIATION (AGENTS §12).** Leto
   executes the **J-lane swap seam #1** and the **J-lane conflict resolution** in the
   jess→main merge. Both are taken from **Jess's own work** (her probe
   `jess-swap-probe-v6`), not newly designed: the seam is her recipe, and the ONE
   change beyond it is the migration of the app's single reference to the deleted
   lane-local decoder — the line the probe proved was missing. **THE DEVIATION ENDS
   WITH M2.** From M3 the three-lane discipline resumes: Paul owns `Engine/**`, Jess
   owns `App/**`/`Features/**`, Leto owns the integration lane.
3. **THE M2 GATE CLOSES ON THE CI + CONTRACT EVIDENCE.** Specifically: the whole M2
   stack merged to `main`; the M2 gate run on `main` is green with **ALL 8 jobs**
   (including `build-ipa`, which compiles the REAL binding + the REAL ALAC writer with
   `SEPARATION_IMPORT_ENGINE` ON, and `logic-tests`, which runs the swapped suite);
   `separation-spike` REAL green; contracts at **v1.0.3**; D-22/D-25/D-30/D-31/D-32
   ruled; `m2` tagged.
4. **THE UX §10.2 DEVICE DEMO WAS NOT RUN — AND IS NOT CLAIMED.** It needs an iPhone
   12 Pro Max, the 84 MB htdemucs weights, and a human. **Leto does not fabricate a
   device result.** The demo's steps are preserved **verbatim** as a seeded M3 row
   (**L-205**), which also carries the **device RTF / peak RSS / thermal** numbers —
   the P-603 standing ask and the only source of §8's device numbers. **The M2 device
   demo rides along with the M3 demo: same device, same weights, one trip, both
   results.** Rows **J-206 / J-207 / J-208 are REVIEW, not DONE** — their code is
   complete and green, and each carries a device leg only a human can run.
5. **THE D-30 TIER B SIGN-OFF IS OUTSTANDING — AND IT DOES NOT BLOCK `m2`.** htdemucs
   weights are MIT-licensed but their training data carries NC terms ⇒ **Tier B with a
   recorded risk** ⇒ **human sign-off before any COMMERCIAL / App Store distribution**.
   Sideloading (SideStore/LiveContainer) needs nothing. The sign-off is a human action
   **by definition** — Leto cannot sign it and does not pretend to. It is tracked in
   this entry and surfaces again with the App Store readiness memo (L-602).
6. **WHAT DOES NOT CHANGE.** **D-37 STANDS:** no separation arm meets §8's device
   budgets (RTF ≤ 2×, RSS < 1.5 GB) on ANY measured environment, so **M2 separation is
   an OFFLINE / QUALITY-MODE job** and closing the RTF gap belongs to **M6** (CoreML
   EP). The miss is **RECORDED, NOT PAPERED OVER**. D-30…D-37 are not re-litigated.
   The honesty rail (AGENTS §11 — never promise perfect 5-way separation) carries into
   M3 unchanged, and the M3 milestone header repeats it.
7. **M3 OPENS IMMEDIATELY, SEEDED AND READY.** `m2` is tagged, the M3 milestone header
   is live, and the board carries P-301…P-306, X-301, J-301…J-304, L-205, L-301…L-304,
   X-302 (plus the pre-seeded P-307…P-309, X-311, P-605). **L-303's D10 (MusicXML
   parser) and D12 (assignment confidence thresholds) must be ruled EARLY** — they
   block P-303/P-304, the M3 long pole.
**Affects:** AGENTS §12 (one recorded deviation, M2 only), QUEUE.md (L-204 DONE; J-206/
J-207/J-208 REVIEW; L-205 seeded; the M3 seed), PLAN.md (the M2 gate row + the M3 open
condition), DECISIONS.md (this entry), `project.yml` (step 5(c) @dcdfbff), the M2 gate
run on `main` (ALL 8 GREEN), and the M2 tag.

## D-37 | 2026-11-23 UTC | Leto | RULED (M2 gate session 10 — the D-25 chunk-policy arm is decided BY MEASUREMENT; Rule 3 escalation answered)
**Context:** The D-25 protocol was fixed at QUEUE 2026-11-22T21:00Z §6 (Rules 1–4) so the gate could
never stall on a judgement call. Paul has now landed both measurement legs and escalated the
outcome with the numbers, as Rule 3 requires:
- **L3** (BENCHMARKS §4.1, v1.6): 30.0 s synthetic mix, **3 paired repeats × 3 arms**, same fixture,
  same weights (htdemucs fp16 ggml, sha256 `72b17c42…df0064`), same runner class, 1 vendor thread,
  **Linux dev box — ENV-LABELED, NOT A14**.
- **L4(a)** (BENCHMARKS §4.2, v1.7): 240.0 s synthetic mix (8× the L3 fixture), `planDefault` arm,
  1 repeat, same env.
The numbers below are quoted from Paul's own tables in `Docs/BENCHMARKS.md` §4.1/§4.2; they are not
re-derived here. I am answering the Rule-3 escalation.

| arm | all-sources SDR | instrumental SDR | vocals SDR | NSDR (all-src) | wall | RTF | peak RSS |
|---|---|---|---|---|---|---|---|
| reference (whole song) | n/m (it IS the baseline) | n/m | n/m | n/m | 692.2 s | **23.07** (22.17–27.50) | 1829 MB (1781–1885) |
| muskeyRecipe (4.5 s / 1.0 s) | **1.63 dB** | 8.07 dB | 1.11 dB ⚠ | −21.28 dB | 1048.2 s | **34.94** (33.19–36.72) | 1767 MB (1738–1785) |
| **planDefault (8.0 s / 2.0 s)** | **6.39 dB** | **12.11 dB** | 5.06 dB ⚠ | **−16.51 dB** | 1298.5 s | **43.28** (40.53–43.73) | 1778 MB (1740–1788) |
| planDefault @ 240 s (L4(a)) | n/a (paired comparison lives in the 30 s rows) | n/a | n/a | n/a | 8717.6 s | 36.32 | **1805 MB** |

**Ruling:**
1. **RULE 1 FAILS — `muskeyRecipe` IS REJECTED.** Its SDR gate is decisive: 1.63 dB vs 6.39 dB
   all-sources = **4.76 dB behind** (instrumental 8.07 vs 12.11 = 4.04 dB behind). Its other two
   gates pass (RTF 34.94 ≤ 1.25 × 43.28 = 54.10 ✓; peak RSS 1767 ≤ 1778 MB ✓), but Rule 1 requires
   ALL of them. **⇒ No §8 window deviation is recorded, and none is needed: the shipped arm keeps a
   §8-native 5–10 s window.**
2. **RULE 2's PRECONDITION FAILS ⇒ RULE 3 TRIGGERED ⇒ ESCALATED TO ME ⇒ RULED HERE.** Rule 2 would
   have selected `planDefault` had both arms been in budget; neither is (see §4). The Rule-3
   reversible option was designated "the better-quality arm at `planDefault`, flagged".
   **THE SHIPPED DEFAULT IS `planDefault` — 8.0 s window / 2.0 s overlap / linear crossfade.**
3. **THE REQUIRED LANDING SITE IS ALREADY SATISFIED — PAUL OWES ZERO CODE FOR D-25.**
   D-36 §6 made the arm land as `DemucsEngine.init(modelPath:threads:policy:)`'s default `policy`.
   Verified on `origin/paul` @599b441, `Engine/Separation/DemucsEngine.swift:80–81`:
   `policy: ChunkPolicy = .planDefault` — **already the default.** Nothing to change, no new ruling
   to implement. **P-202's only open item (this ruling) is now closed; the row is gate-closable.**
4. **THE BUDGET MISS IS RECORDED, NOT PAPERED OVER.** No arm meets §8's device budgets on any
   measured environment: dev-box RTF 34.94 / 43.28 against the ≤ 2.0 target, and peak RSS 1767 /
   1778 MB against the < 1.5 GB target. **The miss is NOT caused by chunking** — the whole-song
   REFERENCE itself is RTF 23.07. The derived macOS-runner factor (≈3.7×, from the §4 CI row) puts
   the long-form arms at ≈ 9.4 (muskey) / ≈ 11.7 (plan) — still ≫ 2.0. **§8's RTF ≤ 2× and
   RSS < 1.5 GB are NOT amended by this ruling; they remain the targets** — but they are **NOT MET**
   by M2's CPU path. The honest product consequence: **M2 separation is an OFFLINE / QUALITY-MODE
   job** (foreground progress, or `BGProcessingTask` while charging, per §8) — not a
   "≤ 2× song length" interactive path. **Closing the RTF gap belongs to the M6 acceleration phase
   (CoreML EP, same ONNX models — AGENTS §0 hard rail 2), not to M2.** The A14 numbers arrive from
   the §10.2 device demo (P-603 / Jess's J-206 readout) and go into BENCHMARKS §6 — **runner
   numbers are never presented as device numbers, and these are not.**
5. **THE MEMORY CLAIM IS THE ONE THAT HOLDS.** L4(a): 8× the audio cost grew peak RSS by **+27 MB
   (+1.5 %)** — the peak is the vendor's per-segment working set (~1.7–1.8 GB), not whole-song
   accumulation — and 1805 MB is under the Linux 2.0 GB spike sanity bound. **P-202's "4-minute
   synthetic processes without OOM" ac leg is MET on this path.** But the measurement comes from the
   **C++ MIRROR**, which accumulates MORE than the Swift shipping path (four source stems vs the
   Swift driver's two blended output stems) — and the Swift driver's own whole-song accumulation
   term DOES scale with length. **A streaming stem writer (write each window's blended stems to
   disk instead of accumulating them) is therefore a REAL follow-up, filed as X-214 (owner: paul,
   M3-prep, NON-GATING for `m2`)** — recorded, not smuggled into this gate.
6. **CHUNKING LOSES ON RTF BY CONSTRUCTION — a standing fact, not a re-litigation.** The vendor pads
   every external window to full 7.8 s internal segments (an 8 s window costs 15.6 s of vendor
   compute; a 4.5 s window costs 7.8 s), and the measured ordering matches that cost model exactly
   (reference 23.07 < muskey 34.94 < plan 43.28). **Any future window-policy change must beat this
   cost model with measurement, not with opinion.** (Paul's honest cost model from the vendor source
   is what predicted the outcome before the run — it was right.)
7. **TWO SMALL POINTS ACCEPTED (no new row, no contract change):** (a) the D-9 near-silent
   instrumental threshold (**−50 dBFS RMS**) is **ACCEPTED** as the M2 heuristic constant — it lives
   in EngineCore, it is **not** a contract item, and it is revisited only with evidence; (b) the
   engine-side cache index is **not** D-4's library index (that is Jess's J-202) — the distinction is
   correct and stands as stated.
8. **THE VOCALS-SDR COLUMN IS NOT A QUALITY CLAIM.** On the L3 fixture the tone energy routes to
   other stems, so the vocals stem sits at ≈ −70 dB and the SDR of two near-silent signals is noise
   (1.11 dB vs 5.06 dB — a 3.95 dB spread that is meaningless in itself). **The primary quality
   numbers are all-sources + instrumental.** Any real vocal-separation quality claim needs a
   truth-bearing fixture (known stems) — that is M3's eval-harness job (X-301/X-311), not M2's.
9. **NOTHING HERE RE-OPENS ANYTHING.** Rules 1–4 were applied as written; D-22..D-36 stand; the
   next decision letter is **D-38**.
**Affects:** P-202 (REVIEW → gate-closable; the D-25 arm is ruled), P-201/P-203/P-204/P-205 (gate
rows), P-206 (M6/D-31, non-gating), P-603 + J-206 (the A14 device numbers → BENCHMARKS §6),
`Docs/BENCHMARKS.md` §4.1/§4.2/§6, `Docs/ENGINE.md`, **X-214 (new: streaming stem writer,
owner paul, M3-prep, non-gating)**, L-204 (M2 gate).

## D-36 | 2026-11-23 UTC | Leto | RULED (M2 gate session 9, same session — SUPERSEDES D-35 §1/§2 after Jess's in-flight work was read and PROVEN; the FINDING stands, the SHAPE changed)
**Context:** D-35 (committed earlier this session, `029408c`) ruled that the M2 app-facing engine
would be a NEW app-target facade (`SeparationImportEngine`, `init(modelPath:libraryRoot:)`) whose
`separate` would publish the bundle, and that Jess's factory would change by ONE LINE. **Two
things that happened after D-35 was written changed the ruling — and I am recording the
correction openly rather than letting two shapes exist:**
(1) **JESS'S OWN WORK moved while I was ruling.** Her branch (`origin/jess` @9074653) now carries
a rewritten binding: the app builds `DemucsEngine(modelPath:)` (Paul's app-target bridge),
injects `demucs.separationRun()` into `SongBundleImportEngine(libraryRoot:separator:)`, and drives
the engine's EXISTING whole-import call `importSong(source:title:) -> ImportOutcome` — one call
that owns decode → separate → assemble → atomic publish. The app-side seam hides the difference
behind ONE closure (`ImportEngineHandle.runImport` → an app-owned `PublishedImport`), so the C-3
pair is still what the MOCK runs and the UI is untouched. **CI-proven: probe `jess-swap-probe-v5`
run `45098520720` = `build-ipa` SUCCESS with `SEPARATION_IMPORT_ENGINE` ON, `canImport(ImportKit)`
TRUE and the REAL classes in place** — her binding compiles against Paul's actual API
(`DemucsEngine.init(modelPath:threads:policy:)`, `separationRun()`, `SongBundleImportEngine.init(libraryRoot:separator:)`,
`importSong`, `ImportOutcome` — all verified present in `origin/paul`).
(2) **MY OWN SHAPE WAS TECHNICALLY INFERIOR, and the reason is the manifest, not the taste.** The
bundle's `song.json` needs facts that only the DECODE stage produces (the source hash, the decoded
duration, the normalised mix). Splitting the flow into `importAudio` → `separate` forces a SECOND
decode/hash to build the manifest, and splits the all-or-nothing guarantee (C-8: no partial bundle,
NO residue) across two calls with the APP in between — exactly the atomicity C-2.2/C-8 exist to
provide. Jess's shape keeps the whole import inside ONE atomic, already-tested, already-written
engine call (`ImportOrchestrator.run(source:…)`, with staging discipline + pre-publish validation +
the C-9 publish + the global monotonic progress bands).
**Ruling:**
1. **D-35 §1 (the facade) and §2 (the one-line factory change) are SUPERSEDED. D-35's FINDING —
   the C-3 pair as it stood could not publish, and the real-engine import would have failed the
   app's own C-2.2 completeness check — STANDS and is the reason for this ruling. The contract
   clause D-35 added is RESTATED in v1.0.3 to be shape-agnostic.**
2. **The M2 real path is the ATOMIC whole-import call (Jess's shape), and it is RATIFIED.**
   The app drives ONE call that owns decode → separate → assemble → atomic publish; the app
   translates the outcome at ONE seam point (`PublishedImport`); the mock keeps the frozen C-3
   pair; the UI changes not at all. The app owns the weights path (J-207) and constructs the
   engine behind its factory (D-34 §3) — that is the app's job and it is lane-correct.
3. **C-9.1 IS ADDED (CONTRACTS v1.0.3):** the M2 bundle-producing engine exposes a whole-import
   entry point — `importSong(source: URL, title: String) async throws -> ImportOutcome` — and the
   app drives an engine that has it through that call (an engine without it is driven with the
   frozen C-3 pair, as the mock is). **NO NEW SWIFT PROTOCOL IS REQUIRED** — the app-side
   `runImport` closure IS the interface, and the app binds the concrete engine at its factory
   (which is exactly what compiles today). Paul MAY publish an `AtomicBundleImporting` protocol
   in EngineCore as an additive nicety; it is **NOT a gate item**. Naming the entry point in the
   contract is what protects Jess's binding from a rename.
4. **C-9 RULE 5 IS RESTATED (shape-agnostic):** what the contract requires is the OUTCOME — the
   import flow the app drives ENDS with a COMPLETE published bundle (`song.json` present) and
   `importedBundleID` set. HOW the engine gets there (the atomic call, or a C-3 pair whose
   `separate` publishes) is the engine's business. My v1.0.2 wording ("by the time `separate`
   returns…") was over-specified and is withdrawn.
5. **PAUL'S REMAINING WORK SHRINKS — X-211 (the facade) IS CANCELLED.** Paul owes: X-213 (the
   `ALACStemWriter` compile fix — now also a `build-ipa` red once step 5(a) lands), P-202 L3 (the
   D-25 numbers) + L4(a) (the 4-minute no-OOM run), P-204/P-205 close (bundle sizes logged), and
   the D-25 arm as `DemucsEngine`'s default `policy` (see §6). **No new facade, no new orchestrator
   entry point, no change to `separate`.** Jess's session-7 finding and her probe already reported
   the two ALAC facts Paul needs (`AVAssetWriterInput.sourceFormatHint` is GET-ONLY ⇒ delete the
   assignment; `AVAudioFile.read(into:frameCount:)` returns Void ⇒ the count is
   `buffer.frameLength` after the read); the remaining work is the `CMSampleBuffer` conversion.
6. **THE D-25 PICK MAPS ONTO `DemucsEngine.init(modelPath:threads:policy:)` — the `policy:`
   DEFAULT (currently `.planDefault`).** The app constructs `DemucsEngine` and does NOT know about
   `ChunkPolicy`, so the arm chosen under the D-25 protocol MUST land as that default (or the app
   must be taught the arm — worse). Paul: the D-25 ruling therefore has a REQUIRED landing site.
   Rules 1–4 (QUEUE 21:00Z §6) are unchanged, the tie goes to `planDefault`, and runner numbers
   are never device numbers.
7. **STEP 5 IS RESHAPED (X-209 updated):** (a) project.yml `packages:` += `ImportKit: {path:
   Engine/ImportKit}` + app `dependencies:` += `- package: ImportKit` / `product: ImportKit`
   (PROVEN by BOTH probes — mine `45097390536` and Jess's `45098520720` wired it the same way);
   (b) app `sources:` += `Models/manifest.json` (X-207) — AFTER paul→main lands the manifest that
   carries the `htdemucs` entry; (c) **the `SEPARATION_IMPORT_ENGINE` compilation condition ALONE**
   — **NO `Engine/Separation/SeparationImportEngine.swift` source path (the class does not exist and
   is no longer needed)** — LAST and as its own commit, after (a)+(b) and after Jess's binding is
   on main. Plus, at step 5: drop `optional: true` from the two `Engine/Separation` entries, remove
   the X-201 branch-state adapter from build.yml, and add the Info.plist Files-container keys.
8. **THE ORDER IS UNCHANGED** (D-34 §5): paul→main → Jess rebase + swap seam #1 → jess→main →
   leto→main step 5(a)+(b) then (c) → main gate run ALL 8 → human device demo → Tier B ask → tag m2
   → open M3. The merge order is CONTRACTUAL and is not re-opened.
**Affects:** CONTRACTS.md (v1.0.3 — C-9 rule 5 restated + NEW C-9.1 + changelog), QUEUE (X-209
reshaped, X-211 CANCELLED, X-212 SUPERSEDED by Jess's rewrite, L-204), `Engine/ImportKit`
(`SongBundleImportEngine.importSong` — unchanged, now the ratified entry point),
`App/Sources/Features/Import/{ImportEngineSeam,RealImportEngineFactory,ImportModel}.swift`
(Jess's rewrite, as built), `project.yml` (step 5(a)+(b)+(c) — no facade path).

## D-35 | 2026-11-23 UTC | Leto | RULED (M2 gate session 9; the M2 real-engine seam surface is FIXED + the C-3 import flow must END in a PUBLISHED bundle) — **§1/§2 SUPERSEDED BY D-36 (same session); the FINDING and the spirit stand**
**Context:** Session-9 gate review, after both lanes moved past the session-8 checkpoint
(paul @2d9f7f8, jess @772c112). Three facts, all found by reading code — not by trusting a row:
(1) **The X-208 surface does not exist.** Paul landed P-204's Apple side as
`SongBundleImportEngine` inside the `Engine/ImportKit` SPM package — `init(libraryRoot:separator:)`,
NON-throwing, separator injected — and Jess's committed binding expects an APP-TARGET
`SeparationImportEngine` with a THROWING `init(modelPath:)`. Session-8 Finding 1 stands
(`Engine/Separation/SeparationImportEngine.swift` is still absent from origin/paul); the two
lanes have now built to two different surfaces, and D-34 §2/X-208 were written before either
implementation existed.
(2) **NEW, GATE-BREAKING — the C-3 import flow cannot publish a bundle as it stands.**
Jess's flow (J-201 `ImportModel`) drives the FROZEN C-3 API — `importAudio(url:)` then
`separate(audio, mode:)` — and then REQUIRES a complete published bundle: she resolves the id
via C-9 and throws `EngineError.importFailed("completed bundle failed the completeness check")`
unless `<libraryRoot>/<id>/song.json` exists. Paul's ONLY publish path is `importSong(source:title:)`
(the whole-path orchestrator: decode → separate → assemble → publish); `SongBundleImportEngine.separate()`
returns the separator's RAW stem URLs, never assembles, never publishes, and leaves
`importedBundleID` nil. ⇒ With the real engine compiled in, the M2 demo would import, separate,
and then FAIL THE APP'S OWN COMPLETENESS CHECK: no bundle in the library, no stems in the mixer.
This would have surfaced only at the human demo, after the entire gate.
(3) **Session-8 Finding 2 is RESOLVED** — the C-9 `BundleProducingEngine` protocol now exists in
EngineCore (Paul @5258632, `Engine/Sources/EngineCore/ImportProgress.swift`), verbatim per §C-9.
**Ruling:**
1. **The M2 real-engine seam is ONE app-target facade — `Engine/Separation/SeparationImportEngine.swift`
   (Paul's lane; X-211). Exact surface, frozen for both lanes:**
   ```swift
   public final class SeparationImportEngine: ProgressReportingEngine, BundleProducingEngine, @unchecked Sendable {
       public init(modelPath: URL, libraryRoot: URL) throws
   }
   ```
   - `init` THROWS when the htdemucs ggml weights cannot be loaded. Jess's factory catches it
     and surfaces an actionable error; it must NOT fall back to the mock (D-34 §3, D-12 honesty).
   - `importAudio(url:)` → decode + normalize to the 44.1 kHz mix (staged; NO publish).
   - `separate(audio, mode: .twoStem)` → separate + assemble (ALAC stems + `song.json` v1.0) +
     ATOMIC PUBLISH under `libraryRoot`; set `importedBundleID` to the published DIRECTORY name;
     return the PUBLISHED stem URLs. On failure/cancellation: throw, `importedBundleID` stays
     nil, NO partial bundle (C-2.2).
   - C-8 progress stays monotonic across the whole flow; 1.0 only AFTER the publish rename.
   - The facade is the ONLY place that knows the vendor bridge: it constructs `DemucsEngine`
     (app target) and injects it into the ImportKit `SongBundleImportEngine` (SPM package).
     ImportKit stays free of the C++ bridge; EngineCore stays portable (Linux loop clean).
   - The source MUST be decoded ONCE per import. The C-3 flow already decoded in `importAudio`;
     the facade must not decode the source a second time.
   - **The APP MUST NOT CONSTRUCT THE ASSEMBLER OR THE BRIDGE ITSELF.** The app target does
     not import `ImportKit` for the import path and does not build a `DemucsEngine`; the facade
     owns that wiring. (This SUPERSEDES the app-side-construction sketch Jess recorded in her
     session-7 LOG — "both call shapes … the app injects `DemucsEngine.separationRun()`" — which
     would have put the vendor-bridge wiring in the APP lane and created a second import path.
     Her independent FINDING is the same one this ruling encodes; her proposed SHAPE is not.)
2. **Jess's `RealImportEngineFactory` changes by ONE LINE** (X-212, Jess's lane):
   `try SeparationImportEngine(modelPath: modelURL, libraryRoot: bundleRoot)` — she already
   receives `bundleRoot` in `makeEngine(bundleRoot:)`. No other app change, no view change, no
   UI/UX change (the J-105 precedent). **The app's import path stays the frozen C-3 pair**
   (`importAudio` → `separate`) — there is ONE import path in the app, not two, and the app
   does not need to know whether the engine conforms to anything beyond C-8 + C-9.
3. **C-3/C-9 semantics CLARIFIED (CONTRACTS v1.0.2 — additive clarification, NO signature
   changed):** the C-3 import flow IS `importAudio` → `separate`, so the publish happens INSIDE
   that flow. By the time `separate` returns, a conforming M2 engine MUST have published a
   COMPLETE bundle under the library root (C-2.2 completion marker `song.json` present) and MUST
   have set `importedBundleID`. An engine that returns stems without publishing satisfies C-3 but
   NOT C-9 for M2, and the consumer rejects it with the C-2.2 completeness check. This pins down
   WHEN the publish happens; it changes no signature and re-opens nothing (C-9 rule 1 already
   implied it, and C-9 rule 3's derivation fallback presupposes it — a published stem's parent
   IS the bundle directory).
4. **Paul's `SongBundleImportEngine` (ImportKit) is the ASSEMBLER, not the app-facing engine.**
   It stays — the facade delegates to it — and the orchestrator gains the entry point that takes
   an ALREADY-DECODED mix (the C-3 flow decodes first, then separates). Implementation is Paul's;
   the REQUIREMENTS are: decode once, publish once, no partial bundle, no residue.
5. **X-210 is CLOSED** (the C-9 protocol landed) and **session-8 Finding 1 is RE-STATED, NOT
   REVERSED**: the app-target facade must EXIST before gate step 5(c) lands the compilation
   condition + the source path (the X-201-r1 missing-file red). Step 5(c) stays LAST and stays
   ONE COMMIT (X-209).
6. **The D-25 decision is NOT pre-empted and NOT re-litigated.** Paul owns the 30 s paired run;
   the protocol (QUEUE 21:00Z §6 Rules 1–4) stands. Preliminary numbers are not a ruling, and
   runner numbers are never presented as device numbers.
7. **Merge order is UNCHANGED** (D-34 §5): paul→main → Jess swap seam #1 → jess→main → leto→main
   step 5(a)+(b) then (c) → main gate run ALL 8 → human device demo → Tier B ask → tag m2 → open M3.
**Affects:** CONTRACTS.md (v1.0.2 — C-3 note + C-9 rule 5 + changelog), QUEUE (X-211 Paul,
X-212 Jess, X-209 dependency updated, X-210 closed), `Engine/Separation/SeparationImportEngine.swift`
(NEW — Paul), `App/Sources/Features/Import/RealImportEngineFactory.swift` (one line — Jess),
`project.yml` (gate step 5c: condition + source path, unchanged in shape).

## D-34 | 2026-11-22 UTC | Leto | RULED (M2 gate session 7; the bundle-identity seam + two demo-blocking gaps closed by ruling)
**Context:** Gate review for L-204 surfaced two facts that would have failed the M2 device
demo on the day, both found by reading the code rather than the rows:
(1) The app's import flow (J-201 `ImportModel`) hard-wires `ScriptedImportEngine` — there
is NO app-side path to the real engine, so "import a real SDA FLAC → stems → mixer" is
impossible as the code stands; and the fact the app needs from a real engine
(`importedBundleID`) is NOT in the frozen C-3 `EngineAPI` (`separate` returns raw stem
URLs). (2) `DemucsEngine.init(modelPath:threads:)` needs the 84 MB htdemucs ggml weights
on device, and **no runtime model downloader exists anywhere in the app** — the manifest
cache scheme (`SwiftF0ModelStore.modelURL`) is only a LOCATOR; the actual fetch lives in
`scripts/models/download.py` (Python, CI-only). The M1 demo passed because the live ribbon
(MPM/YIN) needs no weights — so this gap was never exercised. Meanwhile AGENTS §0/§6 make
runtime model download a HARD rail ("models download once, then never needed again";
"App and CI download once, cache locally, verify SHA256, then run fully offline").
**Ruling:**
1. **C-9 `BundleProducingEngine` ADDED (CONTRACTS v1.0.1, no signature changed).** The
   bundle-identity fact travels in a NEW additive protocol over C-8, not in a changed
   `EngineAPI`. `importedBundleID` is set ONLY after the atomic publish (C-2.2 rename;
   `song.json` = completion marker) and is nil on cancel/failure. The consumer MAY derive
   the bundle dir from a stem URL's parent when an engine does not conform (C-9 rule 3) —
   so C-9 can never become a new blocker; it exists to make an existing dependency explicit.
   Both lanes ack C-9 in their next LOG line (L-006/L-102 precedent).
2. **The M2 device demo REQUIRES a runtime model-download path — assigned, gate-relevant.**
   No weights in git, no weights in the IPA (the 8 MB/21 MB size guard stays), no network
   at runtime beyond the one-time model download (that IS the rail). Download = URLSession +
   SHA256 verify + the EXISTING cache filename scheme (`<name>-<sha256[:16]>`, so
   `SwiftF0ModelStore.modelURL` keeps working) + a Models-screen action + on-demand/first-run
   trigger. Fallback so the demo cannot stall: the human may place the ggml file into the
   app's Files container — SHA256 is still verified before use; I add the two Info.plist keys
   (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`) at gate step 5.
3. **The app-side real-engine swap is a named deliverable, not an implicit hope.** The app
   must construct the real engine behind a factory/seam (mock retained for previews and
   tests), with ZERO UI change — the J-105 precedent applied to the import flow.
4. **P-204's contract surface (Paul's lane, gate row):** the assembled engine must publish
   `importedBundleID` (C-9), decode MP3/FLAC through ImportKit (his own scope note says
   `importAudio` is WAV-only today), write ALAC stems + `song.json` v1.0 atomically, and
   accept the htdemucs cache path from the manifest entry (`name: "htdemucs"`).
5. **This ruling does NOT re-open D-30..D-33 and does not change the merge order.** The
   runbook stands: paul→main → Jess swap seam #1 (+ the two new J-rows) → jess→main →
   leto→main (adapter removal + ImportKit package/dep entries + Info.plist fallback keys) →
   main gate run ALL 8 → human device demo → Tier B ask → tag m2 → open M3.
**Affects:** CONTRACTS.md (C-9 + changelog v1.0.1), QUEUE (J-206/J-207/J-208 to be filed by
Jess in her section; P-204 addenda), L-204 gate runbook step 5, project.yml (Info.plist
keys), Docs/UX.md §10.2 (demo script gains the one-time download step), AGENTS §0 (rail now
has an owner).

## D-33 | 2026-11-22 UTC | Leto | RULED (M2 session; OPTIONAL notesFile semantics — resolves the Paul/Jess round-2 counter-check dispute)
**Context:** Paul's round-2 lane exception (@7df00ba, fixing the 5 C-2.1 `notesFile → String?`
compile-fallout sites) chose `p.notesFile ?? ""` in LibraryCatalog — appendingPathComponent("")
→ directory read fails → renders as a V1 "notes file missing" row. Jess counter-checked the
explicitly-flagged semantic and VETOED it (LOG 12:58Z + BLOCKED merge-guidance entry), with two
evidence pieces. This is a Paul/Jess disagreement → Leto ruling (AGENTS §1).
**Ruling:**
1. **Jess's engine-consistent semantic ADOPTED: `nil` notesFile ⇒ no violation, no report row.**
   Decisive evidence: Paul's OWN EngineCore `BundleValidator.validate(bundleDirectory:)` treats
   `nil` as no-violation (`if let notesRel = p.notesFile { … }`) — one semantic source of truth;
   the app-side renderer must mirror the engine-side validator. Paul's `?? ""` variant would
   false-flag EVERY INSTRUMENTAL part on EVERY real M2 two-stem bundle (V15-consistent:
   INSTRUMENTAL carries no notes) with an empty filename — J-202 inspector FAIL rows on healthy
   bundles + device-demo §10.2 step 5 misleading.
2. **Merge guidance ADOPTED for L-204 (Jess's BLOCKED entry, verified):** at the
   paul↔main/jess↔main conflicts take Jess @21d3beb for LibraryCatalog (nil⇒skip) AND the
   both-worlds integration test (Paul's variant works post-merge but breaks any main-base branch
   and needs re-editing per future C-1 addition); BundleInspectorView equivalent either way.
   Jess's both-worlds fixes CI-proven: 45022908849@13bb874 ALL 8 GREEN. The compile-fix part of
   Paul's exception stands RATIFIED (both lanes agree); only the semantic is overridden.
3. **Going forward:** optional manifest fields are ABSENT-means-clean unless a validator says
   otherwise; any new optional field lands with an explicit nil-semantics note in CONTRACTS.
**Affects:** App/Sources/Features/Library/LibraryCatalog.swift, Tests/Logic (both-worlds test),
CONTRACTS C-2.1/V15 consumers, L-204 merge set, J-202 inspector semantics.

## D-30 | 2026-11-22 UTC | Leto | RULED (M2 session; uniform WEIGHTS PROVENANCE policy — resolves the D-17/D-21 vs demucs inconsistency)
**Context:** D-17 banned NanoPitch's GTSinger-trained weights and D-21.3 banned
grouper/drums outright, while M2 ships htdemucs weights that are trained on MUSDB18 —
under the same "NC training data" logic M2's own model would be banned. Per-model
improvisation is not a policy. Ruling needed BEFORE P-201 lands weights in the HF
repo. All facts below verified against primary sources this session (never the
dossier), D-19.1 precedent.
**Ruling — the three-tier WEIGHTS PROVENANCE POLICY (applies to every model/weights
decision from M2 on):**
1. **TIER A — SHIP (clean):** explicit permissive license on code AND weights +
   commercially clean / CC / permissive training data, or no training data (pure
   DSP). Examples: SwiftF0, silero-vad, basic-pitch (Apache-2.0 + clean), dettato
   transcriber + evidence (Apache-2.0 + clean synthetic training — NOTICE obligation
   D-26.2 stands), demucs.cpp CODE, sevagh/pitch-detection (no training data).
2. **TIER B — SHIP WITH RECORDED RISK:** weights carry an EXPLICIT permissive
   license, but upstream training data has NC terms or is undocumented.
   Requirements: provenance + risk recorded in DECISIONS; **HUMAN SIGN-OFF before
   any commercial / App Store distribution** (v1 stays sideload-first per D-3, so
   Tier B is shippable for sideload builds); NEVER represented as "clean" — the
   licenses screen states the honest provenance line.
3. **TIER C — REFUSE:** no explicit license, explicitly NC-licensed weights, OR
   weights WE would train ourselves on NC data. The last is why D-7's
   NanoPitch-trained-on-GTSinger fallback stays banned: that is us CREATING
   encumbered weights — a different act from using upstream permissively-licensed
   ones. Unknown license = Tier C (verify-before-use, D-15, unchanged).

**M2 classification (demucs / htdemucs):**
- **demucs.cpp CODE = TIER A.** MIT © 2023 Sevag H verified VERBATIM at pinned
  HEAD `4edae497a114de1ccb17ac9b4a2b8fc0144714d7` (2026-11-06) — standard MIT
  text, no non-standard terms. Vendor intake per L-008 executes in this session
  (Leto lane, D-19.2 M1 precedent; P-201 = Paul's bridge/port/spike).
- **htdemucs WEIGHTS = TIER B.** facebookresearch/demucs @`e976d93ecc3865e5757426930257e200846a520a`
  (2023-11-16): MIT © Meta Platforms Inc. and affiliates — LICENSE read verbatim
  AND the README License section states blanket MIT for the release; the same
  README states htdemucs was "Trained on MUSDB HQ + an extra training dataset of
  800 songs" (lines 30/222) — MUSDB18 audio = CC BY-NC-SA (verified verbatim
  2026-11-21, D-21/X-310 forensics) and the 800-song extra set is undocumented.
  → Ships in M2 under Tier B: provenance + risk recorded HERE; human sign-off
  required before commercial distribution; sideload builds unaffected; licenses
  screen copy: "htdemucs weights © Meta (MIT); trained on MUSDB18 (CC BY-NC-SA)
  + additional data — training-data risk recorded (D-30)."
- **dettato grouper/drums: reclassified banned → TIER B** (weights carry an
  explicit Apache-2.0 license; training data MUSDB18/IRMAS NC — verified
  verbatim). FUNCTIONAL OUTCOME UNCHANGED: still not shipped in v1 (author
  admits weakest stage; 73 GM instrument classes; needs our synthetic-SATB
  retrain per D-21/X-301). D-21's benchmark/retrain plan stands.
- **NanoPitch weights: remain effectively TIER C** until the weights' own license
  is verified explicit-permissive (never done — D-7) AND human sign-off. Moot in
  practice: D-17's outcome (vendored MPM/YIN ribbon) is final for shipped v1.
- **Community RoFormer checkpoints (BS-Roformer-SW, MVSep 53-stem, viperx,
  KimberleyJensen, UVR/MDX): TIER B only if an explicit permissive weight license
  is verified (X-310 pending); TIER C otherwise.** Verify-before-use unchanged.

**Affects:** P-201..P-205, D-15 (baseline list gains the tier lens), D-17.2/D-21.3
(superseded ONLY in phrasing: blanket NC ban → Tier B process for upstream
explicit-permissive weights; self-trained-NC stays banned), AGENTS §9/§11
(amended by this ruling, separate commit), Models/manifest.json `license` fields
(Tier B entries must say so), J-204 licenses screen, L-602/L-603 (commercial
distribution gate = human sign-off checkpoint), X-310.

---

## D-31 | 2026-11-22 UTC | Leto | RULED (P-206 scope move)
**Context:** Paul carries 7 GATING M2 tasks (P-201..P-205, P-207, P-208). P-206
(windowed-roformer ONNX export + benchmark vs demucs.cpp) is an L-size R&D item
with no M2 gate dependency: htdemucs two-stem satisfies the M2 quality bar (§0
SDR ≥ 8 dB synthetic vocals), and a RoFormer swap is only decision-relevant when
the M6 quality-mode question is live (P-605, itself gated on X-310).
**Ruling:**
1. **P-206 MOVES from M2 (stretch) to M6** alongside P-605. PLAN.md tables updated
   by this ruling (M2 row removed; M6 gains it, non-gating stretch, deps:
   P-601 + shipped P-201 engine). AC unchanged: evaluation report in
   BENCHMARKS.md; swap proposal ONLY via a DECISIONS ruling. It can never threaten
   the M2 gate now.
2. **PAUL: do not claim P-206 during M2.** The QUEUE row (Paul's section — lane
   rule) stays where seeded; the M2 milestone header records DEFERRED→M6 (D-31)
   and the M3/M6 pre-seed block already shows it as non-gating. PLAN.md is the
   task source (AGENTS §0/§2) — PLAN is authoritative over the stale row text.
3. Flex note: if demucs.cpp SDR/RSS badly misses §0 targets at P-202, Paul files
   an X-task to pull P-206's EVAL (export-only, no ship) forward — Leto rules on
   the X-task; the default remains M6.
**Affects:** PLAN.md M2/M6 tables, QUEUE M2 header, P-206, P-605, M2/M6 gates.

---

## D-32 | 2026-11-22 UTC | Leto | RULED (M2 consolidation — L-201; confirms carry-overs, rules vendor split + weights source + Eigen)
**Context:** Dispatch asked for rulings labeled "D14" (tuning default), "D17"
(chunking), and confirmation of M0 carry-overs — those letters are taken (D-14
bootstrap exception; D-17 NanoPitch). Mapping: dispatch-D14 = **D-22, ALREADY
RULED** (2026-11-21); dispatch-D17 = **D-25, ALREADY RULED**. Confirmed here as
final for M2; no re-litigation.
**Ruling (consolidation):**
1. **Tuning default = D-22 CONFIRMED, FINAL:** estimate `tuning_cents` at import
   (P-207); grading offsets the REFERENCE (J-401 adds tuning_cents before
   deviation math) and the ribbon's note-name mapping adjusts; **stored
   audio/stems are NEVER resampled/retuned** (fidelity + artifact avoidance);
   retune happens transiently, in memory, ENGINE-SIDE, only for M3 transcription
   (P-308) when |tuning_cents| ≥ 10, times mapped back. UI indicator + user
   override = J-205. Matches the dispatch recommendation verbatim.
2. **Chunking = D-25 CONFIRMED, AUTHORIZED:** P-202 benchmarks Muskey's shipping
   recipe (4.5 s windows / 1 s overlap / crossfade) against our §8 5–10 s plan;
   decide by MEASURED SDR + RTF + RSS logged in BENCHMARKS.md, not preference.
   §8 text stands until the benchmark rules.
3. **M0 carry-overs CONFIRMED holding for M2:** D-2 (HF repo — EXECUTED via D-20,
   `thesagezm/pitchnotes-models` public, no token needed; weights URL swaps never
   change sha256), D-3 (bundle id `com.thesagezm.pitchnotes`, iOS 16.0,
   sideload-first), D-4 (JSON index v0 for M2 J-202; GRDB in M4), D-8 (44.1 kHz;
   voice stems MONO, INSTRUMENTAL STEREO), D-9 (always run two-stem; near-silent
   instrumental ⇒ `hasInstrumental=false`). No gaps found; progress/cancel
   callback shape is CONTRACT work → L-203 (v1.0 freeze), not a ruling.
4. **Vendor-intake split for P-201 (D-19.2 M1 precedent):** LETO performs the
   demucs.cpp vendor intake (license verification, pin, LICENSE + intake README +
   patches.log) — executing this session; PAUL's P-201 = C++17→Swift bridge
   (`Engine/Separation/DemucsEngine`), threading work, spike, benchmarks. Intake
   scope: upstream `src/**` + Eigen headers only; EXCLUDED (logged in
   patches.log): `cli-apps/` + `vendor/libnyquist` (CLI audio I/O — AVFoundation
   replaces it), `vendor/googletest` (tests), `vendor/demucs` (sevagh's Python
   conversion fork — Linux-side tooling, never compiled into the app).
   **Verified fact recorded: demucs.cpp `src/` (8,640 lines) contains ZERO OpenMP
   pragmas** — "OpenMP requirement" is Eigen's optional parallelism (absent
   `-fopenmp` it runs serial); the CLI multithreading already uses std::thread.
   P-201's port = add std::thread/GCD parallelism around Eigen ops + benchmark.
5. **Eigen = SHIP-SAFE (new license class, D-15 procedure):** header-only MPL-2.0
   verified at demucs.cpp's pinned submodule `dd8c71e62852b2fe429edb6682ac91fd1c578a26`
   (COPYING.README: "primarily MPL2"; some files BSD/MPL2-compatible). File-level
   copyleft binds only modified files; we vendor unmodified headers at the pin
   and keep LICENSE notices (licenses screen via intake). MPL-2.0 joins the
   ship-safe list for this and future intakes.
6. **WEIGHTS SOURCE for htdemucs fp16 ggml:** PRIMARY = convert from the OFFICIAL
   Meta .pth (host `https://dl.fbaipublicfiles.com/demucs/`, demucs/pretrained.py:20
   @e976d93e) using demucs.cpp's `convert-pth-to-ggml.py` at the pinned commit —
   authoritative provenance chain (D-26.1 precedent: convert from upstream
   ourselves). FALLBACK = pin `Retrobear/demucs.cpp` HF dataset
   `ggml-model-htdemucs-4s-f16.bin` (84 MB, MIT-tagged repo, linked from the
   demucs.cpp README itself) with the SHA256 trust anchor. Either path: mirror to
   `thesagezm/pitchnotes-models` via `scripts/models/hf_upload.sh` (D-20 flow —
   sha256 pinned at first verification, never changes), `Models/manifest.json`
   `license` field reads "MIT (Tier B per D-30: training-data risk recorded)",
   attribution lands in NOTICE + the J-204 licenses screen. Paul picks the path
   operationally; the trust requirements above are mandatory either way.
7. dettato "±35c → F1 0.81→0.96" remains VERIFICATION PENDING (human-reported;
   not M2-relevant — P-307/P-308 will measure our own number).
**Affects:** L-201, P-201..P-207, P-202 (D-25 execution), P-308/J-205/J-401 (D-22
execution), vendor/demucs.cpp intake, Models/manifest.json, J-204, X-310.

---

## D-29 | 2026-11-22 UTC | Leto | RULED (executes X-014; amends D-13)
**Context:** X-013 forensics (paul, 2026-11-22T04:45Z): the ORT mirror's ObjC
element-type table (`kElementTypeInfos`, ort_enums.mm) lacks `double`, so SwiftF0's
`pitch` output (tensor(double)) throws "unsupported tensor element type" (NSError
Code=9) at session.run. Repo forensics prove the mirror is BYTE-IDENTICAL to the
pre-pull upstream (fork-wave diff = zero) — the gap is upstream's own, faithfully
preserved by the re-host; not a mirror defect. SwiftF0 model I/O verified via
Python: inputs audio tensor(float) [1,samples] + fmin/fmax tensor(float) [];
outputs pitch tensor(double) [1,frames] + confidence tensor(float).
**Ruling:**
1. **X-014 EXECUTED by Leto (mirror lane):** thesagezm/onnxruntime-swift-package-manager
   main @837832e adds `ORTTensorElementDataTypeDouble` (ort_enums.h, appended LAST —
   implicit enum values stable) + the kElementTypeInfos row
   `{ORTTensorElementDataTypeDouble, ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE,
   sizeof(double)}` (ort_enums.mm) — upstream-faithful 1-line-equivalent fix,
   matching microsoft/onnxruntime's own objectivec wrapper (which supports Double).
2. **Tag 1.24.2 re-pointed 7dbd851 → 837832e** per the D-18.2 re-host precedent
   (same version, new rev): pod archives BYTE-IDENTICAL (untouched — the C core
   binaries are unaffected); only the objectivec wrapper source changes (it builds
   from source). project.yml pin unchanged (tag 1.24.2); **D-13's recorded rev is
   now 837832e** (was b7fb7f7 → 7dbd851 → 837832e). No Package.swift bump needed
   anywhere — Paul's planned 1-line `.exact()` bump is a NO-OP (do nothing).
3. **Verified end-to-end (leto run 44989794347 ALL 8 GREEN; main re-proofs
   44990383509/44992437628):** all 4 swiftf0 real-model tests pass — ±20c steady
   tone, silence gate, streaming==batch parity, 44.1k resample — executing the
   double path through the fixed table.
**Affects:** D-13/D-18.2, X-014 (CLOSED), Engine/PitchORT, project.yml comment,
X-013 closure.

---

## D-27 | 2026-11-21 UTC | Leto | RULED (human-confirmed)
**Context:** GitHub Actions quota wall: the free plan's 2,000 included minutes/month are
shared by all private repos on the account and bill macOS runners at 10×; pitchnotes-ios
(~40 runs) + speechnotes-ios (~71 runs) since Nov 1 exhausted them, so all 7 jobs fail at
0 s with the misleading "recent account payments have failed" boilerplate (no card on
file, nothing owed — verified via check-run annotations + run billing data). Jess filed
X-007 PROPOSED (CI minute diet) @c6aeb59. The human ruled: "solve this — I don't mind
public repo."
**Ruling:**
1. **`pitchnotes-ios` is now PUBLIC** (flipped via API 2026-11-21 by Leto on the human's
   explicit instruction). This SUPERSEDES the L-001 "private" call. Consequences: Actions
   minutes free/unlimited (quota wall gone — proven: run 44881046959@cf9561e ALL 7 JOBS
   GREEN incl. the D-2 HF-model download verification steps); source visible (no secrets
   in git — HF token lives only in the human's ~/.bashrc, never committed; weights stay
   in HF, never git).
2. **Branch protection on `main` ENABLED** (possible on public repos — resolves the L-001
   BLOCKED(human) residue): force-push and deletions blocked, admins not enforced,
   NO required status checks — deliberate: our merge model is direct green-verified
   pushes (milestone merges), and required-check protection would deadlock that flow.
   Procedural rails (AGENTS §3/§11) + this soft protection now both apply.
3. **X-007 (Jess, quota diet) SUPERSEDED by this ruling** — moot under free unlimited
   minutes; macOS runners STAY (they validate the Apple toolchain). If the repo ever
   goes private again, re-propose the diet.
4. **X-007 (Paul's duplicate filing — build.yml YAML line-148 colon fix) ALREADY
   RESOLVED** by f5d2a96 (on main since 953e105). Paul's red pushes were pre-rebase
   artifacts; his rebase onto current origin/main resolves his branch CI. ID collision
   noted: renumber any FUTURE quota-related proposal (not needed — superseded).
5. **X-008 (Paul, PitchORT wiring) ACCEPTED — executes at L-103 gate time**, one commit
   immediately after the paul→main merge and BEFORE tagging m1: (a) project.yml packages
   += `PitchORT: {path: Engine/PitchORT}`; (b) app target deps += package PitchORT
   (static); (c) logic-tests job += `cd Engine/PitchORT && swift test` after the swiftf0
   download step (model cache warm; XCTSkip-safe locally); (d) spike venvs += onnxruntime
   and, at the same commit, L-101 flips the real-spike env (`PITCHNOTES_SPIKE_REAL:
   required`) and removes continue-on-error. Rationale for gate-time execution: PitchORT
   exists only on paul's branch — landing (a)/(b) on main earlier would break
   xcodegen/build-ipa.
6. **speechnotes-ios flag (human's other private repo, same shared quota):** it will keep
   draining until reset unless made public or dieted. Human's call; not this repo's lane.
**Affects:** L-001 residue, X-007 (both), X-008, L-101/L-103 sequence, QUEUE BLOCKED,
RESEARCH none.---

## D-20 | 2026-11-21 UTC | Leto | RULED (executes D-2)
**Context:** The human authorized Leto to create the HF model repo ("you can create the
repo: when the HF repo lands, swap URLs only — SHAs must not change"). No HF credential
existed in the environment; the human created a fine-grained Write token and made it
available via `~/.bashrc` (`HF_TOKEN`).
**Ruling:**
1. **D-2 is EXECUTED.** `thesagezm/pitchnotes-models` created **public** (id
   `6b013fbf71c703296dc90e79`, 2026-11-21). Uploaded via `scripts/models/hf_upload.sh`
   (runbook committed @4c23177, fixed @05af094) and verified **byte-identical**:
   `swiftf0/model.onnx` (135090 B, sha256 6385e8c2…b0a22), `silero-vad/silero_vad.onnx`
   (2327524 B, sha256 1a153a22…88e3), `test-blob/test-blob.bin` (1024 B, sha256
   785b0751…c26c9) — each re-downloaded from HF and hashed back to the manifest values.
2. **`Models/manifest.json` URLs swapped to the HF re-hosts @543cc4f; `sha256`/`size`
   fields UNCHANGED** (byte-identity is the trust anchor). `http-probe` retained as the
   independent generic network check; the CI `file://` test-blob override is retained to
   exercise the override path. Local download+verify proven for all three entries; CI
   proves it on the next run.
3. Public repo ⇒ CI and devices download WITHOUT a token. Future model uploads (M2+)
   use `hf_upload.sh`; URL swaps never change sha256.
**Affects:** D-2, D-19.4, `Models/manifest.json`, `scripts/models/hf_upload.sh`,
L-005/L-101 follow-ups, all future model tasks.

## D-21 | 2026-11-21 UTC | Leto | RULED (adopted from amendment proposal "D13"; M3 note engine)
**Context:** RESEARCH Addendum A (dettato). The transcriber's DCS choral row (onset
55.9/frame 82.0/offset 44.4 vs MuScriptor 14.4/80.7/11.5) dwarfs the polyphonic-note
status quo; code+weights Apache-2.0, transcriber/evidence training data commercially
clean. But it is a 15.3M-param PyTorch model with no ONNX export; CPU cost on A14
unknown; scores are PART-AGNOSTIC and author-self-reported (reproducible via
`kobimusic/dettato-benchmark`).
**Ruling:** dettato transcriber becomes a CANDIDATE to replace `basicpitch.cpp` as the
M3 primary note engine.
1. **Benchmark head-to-head** (P-307): dettato port vs basicpitch.cpp on Dagstuhl
   ChoirSet / CSD + synthetic SATB + local real SDA songs; parity-tested per D-24.
2. **Adoption threshold: A14 import RTF ≤ ~3× song length** → dettato PRIMARY; else
   basicpitch.cpp stays the fast path and dettato ships as an OPTIONAL quality-mode
   download (user-selectable, P-604 pattern). Levers to hit the threshold:
   transcriber-only (no grouper), fp16, hop 2 s → 4 s.
3. **NEVER ship grouper or drums weights** (NC training data: MUSDB18/IRMAS — Addendum
   A.1; confirmed verbatim on the grouper card). Grouper ARCHITECTURE + distinct-tracks
   decode heuristics MAY be reimplemented and retrained on our clean synthetic SATB
   (X-301) — the algorithm is not encumbered, the weights are.
4. Evidence-repairer weights are clean (verified) but optional — see P-309 (gated on
   X-310 completing the license bundle).
5. Any dettato-derived port/weights carry the Apache-2.0 NOTICE attribution (D-26).
**Affects:** P-301/P-303/P-306/P-307/P-308/P-309, X-301/X-310, M3 gate, AGENTS §9 (D-26),
RESEARCH Addendum A.1.

## D-22 | 2026-11-21 UTC | Leto | RULED (adopted from amendment proposal "D14" + insight C; tuning reference)
**Context:** Grading assumes A440 equal temperament. Old SDA recordings often sit
systematically sharp/flat (tape, varispeed, group tuning by ear) — a singer reproducing
the RECORDING faithfully would be marked ~tens-of-cents off on every note. Invisible,
systematic grading failure. dettato already solves the detection side (`retune.py`,
`MIN_CENTS = 10.0`, estimate ±50c via circular mean of refined spectral maxima).
**Ruling:** ADOPT.
1. **Estimate `tuning_cents` at IMPORT (M2, P-207)** — same estimator family as dettato
   (circular-mean of spectral-peak deviations, ±50c clamp), stored in `song.json`
   (CONTRACTS v0.1.1, optional now / required at the v1.0 freeze per L-203 pre-staging).
   Default 0 when the estimate is weak (low salience or <10c).
2. **Default behavior = OFFSET THE REFERENCE, never mutate stored audio.** Grading adds
   `tuning_cents` to the reference pitch before deviation math (J-401); the UI shows an
   indicator ("this recording is +32c sharp — reference adjusted") with a user override
   (J-205). Audio/stems stay byte-true — no resample of the user's library.
3. **Transcription consumes it as an ENGINE-SIDE retune** (P-308, dettato approach):
   when |tuning_cents| ≥ 10, retune IN MEMORY before transcription and map times back —
   never touching the stored files.
4. Live ribbon unaffected in M1 (mic path is relative to the selected part's reference;
   tuning_cents enters at grading, M4).
**Affects:** P-207/P-308/J-205/J-401, CONTRACTS v0.1.1 + v1.0 pre-stage (L-203),
RESEARCH Addendum A.3.

## D-23 | 2026-11-21 UTC | Leto | RULED (adopted from amendment proposal "D15"; M6 CoreML strategy)
**Context:** Muskey's shipping Swift port found Core ML runs dettato's GRUs far slower
than Accelerate, and ships the transcriber as FOUR models cut at the three GRUs with
Accelerate between them (Addendum A.2.1).
**Ruling:** ADOPT for the M6 CoreML phase: split the graph at GRUs — conv/attention
blocks on CoreML (ANE), GRUs via Accelerate/BNNS. **IMPORTANT NUANCE recorded
explicitly: this is CoreML-SPECIFIC. ONNX Runtime's CPU GRU is fine, so the M1–M5 CPU
path stays a SINGLE ONNX graph** (D-13: no second runtime; CoreML EP remains a later
acceleration on the same models). P-601's AC amended accordingly.
**Affects:** P-601, M6 gate, D-13, RESEARCH Addendum A.2.

## D-24 | 2026-11-21 UTC | Leto | RULED (adopted from amendment proposal "D16"; spike methodology)
**Context:** Muskey's `--dettato-check DIR` pattern: port-vs-Python numerical PARITY
against saved reference tensors — strictly stronger than our current shape/range spike
assertions.
**Ruling:** ADOPT. Spike harness gains numerical-parity assertions (Python reference
tensors vs Swift/ORT outputs, tolerance-based) — effective M2 via P-208. **M1 exports
(SwiftF0/silero) should CAPTURE reference tensors NOW** (cheap, avoids rework): the
non-gating ask to Paul folded into P-101/P-103 or deferred to P-208 — never blocking
the M1 merge.
**Affects:** P-208, Tests/Spikes harness, P-101/P-103 note, CONTRACTS v0.1.1 (C-7).

## D-25 | 2026-11-21 UTC | Leto | RULED (adopted from amendment proposal "D17"; M2 chunking)
**Context:** Muskey ships separation in 4.5 s windows / 1 s overlap / crossfade; our M2
plan says 5–10 s windows (§8).
**Ruling:** Benchmark BOTH at P-202 (measured SDR + RTF + RSS on the CI runner, logged
in BENCHMARKS.md); pick by measurement, not preference. The §8 5–10 s text stays until
the benchmark rules.
**Affects:** P-202 AC (amended), Docs/BENCHMARKS.md, RESEARCH Addendum A.2.3.

## D-26 | 2026-11-21 UTC | Leto | RULED (adopted from amendment proposal "D18"; sourcing boundary + AGENTS §9 amendment)
**Context:** Muskey is an excellent engineering reference with a toxic-for-us license
stack; dettato's license requires NOTICE attribution; two third-party checkpoints are
unverified.
**Ruling:**
1. **Muskey = STUDY-ONLY, forever:** never link or copy code; never hotlink
   lowtechguys.com models; convert from upstream weights ourselves. Techniques
   reimplemented AGPL-clean (ideas only, per AGENTS §9 study-only discipline).
2. **Apache-2.0 NOTICE obligation:** any dettato-derived port or weights MUST carry the
   upstream NOTICE text ("Dettato, Copyright 2026 KobiMusic. This product includes
   software and model weights developed by KobiMusic.") in our repo NOTICE file and the
   in-app licenses screen (J-204 reads vendor/ + NOTICE).
3. **Verify-before-use additions:** dettato-evidence model card terms (now verified
   clean — see X-310 residual), BS-Roformer-SW checkpoint, MVSep 53-stem checkpoint.
4. **AGENTS.md §9 amendment (via this ruling, per AGENTS' change rule):** ship-safe list
   += dettato transcriber (Apache-2.0, clean training data) with the NOTICE note;
   verify-before-use += dettato-evidence (verification largely done — record verdict),
   BS-Roformer-SW, MVSep 53-stem; study-only += FuzzyIdeas/Muskey (AGPL + static
   GPL/Essentia deps); NC list += dettato-grouper and dettato-drums weights
   (MUSDB18/IRMAS). File map: Docs/RESEARCH.md owner = Leto. Edits committed separately.
**Affects:** AGENTS.md §9/§12, P-309/P-605, X-310, NOTICE file (M6), J-204 licenses screen.

## X-310 | 2026-11-21 UTC | Leto | OPEN (Leto owns) — UPDATED 2026-11-22: (c)+(d) RULED
**Question:** LICENSE VERIFICATION BUNDLE (verify-before-use, per D-15/D-26): (a) confirm
dettato transcriber + evidence Apache-2.0 + exact NOTICE text — **transcriber DONE
(verified 2026-11-21), evidence DONE (card verified: Apache-2.0, synthetic-only training)
— residual: the ~20 "soundfont babies" soundfonts' file licenses**; (b) confirm grouper
NC terms — **DONE (MUSDB18 academic/CC BY-NC-SA + IRMAS CC BY-NC-SA 3.0 confirmed verbatim;
weights NEVER ship)**; (c) BS-Roformer-SW checkpoint license — **RULED 2026-11-22 (below)**;
(d) MVSep 53-stem checkpoint license — **RULED 2026-11-22 (below)**; (e) drums NC —
**DONE (README confirms)**. Record each verdict here.
**2026-11-22 verdicts (Leto, primary sources, D-30 tier lens):**
- **(c) BS-Roformer-SW = TIER C (REFUSE) as of today.** HF mirrors
  (FractalSurfer/BS-RoFormer-SW-6stem — byte-for-byte mirror of
  enerjazzer/BS-ROFO-SW-Fixed) carry license tag "unknown" with the card stating
  verbatim: "Upstream declares no license (license: unknown). This mirror grants no
  additional rights." Original author jarredou's HF account is DELETED; no
  authoritative license statement exists anywhere in the chain; training data
  undocumented. P-605's BS-RoFormer-SW path CANNOT ship. Re-classification path: only
  if an authoritative author statement (surfacing author or rights holder) grants an
  explicit permissive license → then Tier B at best (training data still undocumented).
  P-605's live path: windowed-roformer (Smule MIT — weight-availability/license
  verified when P-605 opens) and/or demucs.cpp Tier B baseline.
- **(d) MVSep Mega 53-stem (ZFTurbo MSST) = TIER C (REFUSE) as of today.** MSST CODE
  repo is MIT (verified) — but that covers CODE; the 53-stem CHECKPOINT carries NO
  author license declaration (canonical repo shares checkpoints via releases/issues
  "with no license terms attached"; docs/pretrained_models.md has no license column).
  Third-party mirrors (e.g. Audante int8) tag MIT "as the source" while stating
  "All rights to the model remain with its authors" — derivative tags, not
  authoritative. Training data undocumented. Re-classification path: an explicit
  license statement by ZFTurbo (active, contactable) in the repo/release → Tier B at
  best (training data still undocumented). Muskey's MVSep-53-stem woodwind route
  (RESEARCH A.2.2) is unusable for us.
- **Residual (a) soundfont-babies file licenses: still PENDING** — gates X-301 (M3
  prep) and P-309/P-605 indirectly; not an M2 gate item.
**Affects:** D-21.4, D-30 (tier lens), P-309, P-605, M6, X-301.

## X-311 | 2026-11-21 UTC | Leto | OPEN (Paul owns; M3 prep, NON-GATING)
**Question:** Read dettato's published "soundfont babies" soundfont-morphing technique
(kobi.music/research/making-soundfont-babies) and the `kobimusic/dettato-benchmark` HF
dataset; apply both to X-301 synthetic SATB generation and to our M3 evaluation harness
(per-set mir_eval reporting). No integration before X-310 soundfont verdicts.
**Affects:** X-301, P-106/P-306, X-310(a-residual).

---

## D-19 | 2026-11-21 UTC | Leto | RULED (executes D-7/D-17; closes M0 X-task residue)
**Context:** M1 open. The session plan orders three Leto actions before lane work:
(a) execute D-17 — independently verify the `sevagh/pitch-detection` license (do not
trust the dossier), perform the vendor intake per L-008, and resolve the spike-job
naming; (b) close the leftover M0 X-task accounting (part presets, MockEngine
scenario surface, logic-tests wiring, portable Foundation-only test package, HF repo
status); (c) ratify CONTRACTS v0.1 early so P-105 is unblocked (separate commit, L-102).
**Ruling:**
1. **`sevagh/pitch-detection` LICENSE VERIFIED by Leto, independent of the dossier:**
   upstream `LICENSE` read verbatim at pinned tag **v2023.12 = `faa04bb262476bdc0490f4bb3ffd7c6cdeeb3052`**
   — standard MIT text (© 2018 Sevag Hanssian), no non-standard terms. SHIP-SAFE.
2. **VENDOR INTAKE COMPLETE per L-008** (@47410e6): `vendor/pitch-detection/` —
   LICENSE verbatim, intake-record README, patches.log, and a SUBSET of upstream:
   `include/pitch_detection.h` + `src/{mpm,yin,autocorrelation,parabolic_interpolation}.cpp`
   (deterministic MPM/YIN only). Two deliberate exclusions, logged in patches.log:
   (a) the mlpack-backed probabilistic HMM variants (`pmpm`/`pyin`/`hmm.cpp`) —
   mlpack is Apache-2.0 (permissive) but a huge dependency we do not need; re-intake
   + new ruling required before any probabilistic use; (b) upstream FFTS hard
   dependency replaced by a PitchNotes-local C-ABI seam (`include/pd_fft.h` +
   `src/pd_fft_backend.cpp`) backed by **kissfft v131 (`0bfa4d5…`, BSD-3-Clause —
   per-file SPDX headers verified)** vendored under `third_party/kissfft/`. FFTS
   itself was ALSO verified BSD-3-Clause (upstream COPYRIGHT read at HEAD `b22d839`)
   but is NOT vendored — the seam keeps the third-party surface minimal and lets
   P-102 bind vDSP/Accelerate on iOS later. Intake verification: **13/13 checks**
   (mpm/yin recover integer-period sines < 0.01 Hz, E2 82.4 Hz + 440 Hz on the
   complex path, silence → −1, float+double, allocation reuse; `kiss_fftri`
   natural-order output probed vs a complex-IDFT reference, rms 2.5e-05). The
   upstream CIRCULAR-autocorrelation leakage artifact (non-integer periods bias
   the estimate) is documented in the intake README as an engineering note for
   P-102 — it is upstream-faithful behavior, not an intake defect.
3. **SPIKE JOB RENAME: `nanopitch-spike` → `ribbon-spike`.** Rationale: D-17 bans
   NanoPitch pretrained weights (GTSinger NC data); the M1 gate spike now tests the
   D-17 ribbon default (vendored MPM/YIN), so the frozen name would misreport WHAT
   was tested at the merge gate. Leto updates `.github/workflows/build.yml`,
   PLAN.md (M1 CI jobs + gate + P-102 row context via this ruling), AGENTS.md §6 job
   list, and the QUEUE M1 gate text. P-102's deliverable is unchanged (D-17
   fallback-becomes-default ribbon); its spike reference is `ribbon-spike`. The
   ribbon-spike job runs the P-002 mock harness until Paul's P-102 delivers the
   real C++ runner (compiled vendored MPM/YIN against the synthetic fixtures). If a
   clean NanoPitch retrain ever lands (D-17.2), it gets its OWN future job
   (`nanopitch-retrain-spike`) — never the ribbon name.
4. **M0 X-task residue, ruled:**
   - **Part range presets (X-001)** → ratified into CONTRACTS **v0.1** as C-6.1
     (verbatim UX.md §3.6 table, calibratable per UX §3.6 calibration spec).
     Ratified in the L-102 commit of this session; UX §3.6 remains the
     human-facing spec, CONTRACTS C-6.1 the single interface source of truth.
   - **MockEngine scenario surface** → remained STRUCK by D-16.4 (P-001
     `MockScenario` init parameter satisfies it; no frozen surface).
   - **logic-tests wiring to the real test targets** → DONE (D-16.5 wired
     EngineCore into logic-tests at L-009; Jess's X-006 swap adds her
     `Tests/Logic` package dependency on her branch).
   - **Portable Foundation-only test package** → SATISFIED by `EngineCore`
     (Engine/ SPM package is Foundation-only, compiles + tests green on Linux
     swift 6.0.3 and the macOS CI runner). No separate package; no action.
   - **HF repo (D-2)** → still BLOCKED(human). INTERIM RULE for L-101/M1:
     `Models/manifest.json` gains real-model entries pinned to UPSTREAM public
     URLs + Leto-verified SHA256 (swiftf0 from `aaatmy/swift-f0-onnx`, silero-vad
     from the official snakers4 release) so CI exercises the REAL
     download→verify→spike path before the HF repo exists; when the human creates
     `thesagezm/pitchnotes-models`, the URL fields swap to HF re-hosts (SHA256
     values MUST NOT change — byte-identity is the trust anchor). Human
     re-escalated in LOG; M1 does not stall on this.
5. **P-102 AC note:** the ribbon RTF target (< 0.1 native) and spike expectations
   apply to the vendored MPM/YIN path; RTF/RSS numbers logged in
   Docs/BENCHMARKS.md per the honesty rule.
**Affects:** `vendor/pitch-detection/**`, P-102, P-105, L-101, L-102, L-103,
`.github/workflows/build.yml`, `Models/manifest.json`, PLAN.md M1, AGENTS.md §6,
CONTRACTS v0.1, X-001, D-7/D-17/D-15.

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
