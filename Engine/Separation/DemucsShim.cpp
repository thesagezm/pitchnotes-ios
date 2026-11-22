// DemucsShim.cpp — C-ABI seam implementation over the vendored demucs.cpp
// library (see DemucsShim.h for the design contract). P-201 (M2), PAUL lane.
//
// The vendored library is header `model.hpp` + the 8 src/*.cpp translation
// units (compiled into the same target by project.yml — intake README build
// notes). This file only converts buffers and translates exceptions into
// status codes; ALL model math stays in the vendored code (D-30 Tier A).

#include "DemucsShim.h"

#include "model.hpp"

#include <Eigen/Dense>
#include <cstdio>
#include <cstring>
#include <exception>
#include <new>
#include <string>
#include <vector>

struct demucs_shim_model {
    struct demucscpp::demucs_model model;
};

extern "C" {

void demucs_shim_set_threads(int32_t n) {
    // D-32.4 threading seam: the Leto-applied vendor patch reads this env per
    // call; the unpatched vendor ignores it (single-threaded Eigen).
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%d", n > 0 ? n : 1);
    setenv("DEMUCSCPP_NUM_THREADS", buf, 1);
}

demucs_shim_model* demucs_shim_load(const char* model_path, int32_t* status) {
    if (status) *status = DEMUCS_SHIM_ERR_LOAD;
    if (!model_path || !*model_path) return nullptr;
    demucs_shim_model* handle = nullptr;
    try {
        handle = new demucs_shim_model();
        if (!demucscpp::load_demucs_model(std::string(model_path), &handle->model)) {
            delete handle;
            return nullptr;
        }
    } catch (const std::bad_alloc&) {
        delete handle;
        return nullptr;
    } catch (...) {
        delete handle;
        return nullptr;
    }
    if (status) *status = DEMUCS_SHIM_OK;
    return handle;
}

void demucs_shim_free(demucs_shim_model* model) { delete model; }

int32_t demucs_shim_num_sources(const demucs_shim_model* model) {
    if (!model) return 0;
    return model->model.is_4sources ? 4 : 6;
}

int32_t demucs_shim_infer(demucs_shim_model* model,
                          const float* interleaved, int32_t n_samples,
                          demucs_shim_progress_cb cb, void* context,
                          float** out_stems, int32_t* out_n_samples) {
    if (out_stems) *out_stems = nullptr;
    if (out_n_samples) *out_n_samples = 0;
    if (!model || !interleaved || n_samples <= 0 || !out_stems || !out_n_samples)
        return DEMUCS_SHIM_ERR_AUDIO;

    // Build the vendor's 2 x N matrix from interleaved stereo.
    Eigen::MatrixXf full_audio(2, n_samples);
    for (int32_t i = 0; i < n_samples; ++i) {
        const float l = interleaved[2 * i];
        const float r = interleaved[2 * i + 1];
        if (!std::isfinite(l) || !std::isfinite(r)) return DEMUCS_SHIM_ERR_AUDIO;
        full_audio(0, i) = l;
        full_audio(1, i) = r;
    }

    // Bridge the C progress callback into the vendor's std::function.
    demucscpp::ProgressCallback vendor_cb;
    if (cb) {
        vendor_cb = [cb, context](float progress, const std::string& msg) {
            cb(progress, msg.c_str(), context);
        };
    }

    Eigen::Tensor3dXf out;
    try {
        out = demucscpp::demucs_inference(model->model, full_audio, vendor_cb);
    } catch (...) {
        return DEMUCS_SHIM_ERR_INFERENCE;
    }

    const int n_src = model->model.is_4sources ? 4 : 6;
    const std::size_t total = std::size_t(n_src) * 2 * std::size_t(n_samples);
    float* stems = static_cast<float*>(std::malloc(total * sizeof(float)));
    if (!stems) return DEMUCS_SHIM_ERR_ALLOC;

    // Tensor (source, channel, sample) → source-major INTERLEAVED stereo
    // [L0, R0, L1, R1, …] per source block (matches DemucsShim.h docs, the
    // spike runner's .f32 dumps, and DemucsOutputMapper).
    // Finiteness is checked here so a NaN in the model output fails loudly
    // (S3 in the spike; the app never writes a corrupt stem to disk).
    for (int s = 0; s < n_src; ++s) {
        for (int32_t i = 0; i < n_samples; ++i) {
            const float l = out(s, 0, i);
            const float r = out(s, 1, i);
            if (!std::isfinite(l) || !std::isfinite(r)) {
                std::free(stems);
                return DEMUCS_SHIM_ERR_INFERENCE;
            }
            stems[std::size_t(s) * 2 * std::size_t(n_samples) + 2 * i] = l;
            stems[std::size_t(s) * 2 * std::size_t(n_samples) + 2 * i + 1] = r;
        }
    }
    *out_stems = stems;
    *out_n_samples = n_samples;
    return DEMUCS_SHIM_OK;
}

void demucs_shim_free_buffer(float* buf) { std::free(buf); }

} // extern "C"
