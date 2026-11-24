// Basic-pitch spike runner (P-301, PAUL lane).
//
// Drives the VENDORED sevagh/basicpitch.cpp subset (vendor/basicpitch, MIT —
// D-30 Tier A for code) under the EXISTING ONNX Runtime (D-39: ONE runtime —
// the SPM ORT 1.24.2; the trimmed ort-builder route is REJECTED) on a
// 22.05 kHz mono fixture, and dumps everything the parity test needs:
//
//   <outdir>/notes.f32     the model's note tensor,   row-major [time][freq]
//   <outdir>/onsets.f32    the model's onset tensor,  row-major [time][freq]
//   <outdir>/contours.f32  the model's contour tensor, row-major [time][freq]
//   <outdir>/events.tsv    the RAW vendor note events (frame domain):
//                          start_frame \t end_frame \t midi \t amplitude
//   <outdir>/timed.tsv     the ENGINE OUTPUT (time domain): the corrected
//                          frame -> seconds mapping + the release trim:
//                          start_s \t end_s \t midi \t amplitude
//
// The row-major [time][freq] dump is the contract with the Python reference
// (Tests/Spikes/basicpitch_ref.py): the vendor's Eigen tensor is indexed
// [time, freq] (verified by an empirical Eigen probe — the upstream
// `swap_layout().shuffle({1,0})` keeps the frame-major VALUES), and the spike
// compares the two with the C-7 tolerance (abs 1e-3 OR rel 1e-4).
//
// The timing + trim rules live in Engine/Transcription/BasicPitchNotes.hpp —
// the SAME header the app bridge uses, so the spike measures the shipped
// behaviour rather than a parallel implementation.
//
// Usage:
//   basicpitch_runner <model-onnx> <input-wav-22050-mono> <outdir>
//
// stdout metric lines (the driver parses; chatter goes to stderr):
//   SAMPLES\t<N>
//   FRAMES\t<N>\t<N_FREQ>
//   CHUNKS\t<N>
//   NOTE_EVENTS\t<N>
//   TIMED_EVENTS\t<N>
//   MODEL_LOAD_S\t<f>   (not emitted: the vendor loads the session inside
//                       ort_inference, so the load is part of INFER_S)
//   INFER_S\t<f>
//   RTF\t<f>            inference wall / audio duration
//   RSS_KB\t<peak>
//   DONE
//
// Determinism: the pipeline is deterministic (no RNG anywhere); the spike runs
// the runner twice and compares the dumps byte-for-byte.

#include "basicpitch.hpp"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <string>
#include <sys/resource.h>
#include <unistd.h>
#include <vector>

#include "BasicPitchNotes.hpp"

namespace {

[[noreturn]] void die(const char *msg) {
    std::fprintf(stderr, "basicpitch_runner: %s\n", msg);
    std::exit(2);
}

struct Wav {
    int sample_rate = 0;
    int channels = 0;
    std::vector<float> samples; // mono, [-1, 1]
};

Wav read_wav_mono_22050(const char *path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) die("cannot open wav");
    auto read_u32 = [&f]() {
        std::uint32_t v = 0;
        f.read(reinterpret_cast<char *>(&v), 4);
        return v;
    };
    auto read_u16 = [&f]() {
        std::uint16_t v = 0;
        f.read(reinterpret_cast<char *>(&v), 2);
        return v;
    };
    auto read_i16 = [&f]() {
        std::int16_t v = 0;
        f.read(reinterpret_cast<char *>(&v), 2);
        return v;
    };
    char tag[5] = {0};
    f.read(tag, 4);
    if (std::string(tag) != "RIFF") die("not RIFF");
    read_u32();
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
            read_u32();
            read_u16();
            bits = read_u16();
            if (sz > 16) f.ignore(sz - 16);
            have_fmt = true;
        } else if (std::string(tag) == "data") {
            const std::size_t n = sz / (bits / 8);
            w.samples.resize(n);
            if (bits == 16 && fmt == 1) {
                for (std::size_t i = 0; i < n; ++i) {
                    w.samples[i] = read_i16() / 32768.0f;
                }
            } else {
                die("unsupported wav format (need PCM16)");
            }
            have_data = true;
        } else {
            f.ignore(sz & 1 ? sz + 1 : sz);
        }
    }
    if (!have_fmt || !have_data) die("missing fmt or data chunk");
    if (w.channels != 1) die("input must be mono");
    if (w.sample_rate != pitchnotes::basicpitch::kSampleRate) {
        die("input must be 22050 Hz (the model's native rate)");
    }
    return w;
}

