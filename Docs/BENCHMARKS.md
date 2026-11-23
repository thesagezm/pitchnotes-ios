# Docs/BENCHMARKS.md — PitchNotes-iOS measured results

> **Owner:** Paul. **Version:** v1.6 (§4.1 P-202 L3 chunk-policy benchmark filled —
> D-25 protocol applied, Rule 3 escalation; §5–§6 fill at M3/M6).
> **Honesty rule (AGENTS §11 / PLAN §0):** every engine task logs measured numbers
> here; no overclaiming; CI-runner numbers are labeled as such (A14 device numbers
> come from human-assisted device runs).

## 1. Methodology (fixed v0 — do not drift without a Leto ruling)

- **RTF** = inference_time / audio_time (wall clock, single run on otherwise-idle
  machine; report the median of ≥3 runs). One CPU core pinned for pitch benchmarks
  (pitch-benchmark methodology); separation uses the ORT/thread config it ships with
  (ORT `intra_op_num_threads` 2–4 per §8, benchmarked not guessed).
- **Pitch F1@50c** = for each frame pair (est, ref): cents = 1200·log2(f_est/f_ref);
  hit iff both voiced AND |cents| < 50; F1 over hits vs voiced-ref/voiced-est sets
  (pitch-benchmark definition; raw-pitch accuracy variants RPA/RCA reported alongside).
- **Voicing** = hz > 0 (contract V11 semantics: 0.0 = unvoiced).
- **SDR / NSDR** (separation, M2+): mir_eval/museval definitions; NSDR vs the input
  mixture as reference for vocals/instrumental.
- **Note metrics** (M3+): onset/offset F1 @50 ms; part-aware macro F1 (PawCT-style,
  @50 ms) — reported WITHOUT overclaim (published SOTA ≈ 0.225 real).
- **RSS** = peak resident set size via task_info/RSS APIs on device, `/usr/bin/time -l`
  or equivalent on runners; thermal state (`ProcessInfo.thermalState`) logged alongside.
- **Latency** = mic capture → PitchFrame emitted (loopback measured, J-403 hook).
- **Parity (D-24/C-7, P-208):** Swift/ORT outputs vs committed Python reference tensors (Tests/Spikes/ReferenceTensors/, C-7 sidecars) on committed fixtures; pass = every element within abs 1e-3 OR rel 1e-4 of the reference; model+fixture sha256 binding asserted before comparison. Tolerance changes need a recorded ruling (never tightened silently).
- **Environment rows:** every result cites {runner/device, OS, build sha, model sha256}.
- Fixtures for repeatable runs: `Tests/Spikes/Fixtures/` (synthetic, seeded,
  byte-identical — P-001); real SDA songs local-only, results reported but audio
  never committed.

## 2. Targets (from PLAN §0 — ratification source)

| Metric | Target | Source of truth |
|---|---|---|
| Live monophonic pitch F1@50c (synthetic clean) | ≥ 0.75 | SwiftF0 0.781 / RMVPE 0.768 (pitch-benchmark) |
| Live pitch RTF on A14 | < 0.3 | SwiftF0 179.6× RT / NanoPitch RTF 0.1–0.3 WASM |
| Live feedback latency | < 100 ms | NanoPitch causal (0 lookahead); SwiftF0 176 ms grading-only |
| Separation SDR (vocals, synthetic) | ≥ 8 dB | htdemucs ~9.2; windowed-roformer 11.17 (MUSDB) |
| Per-part NSDR (real acapella, post-v1) | 4–14 dB by part | ACappellaSet S4.05/A4.41/T7.91/B10.50; jaCappella MRDLA |
| Part-aware note F1 (real, heuristic) | 0.2–0.4 honest | PawCT 0.225 macro @50 ms = published SOTA |
| Peak RSS during separation | < 1.5 GB | A14 6 GB jetsam ~3 GB |
| Core model bundle | < 200 MB | demucs fp16 81 + SwiftF0 ~0.06 + NanoPitch ~1.3 + basic-pitch ~2 + silero ~2 MB |

## 3. Results — live pitch (M1: P-101/P-102/P-105/P-106)

*Empty — fills at M1. Columns: engine | fixture | F1@50c | RPA | RTF (1 core) |
RSS | env {runner/device, sha}.*

