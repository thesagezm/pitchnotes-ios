// Unit checks for the release-trim + frame-mapping rules in
// Engine/Transcription/BasicPitchNotes.hpp (P-301, PAUL lane).
//
// This is a STANDALONE C++ test (no ORT, no Eigen, no vendor code): the
// header under test is dependency-free by design, so the rule can be pinned
// down on any machine that has a C++20 compiler — including the Linux box
// and the macOS CI runner.
//
// WHY THE RULES NEED UNIT CHECKS (not just the end-to-end truth check):
//   * The OLD rule ("scan backward, cut at t+1 of the FIRST sustained dip")
//     latched onto the ATTACK ramp. The end-to-end fixture catches that only
//     indirectly; the unit check names it.
//   * The trim must never EXTEND a note and never cut it to zero length.
//   * The corrected frame -> seconds mapping must keep the chunk-aware
//     behaviour (the naive mapping drifts ~5.2 ms per second of audio).
//
// The spike compiles and runs this next to the real-model run; a failure
// here is a hard failure of the basicpitch spike.

#include "BasicPitchNotes.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool condition, const std::string &what) {
    ++g_checks;
    if (condition) {
        std::printf("ok   %s\n", what.c_str());
    } else {
        ++g_failures;
        std::printf("FAIL %s\n", what.c_str());
    }
}

void checkEq(int got, int want, const std::string &what) {
    check(got == want, what + " (got " + std::to_string(got) + ", want " +
                             std::to_string(want) + ")");
}

/// A note-energy tensor with ONE pitch column (pitchBin 0 = midi 21).
std::vector<float> curve(const std::vector<float> &values) {
    return values; // one column -> row-major [time][1] is just `values`
}

} // namespace

int main() {
    using pitchnotes::basicpitch::frameToSeconds;
    using pitchnotes::basicpitch::medianEnergy;
    using pitchnotes::basicpitch::trimmedEndFrame;

    const int kFreqBins = 1;
    const int kPitchBin = 0;

    // --- 1. the median is the sustain level (odd + even counts) -----------
    check(std::fabs(medianEnergy({1.0f, 2.0f, 3.0f}) - 2.0f) < 1e-6,
          "medianEnergy: odd count -> the middle value");
    check(std::fabs(medianEnergy({1.0f, 2.0f, 3.0f, 4.0f}) - 2.5f) < 1e-6,
          "medianEnergy: even count -> the average of the two middle values");
    check(std::fabs(medianEnergy({}) - 0.0f) < 1e-6,
          "medianEnergy: empty -> 0");

    // --- 2. a clean note: the ATTACK ramp is never the release ------------
    // 3 low attack frames, 14 sustain frames, 3 low release frames.
    {
        std::vector<float> e = curve({0.1f, 0.1f, 0.1f, 1.0f, 1.0f, 1.0f, 1.0f,
                                      1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f,
                                      1.0f, 1.0f, 1.0f, 0.1f, 0.1f, 0.1f});
        const int cut = trimmedEndFrame(e, 20, kFreqBins, 0, 20, kPitchBin);
        checkEq(cut, 17, "clean note: the cut is the RELEASE dip's start (17), "
                         "not the attack dip's start (0)");
    }

    // --- 3. a mid-note wobble is not the release either --------------------
    {
        std::vector<float> e = curve({0.1f, 0.1f, 0.1f, 1.0f, 1.0f, 1.0f, 1.0f,
                                      1.0f, 1.0f, 1.0f, 0.1f, 1.0f, 1.0f, 1.0f,
                                      1.0f, 0.1f, 0.1f, 0.1f});
        const int cut = trimmedEndFrame(e, 18, kFreqBins, 0, 18, kPitchBin);
        checkEq(cut, 15, "wobble: the cut is the LAST dip (15), not the wobble at 10");
    }

    // --- 4. a note whose energy never dips keeps its end ------------------
    {
        std::vector<float> e = curve({1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f});
        const int cut = trimmedEndFrame(e, 8, kFreqBins, 0, 8, kPitchBin);
        checkEq(cut, 8, "no dip: the note keeps its original end");
    }

    // --- 5. the trim NEVER extends a note ---------------------------------
    {
        // The energy only drops on the note's LAST frame.
        std::vector<float> e = curve({1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 0.1f});
        const int cut = trimmedEndFrame(e, 8, kFreqBins, 0, 8, kPitchBin);
        check(cut <= 8, "never extends: the cut is not past the note's end");
        checkEq(cut, 7, "never extends: the cut is the last low frame (7)");
    }

    // --- 6. the trim never cuts a note to zero length ---------------------
    {
        // The dip starts ON the note's first frame.
        std::vector<float> e = curve({0.1f, 1.0f, 1.0f, 1.0f});
        const int cut = trimmedEndFrame(e, 4, kFreqBins, 0, 4, kPitchBin);
        check(cut >= 1, "never empty: the note keeps at least one frame");
        checkEq(cut, 1, "never empty: the cut is clamped to startFrame + 1");
    }

    // --- 7. a note with no usable level is left alone ---------------------
    {
        std::vector<float> e = curve({0.0f, 0.0f, 0.0f, 0.0f});
        const int cut = trimmedEndFrame(e, 4, kFreqBins, 0, 4, kPitchBin);
        checkEq(cut, 4, "silent note: no usable level -> the note is untouched");
    }

    // --- 8. a degenerate range is left alone ------------------------------
    {
        std::vector<float> e = curve({1.0f, 1.0f, 1.0f, 1.0f});
        checkEq(trimmedEndFrame(e, 4, kFreqBins, 3, 3, kPitchBin), 3,
                "empty range: an empty note is untouched");
        // An end past the tensor is INVALID input: the note is left exactly as
        // it was (the trim never invents a boundary).
        checkEq(trimmedEndFrame(e, 4, kFreqBins, 0, 99, kPitchBin), 99,
                "out-of-range end: the note is untouched");
    }

    // --- 9. the frame -> seconds mapping is the CHUNK-AWARE one ------------
    {
        const double sr = 22050.0;
        const double naive0 = 0.0;
        const double naive142 = 142.0 * 256.0 / sr;
        const double mapped142 = frameToSeconds(142);
        check(std::fabs(mapped142 - 36164.0 / sr) < 1e-9,
              "mapping: frame 142 is the first frame of chunk 1 (36164 samples)");
        check(std::fabs(mapped142 - naive142) > 0.005,
              "mapping: the chunk-aware value DIFFERS from the naive "
              "frame*256/22050 (the drift the naive mapping causes)");
        check(std::fabs(frameToSeconds(0) - naive0) < 1e-12,
              "mapping: frame 0 is t=0");
        // The drift per chunk is 188 samples = 8.5 ms. The chunk grid is
        // 188 samples SHORTER than 142 frames x 256 samples, so the chunk-aware
        // mapping is EARLIER than the naive one — the naive mapping runs LATE
        // by ~5.2 ms per second of audio.
        check(std::fabs((frameToSeconds(142) - 142.0 * 256.0 / sr) +
                        188.0 / sr) < 1e-9,
              "mapping: the per-chunk drift is exactly -188 samples (-8.5 ms) "
              "vs the naive mapping");
    }

    std::printf("%s: %d checks, %d failures\n",
                g_failures == 0 ? "TRIM UNIT TESTS PASSED" : "TRIM UNIT TESTS FAILED",
                g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
