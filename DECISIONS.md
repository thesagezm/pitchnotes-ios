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

## X-310 | 2026-11-21 UTC | Leto | OPEN (Leto owns)
**Question:** LICENSE VERIFICATION BUNDLE (verify-before-use, per D-15/D-26): (a) confirm
dettato transcriber + evidence Apache-2.0 + exact NOTICE text — **transcriber DONE
(verified 2026-11-21), evidence DONE (card verified: Apache-2.0, synthetic-only training)
— residual: the ~20 "soundfont babies" soundfonts' file licenses**; (b) confirm grouper
NC terms — **DONE (MUSDB18 academic/CC BY-NC-SA + IRMAS CC BY-NC-SA confirmed verbatim;
weights NEVER ship)**; (c) BS-Roformer-SW checkpoint license — PENDING (needed before any
P-605 quality-mode ship); (d) MVSep 53-stem checkpoint license — PENDING (same gate);
(e) drums NC — **DONE (README confirms)**. Record each verdict here.
**Affects:** D-21.4, P-309, P-605, M6.

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
