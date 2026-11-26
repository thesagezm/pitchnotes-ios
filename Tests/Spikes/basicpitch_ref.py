#!/usr/bin/env python3
"""Python reference for the vendored basicpitch.cpp pipeline (P-301, PAUL lane).

This is the INDEPENDENT reimplementation of the upstream pipeline that the
`basicpitch-spike` compares the C++ port against:

  1. CHUNKING (vendor/basicpitch/src/ort_inference.cpp):
       padded = 3840 zeros + audio          (overlap_len / 2, overlap_len = 30*256)
       hop    = 43844 - 7680 = 36164         (AUDIO_N_SAMPLES - overlap_len)
       chunks = ceil(len(padded) / hop), each chunk zero-padded to 43844
       ONE ORT run with the whole batch: input [chunks, 43844, 1] float32
       input name  "serving_default_input_2:0"
       output names "StatefulPartitionedCall:1" (notes), ":2" (onsets),
                    ":0" (contours)
  2. UNWRAP (upstream `unwrap_output`, semantics PINNED by an Eigen probe —
     see Tests/Spikes/README.md): drop 15 time frames at each end of every
     chunk, concatenate chunk-major, truncate to the frame count the VENDOR
     computes, and the result is indexed [time, freq] (88 freq bins; the
     vendor tensor's memory is column-major over [time, freq], so the
     row-major [time, freq] dump is what the spike compares).

     **THE FRAME-COUNT TRUNCATION IS AN INT-86 TRUNCATION (upstream quirk,
     reproduced faithfully here):** `basicpitch.hpp` declares
     `constexpr int ANNOTATIONS_FPS = SAMPLE_RATE / FFT_HOP;` — INTEGER
     division, so ANNOTATIONS_FPS is **86**, NOT 22050/256 = 86.1328. The
     vendor's `unwrap_output` therefore computes
     `floor(audio_len * (86f / 22050f))`, which is 1-4 frames SHORTER than
     the exact `floor(audio_len / 256)` for longer inputs (8 s = 176400
     samples => 688 frames, not 689). `n_output_frames()` below mirrors the
     vendor expression EXACTLY, including its float32 arithmetic — a
     reference that used the "mathematically correct" 86.1328 would produce
     a SHAPE MISMATCH against the C++ runner and the parity gate would be
     measuring the wrong thing. (The frame -> SECONDS conversion is a
     different question: the bridge uses the exact `frame * 256 / 22050`,
     which is what `frame_to_seconds()` does.)
  3. DECODE (vendor/basicpitch/src/midi_notes.cpp): peak-picking on the onsets
     + the frame-threshold continuation + the "melodia trick" residual pass.

The constants mirror vendor/basicpitch/src/basicpitch.hpp verbatim. The frame
rate is ANNOTATIONS_FPS = 22050 / 256 ≈ 86.13 Hz, so frame -> seconds is
`frame * 256 / 22050`.

Numerics note (honest): the C++ side runs the SPM ONNX Runtime 1.24.2 (D-39:
ONE ORT runtime) while this reference runs the `onnxruntime` wheel. The two are
different builds of ORT 1.x, so the parity tolerance is the C-7 rule
(abs 1e-3 OR rel 1e-4) — loose enough for kernel drift between ORT builds,
tight enough that a CORRUPTED port (wrong chunking, wrong overlap trim, wrong
axis order) fails loudly. The note-level assertions (onset/offset within 50 ms
on the synthetic truth) are version-independent by construction.
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np

# --- constants (vendor/basicpitch/src/basicpitch.hpp, verbatim) -------------
SAMPLE_RATE = 22050
FFT_HOP = 256
ANNOTATIONS_FPS = SAMPLE_RATE / FFT_HOP  # 86.13... (the EXACT rate, used for
#                                         frame -> seconds in the bridge)
# The VENDOR's integer-division constant (basicpitch.hpp): 22050 / 256 == 86.
# Used for the unwrap truncation — see n_output_frames() and the module
# docstring. Upstream quirk, reproduced deliberately.
ANNOTATIONS_FPS_INT = SAMPLE_RATE // FFT_HOP  # 86
AUDIO_N_SAMPLES = SAMPLE_RATE * 2 - FFT_HOP  # 43844
N_OVERLAPPING_FRAMES = 30
OVERLAP_LEN = N_OVERLAPPING_FRAMES * FFT_HOP  # 7680
HOP_SIZE = AUDIO_N_SAMPLES - OVERLAP_LEN  # 36164
N_OLAP = N_OVERLAPPING_FRAMES // 2  # 15
ONSET_THRESHOLD = 0.5
FRAME_THRESHOLD = 0.3
MIN_NOTE_LEN = 11
ENERGY_TOL = 11
MIDI_OFFSET = 21
MAX_FREQ_IDX = 87

INPUT_NAME = "serving_default_input_2:0"
OUTPUT_NAMES = ("StatefulPartitionedCall:1",   # notes
                "StatefulPartitionedCall:2",   # onsets
                "StatefulPartitionedCall:0")   # contours

# C-7 parity tolerance (CONTRACTS C-7 example; per-engine overrides only via
# a recorded ruling).
TOLERANCE = {"abs": 1e-3, "rel": 1e-4}


def n_output_frames(audio_length: int) -> int:
    """The VENDOR's frame-count truncation, reproduced bit-for-bit.

    `vendor/basicpitch/src/basicpitch.hpp` declares ANNOTATIONS_FPS as an
    INT (22050 / 256 == 86, integer division) and `ort_inference.cpp` uses
    `floor(audio_original_length * (ANNOTATIONS_FPS / 22050.0f))` in float32
    arithmetic. Reproduced exactly here (float32 division, float32 multiply,
    floor) so the reference and the C++ runner agree on the SHAPE.
    """
    ratio = np.float32(ANNOTATIONS_FPS_INT) / np.float32(SAMPLE_RATE)
    scaled = np.float32(audio_length) * ratio
    return int(math.floor(scaled))


def build_input_chunks(audio: np.ndarray) -> np.ndarray:
    """Padded + chunked model input, shape [chunks, AUDIO_N_SAMPLES, 1]."""
    padded = np.concatenate([np.zeros(OVERLAP_LEN // 2, dtype=np.float32),
                             np.asarray(audio, dtype=np.float32)])
    n_chunks = (len(padded) + HOP_SIZE - 1) // HOP_SIZE
    out = np.zeros((n_chunks, AUDIO_N_SAMPLES, 1), dtype=np.float32)
    for i in range(n_chunks):
        start = i * HOP_SIZE
        piece = padded[start:start + AUDIO_N_SAMPLES]
        out[i, :len(piece), 0] = piece
    return out


def unwrap_output(raw: np.ndarray, audio_length: int) -> np.ndarray:
    """Upstream `unwrap_output`, numpy port. `raw` is [batch, times, freqs]
    as returned by ORT; the result is [time_frames, freqs] (row-major)."""
    n_times = raw.shape[1]
    sliced = raw[:, N_OLAP:n_times - N_OLAP, :]
    flat = sliced.reshape(-1, raw.shape[2])
    n_out = min(n_output_frames(audio_length), flat.shape[0])
    return flat[:n_out, :]


def find_peaks(onsets: np.ndarray) -> list[tuple[int, int]]:
    """Upstream `find_peaks` — row-major scan (t outer, f inner), strict local
    max over time, threshold `> 0.5`."""
    peaks: list[tuple[int, int]] = []
    n_times, n_freqs = onsets.shape
    for t in range(1, n_times - 1):
        for f in range(n_freqs):
            v = onsets[t, f]
            if v > ONSET_THRESHOLD and v > onsets[t - 1, f] and v > onsets[t + 1, f]:
                peaks.append((t, f))
    return peaks


def decode_notes(notes: np.ndarray, onsets: np.ndarray,
                 use_melodia_trick: bool = True) -> list[dict]:
    """Upstream `output_to_notes_polyphonic` (melodia + bends variants off),
    numpy port. Returns [{start_idx, end_idx, midi, amplitude}]."""
    frames = notes.copy()
    remaining = notes.copy()
    events: list[dict] = []
    n_times = onsets.shape[0]

    peaks = find_peaks(onsets)
    peaks.reverse()  # upstream: std::reverse(peaks.begin(), peaks.end())

    for note_start_idx, freq_idx in peaks:
        i = note_start_idx + 1
        k = 0
        while i < n_times - 1 and k < ENERGY_TOL:
            if remaining[i, freq_idx] < FRAME_THRESHOLD:
                k += 1
            else:
                k = 0
            i += 1
        i -= k

        if i - note_start_idx <= MIN_NOTE_LEN:
            continue

        for t in range(note_start_idx, i):
            remaining[t, freq_idx] = 0.0
            if freq_idx > 0:
                remaining[t, freq_idx - 1] = 0.0
            if freq_idx < MAX_FREQ_IDX:
                remaining[t, freq_idx + 1] = 0.0

        amplitude = float(np.mean(frames[note_start_idx:i, freq_idx]))
        events.append({"start_idx": int(note_start_idx), "end_idx": int(i),
                       "midi": int(freq_idx + MIDI_OFFSET), "amplitude": amplitude})

    if use_melodia_trick:
        events.extend(_melodia_trick(remaining, frames))
    return events


def _melodia_trick(remaining: np.ndarray, frames: np.ndarray) -> list[dict]:
    """Upstream `apply_melodia_trick` — the residual-energy pass.

    The upstream maxCoeff() tie-break is COLUMN-MAJOR (smallest freq first,
    then smallest time) because the energy matrix is mapped as a column-major
    Eigen::MatrixXf; numpy's argmax over the freq-major flatten reproduces it.
    """
    events: list[dict] = []
    n_times = remaining.shape[0]
    work = remaining.copy()
    while True:
        flat = work.T.ravel()  # freq-major == Eigen column-major order
        if flat.size == 0:
            break
        idx = int(np.argmax(flat))
        if flat[idx] <= FRAME_THRESHOLD:
            break
        freq_idx, i_mid = divmod(idx, n_times)
        work[i_mid, freq_idx] = 0.0

        # Forward pass.
        i = i_mid + 1
        k = 0
        while i < n_times - 1 and k < ENERGY_TOL:
            if work[i, freq_idx] < FRAME_THRESHOLD:
                k += 1
            else:
                k = 0
            work[i, freq_idx] = 0.0
            if freq_idx < MAX_FREQ_IDX:
                work[i, freq_idx + 1] = 0.0
            if freq_idx > 0:
                work[i, freq_idx - 1] = 0.0
            i += 1
        i_end = i - 1 - k

        # Backward pass.
        i = i_mid - 1
        k = 0
        while i > 0 and k < ENERGY_TOL:
            if work[i, freq_idx] < FRAME_THRESHOLD:
                k += 1
            else:
                k = 0
            work[i, freq_idx] = 0.0
            if freq_idx < MAX_FREQ_IDX:
                work[i, freq_idx + 1] = 0.0
            if freq_idx > 0:
                work[i, freq_idx - 1] = 0.0
            i -= 1
        i_start = i + 1 + k

        if i_end - i_start <= MIN_NOTE_LEN:
            continue

        amplitude = float(np.mean(frames[i_start:i_end, freq_idx]))
        events.append({"start_idx": int(i_start), "end_idx": int(i_end),
                       "midi": int(freq_idx + MIDI_OFFSET), "amplitude": amplitude})
    return events


def run_reference(audio: np.ndarray, model_path: Path | str,
                  session=None) -> dict:
    """Run the model + decode on mono float32 audio at 22050 Hz.

    Returns {"notes": [time,freq], "onsets": ..., "contours": ..., "events": [...]}.
    """
    import onnxruntime as ort  # imported lazily — the mock path must not need it

    if session is None:
        session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    audio = np.asarray(audio, dtype=np.float32)
    chunks = build_input_chunks(audio)
    outputs = session.run(list(OUTPUT_NAMES), {INPUT_NAME: chunks})
    raw_notes, raw_onsets, raw_contours = outputs
    notes = unwrap_output(raw_notes, len(audio))
    onsets = unwrap_output(raw_onsets, len(audio))
    contours = unwrap_output(raw_contours, len(audio))
    events = decode_notes(notes, onsets)
    return {"notes": notes, "onsets": onsets, "contours": contours,
            "events": events, "raw": (raw_notes, raw_onsets, raw_contours)}


def frame_to_seconds(frame: float) -> float:
    """Frame index -> seconds (ANNOTATIONS_FPS = 22050/256)."""
    return float(frame) * FFT_HOP / SAMPLE_RATE


def compare_tensors(a: np.ndarray, b: np.ndarray, abs_tol: float | None = None,
                    rel_tol: float | None = None) -> tuple[bool, str]:
    """C-7 parity: elementwise |a-b| <= abs_tol OR |a-b| <= rel_tol*|b|."""
    abs_tol = TOLERANCE["abs"] if abs_tol is None else abs_tol
    rel_tol = TOLERANCE["rel"] if rel_tol is None else rel_tol
    if a.shape != b.shape:
        return False, f"shape mismatch {a.shape} vs {b.shape}"
    diff = np.abs(a.astype(np.float64) - b.astype(np.float64))
    ok = (diff <= abs_tol) | (diff <= rel_tol * np.abs(b.astype(np.float64)))
    if bool(np.all(ok)):
        return True, f"max abs diff {float(diff.max()) if diff.size else 0.0:.3e}"
    bad = int(np.count_nonzero(~ok))
    worst = float(diff.max()) if diff.size else 0.0
    return False, f"{bad}/{diff.size} elements outside tolerance (abs {abs_tol:g} / rel {rel_tol:g}); worst {worst:.3e}"


def read_wav_mono(path: Path | str) -> tuple[np.ndarray, int]:
    """16-bit PCM WAV -> (mono float32 samples, sample_rate)."""
    import wave

    with wave.open(str(path)) as w:
        sr = w.getframerate()
        channels = w.getnchannels()
        width = w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise ValueError(f"{path}: expected 16-bit PCM, got {width * 8}-bit")
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    return data, sr
