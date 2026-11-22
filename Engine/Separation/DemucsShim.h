// DemucsShim.h — C-ABI seam over the vendored sevagh/demucs.cpp library
// (vendor/demucs.cpp, MIT — D-30 Tier A for code) for the Swift bridge
// (DemucsEngine.swift). P-201 (M2), PAUL lane.
//
// Design rules:
//  - Plain C ABI only (no C++ types, no Eigen, no exceptions across the
//    boundary — all C++ internals are caught inside the implementation and
//    reported as error codes).
//  - Buffers are interleaved float32 stereo (L,R per sample), 44.1 kHz in/out
//    (SUPPORTED_SAMPLE_RATE, D-8 SR policy). The vendored inference takes an
//    Eigen 2 x N matrix; conversion happens inside the shim.
//  - Memory: the caller owns the input buffer; the shim allocates the output
//    stem buffer (freed via demucs_shim_free_buffer).
//  - Threading (D-32.4): the vendored src has ZERO OpenMP pragmas — the
//    std::thread parallelism arrives as a Leto-applied vendor patch (patches.log)
//    which reads DEMUCSCPP_NUM_THREADS. The shim exposes demucs_shim_set_threads
//    which sets that env BEFORE the first inference call (env read per call).
//
// Compiled into the app target via project.yml (Leto X-task, intake README
// "Build notes for P-201"): sources Engine/Separation/DemucsShim.cpp +
// vendor/demucs.cpp/src/*.cpp; header search paths Engine/Separation,
// vendor/demucs.cpp/src, vendor/demucs.cpp/third_party/eigen.
#ifndef DEMUCS_SHIM_H
#define DEMUCS_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque loaded-model handle (fp16 ggml dequantized to fp32 Eigen tensors).
typedef struct demucs_shim_model demucs_shim_model;

/// Progress callback (C-8 seam): overall fraction [0, 1] + stage detail.
/// Called on the inference thread — the Swift side must not block it.
typedef void (*demucs_shim_progress_cb)(float fraction, const char* detail,
                                        void* context);

/// Result codes (stable ABI; Swift maps to EngineError).
enum demucs_shim_status {
    DEMUCS_SHIM_OK = 0,
    DEMUCS_SHIM_ERR_LOAD = 1,        // model file missing/corrupt/magic mismatch
    DEMUCS_SHIM_ERR_AUDIO = 2,       // null/empty/degenerate input
    DEMUCS_SHIM_ERR_INFERENCE = 3,   // inference threw / produced non-finite
    DEMUCS_SHIM_ERR_ALLOC = 4,       // output allocation failed
    DEMUCS_SHIM_ERR_ABORTED = 5      // abort requested via demucs_shim_request_abort
};

/// Load the ggml fp16 model. Returns NULL on failure (status set if non-NULL).
demucs_shim_model* demucs_shim_load(const char* model_path, int32_t* status);

/// Free a loaded model. NULL-safe.
void demucs_shim_free(demucs_shim_model* model);

/// 4 for the htdemucs 4-source model (drums, bass, other, vocals).
int32_t demucs_shim_num_sources(const demucs_shim_model* model);

/// Threading seam (D-32.4): sets DEMUCSCPP_NUM_THREADS for the patched vendor
/// build; ignored (single-threaded) by the unpatched build.
void demucs_shim_set_threads(int32_t n);

/// Run full-song inference (normalize → shift → 7.8 s segments, 0.25 overlap
/// weighted → denormalize; the vendor owns chunking).
///   interleaved: 2*N floats (L,R), 44.1 kHz, finite, non-empty
///   n_samples:   per-channel frame count N
///   out_stems:   on success receives n_sources*2*N interleaved float32
///                (source-major: src0 L,R L,R … src1 L,R …); free via
///                demucs_shim_free_buffer.
///
/// ABORT (P-202 L2): the vendored inference is a blocking C++ call, so a
/// cancelled Swift Task cannot unwind it from the outside. The shim therefore
/// checks an abort flag INSIDE the vendor's progress callback (the vendor
/// calls it ~26 times per 7.8 s segment, at every encoder stage) and throws
/// to unwind the vendor frames; the shim catches it and returns
/// DEMUCS_SHIM_ERR_ABORTED. Abort latency = one encoder stage (a few seconds
/// on a laptop; measured on device at P-603). No vendor patch needed.
int32_t demucs_shim_infer(demucs_shim_model* model,
                          const float* interleaved, int32_t n_samples,
                          demucs_shim_progress_cb cb, void* context,
                          float** out_stems, int32_t* out_n_samples);

/// Request abort of the NEXT (or in-flight) demucs_shim_infer call on this
/// model. Thread-safe; safe to call from another thread while an inference is
/// running (the Swift cancellation handler does exactly that). The caller
/// clears the flag with demucs_shim_clear_abort before each fresh call.
void demucs_shim_request_abort(demucs_shim_model* model);

/// Clear a pending abort request (call before a fresh inference).
void demucs_shim_clear_abort(demucs_shim_model* model);

/// Free a stem buffer returned by demucs_shim_infer. NULL-safe.
void demucs_shim_free_buffer(float* buf);

#ifdef __cplusplus
}
#endif

#endif /* DEMUCS_SHIM_H */
