/*
 * pd_fft_backend.cpp — kissfft implementation of the pd_fft seam.
 *
 * NOT upstream (sevagh/pitch-detection). PitchNotes-local glue, see patches.log.
 * kissfft v131 (BSD-3-Clause, Mark Borgerding) vendored unmodified under
 * third_party/kissfft — flattened from the upstream root + tools/ layout so
 * the relative #includes resolve; no source edits.
 *
 * Normalization contract (must match upstream FFTS call sites): both forward
 * and inverse transforms are RAW/unnormalized. The autocorrelation pipeline in
 * acorr_r() applies its own 1/nfft scale in the frequency domain, which yields
 * the unscaled autocorrelation r(tau) exactly when the inverse is raw. kissfft
 * is raw by design (kiss_fftri docs: caller divides for normalized output) —
 * no compensation applied here. Verified empirically: pitch::mpm/pitch::yin
 * recover 440 Hz / 82.4 Hz sines at 16 kHz on this backend (D-19 intake test).
 */
#include "pd_fft.h"

#include "../third_party/kissfft/kiss_fft.h"
#include "../third_party/kissfft/kiss_fftr.h"

#include <cstdlib>

struct pd_fft_plan {
	enum pd_fft_direction dir;
	int real; /* 1 = real-input transform, 0 = complex */
	union {
		kiss_fftr_cfg fftr;
		kiss_fft_cfg fft;
	} cfg;
};

static void *
pd_alloc_cfg(size_t memneeded)
{
	return malloc(memneeded);
}

pd_fft_plan *
pd_fft_init_1d_real(long nfft, enum pd_fft_direction dir)
{
	if (nfft <= 0 || nfft % 2 != 0)
		return nullptr;

	size_t memneeded = 0;
	/* kiss_fftr_alloc(NULL) returns the required size in memneeded. */
	kiss_fftr_alloc((size_t)nfft, dir == PD_FFT_BACKWARD, nullptr, &memneeded);

	pd_fft_plan *plan = (pd_fft_plan *)malloc(sizeof(pd_fft_plan));
	if (!plan)
		return nullptr;
	plan->dir = dir;
	plan->real = 1;
	plan->cfg.fftr = (kiss_fftr_cfg)pd_alloc_cfg(memneeded);
	if (!plan->cfg.fftr ||
	    !(plan->cfg.fftr = kiss_fftr_alloc((size_t)nfft,
	           dir == PD_FFT_BACKWARD, plan->cfg.fftr, &memneeded))) {
		free(plan);
		return nullptr;
	}
	return plan;
}

pd_fft_plan *
pd_fft_init_1d(long nfft, enum pd_fft_direction dir)
{
	if (nfft <= 0)
		return nullptr;

	size_t memneeded = 0;
	kiss_fft_alloc((size_t)nfft, dir == PD_FFT_BACKWARD, nullptr, &memneeded);

	pd_fft_plan *plan = (pd_fft_plan *)malloc(sizeof(pd_fft_plan));
	if (!plan)
		return nullptr;
	plan->dir = dir;
	plan->real = 0;
	plan->cfg.fft = (kiss_fft_cfg)pd_alloc_cfg(memneeded);
	if (!plan->cfg.fft ||
	    !(plan->cfg.fft = kiss_fft_alloc((size_t)nfft, dir == PD_FFT_BACKWARD,
	        plan->cfg.fft, &memneeded))) {
		free(plan);
		return nullptr;
	}
	return plan;
}

void
pd_fft_execute(pd_fft_plan *plan, void *in, void *out)
{
	if (!plan || !in || !out)
		return;

	if (plan->real) {
		if (plan->dir == PD_FFT_FORWARD) {
			/* nfft real floats -> (nfft/2+1) interleaved complex floats */
			kiss_fftr(plan->cfg.fftr, (const kiss_fft_scalar *)in,
			    (kiss_fft_cpx *)out);
		} else {
			/* (nfft/2+1) complex -> nfft real (raw/unnormalized inverse) */
			kiss_fftri(plan->cfg.fftr, (const kiss_fft_cpx *)in,
			    (kiss_fft_scalar *)out);
		}
	} else {
		kiss_fft(plan->cfg.fft, (const kiss_fft_cpx *)in, (kiss_fft_cpx *)out);
	}
}

void
pd_fft_free(pd_fft_plan *plan)
{
	if (!plan)
		return;
	if (plan->real)
		free(plan->cfg.fftr);
	else
		free(plan->cfg.fft);
	free(plan);
}
