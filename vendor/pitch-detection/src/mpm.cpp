// Upstream: sevagh/pitch-detection @ v2023.12 (faa04bb), MIT — PATCHED by
// PitchNotes intake 2026-11-21 (patches.log): probabilistic HMM-backed pmpm
// path (probabilistic_pitch + pitch_from_hmm) removed with the mlpack
// dependency. Deterministic MPM (McLeod) is algorithm-identical to upstream.

#include "pitch_detection.h"
#include <algorithm>
#include <complex>
#include <float.h>
#include <numeric>
#include <vector>

#define MPM_CUTOFF 0.93
#define MPM_SMALL_CUTOFF 0.5
#define MPM_LOWER_PITCH_CUTOFF 80.0

template <typename T>
static std::vector<int>
peak_picking(const std::vector<T> &nsdf)
{
	std::vector<int> max_positions{};
	int pos = 0;
	int cur_max_pos = 0;
	ssize_t size = nsdf.size();

	while (pos < (size - 1) / 3 && nsdf[pos] > 0)
		pos++;
	while (pos < size - 1 && nsdf[pos] <= 0.0)
		pos++;

	if (pos == 0)
		pos = 1;

	while (pos < size - 1) {
		if (nsdf[pos] > nsdf[pos - 1] && nsdf[pos] >= nsdf[pos + 1] &&
		    (cur_max_pos == 0 || nsdf[pos] > nsdf[cur_max_pos])) {
			cur_max_pos = pos;
		}
		pos++;
		if (pos < size - 1 && nsdf[pos] <= 0) {
			if (cur_max_pos > 0) {
				max_positions.push_back(cur_max_pos);
				cur_max_pos = 0;
			}
			while (pos < size - 1 && nsdf[pos] <= 0.0) {
				pos++;
			}
		}
	}
	if (cur_max_pos > 0) {
		max_positions.push_back(cur_max_pos);
	}
	return max_positions;
}

template <typename T>
T
pitch_alloc::Mpm<T>::pitch(const std::vector<T> &audio_buffer, int sample_rate)
{
	util::acorr_r(audio_buffer, this);

	std::vector<int> max_positions = peak_picking(this->out_real);
	std::vector<std::pair<T, T>> estimates;

	T highest_amplitude = -FLT_MAX;

	for (int i : max_positions) {
		highest_amplitude =
		    std::max(highest_amplitude, static_cast<T>(this->out_real[i]));
		if (this->out_real[i] > MPM_SMALL_CUTOFF) {
			auto x = util::parabolic_interpolation<T>(this->out_real, i);
			estimates.push_back(x);
			highest_amplitude = std::max(highest_amplitude, std::get<1>(x));
		}
	}

	if (estimates.empty())
		return -1;

	T actual_cutoff = MPM_CUTOFF * highest_amplitude;
	T period = 0;

	for (auto i : estimates) {
		if (std::get<1>(i) >= actual_cutoff) {
			period = std::get<0>(i);
			break;
		}
	}

	T pitch_estimate = (sample_rate / period);

	this->clear();

	return (pitch_estimate > MPM_LOWER_PITCH_CUTOFF) ? pitch_estimate : -1;
}

template <typename T>
T
pitch::mpm(const std::vector<T> &audio_buffer, int sample_rate)
{
	pitch_alloc::Mpm<T> ma(audio_buffer.size());
	return ma.pitch(audio_buffer, sample_rate);
}

template class pitch_alloc::Mpm<double>;
template class pitch_alloc::Mpm<float>;

template double
pitch::mpm<double>(const std::vector<double> &audio_buffer, int sample_rate);

template float
pitch::mpm<float>(const std::vector<float> &audio_buffer, int sample_rate);
