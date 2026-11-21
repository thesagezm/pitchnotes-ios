// Upstream: sevagh/pitch-detection @ v2023.12 (faa04bb), MIT — PATCHED by
// PitchNotes intake 2026-11-21 (patches.log): probabilistic HMM-backed pyin
// path (Beta_Distribution_0 table, probabilistic_threshold,
// probabilistic_pitch + pitch_from_hmm) removed with the mlpack dependency.
// Deterministic YIN is algorithm-identical to upstream.

#include "pitch_detection.h"
#include <algorithm>
#include <complex>
#include <tuple>
#include <vector>

#define YIN_THRESHOLD 0.20

template <typename T>
static int
absolute_threshold(const std::vector<T> &yin_buffer)
{
	ssize_t size = yin_buffer.size();
	int tau;
	for (tau = 2; tau < size; tau++) {
		if (yin_buffer[tau] < YIN_THRESHOLD) {
			while (tau + 1 < size && yin_buffer[tau + 1] < yin_buffer[tau]) {
				tau++;
			}
			break;
		}
	}
	return (tau == size || yin_buffer[tau] >= YIN_THRESHOLD) ? -1 : tau;
}

template <typename T>
static void
difference(const std::vector<T> &audio_buffer, pitch_alloc::Yin<T> *ya)
{
	util::acorr_r(audio_buffer, ya);

	for (int tau = 0; tau < ya->yin_buffer_size; tau++)
		ya->yin_buffer[tau] =
		    ya->out_real[0] + ya->out_real[1] - 2 * ya->out_real[tau];
}

template <typename T>
static void
cumulative_mean_normalized_difference(std::vector<T> &yin_buffer)
{
	T running_sum = static_cast<T>(0.0f);

	yin_buffer[0] = 1;

	for (int tau = 1; tau < signed(yin_buffer.size()); tau++) {
		running_sum += yin_buffer[tau];
		yin_buffer[tau] *= tau / running_sum;
	}
}

template <typename T>
T
pitch_alloc::Yin<T>::pitch(const std::vector<T> &audio_buffer, int sample_rate)
{
	int tau_estimate;

	difference(audio_buffer, this);

	cumulative_mean_normalized_difference(this->yin_buffer);
	tau_estimate = absolute_threshold(this->yin_buffer);

	auto ret = (tau_estimate != -1)
	               ? sample_rate / std::get<0>(util::parabolic_interpolation<T>(
	                                   this->yin_buffer, tau_estimate))
	               : -1;

	this->clear();
	return ret;
}

template <typename T>
T
pitch::yin(const std::vector<T> &audio_buffer, int sample_rate)
{

	pitch_alloc::Yin<T> ya(audio_buffer.size());
	return ya.pitch(audio_buffer, sample_rate);
}

template class pitch_alloc::Yin<double>;
template class pitch_alloc::Yin<float>;

template double
pitch::yin<double>(const std::vector<double> &audio_buffer, int sample_rate);

template float
pitch::yin<float>(const std::vector<float> &audio_buffer, int sample_rate);
