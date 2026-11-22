#!/usr/bin/env python3
"""SwiftF0 real-model spike (P-101, PAUL lane).

Runs the D-19-pinned SwiftF0 ONNX (lars76/swift-f0, MIT — model SHA256-verified
via scripts/models/download.py against Models/manifest.json) on the synthetic
fixtures and asserts the P-101 AC: pitch within ±20 cents of synthetic truth
(sweep + synthetic-voice), silence gated to unvoiced, confidence in [0, 1],
contract grid, RTF logged with intra_op threads 1/2/4.

Called from run_spike.py (spike name `swiftf0`); can also run standalone:
    python3 Tests/Spikes/swiftf0_real.py            # full real check
    python3 Tests/Spikes/swiftf0_real.py --threads-only

Determinism: the model is deterministic; checks compare two identical runs.

Fallback policy: run_spike.py falls back to the deterministic mock when
onnxruntime (or the model) is unavailable so CI stays green until the spike
venv gains `onnxruntime` (Leto one-liner; L-101 flips real-blocking at the gate).
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
import gen as fixtures  # noqa: E402  (P-001 generator — shared truth functions)

REPO_ROOT = Path(__file__).resolve().parents[2]
SR = 16000
HOP = 256
FMIN, FMAX = 46.875, 2093.75
SILENCE_PEAK = 1e-3
VOICED_THRESHOLD = 0.5

# P-101 AC tolerance (PLAN M1): pitch within ±20 cents of synthetic truth.
CENTS_LIMIT = 20.0


def read_wav_mono(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        assert w.getsampwidth() == 2, "fixtures are PCM16"
        frames = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
        assert w.getnchannels() == 1
        assert w.getframerate() == SR
    return frames.astype(np.float32) / 32768.0


def postprocess(audio: np.ndarray, conf_raw: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Upstream gate + loudness (mirrors EngineCore.SwiftF0Postprocessor)."""
    n = conf_raw.shape[0]
    conf = conf_raw.copy()
    usable = min(n * HOP, len(audio))
    power = np.zeros(n)
    for i in range(n):
        start = i * HOP
        length = min(HOP, max(0, usable - start))
        if length == 0:
            continue
        hop = audio[start:start + length]
        if float(np.abs(hop).max()) < SILENCE_PEAK:
            conf[i] = 0.0
        power[i] = float(np.sum(hop.astype(np.float64) ** 2))
    rms = np.sqrt((np.concatenate(([0.0], power[:-1])) + power) / 512.0)
    loud = 20.0 * np.log10(np.maximum(rms, 1e-7))
    return conf, loud


def frame_truth(t_center: np.ndarray, truth_fn) -> np.ndarray:
    """Instantaneous truth F0 at each frame center (0.0 where silent)."""
    f = truth_fn(t_center)
    return np.where(np.isfinite(f) & (f > 0), f, 0.0)


def cents_error(est_hz: np.ndarray, truth_hz: np.ndarray, voiced: np.ndarray) -> np.ndarray:
    """cents = 1200·log2(f_est/f_true) over frames voiced in BOTH est and truth."""
    mask = voiced & (truth_hz > 0) & (est_hz > 0)
    if not mask.any():
        return np.array([])
    return 1200.0 * np.log2(est_hz[mask] / truth_hz[mask])


def ensure_model(cache_dir: Path | None = None) -> Path:
    """Download + SHA256-verify the pinned model via download.py (D-19 entry)."""
    cache = Path(cache_dir or os.environ.get(
        "PITCHNOTES_MODEL_CACHE", REPO_ROOT / "Models" / "downloads"))
    r = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "models" / "download.py"),
         "--manifest", str(REPO_ROOT / "Models" / "manifest.json"),
         "--entry", "swiftf0",
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


def load_session(model_path: Path, threads: int):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = threads
    return ort.InferenceSession(str(model_path), so, providers=["CPUExecutionProvider"])


def run_session(sess, audio: np.ndarray, fmin: float = FMIN, fmax: float = FMAX):
    pitch, conf = sess.run(
        ["pitch", "confidence"],
        {"audio": audio[None, :].astype(np.float32),
         "fmin": np.asarray(fmin, dtype=np.float32),
         "fmax": np.asarray(fmax, dtype=np.float32)})
    return np.asarray(pitch[0], dtype=np.float64), np.asarray(conf[0], dtype=np.float32)


