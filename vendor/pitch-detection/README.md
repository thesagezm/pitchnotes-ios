# pitch-detection intake

- Upstream:        https://github.com/sevagh/pitch-detection
- Upstream commit: tag `v2023.12` = `faa04bb262476bdc0490f4bb3ffd7c6cdeeb3052`
- Pinned:          2026-11-21 (PitchNotes intake)
- License:         MIT — **verified by Leto 2026-11-21 by reading the upstream
  LICENSE at the pinned tag** (verbatim MIT text, © 2018 Sevag Hanssian; no
  non-standard terms). Independent verification recorded in DECISIONS D-19
  (extends D-7/D-17 — the dossier claim was NOT trusted, it was re-checked).
- Purpose:         **P-102 / M1 v1 causal ribbon** (D-17: NanoPitch pretrained
  weights are GTSinger-trained = NC-encumbered = banned, so the D-17 default is
  this pure-DSP MPM/YIN — zero training data, zero lookahead, no encumbrance).
  Consumed by `Engine/Pitch` (Paul) via the `pd_fft` seam; the vendored subset
  is portable C++17 (iOS/Android/Linux — AGENTS §0 sibling-app requirement).
- Local changes:   see `patches.log`. Summary: FFTS backend replaced by the
  `pd_fft.h` seam (kissfft v131, BSD-3-Clause, under `third_party/kissfft/`);
  mlpack/HMM probabilistic variants (pmpm/pyin) excluded — deterministic
  MPM/YIN retained algorithm-identical. `src/parabolic_interpolation.cpp` is
  upstream byte-identical.
- Audit:           DECISIONS **D-19** (execution of D-17 / D-7 / D-15). FFTS
  itself was ALSO verified BSD-3-Clause (upstream COPYRIGHT read at HEAD
  b22d839) but is not vendored — the kissfft-backed seam keeps the third-party
  surface smaller; an upstream-faithful FFTS build remains possible via the
  seam if ever needed.
- Subsetting note: upstream `hmm.cpp`, `wav_analyzer/`, `misc/`, `test/`,
  `CMakeLists.txt`, build tooling are NOT vendored (mlpack-heavy or non-core).
  Only `include/pitch_detection.h` + `src/{mpm,yin,autocorrelation,
  parabolic_interpolation}.cpp` + local `pd_fft` seam + kissfft subset ship.
- Verified (D-19 intake test, Linux g++ 13.3.0, 13/13 checks): `pitch::mpm` and
  `pitch::yin` recover synthetic sines at 16 kHz — 437.5 Hz and 93.75 Hz
  (integer-period 1024-sample buffers, error < 0.01 Hz), E2 82.4 Hz and 440 Hz
  on non-power-of-two buffers (COMPLEX_TO_COMPLEX path), silence → −1; float
  and double instantiations; reused `pitch_alloc::Mpm` allocation (ribbon hot
  path). The `pd_fft` kissfft backend was additionally probed element-wise
  against a full complex-IDFT reference: rms difference 2.5e-05 (float
  rounding) — `kiss_fftri` output is consumed in NATURAL order, no unfold.
- **ENGINEERING NOTE for P-102 (upstream behavior, NOT a bug):** the upstream
  autocorrelation is CIRCULAR (raw FFT of the buffer, power spectrum, inverse
  FFT, no windowing/zero-padding). A buffer containing a non-integer number of
  periods leaks and biases the period estimate (e.g. 440 Hz in exactly-1024
  samples @16 kHz = 28.16 periods → ~438 Hz returned; 1200 samples = 33.0
  periods → 440.0 exact). Upstream FFTS exhibits the identical artifact. Ribbon
  integration must choose window sizes/overlap accordingly (or add
  zero-padding/windowing as a documented engine-side change — a NEW patches.log
  entry, never a silent edit).

