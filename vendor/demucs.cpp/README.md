# demucs.cpp intake

- Upstream:        https://github.com/sevagh/demucs.cpp
- Upstream commit: `4edae497a114de1ccb17ac9b4a2b8fc0144714d7` (HEAD 2026-11-06,
  "Remove website references from the docs"; latest master at intake time)
- Pinned:          2026-11-22 (Leto, M2 session)
- License:         **MIT** — verified VERBATIM by Leto by reading `LICENSE` at the
                   pinned commit (standard MIT text, © 2023 Sevag H, no
                   non-standard terms). Recorded in **DECISIONS D-30** (Tier A
                   for the CODE). Upstream facebookresearch/demucs (weights
                   provenance) = MIT © Meta but htdemucs weights are **Tier B**
                   (MUSDB18 CC BY-NC-SA + undocumented 800-song extra training
                   set) — see D-30 before touching any weights.
- Purpose:         **P-201 (M2)** — two-stem vocals/instrumental separation
                   engine (`Engine/Separation/DemucsEngine` Swift bridge);
                   `separation-spike` (real, gate-blocking at L-202).
- Local changes:   **none at intake** (`src/` byte-identical to upstream —
                   `diff -rq` = 0). patches.log starts empty; ALL future patches
                   (OpenMP→std::thread/GCD threading, Eigen NEON notes, any API
                   trim) MUST be logged there per L-008.
- Audit:           **D-30** (three-tier weights provenance policy + this
                   classification), **D-32.4** (intake split: Leto = this intake;
                   Paul = bridge/port/spike), **D-32.5** (Eigen MPL-2.0
                   ship-safe verdict), **D-32.6** (weights source ruling).

## What is vendored (and what is NOT)

| Path | Content | Why |
|---|---|---|
| `LICENSE` | upstream MIT, verbatim | L-008 rule 1 |
| `src/**` (16 files: tensor.hpp, dsp.*, layers.*, conv.hpp, lstm.*, encdec.*, crosstransformer.*, model.hpp, model_*.cpp) | the inference LIBRARY — the only part we compile into the app | P-201 consumes exactly these |
| `scripts/convert-pth-to-ggml.py` + `scripts/requirements.txt` | weight-conversion tooling, pinned | D-32.6 PRIMARY provenance chain (Meta .pth → ggml fp16); **Linux/CI-side tooling only — NEVER compiled into any app target** |
| `third_party/eigen/Eigen/**` + `unsupported/**` + COPYING.{MPL2,README,BSD,APACHE,MINPACK} | Eigen headers at upstream's pinned submodule `dd8c71e62852b2fe429edb6682ac91fd1c578a26` | demucs.cpp's only library dependency (header-only); `unsupported/Eigen/CXX11/Tensor` IS required (src/tensor.hpp) |

**Deliberately NOT vendored** (upstream submodules/dirs, logged per L-008 rule 3):
- `cli-apps/**` + `vendor/libnyquist` — CLI audio I/O; our app uses AVFoundation
  (AGENTS §6). libnyquist is MIT but we don't need it.
- `vendor/googletest` — upstream unit tests; our coverage is Paul's EngineCore
  tests + the separation spike.
- `vendor/demucs` (sevagh's release_v4 fork of facebookresearch/demucs) — Python
  reference/conversion aid; conversion runs Linux-side against pip-installed
  upstream demucs per D-32.6; never compiled into the app.
- `CMakeLists.txt` + `.github/` + docs — upstream build system not used; Paul
  compiles `src/*.cpp` via the Engine bridge target (XcodeGen/project.yml),
  include paths: `-I<vendor>/demucs.cpp/src -I<vendor>/demucs.cpp/third_party/eigen`.
- Remaining upstream `scripts/*` (benchmarks/evaluate) — not part of our chain.

## Intake verification (2026-11-22, Leto)

- **Compile smoke test: 8/8 `src/*.cpp` compile GREEN** with the vendored subset:
  `g++ -std=c++17 -Isrc -Ithird_party/eigen -c src/<f>.cpp` on g++ 13.3.0
  (Ubuntu 24.04 x86_64). First attempt FAILED on the missing
  `unsupported/Eigen/CXX11/Tensor` — the smoke test caught it and the
  `unsupported/` tree was added before landing (this is why the test exists).
- Compiled WITHOUT `-fopenmp`: **empirically confirms D-32.4's finding that
  `src/` contains ZERO OpenMP pragmas** — the "OpenMP requirement" in upstream's
  README is Eigen's optional parallelism. P-201's threading work = ADD
  std::thread/GCD parallelism around Eigen ops (upstream's own CLI apps already
  use std::thread as the pattern), NOT a pragma migration.
- `src/` byte-identity vs upstream pin: `diff -rq` = 0 differences.
- Inference-level verification (load htdemucs ggml, assert stems) = **P-201's
  separation-spike** on CI with real weights (D-30 Tier B provenance per D-32.6) —
  NOT covered by this intake.

## Build notes for P-201 (Paul)

- C++17; dependencies = standard library + Eigen headers ONLY (vendored above).
- The library reads ggml-format weights: `ggml-model-htdemucs-4s-f16.bin` (~84 MB;
  D-32.6 ruling for sourcing/mirroring). 4-source output order: target_0_drums,
  target_1_bass, target_2_other, target_3_vocals (upstream CLI naming) — our M2
  consumes vocals + (instrumental = mix − vocals sum or the 4-stem residual per
  Paul's bridge; D-9 always-two-stem policy).
- 44.1 kHz mono/stereo float in/out per CONTRACTS v1.0 (C-2.2 stem naming;
  D-8 channel policy). Decode/encode stays AVFoundation (P-203/P-204) — the
  library takes float tensors (see upstream model_apply.cpp signature).
