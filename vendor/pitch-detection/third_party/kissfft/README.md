# kissfft (vendored subset — third_party of pitch-detection intake)

- Upstream:        https://github.com/mborgerding/kissfft
- Upstream commit: tag `v131` = `0bfa4d538f80253b8fd44656ee973442e9a7d6b2`
- Pinned:          2026-11-21 (PitchNotes intake, DECISIONS D-19)
- License:         BSD-3-Clause — per-file SPDX headers verified by Leto by
  reading the source at the pinned tag; `LICENSE` here is upstream `COPYING`
  verbatim (renamed for the intake checklist).
- Files: `kiss_fft.{h,c}`, `_kiss_fft_guts.h` (upstream root) +
  `kiss_fftr.{h,c}` (upstream `tools/`) — flattened into one directory so the
  relative `#include`s resolve unmodified. No other edits.
- Purpose: FFT backend for `pd_fft_backend.cpp` (the `pd_fft.h` seam in the
  vendored sevagh/pitch-detection subset). Portable iOS/Android/Linux; P-102
  may swap in a vDSP implementation of the same 4-function ABI on iOS.
- float precision: kiss_fft_scalar defaults to `float` — required by
  `pitch_alloc::BaseAlloc`'s float buffers. Do not build with KISSFFT_DOUBLE.
