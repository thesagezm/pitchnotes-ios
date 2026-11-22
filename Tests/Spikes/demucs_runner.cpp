// Demucs spike runner (P-201, PAUL lane).
//
// Compiles against the VENDORED sevagh/demucs.cpp subset (vendor/demucs.cpp,
// MIT — D-30 Tier A for code) + Eigen headers (MPL-2.0, D-32.5) and drives the
// real htdemucs fp16 ggml inference on a 44.1 kHz fixture. Weights = TIER B
// (D-30: MIT © Meta, MUSDB18 CC BY-NC-SA training-data risk recorded; trust
// anchor = sha256 at first verification, D-19.4).
//
// Usage:
//   demucs_runner <model-ggml> <input-wav-44k1> <outdir> [--threads N]
// The --threads flag sets DEMUCSCPP_NUM_THREADS for the patched vendor build
// (std::thread parallelism around Eigen ops — threading patch is Paul's, Leto
// applies to vendor/ with patches.log entry per D-32.4). The unpatched build
// ignores it (single-threaded); the benchmark records both.
//
// stdout metric lines (driver parses; progress chatter goes to stderr):
//   SAMPLES\t<N>\t<SR>\t<CHANNELS-IN>
//   N_SOURCES\t<N>
//   SEGMENTS\t<N>
//   MODEL_LOAD_S\t<f>
//   RTF\t<f>                     inference wall / audio duration
//   RSS_KB\t<peak>
//   STEM_RMS_DB\t<name>\t<db>    vocals + instrumental (composed) + 4 sources
//
// Output files in <outdir> (never committed — temp build dir):
//   stem_drums.f32 / stem_bass.f32 / stem_other.f32 / stem_vocals.f32
//       raw float32, channel-interleaved stereo (2 × N), target order per
//       intake README: target_0_drums, target_1_bass, target_2_other,
//       target_3_vocals.
//   vocals.wav / instrumental.wav   PCM16 mono channel-mean (D-8 preview)
//
// Determinism (S6): upstream shift_inference draws `rand() % max_shift` — the
// runner seeds srand(1337) so every run is byte-identical. This is a runner
// choice, not a vendor change.
//
// D-9: always two-stem. The 4-source model is run once; vocals = target_3,
// instrumental = drums+bass+other summed (residual policy per intake README
// "Build notes for P-201"). Instrumental-presence detection (D-9 near-silence
// flag) is P-205, not here.

#include "model.hpp"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/resource.h>
#include <vector>

