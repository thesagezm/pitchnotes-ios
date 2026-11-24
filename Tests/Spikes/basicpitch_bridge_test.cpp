// The C ABI bridge proof (P-301, PAUL lane).
//
// The APP's Swift side calls the bridge (`pitchnotes_basicpitch_transcribe`),
// not the spike's runner. If the bridge and the runner ever disagreed, the
// spike would be measuring something the app does NOT ship — so this test
// drives the BRIDGE on the same fixture and prints its notes in the same
// format as the runner's timed.tsv, and the Python driver compares the two.
//
// Usage:
//   basicpitch_bridge_test <model-onnx> <input-wav-22050-mono>
// stdout (one note per line):
//   NOTE\t<start_s>\t<end_s>\t<midi>\t<amplitude>

#include "BasicPitchBridge.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

namespace {

[[noreturn]] void die(const char *msg) {
    std::fprintf(stderr, "basicpitch_bridge_test: %s\n", msg);
    std::exit(2);
}

std::vector<float> read_wav_mono_22050(const char *path) {
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
    bool have_fmt = false;
    bool have_data = false;
    std::uint16_t bits = 0;
    std::uint16_t fmt = 0;
    std::vector<float> samples;
    while (f) {
        f.read(tag, 4);
        if (!f) break;
        std::uint32_t sz = read_u32();
        if (std::string(tag) == "fmt ") {
            fmt = read_u16();
            read_u16(); // channels
            const std::uint32_t sample_rate = read_u32();
            read_u32();
            read_u16();
            bits = read_u16();
            if (sz > 16) f.ignore(sz - 16);
            if (sample_rate != 22050) die("the fixture must be 22050 Hz");
            have_fmt = true;
        } else if (std::string(tag) == "data") {
            const std::size_t n = sz / (bits / 8);
            samples.resize(n);
            if (bits == 16 && fmt == 1) {
                for (std::size_t i = 0; i < n; ++i) {
                    samples[i] = read_i16() / 32768.0f;
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
    return samples;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: basicpitch_bridge_test <model-onnx> "
                             "<input-wav-22050-mono>\n");
        return 2;
    }
    const std::vector<float> samples = read_wav_mono_22050(argv[2]);

    PitchnotesBasicPitchResult result;
    const int32_t rc = pitchnotes_basicpitch_transcribe(
        samples.data(), static_cast<std::int32_t>(samples.size()), argv[1], &result);
    if (rc != PITCHNOTES_BASIC_PITCH_OK) {
        std::fprintf(stderr, "basicpitch_bridge_test: transcribe failed (%d): %s\n",
                     rc, pitchnotes_basicpitch_last_error());
        return 3;
    }
    for (size_t i = 0; i < result.count; ++i) {
        std::printf("NOTE\t%.9f\t%.9f\t%d\t%.9f\n", result.notes[i].start_s,
                    result.notes[i].end_s,
                    static_cast<int>(result.notes[i].midi),
                    static_cast<double>(result.notes[i].amplitude));
    }
    std::printf("BRIDGE_NOTES\t%zu\n", result.count);
    std::printf("BRIDGE_RTF\t%.4f\n", result.rtf);
    pitchnotes_basicpitch_result_free(&result);
    return 0;
}