def real_available() -> str | None:
    try:
        import onnxruntime  # noqa: F401
    except ImportError:
        return None
    return "onnxruntime"


def run_real(report: sc.CheckReport) -> None:
    import onnxruntime  # guaranteed by real_available()

    model_path = ensure_model()
    report.ok("S1", f"model pinned+verified: {model_path.name}")
    sess = load_session(model_path, threads=1)

    # --- I/O shape contract (S2) ---
    inputs = {i.name: i for i in sess.get_inputs()}
    outputs = {o.name: o for o in sess.get_outputs()}
    if set(inputs) != {"audio", "fmin", "fmax"} or set(outputs) != {"pitch", "confidence"}:
        report.bad("S5", f"ONNX I/O mismatch: in={sorted(inputs)} out={sorted(outputs)}")
    else:
        report.ok("S5", "ONNX I/O: audio[1,samples] f32 + fmin/fmax scalars → pitch/confidence")

    fixtures_dir = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"

    # --- Sweep: full contract band, log chirp with exact truth (S3/S4) ---
    sweep = read_wav_mono(fixtures_dir / "sweep_46_2100Hz_16k.wav")
    pitch, conf_raw = run_session(sess, sweep)
    conf, loud = postprocess(sweep, conf_raw)
    n = conf.shape[0]
    sc.check_shape((n,), (len(sweep) // HOP,), np.float64, pitch, report, "swiftf0/sweep")
    sc.check_confidence_bounds(conf_raw.astype(np.float64), report, "swiftf0/sweep")
    t_center = (np.arange(n) * HOP + HOP // 2) / SR
    truth = frame_truth(t_center, fixtures.sweep_f0)
    voiced = conf >= VOICED_THRESHOLD
    err = cents_error(pitch, truth, voiced)
    if err.size < 100:
        report.bad("S4", f"swiftf0/sweep: only {err.size} comparable voiced frames")
    else:
        med, p95 = float(np.median(np.abs(err))), float(np.percentile(np.abs(err), 95))
        in_limit = p95 < CENTS_LIMIT
        (report.ok if in_limit else report.bad)(
            "S4", f"swiftf0/sweep: |cents| med {med:.2f} p95 {p95:.2f} (limit {CENTS_LIMIT}) "
                  f"over {err.size} frames")
    loud_med = float(np.median(loud[voiced])) if voiced.any() else -999
    if not (-80 < loud_med < 0):
        report.bad("S6", f"swiftf0/sweep: median loudness {loud_med:.1f} dB outside sane range")
    else:
        report.ok("S6", f"swiftf0/sweep: median voiced loudness {loud_med:.2f} dBFS")

    # --- Synthetic voice: vibrato melody with exact truth (S4, ±20 c AC) ---
    voice = read_wav_mono(fixtures_dir / "synthetic_voice_16k.wav")
    pitch_v, conf_raw_v = run_session(sess, voice)
    conf_v, _ = postprocess(voice, conf_raw_v)
    n_v = conf_v.shape[0]
    t_center_v = (np.arange(n_v) * HOP + HOP // 2) / SR
    truth_v = frame_truth(t_center_v, fixtures.synthetic_voice_f0)
    voiced_v = conf_v >= VOICED_THRESHOLD
    err_v = cents_error(pitch_v, truth_v, voiced_v)
    if err_v.size < 100:
        report.bad("S4", f"swiftf0/voice: only {err_v.size} comparable voiced frames")
    else:
        med_v, p95_v = float(np.median(np.abs(err_v))), float(np.percentile(np.abs(err_v), 95))
        (report.ok if p95_v < CENTS_LIMIT else report.bad)(
            "S4", f"swiftf0/voice: |cents| med {med_v:.2f} p95 {p95_v:.2f} (limit {CENTS_LIMIT}) "
                  f"over {err_v.size} frames; voiced {int(voiced_v.sum())}/{n_v}")

    # --- Silence: gate to unvoiced (S4/S8) ---
    sil = read_wav_mono(fixtures_dir / "silence_16k.wav")
    pitch_s, conf_raw_s = run_session(sess, sil)
    conf_s, _ = postprocess(sil, conf_raw_s)
    if int((conf_s >= VOICED_THRESHOLD).sum()) != 0:
        report.bad("S4", f"swiftf0/silence: {int((conf_s >= VOICED_THRESHOLD).sum())} frames survived gating")
    else:
        report.ok("S4", f"swiftf0/silence: all {conf_s.shape[0]} frames gated (conf→0, hz→0)")
    sc.check_confidence_bounds(conf_raw_s.astype(np.float64), report, "swiftf0/silence")

    # --- Contract mapping: hz==0 ⇔ conf<0.5 on gated output (S3/V11) ---
    hz_contract = np.where(conf_v >= VOICED_THRESHOLD, pitch_v, 0.0)
    both = ((hz_contract == 0) == (conf_v < VOICED_THRESHOLD)).all()
    (report.ok if both else report.bad)("S3", "swiftf0/voice: contract mapping hz==0 ⇔ conf<0.5 holds")

    # --- Determinism (S7): two runs byte-equal ---
    p2, c2 = run_session(sess, sweep)
    if np.array_equal(pitch, p2) and np.array_equal(conf_raw, c2):
        report.ok("S7", "swiftf0: two identical runs are byte-equal (deterministic)")
    else:
        report.bad("S7", "swiftf0: model output drifted between identical runs")

    # --- RTF + intra_op threads 1/2/4 (S8, honest numbers for BENCHMARKS.md) ---
    audio4 = sweep[: 4 * SR]
    rows = []
    for threads in (1, 2, 4):
        s = load_session(model_path, threads=threads)
        times = []
        for _ in range(5):
            t0 = time.perf_counter()
            run_session(s, audio4)
            times.append(time.perf_counter() - t0)
        med = float(np.median(times))
        rows.append((threads, med, med / 4.0))
    print("  [bench] swiftf0 RTF (CI runner, 4 s audio, median of 5):")
    for threads, med, rtf in rows:
        print(f"    intra_op={threads}: {med * 1000:.1f} ms → RTF {rtf:.5f} ({4.0 / med:.0f}× RT)")
    best = min(rtf for _, _, rtf in rows)
    if best >= 0.3:
        report.bad("S8", f"swiftf0: best RTF {best:.4f} ≥ 0.3 target")
    else:
        report.ok("S8", f"swiftf0: best RTF {best:.5f} < 0.3 (PLAN §0 target)")
    report.ok("S8", f"swiftf0/sweep voiced {int(voiced.sum())}/{n} frames on in-band sweep")


def export_reference_tensors(sess) -> Path:
    """D-24 (CONTRACTS C-7) sidecar: capture the pinned model's outputs on the
    committed fixtures + the fixture SHA256s, so P-208 parity tests (Python
    reference vs Swift/ORT outputs) are cheap later. Non-gating; regenerable."""
    import hashlib
    out_dir = REPO_ROOT / "Tests" / "Spikes" / "ReferenceTensors"
    out_dir.mkdir(parents=True, exist_ok=True)
    fx = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
    ref_dir = Path.home() / ".cache/pitchnotes-models"
    entry = [m for m in __import__("json").loads((REPO_ROOT / "Models" / "manifest.json").read_text())["models"] if m["name"] == "swiftf0"][0]
    model_sha = entry["sha256"]
    arrays = {}
    sha_rows = []
    for name, truth_fn in (("sweep_46_2100Hz_16k.wav", fixtures.sweep_f0),
                           ("synthetic_voice_16k.wav", fixtures.synthetic_voice_f0),
                           ("silence_16k.wav", None)):
        audio = read_wav_mono(fx / name)
        pitch, conf_raw = run_session(sess, audio)
        conf, loud = postprocess(audio, conf_raw)
        stem = name.removesuffix(".wav")
        arrays[f"{stem}_pitch_hz"] = pitch
        arrays[f"{stem}_confidence_raw"] = conf_raw
        arrays[f"{stem}_confidence_gated"] = conf
        arrays[f"{stem}_loudness_db"] = loud
        if truth_fn is not None:
            n = conf.shape[0]
            arrays[f"{stem}_truth_hz"] = frame_truth((np.arange(n) * HOP + HOP // 2) / SR, truth_fn)
        sha_rows.append(f"{hashlib.sha256((fx / name).read_bytes()).hexdigest()}  {name}")
    arrays["_model_sha256"] = np.array([model_sha])
    out = out_dir / "swiftf0_reference.npz"
    np.savez_compressed(out, **arrays)
    (out_dir / "fixtures.sha256").write_text("\n".join(sha_rows) + "\n")
    (out_dir / "README.md").write_text(
        "# ReferenceTensors (D-24 / CONTRACTS C-7 spike-parity sidecars)\n\n"
        "Captured model outputs of the PINNED manifest entries on the committed "
        "fixtures (regenerable: `python3 Tests/Spikes/swiftf0_real.py --export-ref` "
        "and `... silero_real.py --export-ref`). Consumed by P-208 parity tests "
        "(Python reference vs Swift/ORT outputs, tolerance-based). The model SHA "
        "travels INSIDE the npz (`_model_sha256`) — parity asserts it matches the "
        "manifest entry, so a model bump without regeneration fails loudly.\n")
    return out


def export_c7_sidecars(sess) -> Path:
    """P-208 (D-24): C-7 JSON+bin parity sidecars for the SWIFT tests.

    Same fixtures/tensors as export_reference_tensors minus truth_hz (parity
    compares MODEL outputs, not synthetic truth) in the C-7-ratified shape:
    one JSON manifest + raw little-endian bins per fixture under
    Tests/Spikes/ReferenceTensors/swiftf0/ (c7_export.py writer).
    """
    import json

    import c7_export
    entry = [m for m in json.loads((REPO_ROOT / "Models" / "manifest.json").read_text())["models"]
             if m["name"] == "swiftf0"][0]
    fx = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
    tensors_by_stem: dict[str, dict[str, "np.ndarray"]] = {}
    for name in ("sweep_46_2100Hz_16k.wav", "synthetic_voice_16k.wav", "silence_16k.wav"):
        audio = read_wav_mono(fx / name)
        pitch, conf_raw = run_session(sess, audio)
        conf, loud = postprocess(audio, conf_raw)
        tensors_by_stem[name.removesuffix(".wav")] = {
            "pitch_hz": pitch,            # float64 (model-native output dtype)
            "confidence_raw": conf_raw,   # float32 (model-native)
            "confidence_gated": conf,     # float32 (gateConfidence parity)
            "loudness_db": loud,          # float64 (postprocess math)
        }
    return c7_export.export_c7(
        engine="SWIFTF0", slug="swiftf0",
        stems=list(tensors_by_stem.keys()),
        tensors_by_stem=tensors_by_stem,
        model_entry=entry,
        source=f"lars76/swift-f0 (manifest {entry.get('version', 'pin')}, sha {entry['sha256'][:12]}…)",
        script="Tests/Spikes/swiftf0_real.py --export-c7")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--threads-only", action="store_true", help="only run the RTF/threads table")
    ap.add_argument("--export-ref", action="store_true",
                    help="write the D-24/C-7 reference-tensor sidecar and exit")
    ap.add_argument("--export-c7", action="store_true",
                    help="write the P-208 C-7 JSON+bin parity sidecars and exit")
    args = ap.parse_args()
    if args.export_c7:
        if real_available() is None:
            print("FAILED: onnxruntime required for --export-c7")
            return 1
        sess = load_session(ensure_model(), threads=1)
        out = export_c7_sidecars(sess)
        print(f"C-7 parity sidecars written: {out}")
        return 0
    if args.export_ref:
        if real_available() is None:
            print("FAILED: onnxruntime required for --export-ref")
            return 1
        sess = load_session(ensure_model(), threads=1)
        out = export_reference_tensors(sess)
        print(f"reference sidecar written: {out}")
        return 0

    if real_available() is None:
        print("FAILED: onnxruntime not importable — real-model spike needs the venv "
              "`pip install onnxruntime` (see Tests/Spikes/README.md)")
        return 1

    report = sc.CheckReport()
    if args.threads_only:
        model_path = ensure_model()
        sess = load_session(model_path, threads=1)
        sweep = read_wav_mono(REPO_ROOT / "Tests/Spikes/Fixtures/sweep_46_2100Hz_16k.wav")
        for threads in (1, 2, 4):
            s = load_session(model_path, threads=threads)
            t0 = time.perf_counter()
            run_session(s, sweep[: 4 * SR])
            med = time.perf_counter() - t0
            print(f"intra_op={threads}: {med * 1000:.1f} ms → RTF {med / 4.0:.5f}")
        return 0

    try:
        run_real(report)
    except Exception as e:  # download failure, ONNX load failure, …
        print(f"FAILED: swiftf0 real-model spike error: {e}")
        return 1
    for line in report.failed:
        print(f"  VIOLATION {line}")
    if report.failed:
        print(f"FAILED: swiftf0 real-model spike — {len(report.failed)} violation(s)")
        return 1
    for line in report.passed:
        print(f"  ok {line}")
    print("SWIFTF0 REAL-MODEL SPIKE GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
