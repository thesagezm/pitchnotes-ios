// Upstream: sevagh/pitch-detection @ v2023.12 (faa04bb), MIT — PATCHED by
// PitchNotes intake 2026-11-21 (patches.log): ffts_execute -> pd_fft_execute
// via the local kissfft-backed seam (include/pd_fft.h). Algorithm unchanged.

#include "pitch_detection.h"
#include <algorithm>
#include <complex>
#include <numeric>
#include <vector>

template <typename T>
void
util::acorr_r(const std::vector<T> &audio_buffer, pitch_alloc::BaseAlloc *ba)
{
	if (ba->fft_type == pitch_alloc::FFTType::REAL_TO_COMPLEX) {
		std::copy(audio_buffer.begin(), audio_buffer.begin() + ba->nfft,
		    ba->out_real.begin());
		pd_fft_execute(ba->fft_forward, ba->out_real.data(), ba->out_im.data());
	} else {
		std::transform(audio_buffer.begin(), audio_buffer.begin() + ba->nfft,
		    ba->out_im.begin(),
		    [](T x) -> std::complex<T> { return std::complex<T>(x, 0.0f); });
		pd_fft_execute(ba->fft_forward, ba->out_im.data(), ba->out_im.data());
	}

	std::complex<float> scale = 1.0f / static_cast<float>(ba->nfft);
	int output_size = (ba->fft_type == pitch_alloc::FFTType::REAL_TO_COMPLEX)
	                      ? ba->nfft / 2 + 1
	                      : ba->nfft;
	for (int i = 0; i < output_size; ++i) {
		ba->out_im[i] *= std::conj(ba->out_im[i]) * scale;
	}

	if (ba->fft_type == pitch_alloc::FFTType::REAL_TO_COMPLEX) {
		pd_fft_execute(ba->fft_backward, ba->out_im.data(), ba->out_real.data());
		std::copy(ba->out_real.begin(), ba->out_real.begin() + ba->nfft,
		    ba->out_real.begin());
	} else {
		pd_fft_execute(ba->fft_backward, ba->out_im.data(), ba->out_im.data());
		std::transform(ba->out_im.begin(), ba->out_im.begin() + ba->nfft,
		    ba->out_real.begin(), [](const std::complex<float> &cplx) -> T {
			    return std::real(cplx);
		    });
	}
}

template void
util::acorr_r<double>(
    const std::vector<double> &audio_buffer, pitch_alloc::BaseAlloc *ba);

template void
util::acorr_r<float>(
    const std::vector<float> &audio_buffer, pitch_alloc::BaseAlloc *ba);
