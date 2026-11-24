// Basic-pitch note timing + cleanup (P-301, PAUL lane).
//
// This header is the SINGLE SOURCE OF TRUTH for two things that both the app
// bridge and the `basicpitch-spike` runner need, so the spike proves the
// SHIPPED behaviour instead of a parallel implementation:
//
//   1. FRAME -> SECONDS. The vendored `unwrap_output`
//      (vendor/basicpitch/src/ort_inference.cpp) concatenates the model frames
//      CHUNK-MAJOR and truncates the tail. Because each chunk's frames are
//      trimmed by 15 frames at each end but the chunks advance by only
//      `hop` samples, the concatenated frame grid DRIFTS relative to the
//      audio: 188 samples (8.5 ms, one frame is 256 samples) per chunk, i.e.
//      ~5.2 ms per second of audio. On the 8 s poly fixture the naive
//      `frame * 256 / 22050` mapping puts the last chord's onsets 37 ms late;
//      on a 4-minute song it would put the tail ~1.25 s late. The mapping
//      below reconstructs the true chunk each frame came from and is
//      EXACT for the whole song (verified against the synthetic truth: the
//      onset error drops from +37 ms to 0 ms).
//
//   2. THE RELEASE TRIM. Upstream's decoder ends a note with
//      `ENERGY_TOL = 11` frames of tolerance (~128 ms), which is a sane
//      tolerance for "is this note still sounding" but a poor boundary for a
//      note track that is graded against a reference. The trim below cuts the
//      note at the point where the model's own note-frame energy stops
//      clearing the frame threshold (0.3), allowing a couple of jitter frames.
//      It only ever SHORTENS a note; it never extends one.
//
// Both are portable, dependency-free (no ORT, no Eigen, no Foundation) so the
// sibling ports (Android/Linux, AGENTS §0) can reuse them verbatim.
//
// NOTHING HERE INTERPRETS CONFIDENCE: the note amplitude is the engine's
// note strength and `NoteTrackBuilder` (EngineCore) maps it onto C-2.3's
// `confidence` unchanged (clamped, never rescaled).

