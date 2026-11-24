// Basic-pitch transcription bridge — the C ABI between Swift and the
// vendored basicpitch.cpp pipeline (P-301, PAUL lane).
//
// WHY A C ABI (and not a C++/Swift interop layer): the app target compiles
// the vendored C++ (vendor/basicpitch, MIT) under the ONE ONNX Runtime
// (D-39 — the SPM ORT 1.24.2 pod; never a second runtime, never the trimmed
// ort-builder). A C ABI keeps the Swift side free of C++ interop, of Eigen
// and of ORT types: Swift sees plain structs and one function.
//
// WHY THIS IS NOT IN Engine/Package.swift: the SPM ORT pod is APPLE-ONLY,
// and Engine/ (the EngineCore package) deliberately has NO external
// dependencies so the Linux `swift test` loop stays dependency-free and
// portable (AGENTS §0 — the Android/Linux sibling ports reuse the core).
// The bridge is therefore a PLAIN SOURCE SET that the APP TARGET compiles;
// the project.yml wiring (module map / bridging header / header search paths
// / link flags) is LETO's lane — see the X-### request in QUEUE.md.
//
// WHAT THE BRIDGE DOES (and what it deliberately does NOT do):
//   * Runs the vendored inference (ort_inference) + the vendored note decode
//     (output_to_notes_polyphonic) on 22.05 kHz mono audio.
//   * Converts the frame-domain events to TIME with the CORRECTED,
//     chunk-aware frame -> seconds mapping and the RELEASE TRIM — both in
//     Engine/Transcription/BasicPitchNotes.hpp, the SAME header the
//     basicpitch-spike measures, so the spike proves the shipped behaviour.
//   * It does NOT compute a confidence. The engine's `amplitude` IS the note
//     strength and it crosses into the contract UNCHANGED (clamped, never
//     rescaled) by NoteTrackBuilder (EngineCore) — the bridge must not
//     reinterpret it (D-41's confidence bands belong to the assignment
//     posterior, P-303).
//
// THREADING: the function is re-entrant (no shared mutable state except the
// last-error string, which is thread-local). The caller owns the ONNX
// session's lifetime indirectly: the vendor creates a session per call, so
// the app should call this ONCE per stem.

#ifndef PITCHNOTES_BASIC_PITCH_BRIDGE_H
#define PITCHNOTES_BASIC_PITCH_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One transcribed note, in the contract's TIME domain.
///
/// `amplitude` is the engine's note strength in [0, 1] — it is NOT a
/// calibrated probability and it is NOT the contract's `confidence`; Swift
/// maps it through NoteTrackBuilder (clamped, never rescaled).
typedef struct {
    double start_s;
    double end_s;
    int32_t midi;
    float amplitude;
} PitchnotesBasicPitchNote;

/// The result of one transcription. `notes` is heap-allocated and owned by the
/// caller — release it with `pitchnotes_basicpitch_result_free`.
typedef struct {
    PitchnotesBasicPitchNote *notes;
    size_t count;
    /// Wall time of the inference (model load included — the vendor creates
    /// the session inside the call).
    double inference_seconds;
    /// inference_seconds / audio_duration.
    double rtf;
} PitchnotesBasicPitchResult;

/// Return codes.
#define PITCHNOTES_BASIC_PITCH_OK 0
#define PITCHNOTES_BASIC_PITCH_ERR_INVALID_ARGUMENT (-1)
#define PITCHNOTES_BASIC_PITCH_ERR_WRONG_SAMPLE_RATE (-2)
#define PITCHNOTES_BASIC_PITCH_ERR_MODEL (-3)
#define PITCHNOTES_BASIC_PITCH_ERR_FRAME_MISMATCH (-4)
#define PITCHNOTES_BASIC_PITCH_ERR_OUT_OF_MEMORY (-5)

/// Transcribe 22.05 kHz mono audio into note events.
///
/// - Parameters:
///   - mono_audio: interleaved-free mono samples in [-1, 1]. The model's
///     NATIVE rate is 22050 Hz; the caller resamples.
///   - sample_count: the number of samples (must be > 0).
///   - model_path: the path to the ONNX weights at runtime (the weights are
///     NEVER in git — they are downloaded once and sha-verified).
///   - out: the result. Zero-initialised by the caller; on success `notes`
///     and `count` are set and must be freed with
///     `pitchnotes_basicpitch_result_free`.
/// - Returns: PITCHNOTES_BASIC_PITCH_OK, or a negative error code (the
///   message is available from `pitchnotes_basicpitch_last_error`).
int32_t pitchnotes_basicpitch_transcribe(const float *mono_audio,
                                          int32_t sample_count,
                                          const char *model_path,
                                          PitchnotesBasicPitchResult *out);

/// Release a result's note array and zero the struct. Safe on a zeroed or
/// already-freed struct.
void pitchnotes_basicpitch_result_free(PitchnotesBasicPitchResult *result);

/// The last error message on this thread ("" when there is none). The
/// pointer stays valid until the next bridge call on the same thread.
const char *pitchnotes_basicpitch_last_error(void);

/// The engine version string (the bundle manifest's `engineVersion` source).
const char *pitchnotes_basicpitch_version(void);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // PITCHNOTES_BASIC_PITCH_BRIDGE_H
