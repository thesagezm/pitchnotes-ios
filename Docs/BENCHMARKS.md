# Docs/BENCHMARKS.md — PitchNotes-iOS measured results

> **Owner:** Paul. **Version:** v0 stub (M0, P-003). Empty result tables are
> intentional — they fill at M1+ (P-106 bench v1, P-306 bench v2, P-603 device report).
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
| — | — | — | — | — | — | — |

## 4. Results — separation (M2: P-201/P-202/P-206)

*Empty — fills at M2. Columns: engine/model | fixture | SDR vocals | NSDR |
chunk config | wall time (4-min synth) | peak RSS | thermal | env.*

| Engine | Fixture | SDR | NSDR | Chunk | Time | RSS | Thermal | Env |
|---|---|---|---|---|---|---|---|---|

## 5. Results — note transcription & assignment (M3: P-301…P-306)

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
