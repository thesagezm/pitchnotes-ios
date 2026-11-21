#!/usr/bin/env python3
"""Deterministic MOCK models for the M0 spike harness (P-002, PAUL lane).

M0 ships NO real weights (AGENTS §6: spikes are structural until M1/M2/M3).
Each mock is content-derived (zero-crossing pitch, RMS-gated VAD, seeded
transforms) so the harness exercises the real assertion paths — range, grid,
confidence, non-silence, shape, determinism — on OUR fixtures, deterministically.

REAL-MODEL WIRING POINTS (documented contract; each lands in its milestone):
  swiftf0-spike     M1 P-101: lars76/swift-f0 ONNX (MIT) via ONNX Runtime;
                    input 16 kHz mono, 16 ms frames, fmin/fmax band filter;
                    outputs hz/confidence per frame + loudness_db.
  nanopitch-spike   M1 P-102: smulelabs/NanoPitch C engine (verify LICENSE D-7
                    first; fallback sevagh/pitch-detection MPM/YIN). Zero-lookahead
                    ribbon + VAD head.
  silero-vad-spike  M1 P-103: silero-vad ONNX (MIT), <1 ms per 30 ms chunk.
  separation-spike  M2 P-201: demucs.cpp (MIT, htdemucs fp16 ggml) two-stems
                    vocals/instrumental first; then per-part (M3).
  basicpitch-spike  M3 P-301: basicpitch.cpp (MIT; spotify nmp.onnx Apache-2.0),
                    resample 44.1k->22.05k, polyphonic note events.

Mocks read only Tests/Spikes/Fixtures (P-001); no network, no weights, no deps
beyond numpy.
"""
from __future__ import annotations

import hashlib
import wave
from pathlib import Path

import numpy as np

import spike_checks as sc

FIXTURES_DIR = Path(__file__).resolve().parent / "Fixtures"
SR = 16000
HOP = 256  # 16 ms @ 16 kHz


def load_wav(name: str) -> tuple[np.ndarray, int]:
    with wave.open(str(FIXTURES_DIR / name), "rb") as w:
        sr = w.getframerate()
        assert w.getnchannels() == 1 and w.getsampwidth() == 2
        raw = w.readframes(w.getnframes())
    x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32767.0
    return x, sr


def frame_count(n: int) -> int:
    return n // HOP


def window_rms(x: np.ndarray) -> np.ndarray:
    n = frame_count(len(x))
    win = x[: n * HOP].reshape(n, HOP)
    return np.sqrt(np.mean(np.square(win), axis=1))


def zero_cross_hz(x: np.ndarray) -> np.ndarray:
    """Frame-wise zero-crossing pitch estimate (meaningful on mono tones,
    structural on polyphonic mixes — exactly like a mock should be)."""
    n = frame_count(len(x))
    win = x[: n * HOP].reshape(n, HOP)
    signs = np.sign(win)
    crossings = np.sum(np.abs(np.diff(signs, axis=1)) > 0, axis=1)
    return crossings * SR / (2.0 * HOP)


def band_filter(hz: np.ndarray, fmin: float, fmax: float) -> np.ndarray:
    """SwiftF0-style band filter: outside [fmin, fmax] => unvoiced (0.0)."""
    out = hz.copy()
    out[(out < fmin) | (out > fmax)] = 0.0
    return out


def _seed_for(spike: str) -> int:
    return int.from_bytes(hashlib.sha256(spike.encode()).digest()[:8], "little")


# ---------------------------------------------------------------------------
# Individual spike mocks. Each returns {name: np.ndarray float32} + metadata;
# run_spike.py applies the S-rules. Two identical invocations must return
# byte-identical arrays (S6).
# ---------------------------------------------------------------------------

def mock_swiftf0(fixture: str = "sweep_46_2100Hz_16k.wav") -> dict[str, np.ndarray]:
    x, sr = load_wav(fixture)
    assert sr == SR
    n = frame_count(len(x))
    rms = window_rms(x)
    hz = band_filter(zero_cross_hz(x), sc.HZ_MIN, sc.HZ_MAX)
    voiced = hz > 0.0
    conf = np.clip(rms / 0.5, 0.0, 1.0) * voiced  # energy-scaled, 0 when unvoiced
    loudness = np.maximum(20.0 * np.log10(np.maximum(rms, 1e-10)), -120.0)
    t = np.arange(n) * 0.016
    frames = np.stack([t, hz, conf], axis=1).astype(np.float32)
    return {"frames": frames, "loudness_db": loudness.astype(np.float32)}