namespace {

struct Wav {
	int sample_rate = 0;
	int channels = 0;
	std::vector<float> samples; // interleaved, [-1, 1]
};

[[noreturn]] void die(const char* msg) {
	std::fprintf(stderr, "demucs_runner: %s\n", msg);
	std::exit(2);
}

Wav read_wav(const char* path) {
	std::ifstream f(path, std::ios::binary);
	if (!f) die("cannot open wav");
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
	auto read_i16 = [&f]() {
		std::int16_t v = 0;
		f.read(reinterpret_cast<char*>(&v), 2);
		return v;
	};
	char tag[5] = {0};
	f.read(tag, 4);
	if (std::string(tag) != "RIFF") die("not RIFF");
	read_u32(); // riff size
	f.read(tag, 4);
	if (std::string(tag) != "WAVE") die("not WAVE");
	bool have_fmt = false, have_data = false;
	std::uint16_t bits = 0, fmt = 0;
	Wav w;
	while (f) {
		f.read(tag, 4);
		if (!f) break;
		std::uint32_t sz = read_u32();
		if (std::string(tag) == "fmt ") {
			fmt = read_u16();
			w.channels = read_u16();
			w.sample_rate = read_u32();
			read_u32(); // byte rate
			read_u16(); // block align
			bits = read_u16();
			if (sz > 16) f.ignore(sz - 16);
			have_fmt = true;
		} else if (std::string(tag) == "data") {
			std::size_t n = sz / (bits / 8);
			w.samples.resize(n);
			if (bits == 16 && fmt == 1) {
				for (std::size_t i = 0; i < n; ++i) w.samples[i] = read_i16() / 32768.0f;
			} else if (bits == 32 && fmt == 3) {
				f.read(reinterpret_cast<char*>(w.samples.data()), sz);
			} else {
				die("unsupported wav format (need PCM16 or float32)");
			}
			have_data = true;
		} else {
			f.ignore(sz & 1 ? sz + 1 : sz);
		}
	}
	if (!have_fmt || !have_data) die("missing fmt or data chunk");
	return w;
}

void write_wav_mono(const char* path, const float* samples, std::size_t n, int sr) {
	std::ofstream f(path, std::ios::binary);
	if (!f) die("cannot write wav");
	std::uint32_t data_bytes = std::uint32_t(n * 2);
	std::uint32_t riff = 36 + data_bytes;
	f.write("RIFF", 4);
	f.write(reinterpret_cast<const char*>(&riff), 4);
	f.write("WAVEfmt ", 8);
	std::uint32_t fmt_sz = 16;
	f.write(reinterpret_cast<const char*>(&fmt_sz), 4);
	std::uint16_t pcm = 1, ch = 1;
	f.write(reinterpret_cast<const char*>(&pcm), 2);
	f.write(reinterpret_cast<const char*>(&ch), 2);
	f.write(reinterpret_cast<const char*>(&sr), 4);
	std::uint32_t byte_rate = std::uint32_t(sr * 2);
	f.write(reinterpret_cast<const char*>(&byte_rate), 4);
	std::uint16_t align = 2;
	f.write(reinterpret_cast<const char*>(&align), 2);
	std::uint16_t bits = 16;
	f.write(reinterpret_cast<const char*>(&bits), 2);
	f.write("data", 4);
	f.write(reinterpret_cast<const char*>(&data_bytes), 4);
	for (std::size_t i = 0; i < n; ++i) {
		float v = samples[i];
		if (v > 1.0f) v = 1.0f;
		if (v < -1.0f) v = -1.0f;
		std::int16_t s = std::int16_t(v * 32767.0f);
		f.write(reinterpret_cast<const char*>(&s), 2);
	}
}

double rms_db(const std::vector<float>& x) {
	double s = 0.0;
	for (float v : x) s += double(v) * double(v);
	double rms = std::sqrt(s / double(x.size() ? x.size() : 1));
	if (rms < 1e-12) return -240.0;
	return 20.0 * std::log10(rms);
}

std::size_t peak_rss_kb() {
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	return std::size_t(ru.ru_maxrss); // Linux: KiB
}

} // namespace

