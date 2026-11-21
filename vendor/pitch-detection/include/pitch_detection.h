#ifndef PITCH_DETECTION_H
#define PITCH_DETECTION_H

/*
 * Upstream: sevagh/pitch-detection @ v2023.12 (faa04bb), MIT — LICENSE verbatim.
 * PATCHED by PitchNotes intake 2026-11-21 (patches.log, DECISIONS D-19):
 *   - #include <ffts/ffts.h> replaced by local seam "pd_fft.h" (kissfft backend;
 *     upstream FFTS calls removed — same raw/unnormalized transform semantics).
 *   - mlpack (HMM) dependency REMOVED: detail:: pitch-bin helpers, the `hmm`
 *     member and its ctor wiring, util::pitch_from_hmm, and the probabilistic
 *     HMM-backed variants pmpm/pyin/probabilistic_pitch are excluded. The
 *     deterministic MPM + YIN paths are byte-faithful to upstream algorithm.
 *   - Re-intake (with an mlpack Apache-2.0 audit) required before pmpm/pyin
 *     could ever be used.
 */

#include <complex>
#include <stdexcept>
#include <vector>

#include "pd_fft.h"

/*
 * The pitch namespace contains the functions:
 *
 * 	pitch::mpm(data, sample_rate)
 * 	pitch::yin(data, sample_rate)
 *
 * It will auto-allocate any buffers.
 */
namespace pitch
{

template <typename T>
T
yin(const std::vector<T> &, int);

template <typename T>
T
mpm(const std::vector<T> &, int);
} // namespace pitch

/*
 * This namespace is useful for repeated calls to pitch for the same size of
 * buffer.
 *
 * It contains the classes Yin and Mpm which contain the allocated buffers
 * and each implement a `pitch(data, sample_rate)` method.
 */
namespace pitch_alloc
{

enum FFTType { REAL_TO_COMPLEX, COMPLEX_TO_COMPLEX };

class BaseAlloc
{
  public:
	long nfft;
	FFTType fft_type;
	// kissfft is fine with floats, not doubles (upstream FFTS comment retained)
	std::vector<float> out_real;
	std::vector<std::complex<float>> out_im;
	pd_fft_plan *fft_forward;
	pd_fft_plan *fft_backward;

	BaseAlloc(long audio_buffer_size)
	    : nfft(audio_buffer_size),
	      fft_type(
	          is_power_of_two(nfft) ? REAL_TO_COMPLEX : COMPLEX_TO_COMPLEX),
	      out_real(std::vector<float>(nfft)),
	      out_im((fft_type == REAL_TO_COMPLEX) ? (nfft / 2 + 1) : nfft)
	{
		if (fft_type == REAL_TO_COMPLEX) {
			// For real-to-complex, output size is nfft/2 + 1
			out_im.resize(nfft / 2 + 1);
			fft_forward = pd_fft_init_1d_real(nfft, PD_FFT_FORWARD);
			fft_backward = pd_fft_init_1d_real(nfft, PD_FFT_BACKWARD);
		} else {
			// For complex-to-complex, output size is nfft
			out_im.resize(nfft);
			fft_forward = pd_fft_init_1d(nfft, PD_FFT_FORWARD);
			fft_backward = pd_fft_init_1d(nfft, PD_FFT_BACKWARD);
		}

		if (!fft_forward || !fft_backward)
			throw std::runtime_error("pd_fft plan allocation failed");

		clear();
	}

	~BaseAlloc()
	{
		pd_fft_free(fft_forward);
		pd_fft_free(fft_backward);
	}

  protected:
	void
	clear()
	{
		std::fill(
		    out_im.begin(), out_im.end(), std::complex<float>{0.0f, 0.0f});
	}

  private:
	// Utility function to check if a number is a power of two
	static bool
	is_power_of_two(long x)
	{
		return x && !(x & (x - 1));
	}
};

/*
 * Allocate the buffers for MPM for re-use.
 * Intended for multiple consistently-sized audio buffers.
 *
 * Usage: pitch_alloc::Mpm ma(1024)
 */
template <typename T> class Mpm : public BaseAlloc
{
  public:
	Mpm(long audio_buffer_size) : BaseAlloc(audio_buffer_size){};

	T
	pitch(const std::vector<T> &, int);
};

/*
 * Allocate the buffers for YIN for re-use.
 * Intended for multiple consistently-sized audio buffers.
 *
 * Usage: pitch_alloc::Yin ya(1024)
 */
template <typename T> class Yin : public BaseAlloc
{
  public:
	int yin_buffer_size;
	std::vector<float> yin_buffer;

	Yin(long audio_buffer_size)
	    : BaseAlloc(audio_buffer_size), yin_buffer_size(audio_buffer_size / 2),
	      yin_buffer(std::vector<float>(yin_buffer_size))
	{
	}

	T
	pitch(const std::vector<T> &, int);
};
} // namespace pitch_alloc

namespace util
{
template <typename T>
std::pair<T, T> // the input is a float, output of FFTS
parabolic_interpolation(const std::vector<float> &, int);

template <typename T>
void
acorr_r(const std::vector<T> &, pitch_alloc::BaseAlloc *);
} // namespace util

#endif /* PITCH_DETECTION_H */