| Engine | Fixture | F1@50c | RPA | RTF | RSS | Env |
|---|---|---|---|---|---|---|
| swiftf0 (pinned 6385e8c2…, 1 thread) | sweep_46_2100Hz_16k | **0.764** (prec 1.000, RCA 0.618; \|cents\| med 7.39 / p95 17.41 < 20 AC — F1 gap = pure-sine confidence gating, note ¹) | 0.618 | 0.0156 (4 s audio, med-5) | n/m (dev box) | Linux x86_64, Pop!_OS 24.04, py3.12 + ort 1.32.0, paul @291b084, 2026-11-21 (F1 @ P-106 harness) |
| swiftf0 (2 threads) | sweep | 0.764 (byte-equal output — determinism) | 0.618 | 0.0098 | n/m | same env |
| swiftf0 (4 threads) | sweep | 0.764 | 0.618 | 0.0089 | n/m | same env |
| swiftf0 | synthetic_voice_16k (±15c vibrato melody) | **0.986** (prec 0.986, RCA 0.986; \|cents\| med 3.06 / p95 9.35; 281/281 truth-voiced frames voiced) | 0.986 | — | — | same env |
| swiftf0 | silence_16k | n/a — all frames gated (conf→0, hz→0); empty voiced sets | — | — | — | same env |
| silero-vad (pinned 1a153a22…, 1 thread) | silence_16k | gated: max prob 0.009 | — | 0.23 ms / 32 ms chunk (med-500, p95 0.90 ms; budget <1 ms) | n/m | same env |
| silero-vad | synthetic_voice_16k | detected: max 0.961 (margin 0.952 over silence) | — | — | — | same env |
| silero-vad | noise_burst / click_track | correctly NON-speech: max 0.125 / 0.015 (speech-VAD semantics — M0 mock asserted energy-VAD) | — | — | — | same env |
| ribbon Swift MPM (RibbonEngine, P-102/P-105 live source) | 220 Hz sine 20 s, 640-sample (40 ms) pushes | n/a — tone acc ±10 c mid-frames (LivePitchFacadeTests) | — | **0.093 best-of-3 −O** (per-40 ms-chunk 3.7–4.0 ms; budget < 0.1 PLAN M1; est. 0.02–0.03 was optimistic — direct-NSDF Swift inner loop is scalar, no SIMD) | n/m (dev box) | Linux x86_64, Pop!_OS 24.04, swiftc 6.0.3 -O, paul @b2868ce+facade, 2026-11-21 |
| ribbon Swift MPM (RibbonEngine) | synthetic_voice_16k (P-106 bench) | **0.982** (prec 0.982, RCA 0.982; \|cents\| med 1.63 / p95 2.67; 280/281 truth-voiced) | 0.982 | — | n/m | same env (Tests/Spikes/bench_f1.py, window-center truth) |
| ribbon Swift MPM (RibbonEngine) | sweep_46_2100Hz_16k (P-106 bench) | **0.925** (prec 1.000; \|cents\| med 0.20 / p95 0.96 — direct NSDF, no circular-acorr leakage: beats the vendored FFT path on the chirp) | 0.861 (69 unvoiced ≈ the sweep's 1.15 s below the 80 Hz MPM floor — expected, not an error mode) | — | n/m | same env |
| ribbon vendored C++ sevagh (CI spike, app bind via X-009) | synthetic_voice / sweep / clicks | voice **0.977** (prec 0.979, RCA 0.975; \|cents\| med 1.32 / p95 5.80); sweep@1024 **0.896** (prec 0.972; med 5.86 / p95 42.47 — windowed-chirp lag + circular-acorr leakage, vendor note); sweep@2048 p95 19.4 | voice 0.975 / sweep@1024 0.831 | 0.0014 (≪ 0.1; ~66× faster than the Swift MPM — validates X-009 app-side vendor compile as the shipping hot path; Swift path = portable tests + facade semantics) | n/m | same env (Tests/Spikes/ribbon_real.py + bench_f1.py) |

¹ **swiftf0 × pure-sine sweep — F1 0.764 is confidence gating, not pitch error.** The
sweep fixture is a bare sine; when SwiftF0 voices a frame it is correct (precision
1.000, |cents| med 7.39). It voices 309/500 frames: voiced fraction 0.97 above
1 kHz, 0.70 in 100–1000 Hz, 0.03 below 100 Hz — the model (trained on real vocal
audio) is under-confident on harmonic-free tones, most of all in the sub-100 Hz
tail. The harmonic-rich synthetic_voice fixture voices 281/281 (F1 0.986). AC
carrier: F1 ≥ 0.75 holds on BOTH synthetic-clean fixtures (0.764 / 0.986).
RCA == RPA on every row: zero octave errors on clean synthetic. Regenerate:
`~/.venvs/pitchnotes/bin/python -I Tests/Spikes/bench_f1.py --assert`
(see Tests/Spikes/README.md §bench; report artifact
Tests/Spikes/bench_report_v1.json; CI job = X-012, non-blocking).

**CI-runner + A14 numbers: PENDING** — parked on the X-008/X-007-healed CI (first
green run on the fixed build.yml will add the macOS runner row via the swiftf0/
silero spike logs; A14 device numbers via Jess's debug screen J-103 at the M1
device demo). RTF method per §1 (median of 5; pitch bench pinned to 1 core
on-device via ORT session `intra_op_num_threads`, thread scaling 1→2→4 logged).
RSS measurement arrives with P-104 (device) — dev-box RSS not meaningful for the
A14 budget and is not faked.

## 4. Results — separation (M2: P-201/P-202/P-206)

*Columns: engine/model | fixture | SDR vocals | NSDR | chunk config | wall time
(4-min synth) | peak RSS | thermal | env. P-201 spike harness:
`Tests/Spikes/run_spike.py --spike separation` (demucs_real.py) — finite (S3),
**instrumental** non-silent (S4 — honest gate: the mix44k fixture is PURE
SYNTHETIC TONES and htdemucs routes that energy to OTHER, so vocals RMS
≈ −70 dB is correct semantic classification, NOT silence-defect; per-stem RMS
is logged for humans and the vocal-presence gate moves to real-audio fixtures
at P-205), shape (S5), byte-identical runs (S6), RSS < per-OS spike sanity
bound (S8 — Linux 2.0 GB / macOS-runner 3.75 GB sanity ceiling; AGENTS §8
1.5 GB stays the DEVICE target, measured on A14 at P-603);
reconstruction-SDR (mix vs vocals+instrumental) logged non-gated — demucs
sources do not sum exactly to the mix, so it is a sanity signal, not a quality
claim. Real SDR/NSDR vs known-truth stems fills when a truth-bearing fixture
lands (X-311 synthetic SATB prep for M3). Weights identity: htdemucs fp16
ggml 83,994,361 B, sha256 anchor 72b17c42…df0064 (D-32.6 FALLBACK Retrobear,
TIER B per D-30), load ~0.3–0.65 s, 533 tensors / 80.08 MB fp32-decoded.*

| Engine | Fixture | SDR | NSDR | Chunk | Time | RSS | Thermal | Env |
|---|---|---|---|---|---|---|---|---|
| demucs.cpp htdemucs fp16 ggml (stock serial, pristine intake vendor) | mix44k_short.wav 2.5 s (44.1 kHz mono→stereo, 1 zero-padded 7.8 s segment) | recon-SDR 38.28 dB | n/m (no truth stems on fixture) | vendor 7.8 s @ 0.25 | RTF 45.24 | 1.59–1.63 GB (§8 note: 1.5 GB = DEVICE target, P-603) | n/m (CI/dev) | Linux dev box g++ 13.3 -O2, 1 thread; runner sha @2923a9a; first real-weights run 2026-11-22 |
| demucs.cpp htdemucs + threading patch (env=1 → serial path, byte-identical to stock) | same | recon-SDR 38.28 dB | n/m | same | RTF 38.07 | 1623 MB | n/m | Linux dev box, clang++/g++ -O2 (patched scratch copy == origin/leto @d007780, diff-verified); same-session baseline for the rows below — 45.24 → 38.07 across sessions ≈ serial run-to-run variance (~16%), no patch delta on the serial path |
| demucs.cpp htdemucs + patch (DEMUCSCPP_NUM_THREADS=2 → freq∥time pairs) | same | recon-SDR 38.28 dB | n/m | same | RTF 40.52 | 1590 MB | n/m | **stems BYTE-IDENTICAL to serial** (sha256, 4/4 stems — patch safety argument holds); NO speedup vs serial (40.52 vs 38.07) |
| demucs.cpp htdemucs + patch (4 threads → capped to pairs) | same | recon-SDR 38.28 dB | n/m | same | RTF 34.50 | 1617 MB | n/m | **stems BYTE-IDENTICAL to serial**; −9% vs same-session serial — within the ±8–16% run-to-run variance band, NOT a reliable speedup |
| CI-runner row (macOS, separation-spike real path, 1 thread) | mix44k_short.wav | recon-SDR 38.48 dB; S3/S4/S5/S6 ALL PASSED incl. cross-run byte-identity (first green real-path run 45024720426, 1m35s) | n/m | vendor 7.8 s | **RTF 10.196** (M1-class runner ≈ 3.7× the Linux dev box; per-segment ≈ 10.2 × 2.5/7.8 ≈ 3.3 long-form, derived) | 3206 MB normalized < 3.75 GB darwin runner sanity bound (RSS unit fix proven on runner) | n/m | macOS runner, Xcode clang++; A14 number at P-603 |

### 4.1 P-202 L3 — D-25 chunk-policy benchmark (30 s synthetic mix, 3 paired repeats)

**What this measures (D-25, applied as written — no re-litigation).** Three arms,
ONE fixture, ONE weights file, ONE runner class, **paired** repeats (the same
repeat index of every arm shares the same input file), median + spread:
`reference` = the whole-song vendor path, `muskeyRecipe` = 4.5 s window / 1.0 s
overlap / linear crossfade (Muskey's shipping recipe, ideas only — AGENTS §9
study-only), `planDefault` = 8.0 s / 2.0 s (our §8 5–10 s plan).
Harness: `Tests/Spikes/demucs_chunk_bench.py` (+ `Tests/Spikes/demucs_runner.cpp`
chunked mode); report artifact `Tests/Spikes/.demucs-build/chunk_bench_report_l3_30s.json`
(gitignored), table `chunk_bench_table_l3_30s.md`.
Fixture `bench_mix_30s.wav` (30.0 s, deterministic music-shaped synthetic mix,
generated by the harness — **not committed**, >1 MB policy). Weights: htdemucs
fp16 ggml, sha256 `72b17c42…df0064` (D-32.6 FALLBACK Retrobear, **Tier B per
D-30** — human sign-off before any commercial distribution). Vendor threads: 1
(stock serial path — the §4 rows above use the same setting).

| Engine | Fixture | SDR | NSDR | Chunk | Time | RSS | Thermal | Env |
|---|---|---|---|---|---|---|---|---|
| demucs.cpp htdemucs fp16 ggml — **whole-song REFERENCE** | bench_mix_30s.wav (30.0 s) | n/m — the reference IS the baseline (no truth stems; its SDR against itself is not a quality number) | n/m | whole-song: 1 external window / 6 vendor segments | wall **692.2 s** (665.1–825.1); **RTF 23.07** (22.17–27.50) | **1829 MB** (1781–1885) | n/m (Linux dev box — no thermal API) | Linux x86_64 dev box, g++ -O2, 1 vendor thread, htdemucs fp16 ggml sha 72b17c42…df0064, paul @9e28910, 2026-11-23 |
| demucs.cpp htdemucs fp16 ggml — **muskeyRecipe arm** | bench_mix_30s.wav (30.0 s) | vocals 1.11 dB (⚠ not meaningful on this fixture — see note ²); **instrumental 8.07 dB**; **all-sources 1.63 dB** | all-sources **−21.28 dB** (vs the same-repeat reference reconstruction) | 4.5 s / 1.0 s crossfade → 9 external windows / 9 vendor segments | wall **1048.2 s** (995.8–1101.5); **RTF 34.94** (33.19–36.72) | **1767 MB** (1738–1785) | n/m | same env / same fixture / same weights / same repeat pairing |
| demucs.cpp htdemucs fp16 ggml — **planDefault arm** | bench_mix_30s.wav (30.0 s) | vocals 5.06 dB (⚠ same caveat ²); **instrumental 12.11 dB**; **all-sources 6.39 dB** | all-sources **−16.51 dB** (vs the same-repeat reference reconstruction) | 8.0 s / 2.0 s crossfade → 5 external windows / 10 vendor segments | wall **1298.5 s** (1215.9–1312.0); **RTF 43.28** (40.53–43.73) | **1778 MB** (1740–1788) | n/m | same env / same fixture / same weights / same repeat pairing |

² **The vocals-stem SDR is NOT a meaningful metric on this synthetic fixture.**
htdemucs routes the fixture's tone energy to **OTHER**, so the vocals stem sits
at ≈ −70 dB (near-silent) and the SDR of two near-silent signals is noise: the
muskey arm reads 1.11 dB while the composed-instrumental and all-sources SDRs
read 8.07 / 1.63 dB. **The all-sources and instrumental SDRs are the primary
quality numbers here**; the vocals column is reported, not hidden, and it is
not a claim about vocal separation quality. Real-vocals SDR lands with a
truth-bearing fixture (X-311 synthetic SATB prep, M3) — not from this row.

**D-25 PROTOCOL APPLIED AS WRITTEN — the outcome is Rule 3 (ESCALATION).**

- **Rule 1 (muskey within 1.0 dB SDR of plan AND RTF ≤ 1.25× plan AND peak RSS
  not higher ⇒ muskeyRecipe):** **FAILS on the SDR gate.** muskey's all-sources
  SDR is **4.76 dB behind** plan's (1.63 vs 6.39 dB; instrumental 4.04 dB
  behind: 8.07 vs 12.11 dB). Its other two gates pass (RTF 34.94 ≤ 1.25 × 43.28
  = 54.10; RSS 1767 ≤ 1778 MB), but the SDR gate is decisive — Rule 1 does not
  apply, so **no §8 window deviation is recorded** (muskey's 4.5 s window is
  outside §8's 5–10 s range and would have needed D-25's explicit deviation note).