int main(int argc, char** argv) {
	if (argc < 4) {
		std::fprintf(stderr,
		             "usage: demucs_runner <model-ggml> <input-wav-44k1> <outdir> "
		             "[--threads N]\n");
		return 2;
	}
	const char* model_path = argv[1];
	const char* wav_path = argv[2];
	std::string outdir = argv[3];
	int threads = 1;
	for (int i = 4; i + 1 < argc; i += 2) {
		if (std::strcmp(argv[i], "--threads") == 0) threads = std::atoi(argv[i + 1]);
	}
	// Threading seam for the patched vendor build (D-32.4: ADD parallelism).
	// The unpatched vendor ignores this env; the patch reads it per loop.
	char envbuf[32];
	std::snprintf(envbuf, sizeof(envbuf), "%d", threads);
	setenv("DEMUCSCPP_NUM_THREADS", envbuf, 1);

	// Determinism: pin the shift-inference offset (upstream rand()%max_shift).
	srand(1337);

	Wav wav = read_wav(wav_path);
	if (wav.sample_rate != 44100) die("input must be 44100 Hz (D-8 SR policy)");
	if (wav.channels > 2) die("input must be mono or stereo");
	std::size_t n = wav.samples.size() / wav.channels;

	// Build the 2 x N input (mono duplicated per demucs 2-channel contract).
	Eigen::MatrixXf full_audio(2, int(n));
	for (std::size_t i = 0; i < n; ++i) {
		float l = wav.samples[i * wav.channels];
		float r = wav.channels == 2 ? wav.samples[i * wav.channels + 1] : l;
		full_audio(0, int(i)) = l;
		full_audio(1, int(i)) = r;
	}
	std::printf("SAMPLES\t%zu\t%d\t%d\n", n, wav.sample_rate, wav.channels);

	// Load the ggml fp16 model (dequantizes to fp32 Eigen tensors).
	const auto t_load0 = std::chrono::steady_clock::now();
	struct demucscpp::demucs_model model;
	if (!demucscpp::load_demucs_model(model_path, &model)) die("model load failed");
	const auto t_load1 = std::chrono::steady_clock::now();
	double load_s =
	    std::chrono::duration<double>(t_load1 - t_load0).count();
	std::printf("MODEL_LOAD_S\t%.3f\n", load_s);
	int nb_sources = model.is_4sources ? 4 : 6;
	std::printf("N_SOURCES\t%d\n", nb_sources);

	// Progress -> stderr (keeps stdout machine-parseable).
	demucscpp::ProgressCallback cb = [](float progress, const std::string& msg) {
		std::fprintf(stderr, "[progress %.3f] %s\n", progress, msg.c_str());
	};

	const auto t0 = std::chrono::steady_clock::now();
	Eigen::Tensor3dXf out = demucscpp::demucs_inference(model, full_audio, cb);
	const auto t1 = std::chrono::steady_clock::now();
	double wall_s = std::chrono::duration<double>(t1 - t0).count();
	double audio_s = double(n) / double(wav.sample_rate);
	std::printf("RTF\t%.4f\n", wall_s / audio_s);
	std::printf("RSS_KB\t%zu\n", peak_rss_kb());

	// Dump raw stems (interleaved stereo float32) + compose the two-stem pair.
	// 4-source target order: 0 drums, 1 bass, 2 other, 3 vocals (intake README).
	const char* names[4] = {"drums", "bass", "other", "vocals"};
	std::vector<std::vector<float>> interl(nb_sources);
	for (int s = 0; s < nb_sources; ++s) {
		interl[s].resize(2 * n);
		for (std::size_t i = 0; i < n; ++i) {
			interl[s][2 * i] = out(s, 0, int(i));
			interl[s][2 * i + 1] = out(s, 1, int(i));
		}
		std::string p = outdir + "/stem_" + names[s] + ".f32";
		std::ofstream f(p, std::ios::binary);
		if (!f) die("cannot write stem f32");
		f.write(reinterpret_cast<const char*>(interl[s].data()),
		        std::streamsize(interl[s].size() * sizeof(float)));
		char rms_line[96];
		std::snprintf(rms_line, sizeof(rms_line), "STEM_RMS_DB\t%s\t%.2f\n",
		              names[s], rms_db(interl[s]));
		std::fputs(rms_line, stdout);
	}

	// Composed two-stem outputs (mono channel-mean for the PCM16 previews):
	// vocals = target_3; instrumental = drums+bass+other (D-9 always-two-stem).
	std::vector<float> vocals(n), instrumental(n), vm(2 * n), im(2 * n);
	for (std::size_t i = 0; i < n; ++i) {
		float v = 0.5f * (interl[3][2 * i] + interl[3][2 * i + 1]);
		float ins_l = interl[0][2 * i] + interl[1][2 * i] + interl[2][2 * i];
		float ins_r =
		    interl[0][2 * i + 1] + interl[1][2 * i + 1] + interl[2][2 * i + 1];
		vocals[i] = v;
		instrumental[i] = 0.5f * (ins_l + ins_r);
		vm[2 * i] = interl[3][2 * i];
		vm[2 * i + 1] = interl[3][2 * i + 1];
		im[2 * i] = ins_l;
		im[2 * i + 1] = ins_r;
	}
	write_wav_mono((outdir + "/vocals.wav").c_str(), vocals.data(), n,
	               wav.sample_rate);
	write_wav_mono((outdir + "/instrumental.wav").c_str(), instrumental.data(),
	               n, wav.sample_rate);
	std::printf("STEM_RMS_DB\tvocals-mono\t%.2f\n", rms_db(vocals));
	std::printf("STEM_RMS_DB\tinstrumental-mono\t%.2f\n", rms_db(instrumental));
	std::printf("DONE\n");
	return 0;
}