def mock_nanopitch(fixture: str = "sweep_46_2100Hz_16k.wav") -> dict[str, np.ndarray]:
    out = mock_swiftf0(fixture)
    # NanoPitch adds a causal VAD head bit + zero-lookahead hz (mock: same hz).
    rms = window_rms(load_wav(fixture)[0])
    # Causal VAD head (mock): frame energy above the -60 dBFS floor.
    vad = (rms > 10.0 ** (sc.SILENCE_RMS_DB / 20.0)).astype(np.float32)
    out["vad"] = vad
    return out


def mock_silero_vad() -> dict[str, np.ndarray]:
    """Content-driven: 30 ms chunks; prob = sigmoid over RMS above floor. Asserts
    silence->low, burst->high in run_spike (behavioral sanity on OUR fixtures)."""
    chunk = int(0.030 * SR)
    probs = []
    for name in ("silence_16k.wav", "noise_burst_16k.wav", "click_track_16k.wav"):
        x, _ = load_wav(name)
        n = len(x) // chunk
        win = x[: n * chunk].reshape(n, chunk)
        db = np.array([sc.rms_db(w) for w in win])
        probs.append(1.0 / (1.0 + np.exp(-0.4 * (db - -45.0))))
    return {"speech_probs": np.concatenate(probs).astype(np.float32)}


def mock_separation(fixture: str = "satb_mixture_16k.wav") -> dict[str, np.ndarray]:
    """Structural two-stem mock: seeded energy-envelope transforms of the input.
    SDR is meaningless until demucs.cpp lands (P-201) — shape/finiteness only."""
    x, sr = load_wav(fixture)
    rng = np.random.default_rng(_seed_for("separation"))
    n = len(x)
    stems = []
    for k in range(2):  # two-stems first (D-9)
        env = rng.uniform(0.4, 1.0, size=max(1, n // HOP))
        env = np.repeat(env, HOP)[:n]
        stems.append((x * env).astype(np.float32))
    return {f"stem{k}": s for k, s in enumerate(stems)}


def mock_basicpitch(fixture: str = "mix44k_short.wav") -> dict[str, np.ndarray]:
    """Structural note-event mock: seeded in-band notes gated by frame energy.
    Real polyphonic transcription lands at P-301."""
    x, sr = load_wav(fixture)
    rng = np.random.default_rng(_seed_for("basicpitch"))
    rms = window_rms(x) if sr == SR else None
    dur = len(x) / sr
    notes = []
    t = 0.0
    while t < dur - 0.2:
        length = float(rng.uniform(0.15, 0.45))
        if t + length > dur:
            break
        midi = int(rng.integers(36, 84))
        notes.append({
            "start_s": round(t, 3),
            "end_s": round(t + length, 3),
            "midi": midi,
            "confidence": float(rng.uniform(0.3, 0.95)),
        })
        t += length + float(rng.uniform(0.0, 0.1))
    events = np.array([[n["start_s"], n["end_s"], n["midi"], n["confidence"]] for n in notes], dtype=np.float32)
    return {"note_events": events}


MOCKS = {
    "swiftf0": mock_swiftf0,
    "nanopitch": mock_nanopitch,
    "silero-vad": mock_silero_vad,
    "separation": mock_separation,
    "basicpitch": mock_basicpitch,
}

# Declared output contracts for S5 (name -> {key: (shape_fn, dtype)}); shape_fn
# receives the mock outputs dict and returns the expected shape or None (dynamic).
CONTRACTS = {
    "swiftf0": {"frames": (lambda o: (frame_count(len(load_wav("sweep_46_2100Hz_16k.wav")[0])), 3), np.float32),
                "loudness_db": (lambda o: (frame_count(len(load_wav("sweep_46_2100Hz_16k.wav")[0])),), np.float32)},
    "nanopitch": {"frames": (lambda o: (frame_count(len(load_wav("sweep_46_2100Hz_16k.wav")[0])), 3), np.float32),
                  "loudness_db": (lambda o: (frame_count(len(load_wav("sweep_46_2100Hz_16k.wav")[0])),), np.float32),
                  "vad": (lambda o: (frame_count(len(load_wav("sweep_46_2100Hz_16k.wav")[0])),), np.float32)},
    "silero-vad": {"speech_probs": (lambda o: (len(o["speech_probs"]),), np.float32)},
    "separation": {"stem0": (lambda o: (len(o["stem0"]),), np.float32),
                   "stem1": (lambda o: (len(o["stem1"]),), np.float32)},
    "basicpitch": {"note_events": (lambda o: None, np.float32)},
}


def serialize_outputs(outputs: dict[str, np.ndarray]) -> dict[str, bytes]:
    return {k: v.tobytes() for k, v in outputs.items()}