- **Rule 2 (plan wins quality ≥ 1.0 dB OR memory, AND both stay in budget ⇒
  planDefault):** the plan arm **does** win quality (4.76 dB all-sources) — but
  the "both stay in budget" precondition **FAILS**: the §8 device budgets are
  RTF ≤ 2× song length and peak RSS < 1.5 GB, and **neither arm meets either
  one on this box** (RTF 34.94 / 43.28 against a budget of 2.0 — the whole-song
  REFERENCE itself is 23.07; RSS 1767 / 1778 MB against a budget of 1500 MB).
  Rule 2 therefore does not apply.
- **Rule 3 (NEITHER arm meets the RTF/RSS budgets ⇒ escalate to Leto WITH the
  numbers; reversible option = the better-quality arm at planDefault,
  flagged):** **TRIGGERED.** The numbers are the three rows above. **The
  reversible option, while Leto rules, is `planDefault`** (the better-quality
  arm, and the §8-native 5–10 s window) — **flagged**, not silently shipped.
  Escalated to Leto in QUEUE.md's P-202 row + LOG (2026-11-23, Paul).
- **Rule 4 (genuine tie ⇒ planDefault):** not applicable — the arms are 4.76 dB
  apart in SDR and 23.9 % apart in RTF.

**What the numbers say (honest reading, no spin):**
1. **Chunking LOSES on RTF, and that is structural, not incidental.** The vendor
   pads EVERY external window to a full internal 7.8 s segment, so a 4.5 s
   window costs 7.8 s of vendor compute (9 windows × 1 vendor segment each) and
   an 8 s window costs 15.6 s (5 windows → 10 vendor segments). The measured
   RTF ordering is exactly that cost model: reference 23.07 < muskey 34.94 <
   plan 43.28.