/// Dump an Eigen tensor as row-major [time][freq] float32.
///
/// The vendor's tensors are indexed [time, freq] with the frame-major VALUES
/// (the upstream `swap_layout().shuffle({1,0})` reshapes the MEMORY but keeps
/// the logical order — pinned by an empirical Eigen probe), so the row-major
/// dump is `tensor(t, f)` in time-major order.
void dump_tensor(const std::string &path, const Eigen::Tensor2dXf &t) {
    const int time_frames = static_cast<int>(t.dimension(0));
    const int freq_bins = static_cast<int>(t.dimension(1));
    std::vector<float> out(static_cast<std::size_t>(time_frames) *
                           static_cast<std::size_t>(freq_bins));
    for (int i = 0; i < time_frames; ++i) {
        for (int f = 0; f < freq_bins; ++f) {
            out[static_cast<std::size_t>(i) * static_cast<std::size_t>(freq_bins) +
                static_cast<std::size_t>(f)] = t(i, f);
        }
    }
    std::ofstream f(path, std::ios::binary);
    if (!f) die("cannot write tensor dump");
    f.write(reinterpret_cast<const char *>(out.data()),
            static_cast<std::streamsize>(out.size() * sizeof(float)));
}

std::size_t peak_rss_kb() {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
#if defined(__APPLE__)
    // macOS ru_maxrss is in BYTES; normalize to KiB so the metric means the
    // same thing on every host.
    return std::size_t(ru.ru_maxrss) / 1024;
#else
    return std::size_t(ru.ru_maxrss); // Linux: KiB
#endif
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 4) {
        std::fprintf(stderr,
                     "usage: basicpitch_runner <model-onnx> <input-wav-22050-mono> "
                     "<outdir>\n");
        return 2;
    }
    const char *model_path = argv[1];
    const char *wav_path = argv[2];
    const std::string outdir = argv[3];

    const Wav wav = read_wav_mono_22050(wav_path);
    const int n_samples = static_cast<int>(wav.samples.size());
    std::printf("SAMPLES\t%d\n", n_samples);

    // NOTE: the vendor creates the ORT session INSIDE ort_inference(), so the
    // model load is part of the measured wall time (INFER_S / RTF). The
    // session is created per call; the app bridge keeps one session per
    // import, which is strictly cheaper.
    const auto t0 = std::chrono::steady_clock::now();
    basic_pitch::InferenceResult result =
        basic_pitch::ort_inference(wav.samples, model_path);
    const auto t1 = std::chrono::steady_clock::now();
    const double infer_s = std::chrono::duration<double>(t1 - t0).count();
    const double audio_s = static_cast<double>(n_samples) /
                           static_cast<double>(pitchnotes::basicpitch::kSampleRate);

    const int time_frames = static_cast<int>(result.notes.dimension(0));
    const int freq_bins = static_cast<int>(result.notes.dimension(1));
    const int chunks = pitchnotes::basicpitch::chunkCount(n_samples);
    const int expected_frames =
        pitchnotes::basicpitch::unwrappedFrameCount(n_samples);

    // The frame -> seconds mapping assumes the model's per-chunk frame count
    // (172) and the vendor's trim (30 frames). If either changed, the
    // mapping would silently drift — so FAIL LOUDLY instead.
    if (time_frames != expected_frames) {
        std::fprintf(stderr,
                     "basicpitch_runner: frame count %d != expected %d "
                     "(the model's per-chunk frame count or the vendor's trim "
                     "changed — re-derive the frame -> seconds mapping)\n",
                     time_frames, expected_frames);
        return 3;
    }

    std::printf("FRAMES\t%d\t%d\n", time_frames, freq_bins);
    std::printf("TENSOR_DIMS\tnotes\t%d\t%d\n", time_frames, freq_bins);
    std::printf("TENSOR_DIMS\tonsets\t%d\t%d\n",
                static_cast<int>(result.onsets.dimension(0)),
                static_cast<int>(result.onsets.dimension(1)));
    std::printf("TENSOR_DIMS\tcontours\t%d\t%d\n",
                static_cast<int>(result.contours.dimension(0)),
                static_cast<int>(result.contours.dimension(1)));
    std::printf("CHUNKS\t%d\n", chunks);
    std::printf("INFER_S\t%.3f\n", infer_s);
    std::printf("RTF\t%.4f\n", infer_s / audio_s);
    std::printf("RSS_KB\t%zu\n", peak_rss_kb());

    dump_tensor(outdir + "/notes.f32", result.notes);
    dump_tensor(outdir + "/onsets.f32", result.onsets);
    dump_tensor(outdir + "/contours.f32", result.contours);

    // The vendor's raw note events (frame domain).
    const std::vector<basic_pitch::NoteEvent> events =
        basic_pitch::output_to_notes_polyphonic(result, /*melodia*/true,
                                                 /*bends*/false);
    std::printf("NOTE_EVENTS\t%zu\n", events.size());
    {
        std::ofstream f(outdir + "/events.tsv");
        // 17 significant digits => the TSV round-trips a double EXACTLY, so
        // the bridge's output (the C ABI the app calls) can be compared with
        // this dump bit-for-bit rather than within a formatting tolerance.
        f << std::setprecision(17);
        if (!f) die("cannot write events.tsv");
        for (const auto &e : events) {
            f << e.start_idx << '\t' << e.end_idx << '\t' << e.pitch << '\t'
              << e.amplitude << '\n';
        }
    }

    // The ENGINE OUTPUT: the corrected frame -> seconds mapping + the release
    // trim (Engine/Transcription/BasicPitchNotes.hpp — the same header the
    // app bridge uses).
    std::vector<float> note_energy(
        static_cast<std::size_t>(time_frames) * static_cast<std::size_t>(freq_bins));
    for (int i = 0; i < time_frames; ++i) {
        for (int f = 0; f < freq_bins; ++f) {
            note_energy[static_cast<std::size_t>(i) *
                            static_cast<std::size_t>(freq_bins) +
                        static_cast<std::size_t>(f)] = result.notes(i, f);
        }
    }
    std::vector<pitchnotes::basicpitch::FramedNote> framed;
    framed.reserve(events.size());
    for (const auto &e : events) {
        pitchnotes::basicpitch::FramedNote n;
        n.startFrame = e.start_idx;
        n.endFrame = e.end_idx;
        n.midi = e.pitch;
        n.amplitude = e.amplitude;
        framed.push_back(n);
    }
    const std::vector<pitchnotes::basicpitch::TimedNote> timed =
        pitchnotes::basicpitch::toTimedNotes(framed, note_energy, time_frames,
                                              freq_bins, n_samples);
    std::printf("TIMED_EVENTS\t%zu\n", timed.size());
    {
        std::ofstream f(outdir + "/timed.tsv");
        f << std::setprecision(17);
        if (!f) die("cannot write timed.tsv");
        for (const auto &t : timed) {
            f << t.startSeconds << '\t' << t.endSeconds << '\t' << t.midi << '\t'
              << t.amplitude << '\n';
        }
    }

    std::printf("DONE\n");
    return 0;
}