#ifndef PITCHNOTES_BASIC_PITCH_NOTES_HPP
#define PITCHNOTES_BASIC_PITCH_NOTES_HPP

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace pitchnotes {
namespace basicpitch {

// --- the vendored pipeline's constants (vendor/basicpitch/src/basicpitch.hpp
// --- + ort_inference.cpp, mirrored verbatim) -------------------------------
inline constexpr int kSampleRate = 22050;   // AUDIO_SAMPLE_RATE
inline constexpr int kFrameHop = 256;       // FFT_HOP
inline constexpr int kChunkSamples = 43844; // AUDIO_N_SAMPLES (22050*2 - 256)
inline constexpr int kOverlapFrames = 30;   // n_overlapping_frames
inline constexpr int kOverlapSamples = kOverlapFrames * kFrameHop; // 7680
inline constexpr int kChunkHop = kChunkSamples - kOverlapSamples;   // 36164
inline constexpr int kModelFramesPerChunk = 172; // the model's output frames
inline constexpr int kTrimmedFramesPerChunk =
    kModelFramesPerChunk - kOverlapFrames;      // 142 (15 dropped at each end)
inline constexpr int kPadSamples = kOverlapSamples / 2; // 3840 zeros at the head
inline constexpr float kFrameThreshold = 0.3f;  // FRAME_THRESHOLD
inline constexpr float kOnsetThreshold = 0.5f;   // ONSET_THRESHOLD

/// The number of chunks the vendored chunker produces for `audioLength`
/// samples (padded head + ceil division by the hop).
inline int chunkCount(int audioLength) {
    const long long padded =
        static_cast<long long>(audioLength) + kPadSamples;
    return static_cast<int>((padded + kChunkHop - 1) / kChunkHop);
}

/// The frame count the vendor keeps: `floor(len * (ANNOTATIONS_FPS / 22050))`
/// with the vendor's INTEGER ANNOTATIONS_FPS (22050 / 256 == 86), capped by
/// the number of frames the chunks actually produced.
inline int unwrappedFrameCount(int audioLength) {
    const long long produced =
        static_cast<long long>(chunkCount(audioLength)) * kTrimmedFramesPerChunk;
    const long long byLength = static_cast<long long>(
        std::floor(static_cast<float>(audioLength) *
                   (86.0f / static_cast<float>(kSampleRate))));
    return static_cast<int>(std::min(byLength, produced));
}

/// A note event with the frame-domain fields the vendor emits plus the
/// timing the bridge derives. `startFrame`/`endFrame` are the vendor's
/// frame indices (half-open: the note covers frames [startFrame, endFrame)).
struct FramedNote {
    int startFrame = 0;
    int endFrame = 0;
    int midi = 0;
    float amplitude = 0.0f;
};

/// A note event in the TIME domain — what the app's NoteTrack consumes.
struct TimedNote {
    double startSeconds = 0.0;
    double endSeconds = 0.0;
    int midi = 0;
    float amplitude = 0.0f;
};

/// FRAME -> SECONDS, corrected for the chunk-concatenation drift.
///
/// A frame index `frame` belongs to chunk `frame / 142`; within that chunk it
/// is `frame % 142`, and the chunk's first kept frame sits at
/// `chunk * kChunkHop` samples of the ORIGINAL audio. The frame therefore
/// starts at sample `chunk * kChunkHop + within * kFrameHop`.
inline double frameToSeconds(long long frame) {
    const long long perChunk = kTrimmedFramesPerChunk;
    const long long chunk = frame / perChunk;
    const long long within = frame % perChunk;
    const long long sample = chunk * kChunkHop + within * kFrameHop;
    return static_cast<double>(sample) / static_cast<double>(kSampleRate);
}

/// The energy of one pitch at one frame, from the model's note tensor.
/// `noteEnergy` is row-major [time][freq] (freq = midi - 21).
inline float noteEnergyAt(const std::vector<float> &noteEnergy,
                           int timeFrames, int freqBins, int time, int freq) {
    if (time < 0 || time >= timeFrames || freq < 0 || freq >= freqBins) {
        return 0.0f;
    }
    return noteEnergy[static_cast<std::size_t>(time) *
                          static_cast<std::size_t>(freqBins) +
                      static_cast<std::size_t>(freq)];
}

/// The release trim (see the file header).
///
/// Scans BACKWARDS from the note's end frame and finds the last sustained
/// stretch of frames below `threshold`; the note is cut at the START of that
/// stretch. A dip of at most `jitterFrames` frames is tolerated (a brief
/// wobble must not truncate a note), and a note whose energy never falls
/// below the threshold keeps its original end. The trim only shortens.
inline int trimmedEndFrame(const std::vector<float> &noteEnergy,
                           int timeFrames, int freqBins, int startFrame,
                           int endFrame, int pitchBin,
                           float threshold = kFrameThreshold,
                           int jitterFrames = 2) {
    if (endFrame <= startFrame || endFrame > timeFrames) {
        return endFrame;
    }
    int below = 0;
    int cut = endFrame;
    for (int t = endFrame - 1; t >= startFrame; --t) {
        const float e = noteEnergyAt(noteEnergy, timeFrames, freqBins, t, pitchBin);
        if (e < threshold) {
            ++below;
            if (below > jitterFrames) {
                cut = t + 1; // the frame where the sustained dip began
                break;
            }
        } else {
            below = 0;
        }
    }
    return cut;
}

/// Turn the vendor's frame-domain notes into the time-domain notes the app
/// consumes: the corrected frame -> seconds mapping plus the release trim.
///
/// `noteEnergy` is the model's note tensor as row-major [time][freq].
inline std::vector<TimedNote> toTimedNotes(const std::vector<FramedNote> &notes,
                                           const std::vector<float> &noteEnergy,
                                           int timeFrames, int freqBins,
                                           int audioLength,
                                           float releaseThreshold = kFrameThreshold,
                                           int jitterFrames = 2) {
    (void)audioLength; // the mapping is length-independent by construction
    std::vector<TimedNote> out;
    out.reserve(notes.size());
    for (const FramedNote &n : notes) {
        const int pitchBin = n.midi - 21;
        const int endFrame = trimmedEndFrame(noteEnergy, timeFrames, freqBins,
                                             n.startFrame, n.endFrame,
                                             pitchBin, releaseThreshold,
                                             jitterFrames);
        TimedNote t;
        t.startSeconds = frameToSeconds(n.startFrame);
        t.endSeconds = frameToSeconds(endFrame);
        t.midi = n.midi;
        t.amplitude = n.amplitude;
        if (t.endSeconds > t.startSeconds) {
            out.push_back(t);
        }
    }
    return out;
}

} // namespace basicpitch
} // namespace pitchnotes

#endif // PITCHNOTES_BASIC_PITCH_NOTES_HPP