2. **Chunking buys essentially NOTHING in peak RSS at this length.** The peak
   is the vendor's per-segment working set (~1.7 GB), not our windowing: plan
   −2.8 %, muskey −3.4 % vs the reference. The memory case for chunking is
   therefore NOT "lower peak RSS" — it is (a) bounding the SWIFT-side
   accumulation of blended stems, and (b) bounding what a single vendor call
   must hold, at the cost of RTF. The 240 s run (L4(a), below) quantifies (a):
   the Swift driver accumulates the blended output for the whole song in memory
   (`ChunkedSeparationDriver.acc`), so **RSS grows with song length even with
   chunking** — a real finding for the streaming "decode→process→write" target
   in P-202's own task line.
3. **The quality gap is the one number that argues for the §8-native plan.**
   planDefault's 8 s / 2 s windowing is 4.76 dB better on all-sources SDR and
   4.04 dB better on instrumental SDR than muskey's 4.5 s / 1 s recipe, at a
   23.9 % RTF premium.
4. **These are NOT device numbers.** The budgets are A14 budgets; this is a
   Linux dev box, 1 vendor thread, and the §4 runner row above measures the
   macOS CI runner at ≈ 3.7× the dev box. Even at that factor the derived
   long-form RTFs would be ≈ 6.2 (reference) / 9.4 (muskey) / **11.7 (plan)**
   — all still far above the 2.0 budget. Derived, not measured. The **A14
   numbers are P-603** (device demo) and are NOT yet in.
