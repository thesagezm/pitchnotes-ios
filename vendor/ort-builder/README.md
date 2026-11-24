# ort-builder — REFERENCE INTAKE (NO CODE VENDORED)

- Upstream:        https://github.com/olilarkin/ort-builder
- Upstream commit: `61201bf3b9f4af0df6214d35609e7d18488be602` (branch `main`; upstream's
                   last push 2025-04-22)
- Pinned:          2026-11-24 (Leto, M3 session 12 — reference only, per D-39 §2/§4)
- License:         **MIT** — verified by Leto via the GitHub API's license metadata and
                   the repository's `LICENSE` file. (Ship-safe under AGENTS §9, and
                   MPL-2.0-not-applicable here.)
- Purpose:         **REFERENCE ONLY.** `ort-builder` is the tool that produces a TRIMMED
                   ONNX Runtime (only the ops/types a given model needs) and converts a
                   model into ORT format / compiled-into-C weights. basicpitch.cpp uses
                   it upstream.
- Local changes:   **none — NO CODE IS COPIED.** This directory holds this record only.

## Why it is a reference and not a dependency (D-39 §1/§2)

We already link **ONNX Runtime 1.24.2** through Swift Package Manager (D-13; the mirror
`thesagezm/onnxruntime-swift-package-manager`, tag 1.24.2, revision b7fb7f7). Linking a
SECOND ONNX Runtime — the trimmed build ort-builder produces — inside one static IPA is a
duplicate-symbol / static-link hazard, and the CI gate's no-`@rpath` + static-patch checks
(AGENTS §6) are exactly where that would break. The trimmed build also pins us to an ORT
version of its own, which would skew against 1.24.2.

**Therefore: P-301 runs basic-pitch under the EXISTING SPM ORT** and loads the plain
`nmp.onnx` from the model cache. The ort-builder artifacts upstream ships
(`model.ort`, `model.ort.c`, `model.ort.h`) are **not vendored**.

**If we ever need the trimmed ORT** (e.g. L-302's IPA size check shows ORT's footprint is
the blocker), that requires a **NEW ruling** with its own symbol / no-`@rpath` proof — it
is not a quiet switch, and this record is where that decision would start.

## What would have to be true before any code from ort-builder is copied in

1. A DECISIONS entry naming the exact upstream commit, the license, the shipped artifact,
   and the size win it buys.
2. A proof that the trimmed ORT and the SPM ORT do not collide in the static link
   (symbol audit) and that the IPA still has no `@rpath` framework references.
3. A license/NOTICE update (the trimmed ORT is still ONNX Runtime — MIT — and its
   NOTICE obligations travel with it).
