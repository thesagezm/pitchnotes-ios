# basicpitch.cpp intake

- Upstream:        https://github.com/sevagh/basicpitch.cpp
- Upstream commit: `e0cf072d59fc87846e5be6ee7841bf726552ce9b` (branch `main`; upstream's
                   last push 2024-10-31 — *"Improve README"*)
- Pinned:          2026-11-24 (Leto, M3 session 12 — X-312, per D-39)
- License:         **MIT** — verified VERBATIM by Leto by reading `LICENSE` at the pinned
                   commit (`LICENSE` in this directory is byte-identical to upstream,
                   sha256 `a098fd7245cdba0484f08b83861652118f9fb74470c5d369cd2a18b8c0244aa9`):
                   *"MIT License / Copyright (c) 2024 Sevag H"*, no non-standard terms.
                   The **CODE is Tier A** under D-30. **The WEIGHTS it runs are NOT:**
                   see D-42 — the model is Spotify's ICASSP-2022 `nmp.onnx`
                   (Apache-2.0, byte-identical sha256
                   `2c3c1d144bfa61ad236e92e169c13535c880469a12a047d4e73451f2c059a0ec`),
                   whose **training data includes datasets with NC terms ⇒ TIER B**
                   (human sign-off required before commercial / App Store distribution).
- Purpose:         **P-301 (M3)** — the note-event model that produces the
                   `NoteTrack` for each stem: `Engine/` Swift bridge → this C++ core →
                   `NoteEvent[]` → CONTRACTS C-2 NoteTrack. Backs the real
                   `basicpitch-spike` job (L-302).
- Local changes:   **7 patches, all mechanical and all logged in `patches.log`** — see
                   that file for the exact before/after. In one line: **the MIDI writer
                   is gone (no libremidi), the note-event function is exported (and its
                   definition now matches the header's `basic_pitch::` symbol), the
                   overlapping-pitch-bend drop upstream did in the MIDI tail is restored,
                   the ORT include is the flat public header, and the model is loaded from
                   a FILE PATH instead of a baked-in blob.**
- Audit:           **D-39** (one ORT runtime; libremidi dropped; the exact intake scope;
                   Eigen reuse; whose job the compile proof is), **D-42** (the weights
                   are Tier B), **D-30** (the three-tier policy), **D-32.5** (Eigen
                   MPL-2.0 header-only exception — **we REUSE the Eigen already vendored
                   under `vendor/demucs.cpp/third_party/eigen`, same pin, no new
                   intake**), **L-008** (the intake process itself).

## What is vendored here (and what is deliberately NOT)

| Path | Upstream path | State |
|---|---|---|
| `LICENSE` | `LICENSE` | byte-identical |
| `src/basicpitch.hpp` | `src/basicpitch.hpp` | patched (see `patches.log`) |
| `src/midi_notes.cpp` | `src/midi_notes.cpp` | patched (see `patches.log`) |
| `src/ort_inference.cpp` | `src/ort_inference.cpp` | patched (see `patches.log`) |

**NOT vendored, and why:**

| Upstream path | Why not |
|---|---|
| `src_cli/`, `src_wasm/`, `web/` | demo/CLI shells (Emscripten, libnyquist audio loading); we decode audio with AVFoundation / EngineCore |
| `scripts/` | Python/ORT tooling (reference only; not shipped, not run on device) |
| `ort-model/model.ort`, `model.with_runtime_opt.ort` | ORT-format models built by the trimmed runtime — **D-39 §1: we use the EXISTING SPM ORT 1.24.2** |
| `ort-model/model.ort.c`, `model.ort.h` | the **weights compiled into C source** (1.84 MB) — **weights never enter git** (AGENTS §6); the app loads `nmp.onnx` from the model cache instead |
| `ort-model/model.onnx` | the weights themselves (230,444 B) — same reason; it is fetched once from the project HF model repo and SHA256-verified (`Models/manifest.json`) |
| `vendor/onnxruntime` (submodule) | **D-39 §1: one ORT runtime — the SPM one we already link (D-13)** |
| `vendor/libremidi` (submodule) | **D-39 §3: not needed** (we emit NoteTrack JSON / UltraStar text, not MIDI files) and its own license reads NOASSERTION |
| `vendor/libnyquist` (submodule) | CLI-only audio loading |
| `vendor/oboe-resampler` (submodule) | Android-only; not a current target (M6 port preflight will revisit) |
| `vendor/ort-builder` (submodule) | **reference only** — see `vendor/ort-builder/README.md`; no code copied (D-39 §2) |
| `vendor/eigen` (submodule) | **we reuse the Eigen already vendored at `vendor/demucs.cpp/third_party/eigen`** (upstream pin `dd8c71e62852b2fe429edb6682ac91fd1c578a26`, MPL-2.0, D-32.5) — the same headers, no second copy in the repo |
| `vendor/basic-pitch` (submodule → spotify/basic-pitch) | the Python original (Apache-2.0) — it is the **provenance** of the weights (D-42), not a build dependency of ours |

## How Paul consumes it (P-301)

1. Include paths: `-I<vendor>/basicpitch/src` and
   `-I<vendor>/demucs.cpp/third_party/eigen` (Eigen is already there — D-32.5).
2. The ONNX Runtime comes from the **existing SPM package** (D-13 / D-39 §1). The C++
   API header the core includes is
   `<onnxruntime/core/session/onnxruntime_cxx_api.h>` — **P-301 must confirm the SPM
   package ships the C++ API header** (the C API header alone is not enough). If the SPM
   package does not carry it, that is a FIX task on the Leto side (a vendor-side ORT
   header drop) or, failing that, a NEW D-39 ruling — not a silent second ORT.
3. Call order: `basic_pitch::ort_inference(audio, model_path)` →
   `basic_pitch::output_to_notes_polyphonic(result, /*melodia*/true, /*bends*/false)`.
4. `NoteEvent.start_idx` / `end_idx` are **frame indices** at `ANNOTATIONS_FPS`
   (= 22050 / 256 ≈ 86.13 Hz); `pitch` is already MIDI (`freq_idx + MIDI_OFFSET`).
   The bridge converts frames → seconds (`frame / ANNOTATIONS_FPS`).
5. **If this drop does not compile under the SPM ORT, it is a FIX task on the LETO side**
   (`vendor/**` is Leto's lane, AGENTS §12): file it, and Leto re-applies the patch.
   Paul does not edit `vendor/**`.

## Compile smoke performed at intake (2026-11-24)

`g++ 13.3.0`, `-std=c++20 -Wall -Wextra -fsyntax-only`, against the **real vendored
Eigen** (`vendor/demucs.cpp/third_party/eigen`) and a **minimal ONNX Runtime C++ API
STUB** (a throwaway header in `/tmp`, **not committed** — it mirrors the real API for
the subset upstream uses):

- `src/midi_notes.cpp` — compiles. One **pre-existing upstream** warning
  (`unused variable 'max_energy'` in `apply_melodia_trick`); not introduced by us.
- `src/ort_inference.cpp` — compiles clean.

**What this smoke does NOT prove:** it is not the real ONNX Runtime, so it does not prove
the real ORT C++ API matches our call sites (in particular `Ort::Session(env, path,
options)` and `Ort::Value::CreateTensor`). **The real compile proof is P-301's
`basicpitch-spike` job** (L-302 makes it REAL and gate-blocking).