5. **Mirror honesty (C++ vs Swift).** The benchmark harness runs the C++
   `demucs_runner` in chunked mode, which **mirrors** the Swift
   `ChunkedSeparationDriver`'s window plan and linear crossfade (the Swift
   blend math is separately unit-proven in EngineCore — 187/187 Linux green).
   The C++ mirror is NOT the shipping Swift path, and the two differ in one
   memory-relevant respect (the C++ mirror accumulates all four source stems
   for the whole song in RAM; the Swift driver accumulates the two blended
   output stems). The Swift blend/crossfade semantics are the unit-proven
   ones; the wall/RTF/RSS figures below are the mirror's.

**Threading benchmark verdict (D-25/P-603 input — honest):** the freq∥time
pair patch is BIT-SAFE (byte-identical stems at 1/2/4 threads, dev box AND
macOS runner) but delivers NO reliable speedup on this dev box: pairs wall =
max(freq-chain, time-chain), the time chain dominates, and the deliberately
serial per-source mask/ISTFT section carries a large share of the cost. The
34.5–40.5 RTF spread across thread counts is within observed serial variance
(45.24 → 38.07 across sessions). KEEP the patch (harmless, plausibly more
useful on A14's 2P+4E heterogeneous cores — verify at P-603) but do NOT count
on it as the device lever; the levers for the ≤2× song-length target are the
D-25 chunk-policy benchmark (Muskey 4.5 s/1 s/crossfade vs 5–10 s) and §8
quality-mode pacing. Long-form honesty note: the spike RTF pays a FULL
zero-padded 7.8 s segment for 2.5 s of audio (≈ 95 s compute ÷ 2.5 s = 38);
per-segment cost ÷ 7.8 s ≈ **RTF ~12–13 for long-form songs (derived
estimate, not measured)** — still ≫ 1× ⇒ offline quality mode remains the
only sane device path; real-song rows land at P-202.

**Threading patch note (D-32.4):** vendored src has ZERO OpenMP pragmas
(re-verified on the scratch extraction — 8/8 compile without -fopenmp). The
patch pairs the independent freq/time encoder+decoder chains (disjoint
buffers ⇒ bit-identical output, asserted); the per-source mask/ISTFT section
stays serial (shared stft_buf mutation — deferred by design). X-202 DONE:
applied to vendor/ @d007780 (Leto, + patches.log) with one ternary correction
— `apply_demucs_threading.py` mirrors it byte-for-byte (diff-verified vs
origin/leto). Device target: ≤ 2× song length (stretch ≤ 1×) — A14 rows land
at P-603 device runs.

### 4.2 P-202 L4(a) — the 4-minute no-OOM run (240 s planDefault arm)

**What this measures (P-202's ac leg: "4-min synthetic processes without OOM").**
One arm — the **planDefault** policy (8.0 s window / 2.0 s overlap / linear
crossfade), i.e. the Rule-3 reversible option — on a **240.0 s** deterministic
music-shaped synthetic mix, so the song is **8× the L3 fixture's 30 s**. The
question is narrow and it is the memory one: **does the peak RSS stay inside
the Linux 2.0 GB spike sanity bound while the song grows 8×?** (the D-25
quality comparison stays in the 30 s L3 rows — the reference outputs for that
length were deliberately moved aside, so no mismatched-length SDR could be
computed; the SDR/NSDR cells here read n/a honestly rather than n/m-by-mistake).
Harness: `Tests/Spikes/demucs_chunk_bench.py --seconds 240 --repeats 1 --arms
planDefault` (+ the `demucs_runner` chunked mirror); report artifact
`Tests/Spikes/.demucs-build/chunk_bench_report_l4a_240s.json` (gitignored),
table `chunk_bench_table_l4a_240s.md`. Fixture `bench_mix_240s.wav` (240.0 s —
**not committed**, >1 MB policy). Weights: htdemucs fp16 ggml, sha256
`72b17c42…df0064` (D-32.6 FALLBACK Retrobear, **Tier B per D-30**). Vendor
threads: 1 (the same setting as §4/§4.1). Model load: 0.893 s.

| Engine | Fixture | SDR | NSDR | Chunk | Time | RSS | Thermal | Env |
|---|---|---|---|---|---|---|---|---|
| demucs.cpp htdemucs fp16 ggml — **planDefault arm, 240 s (L4(a))** | bench_mix_240s.wav (240.0 s) | n/a — the 30 s reference outputs were moved aside, so no mismatched-length comparison was possible (the paired quality comparison lives in the §4.1 L3 rows) | n/a | 8.0 s / 2.0 s crossfade → **40 external windows / 80 vendor segments** | wall **8717.6 s** (2 h 25 min 18 s); **RTF 36.32** | **1805 MB** (1 848 088 KB) | n/m (Linux dev box — no thermal API) | Linux x86_64 dev box, g++ -O2, 1 vendor thread, htdemucs fp16 ggml sha 72b17c42…df0064, paul @b01cd9e, 2026-11-23 |

**THE VERDICT — the ac is MET: peak RSS stays under the Linux 2.0 GB spike
bound while the song grows 8×.**

| | 30 s (L3, §4.1 planDefault) | 240 s (L4(a), this row) | Δ |
|---|---|---|---|
| song length | 30.0 s | 240.0 s | **8×** |
| external windows | 5 | 40 | 8× |
| vendor segments | 10 | 80 | 8× |
| **peak RSS** | **1778 MB** (median of 3; 1740–1788) | **1805 MB** (1 repeat) | **+27 MB (+1.5 %)** |
| RTF | 43.28 (40.53–43.73) | 36.32 | −16 % (better, see below) |
| wall | 1298.5 s | 8717.6 s | 6.7× |

- **The peak does NOT scale with song length on this path.** Eight times the
  audio cost **+27 MB (+1.5 %)**, not 8× the memory: the peak is the vendor's
  per-segment working set (~1.7–1.8 GB), which is the same for every window,
  while the whole-song accumulation (the C++ mirror keeps the blended stems in
  RAM; the Swift driver keeps the two blended output stems) is a small
  additive term on top of it. **1805 MB < the Linux 2.0 GB spike sanity bound**
  ⇒ the 4-minute synthetic processed without OOM, with ~195 MB of headroom.
- **RTF improved with length (36.32 vs 43.28), and the cost model says why:**
  the vendor pads every external window to full internal 7.8 s segments, so a
  SHORT song pays proportionally more padding (a 30 s fixture = 5 windows, each
  costing 2 segments; the tail + the first window's padding are a big fraction
  of 30 s). At 240 s the same fixed overhead is amortised over 8× more audio.
  The 30 s number is therefore the PESSIMISTIC end of the range and the 240 s
  number the optimistic one — the long-form RTF is the one that matters for a
  real song, and it is still **36× the audio duration**, i.e. **far above §8's
  ≤ 2× song-length device budget** (unchanged by this run; the A14 numbers are
  P-603).
- **Honest scope of the row:** it is a **Linux dev-box** measurement of the
  **C++ MIRROR** of the Swift driver's window plan (the Swift blend math is
  separately unit-proven in EngineCore), **1 vendor thread**, **1 repeat** (the
  L3 rows carry the median-of-3 spread; this row is a single long run), and a
  synthetic fixture. It says nothing about the A14, the device RAM budget
  (§8's 1.5 GB is the DEVICE target — P-603), or real-music quality.
- **THE STREAMING FOLLOW-UP (recorded, not re-litigated):** the Swift driver
  still ACCUMULATES the blended stems for the whole song in memory
  (`ChunkedSeparationDriver.acc`), while P-202's own task line says "streaming
  decode→process→write". This row shows the accumulation is NOT the peak
  driver on the mirror (the vendor's working set is), but it is still a term
  that grows with song length — on a 12-minute song it is ~2.5× this row's
  additive term. **A streaming writer (write each window's blended stems to
  disk instead of accumulating them) is the follow-up item; it is NOT
  refactored into this gate.**

## 5. Results — note tracking (M3)

*Empty — fills at M3. Columns: stage | fixture | onset F1@50ms | part-aware macro
F1 | multi-f0 P/R/F1 | RTF | env. Real-fixture results stated honestly against
the PawCT 0.225 ceiling.*


| Stage | Fixture | Onset F1 | Part-aware F1 | Multi-f0 P/R/F1 | RTF | Env |
|---|---|---|---|---|---|---|

## 6. Device report (M6: P-603 — CoreML EP, quantized models, battery)

*Empty — fills at M6 (human-assisted A14 run).*

| Model | EP | RTF | Speedup vs CPU | Accuracy delta | Battery/thermal | Env |
|---|---|---|---|---|---|---|

## 7. Change log

| Version | Date (UTC) | Change |
|---|---|---|
| v0 | 2026-11-21 | P-003 stub: methodology, targets (PLAN §0), empty result tables M1/M2/M3/M6. |
| v1 | 2026-11-21 | P-101/P-103 M1 table filled (local Linux evidence, env-labeled): SwiftF0 accuracy/gating/RTF-threads + silero timing/semantics. CI-runner + A14 rows pending (device numbers via J-103 debug screen). F1@50c proper (P-106 harness v1) fills the column at P-106. |
| v1.1 | 2026-11-21 | P-105: Swift MPM ribbon RTF measured (0.093 best-of-3, −O, Linux x86_64 — under the 0.1 budget, 3× over the optimistic estimate; honest note recorded + X-009 vendor path validated as the shipping hot path at 0.0014). Latency-relevant: facade ribbon answer ≈ 4 ms per 40 ms chunk on dev box (≪ 100 ms feedback budget; A14 number via J-103/P-603 pending). |
| v1.2 | 2026-11-21 | P-106: F1@50c column filled by bench harness v1 (Tests/Spikes/bench_f1.py + ribbon_swift_bench/, report artifact bench_report_v1.json, §1 methodology exact: hit iff both voiced AND \|cents\|<50, RPA/RCA alongside, window-center truth pairing). Synthetic-clean AC ≥ 0.75 MET on all 6 engine rows — swiftf0 0.986 voice / 0.764 sweep (note ¹: sine confidence gating, precision 1.000), ribbon-swift 0.982 voice / 0.925 sweep, ribbon-cpp 0.977 voice / 0.896 sweep@1024. RCA == RPA everywhere (zero octave errors on clean synthetic). CI bench job = X-012 (non-blocking, Leto lane). |
| v1.3 | 2026-11-22 | P-201c: §4 separation table opened — harness contract (S3/S4/S5/S6/S8 incl. RSS < 1.5 GB assert), reconstruction-SDR honesty note, threading-patch methodology (freq∥time pairs, bit-identical assertion, ISTFT serial rationale). Numbers PENDING the htdemucs ggml weights (Meta PRIMARY download stalled on dev box → D-32.6 FALLBACK Retrobear HF dataset in flight with sha256 trust anchor); CI-runner row fills at first green real spike post merge. |
| v1.4 | 2026-11-22 | P-201 real-weights rows FILLED: serial RTF 45.24 (pristine intake) / patched-binary rows 38.07 (1-thr) / 40.52 (2-thr) / 34.50 (4-thr) — **byte-identical stems at every thread count (dev box + macOS runner), NO reliable thread speedup on dev box (verdict for D-25: chunk policy + quality mode are the levers, patch kept as harmless)**; recon-SDR 38.28 dB; S4 → honest instrumental gate (tone fixture routes to OTHER); S8 → per-OS spike bound (Linux 2.0 GB / macOS-runner 3.75 GB ceiling after fixing the ru_maxrss bytes-vs-KiB bug found by runner run 45023115947 — S3/S4/S5/S6 all passed on the runner's first real-path run); long-form RTF ~12–13 derived estimate noted; §8 1.5 GB DEVICE target unchanged (P-603). |
| v1.5 | 2026-11-22 | P-208: §1 parity methodology bullet (D-24/C-7 — Python reference vs Swift/ORT, tolerance abs 1e-3 OR rel 1e-4, sha binding first). Parity is a CORRECTNESS check, not a benchmark row; no numbers change. engine-parity CI job spec = X-205 (Leto). |
| v1.6 | 2026-11-23 | **P-202 L3 (D-25 chunk benchmark) FILLED — §4.1 added.** 30 s deterministic synthetic mix, htdemucs fp16 ggml sha 72b17c42…df0064 (Tier B, D-30), 1 vendor thread, 3 PAIRED repeats, median + spread, Linux dev box (env-labeled — NOT A14 numbers). medians: reference (whole-song) RTF 23.07 / RSS 1829 MB; muskeyRecipe (4.5 s/1 s) SDR all-src 1.63 dB, instr 8.07 dB, NSDR −21.28 dB, RTF 34.94, RSS 1767 MB; planDefault (8 s/2 s) SDR all-src 6.39 dB, instr 12.11 dB, NSDR −16.51 dB, RTF 43.28, RSS 1778 MB. **D-25 protocol outcome = Rule 3 (ESCALATION):** Rule 1 fails on the SDR gate (muskey 4.76 dB behind plan), Rule 2's "both in budget" precondition fails (neither arm meets RTF ≤ 2× or RSS < 1.5 GB; the reference itself is RTF 23.07) ⇒ escalated to Leto WITH the numbers; reversible option = **planDefault, flagged** (not silently shipped). Recorded honestly: chunking LOSES on RTF by construction (the vendor pads every window to a full 7.8 s segment) and buys ~3 % peak RSS at 30 s; the vocals-SDR column is flagged as not meaningful on this fixture (htdemucs routes the tone energy to OTHER); the C++ harness is a MIRROR of the Swift driver's window plan + linear crossfade (Swift blend math unit-proven in EngineCore); the A14 numbers remain P-603. |
| v1.7 | 2026-11-23 | **P-202 L4(a) — the 4-minute no-OOM run — FILLED (§4.2 added).** 240.0 s deterministic synthetic mix (8× the L3 fixture), planDefault arm (8 s/2 s), 1 vendor thread, 1 repeat, Linux dev box (env-labeled — NOT A14 numbers): **40 external windows / 80 vendor segments, wall 8717.6 s, RTF 36.32, peak RSS 1805 MB**. **The ac is MET: the peak does NOT scale with song length — 8× the audio cost +27 MB (+1.5 %) vs the 30 s row's 1778 MB, and 1805 MB stays under the Linux 2.0 GB spike sanity bound (~195 MB of headroom), because the peak is the vendor's per-segment working set (~1.7–1.8 GB), not the whole-song accumulation.** The SDR/NSDR cells read n/a honestly (the 30 s reference outputs were moved aside, so no mismatched-length comparison was possible — the paired quality comparison stays in §4.1). RTF improved with length (36.32 vs 43.28) because the vendor's fixed per-window padding amortises over a longer song — and it is still 36× the audio duration, far above §8's ≤ 2× device budget (A14 numbers remain P-603). Recorded as a follow-up, not refactored into this gate: the Swift driver still accumulates the blended stems for the whole song (`ChunkedSeparationDriver.acc`) while P-202's task line says "streaming decode→process→write". Also: the missing "## 5" header above the M3 table is restored. |

