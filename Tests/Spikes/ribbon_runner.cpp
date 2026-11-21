// Ribbon spike runner (P-102, PAUL lane).
//
// Compiles against the VENDORED sevagh/pitch-detection subset
// (vendor/pitch-detection, MIT — D-19 intake) + kissfft (BSD-3) and drives
// the D-17 default causal ribbon: pitch_alloc::Mpm<float>, one reused
// allocation, zero lookahead (each frame sees only past samples).
//
// Usage: ribbon_runner <wav-pcm16-mono> [window=1024] [hop=256]
// stdout: "t\thz" per frame (hz = -1 => unvoiced / below 80 Hz cutoff),
// final line "RTF\t<seconds>" = inference time / audio time.
//
// This is the CI ribbon-spike deliverable per D-19.3 ("real C++ runner,
// compiled vendored MPM/YIN against the synthetic fixtures").

#include "pitch_detection.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

namespace {

struct Wav {
	int sample_rate = 0;
	std::vector<float> samples; // mono, [-1, 1]
};

Wav read_wav_mono(const char* path) {
	std::ifstream f(path, std::ios::binary);
	if (!f) {
		std::fprintf(stderr, "cannot open %s\n", path);
		std::exit(2);
	}
	auto read_u32 = [&f]() {
		std::uint32_t v = 0;
		f.read(reinterpret_cast<char*>(&v), 4);
		return v;
	};
	auto read_u16 = [&f]() {
		std::uint16_t v = 0;
		f.read(reinterpret_cast<char*>(&v), 2);
		return v;
	};
	char tag[5] = {0};
	f.read(tag, 4);
	if (std::string(tag) != "RIFF") { std::fprintf(stderr, "not RIFF\n"); std::exit(2); }
	read_u32();
	f.read(tag, 4);
	if (std::string(tag) != "WAVE") { std::fprintf(stderr, "not WAVE\n"); std::exit(2); }

	int sample_rate = 0, channels = 0, bits = 0;
	std::vector<std::int16_t> pcm;
	bool have_fmt = false, have_data = false;
	while (!f.eof()) {
		char id[5] = {0};
		f.read(id, 4);
		if (f.gcount() < 4) break;
		std::uint32_t size = read_u32();
		std::string cid(id);
		if (cid == "fmt ") {
			std::uint16_t audio_format = read_u16();
			channels = read_u16();
			sample_rate = static_cast<int>(read_u32());
			read_u32();          // byte rate
			read_u16();          // block align
			bits = read_u16();
			if (audio_format != 1 || bits != 16) {
				std::fprintf(stderr, "unsupported fmt (need PCM16)\n");
				std::exit(2);
			}
			have_fmt = true;
		} else if (cid == "data") {
			pcm.resize(size / 2);
			f.read(reinterpret_cast<char*>(pcm.data()), size);
			have_data = true;
		} else {
			f.seekg(size + (size & 1), std::ios::cur);
		}
	}
	if (!have_fmt || !have_data) { std::fprintf(stderr, "missing fmt/data\n"); std::exit(2); }

	Wav w;
	w.sample_rate = sample_rate;
	w.samples.reserve(pcm.size() / static_cast<std::size_t>(channels));
	for (std::size_t i = 0; i + channels <= pcm.size(); i += static_cast<std::size_t>(channels)) {
		float acc = 0;
		for (int c = 0; c < channels; ++c) acc += static_cast<float>(pcm[i + static_cast<std::size_t>(c)]) / 32768.0f;
		w.samples.push_back(acc / static_cast<float>(channels));
	}
	return w;
}

} // namespace

int main(int argc, char** argv) {
	if (argc < 2) {
		std::fprintf(stderr, "usage: ribbon_runner <wav> [window=1024] [hop=256]\n");
		return 2;
	}
	Wav wav = read_wav_mono(argv[1]);
	const long window = (argc > 2) ? std::atol(argv[2]) : 1024;
	const long hop = (argc > 3) ? std::atol(argv[3]) : 256;
	if (window <= 0 || hop <= 0 || wav.sample_rate <= 0) {
		std::fprintf(stderr, "bad args\n");
		return 2;
	}

	pitch_alloc::Mpm<float> mpm(window); // reused allocation = ribbon hot path
	const std::size_t n = wav.samples.size();
	const long n_frames = static_cast<long>((n >= static_cast<std::size_t>(window))
		? (n - static_cast<std::size_t>(window)) / static_cast<std::size_t>(hop) + 1
		: 0);

	std::vector<float> buf(window);
	const auto t0 = std::chrono::steady_clock::now();
	for (long k = 0; k < n_frames; ++k) {
		const std::size_t start = static_cast<std::size_t>(k * hop);
		std::copy(wav.samples.begin() + static_cast<long>(start),
		          wav.samples.begin() + static_cast<long>(start + window),
		          buf.begin());
		const float hz = mpm.pitch(buf, wav.sample_rate);
		const double t = static_cast<double>(start) / wav.sample_rate;
		std::printf("%.4f\t%.4f\n", t, static_cast<double>(hz));
	}
	const auto t1 = std::chrono::steady_clock::now();

	const double audio_time = static_cast<double>(n) / wav.sample_rate;
	const double infer = std::chrono::duration<double>(t1 - t0).count();
	std::printf("RTF\t%.6f\n", audio_time > 0 ? infer / audio_time : 0.0);
	return 0;
}
