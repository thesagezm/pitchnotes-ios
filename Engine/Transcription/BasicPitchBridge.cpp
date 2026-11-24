// Basic-pitch transcription bridge — the C ABI implementation
// (P-301, PAUL lane). See BasicPitchBridge.h for the contract.
//
// COMPILED BY: the APP TARGET (Apple-only — it needs the SPM ORT pod's C++
// headers and the vendored basicpitch.cpp + Eigen). It is deliberately NOT
// part of Engine/Package.swift: the EngineCore package stays dependency-free
// so the Linux `swift test` loop remains portable (AGENTS §0).
//
// THE RULES LIVE IN ONE PLACE: the frame -> seconds mapping and the release
// trim come from Engine/Transcription/BasicPitchNotes.hpp — the SAME header
// the basicpitch-spike measures, so the spike's 50 ms truth result is a
// statement about the SHIPPED behaviour, not about a parallel implementation.

#include "BasicPitchBridge.h"

#include "BasicPitchNotes.hpp"
#include "basicpitch.hpp"

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <vector>

namespace {

thread_local std::string g_last_error;

int32_t fail(int32_t code, const std::string &message) {
    g_last_error = message;
    return code;
}

} // namespace

extern "C" {

const char *pitchnotes_basicpitch_last_error(void) { return g_last_error.c_str(); }

const char *pitchnotes_basicpitch_version(void) { return "basicpitch-vendored-1"; }

void pitchnotes_basicpitch_result_free(PitchnotesBasicPitchResult *result) {
    if (result == nullptr) {
        return;
    }
    std::free(result->notes);
    result->notes = nullptr;
    result->count = 0;
    result->inference_seconds = 0.0;
    result->rtf = 0.0;
}

int32_t pitchnotes_basicpitch_transcribe(const float *mono_audio,
                                          int32_t sample_count,
                                          const char *model_path,
                                          PitchnotesBasicPitchResult *out) {
    if (out == nullptr) {
        return fail(PITCHNOTES_BASIC_PITCH_ERR_INVALID_ARGUMENT,
                    "the result pointer is null");
    }
    std::memset(out, 0, sizeof(*out));
    if (mono_audio == nullptr || sample_count <= 0 || model_path == nullptr ||
        model_path[0] == '\0') {
        return fail(PITCHNOTES_BASIC_PITCH_ERR_INVALID_ARGUMENT,
                    "mono_audio, sample_count and model_path are required");
    }

    g_last_error.clear();

    const std::vector<float> audio(mono_audio,
                                   mono_audio + static_cast<std::size_t>(sample_count));

    basic_pitch::InferenceResult result;
    try {
        const auto t0 = std::chrono::steady_clock::now();
        result = basic_pitch::ort_inference(audio, std::string(model_path));
        const auto t1 = std::chrono::steady_clock::now();
        out->inference_seconds = std::chrono::duration<double>(t1 - t0).count();
    } catch (const std::exception &e) {
        return fail(PITCHNOTES_BASIC_PITCH_ERR_MODEL,
                    std::string("the basic-pitch inference failed: ") + e.what());
    } catch (...) {
        return fail(PITCHNOTES_BASIC_PITCH_ERR_MODEL,
                    "the basic-pitch inference failed (unknown exception)");
    }

    const int time_frames = static_cast<int>(result.notes.dimension(0));
    const int freq_bins = static_cast<int>(result.notes.dimension(1));
    if (time_frames <= 0 || freq_bins <= 0) {
        return fail(PITCHNOTES_BASIC_PITCH_ERR_MODEL,
                    "the model returned an empty tensor");
    }

    // The frame -> seconds mapping assumes the model's per-chunk frame count
    // (172) and the vendor's trim (30 frames). If either changed, the mapping
    // would drift SILENTLY (8.5 ms per chunk, ~5.2 ms per second of audio) —
    // so fail loudly instead.
    const int expected_frames =
        pitchnotes::basicpitch::unwrappedFrameCount(sample_count);
    if (time_frames != expected_frames) {
        return fail(PITCHNOTES_BASIC_PITCH_ERR_FRAME_MISMATCH,
                    "the model returned " + std::to_string(time_frames) +
                        " frames, expected " + std::to_string(expected_frames) +
                        " (the model's per-chunk frame count or the vendor's trim "
                        "changed — re-derive the frame -> seconds mapping)");
    }

    // The vendor's raw note events (frame domain).
    const std::vector<basic_pitch::NoteEvent> events =
        basic_pitch::output_to_notes_polyphonic(result, /*melodia*/true,
                                                 /*bends*/false);

    // The model's note tensor as row-major [time][freq] — the trim reads the
    // note's OWN energy out of it.
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
                                              freq_bins, sample_count);

    if (!timed.empty()) {
        out->notes = static_cast<PitchnotesBasicPitchNote *>(
            std::malloc(timed.size() * sizeof(PitchnotesBasicPitchNote)));
        if (out->notes == nullptr) {
            return fail(PITCHNOTES_BASIC_PITCH_ERR_OUT_OF_MEMORY,
                        "cannot allocate the note array");
        }
        for (std::size_t i = 0; i < timed.size(); ++i) {
            out->notes[i].start_s = timed[i].startSeconds;
            out->notes[i].end_s = timed[i].endSeconds;
            out->notes[i].midi = static_cast<int32_t>(timed[i].midi);
            out->notes[i].amplitude = timed[i].amplitude;
        }
        out->count = timed.size();
    }

    const double audio_seconds =
        static_cast<double>(sample_count) /
        static_cast<double>(pitchnotes::basicpitch::kSampleRate);
    out->rtf = audio_seconds > 0.0 ? out->inference_seconds / audio_seconds : 0.0;
    return PITCHNOTES_BASIC_PITCH_OK;
}

} // extern "C"
