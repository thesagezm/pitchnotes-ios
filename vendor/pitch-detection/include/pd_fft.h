/*
 * pd_fft.h — FFT backend seam for the vendored sevagh/pitch-detection subset.
 *
 * This file is NOT upstream. It is a PitchNotes-local shim (see patches.log)
 * that replaces the upstream hard dependency on FFTS (github.com/anthonix/ffts,
 * BSD-3-Clause — verified 2026-11-21, DECISIONS D-19) with a minimal C ABI so
 * the engine can bind any permissive FFT backend:
 *   - shipped default: kissfft v131 (BSD-3-Clause, vendored under
 *     third_party/kissfft) — portable iOS/Android/Linux;
 *   - intended iOS optimization (P-102): vDSP/Accelerate re-implementation of
 *     this exact 4-function ABI (system framework, zero third-party code).
 *
 * Semantics mirror the upstream FFTS call sites in autocorrelation.cpp /
 * pitch_detection.h: raw (UNNORMALIZED) forward and inverse transforms over
 * float data — do not "fix" normalization here without re-validating the MPM
 * cutoff constants upstream (MPM_CUTOFF 0.93 / MPM_SMALL_CUTOFF 0.5 depend on
 * the unnormalized acorr scale).
 */
#ifndef PD_FFT_H
#define PD_FFT_H

#ifdef __cplusplus
extern "C" {
#endif

enum pd_fft_direction { PD_FFT_FORWARD = 0, PD_FFT_BACKWARD = 1 };

/* Opaque plan. float-only: pitch_alloc::BaseAlloc buffers are float. */
typedef struct pd_fft_plan pd_fft_plan;

/* Real-input transforms. forward: nfft real -> nfft/2+1 complex floats
 * (kissfft packed layout: DC first, Nyquist last). backward: the inverse —
 * (nfft/2+1) complex floats (imaginary parts of DC/Nyquist must be 0) ->
 * nfft real floats. nfft must be even. */
pd_fft_plan *pd_fft_init_1d_real(long nfft, enum pd_fft_direction dir);

/* Complex transforms, nfft complex floats -> nfft complex floats. */
pd_fft_plan *pd_fft_init_1d(long nfft, enum pd_fft_direction dir);

/* in/out match the layouts documented per init above; complex data is
 * Interleaved I/Q float pairs (std::complex<float> layout). */
void pd_fft_execute(pd_fft_plan *plan, void *in, void *out);

void pd_fft_free(pd_fft_plan *plan);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* PD_FFT_H */
