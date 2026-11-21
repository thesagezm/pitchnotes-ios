#!/usr/bin/env python3
"""Silero-vad real-model spike (P-103, PAUL lane).

Runs the D-19-pinned silero-vad ONNX (snakers4/silero-vad, MIT — SHA256-
verified via scripts/models/download.py against Models/manifest.json) with the
EXACT upstream streaming semantics (pinned commit bfdc019, OnnxWrapper):
512-sample chunks @16 kHz, 64-sample prepended context, `state` [2,1,128] fed
back from `stateN`, `sr` int64 scalar.

SEMANTICS NOTE (differs from the M0 mock on purpose): silero is a SPEECH VAD,
not an energy VAD. Non-speech transient energy (noise bursts, clicks) is
CORRECTLY classified non-speech — the M0 mock asserted "burst detected ≥ 0.5"
as an energy-VAD behavior; the real spike asserts the real semantics:
silence/clicks hard-gated, noise burst stays below the speech threshold, and a
voice-like fixture is detected (max prob ≥ 0.5) with a clear margin over
silence. Synthetic-only fixtures cannot reproduce real speech statistics —
the spike asserts model-consistent discrimination, not speech-parity.

Thresholds: silence/clicks max < 0.05 (measured 0.009/0.015 on the pinned
model); voice max ≥ 0.5 (measured 0.961 on synthetic_voice_16k); timing
median per-32 ms chunk < 1 ms (PLAN M1 AC; measured ≈0.33 ms on Linux dev).
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "fixtures"))

import spike_checks as sc  # noqa: E402
import gen as fixtures  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
SR = 16000
CHUNK = 512          # upstream OnnxWrapper: exactly 512 @16 kHz (32 ms)
CONTEXT = 64         # upstream context prepended to each chunk
STATE_SHAPE = (2, 1, 128)
CHUNK_BUDGET_MS = 1.0


def read_wav_mono(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        assert w.getsampwidth() == 2 and w.getnchannels() == 1 and w.getframerate() == SR
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def ensure_model(cache_dir: Path | None = None) -> Path:
    cache = Path(cache_dir or os.environ.get(
        "PITCHNOTES_MODEL_CACHE", REPO_ROOT / "Models" / "downloads"))
    r = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "models" / "download.py"),
         "--manifest", str(REPO_ROOT / "Models" / "manifest.json"),
         "--entry", "silero-vad",
         "--cache-dir", str(cache)],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"download.py failed (rc={r.returncode}): {r.stderr.strip()}")
    line = [l for l in r.stdout.splitlines() if l.startswith(("downloaded", "cached"))]
    if not line:
        raise RuntimeError(f"download.py printed no path: {r.stdout!r}")
    # "downloaded + verified: <path> (<size> bytes)" | "cached: <path>" — strip suffix.
    raw = line[0].split(": ", 1)[1]
    raw = re.sub(r"\s+\(\d+ bytes\)\s*$", "", raw)
    return Path(raw)


def load_session(model_path: Path):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    return ort.InferenceSession(str(model_path), so, providers=["CPUExecutionProvider"])


def real_available() -> str | None:
    try:
        import onnxruntime  # noqa: F401
    except ImportError:
        return None
    return "onnxruntime"


class SileroStream:
    """Upstream OnnxWrapper streaming semantics (pinned bfdc019)."""

    def __init__(self, sess):
        self.sess = sess
        self.reset()

    def reset(self) -> None:
        self.state = np.zeros(STATE_SHAPE, dtype=np.float32)
        self.context = np.zeros((1, CONTEXT), dtype=np.float32)

    def push(self, chunk: np.ndarray) -> float:
        assert chunk.shape == (CHUNK,), f"need exactly {CHUNK} samples, got {chunk.shape}"
        x = np.concatenate([self.context, chunk.reshape(1, CHUNK)], axis=1)
        out, state_n = self.sess.run(
            ["output", "stateN"],
            {"input": x.astype(np.float32), "state": self.state,
             "sr": np.array(SR, dtype=np.int64)})
        self.state = state_n.astype(np.float32)
        self.context = x[:, -CONTEXT:]
        return float(out[0, 0])


def probs_for(sess, audio: np.ndarray) -> np.ndarray:
    s = SileroStream(sess)
    out = []
    for i in range(0, len(audio) - len(audio) % CHUNK, CHUNK):
        out.append(s.push(audio[i:i + CHUNK]))
    return np.array(out)


def run_silero(report: sc.CheckReport) -> None:
    model_path = ensure_model()
    report.ok("S1", f"model pinned+verified: {model_path.name}")
    sess = load_session(model_path)

    inputs = {i.name: i for i in sess.get_inputs()}
    outputs = {o.name: o for o in sess.get_outputs()}
    if set(inputs) != {"input", "state", "sr"} or set(outputs) != {"output", "stateN"}:
        report.bad("S5", f"ONNX I/O mismatch: in={sorted(inputs)} out={sorted(outputs)}")
    else:
        report.ok("S5", "ONNX I/O: input[1,576] f32 + state[2,1,128] f32 + sr int64 → output[1,1] + stateN")

    fx = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
    silence = read_wav_mono(fx / "silence_16k.wav")
    burst = read_wav_mono(fx / "noise_burst_16k.wav")
    clicks = read_wav_mono(fx / "click_track_16k.wav")
    voice = read_wav_mono(fx / "synthetic_voice_16k.wav")

    p_sil = probs_for(sess, silence)
    p_burst = probs_for(sess, burst)
    p_clicks = probs_for(sess, clicks)
    p_voice = probs_for(sess, voice)

    # Silence + clicks hard-gated (speech VAD: non-speech stays non-speech).
    if float(p_sil.max()) >= 0.05:
        report.bad("S4", f"silero/silence: max prob {float(p_sil.max()):.3f} ≥ 0.05 (must gate)")
    else:
        report.ok("S4", f"silero/silence: gated (mean {float(p_sil.mean()):.3f}, max {float(p_sil.max()):.3f})")
    if float(p_clicks.max()) >= 0.05:
        report.bad("S4", f"silero/clicks: max prob {float(p_clicks.max()):.3f} ≥ 0.05")
    else:
        report.ok("S4", f"silero/clicks: gated (max {float(p_clicks.max()):.3f}) — non-speech transients correctly rejected")

    # Noise burst: real semantics assert — speech VAD keeps non-speech below threshold.
    if float(p_burst.max()) >= 0.5:
        report.bad("S4", f"silero/burst: max prob {float(p_burst.max()):.3f} ≥ 0.5 — speech VAD must not flag pure noise")
    else:
        report.ok("S4", f"silero/burst: below speech threshold (max {float(p_burst.max()):.3f}) — SPEECH-VAD semantics (M0 mock asserted energy-VAD ≥0.5; real model correctly rejects non-speech energy)")

    # Voice fixture detected: max ≥ 0.5 + big margin over silence.
    vmax = float(p_voice.max())
    if vmax < 0.5:
        report.bad("S4", f"silero/voice: max prob {vmax:.3f} < 0.5 — voice-like fixture never detected")
    else:
        report.ok("S4", f"silero/voice: detected (max {vmax:.3f})")
    margin = vmax - float(p_sil.max())
    if margin < 0.4:
        report.bad("S4", f"silero/voice-vs-silence margin {margin:.3f} < 0.4")
    else:
        report.ok("S4", f"silero: voice/silence margin {margin:.3f}")

    # Bounds + finite (S2/S3) over every stream.
    for name, p in (("silence", p_sil), ("burst", p_burst), ("clicks", p_clicks), ("voice", p_voice)):
        sc.check_confidence_bounds(p.astype(np.float64), report, f"silero/{name}")

    # Determinism (S6): identical double-run.
    again = probs_for(sess, voice)
    if np.array_equal(p_voice, again):
        report.ok("S6", "silero: two identical runs byte-equal (deterministic)")
    else:
        report.bad("S6", "silero: output drifted across identical runs")

    # Timing (S8 budget): median per-32 ms chunk < 1 ms.
    s = SileroStream(sess)
    chunk = voice[:CHUNK]
    times = []
    for _ in range(500):
        s.reset()
        t0 = time.perf_counter()
        s.push(chunk)
        times.append(time.perf_counter() - t0)
    med_ms = float(np.median(times)) * 1000.0
    p95_ms = float(np.percentile(times, 95)) * 1000.0
    print(f"  [bench] silero per-32ms-chunk: median {med_ms:.3f} ms, p95 {p95_ms:.3f} ms (budget < {CHUNK_BUDGET_MS} ms)")
    if med_ms >= CHUNK_BUDGET_MS:
        report.bad("S8", f"silero: median chunk {med_ms:.3f} ms ≥ {CHUNK_BUDGET_MS} ms budget")
    else:
        report.ok("S8", f"silero: median {med_ms:.3f} ms per 32 ms chunk (< 1 ms budget, PLAN M1)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    args = ap.parse_args()
    if real_available() is None:
        print("FAILED: onnxruntime not importable — real-model spike needs the venv "
              "`pip install onnxruntime` (see Tests/Spikes/README.md)")
        return 1
    report = sc.CheckReport()
    try:
        run_silero(report)
    except Exception as e:
        print(f"FAILED: silero real-model spike error: {e}")
        return 1
    for line in report.failed:
        print(f"  VIOLATION {line}")
    if report.failed:
        print(f"FAILED: silero real-model spike — {len(report.failed)} violation(s)")
        return 1
    for line in report.passed:
        print(f"  ok {line}")
    print("SILERO REAL-MODEL SPIKE GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
