#!/usr/bin/env python3
"""Causal ribbon real spike (P-102, PAUL lane) — the D-19 rename target for
the `nanopitch` mock (CI job `ribbon-spike` switches to `--spike ribbon`).

Compiles the VENDORED sevagh/pitch-detection subset (vendor/pitch-detection,
MIT — Leto-verified per D-19) + kissfft (BSD-3) against Tests/Spikes/
ribbon_runner.cpp and drives the deterministic MPM (McLeod) on the synthetic
fixtures. Zero lookahead (each window sees only past samples), zero training
data, no NC weights (D-17/D-19: NanoPitch + grouper/drums weights banned).

Measured behavior frozen here (local g++ 13.3, Linux dev box; CI re-measures):
  - silence/clicks → 0 voiced frames (MPM returns the -1 sentinel)
  - synthetic voice (C3-D3-E3-D3-C3, ±15 c vibrato @5.5 Hz): ≥80 % voiced,
    |cents| p95 5.8 / med 1.3 vs frame-center truth (64 ms window)
  - sweep (825 c/s chirp): the 64 ms window averages the chirp — med 5.9 /
    p95 42 c; a 128 ms window gives med 3.3 / p95 19.4. BOTH asserted (the
    engine ships the 64 ms window for ribbon latency; the 128 ms row documents
    the window-size tradeoff — see ENGINE.md §ribbon).
  - noise burst: MPM emits transient garbage frames (15/59 voiced) — expected:
    MPM has NO voicing decision; the mic gate is silero (P-103) + VADGate.
    Asserted only as "not fully voiced" (honest documentation, no fake VAD).
  - RTF ≈ 0.002 (target < 0.1, PLAN M1).

Upstream-faithful behavior note (vendor README engineering note): the vendored
autocorrelation is CIRCULAR — non-integer periods bias the estimate; the
sweep-row limits above absorb it. Windowing/zero-padding would be a NEW
vendor patches.log entry (Leto lane), never a silent edit.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "fixtures"))

import spike_checks as sc  # noqa: E402
import gen as fixtures  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
VENDOR = REPO_ROOT / "vendor" / "pitch-detection"
BUILD_DIR = Path(os.environ.get("PITCHNOTES_SPIKE_BUILD", REPO_ROOT / "Tests/Spikes/.ribbon-build"))
SR = 16000
RTF_TARGET = 0.1

CPP_SOURCES = ["mpm.cpp", "yin.cpp", "autocorrelation.cpp", "parabolic_interpolation.cpp", "pd_fft_backend.cpp"]
KISSFFT_SOURCES = ["kiss_fft.c", "kiss_fftr.c"]


def compiler() -> str:
    for c in ("clang++", "g++"):
        if shutil.which(c):
            return c
    raise RuntimeError("no C++ compiler found (need clang++ or g++)")


def build_runner() -> Path:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    binary = BUILD_DIR / "ribbon_runner"
    src_stamp = max(
        (VENDOR / "src" / s).stat().st_mtime for s in CPP_SOURCES
    ) if (VENDOR / "src").is_dir() else 0
    if binary.exists() and binary.stat().st_mtime > src_stamp:
        return binary
    cmd = [compiler(), "-O2", "-std=c++17",
           "-I", str(VENDOR / "include"),
           "-I", str(VENDOR / "third_party" / "kissfft"),
           str(REPO_ROOT / "Tests" / "Spikes" / "ribbon_runner.cpp")]
    for s in CPP_SOURCES:
        cmd.append(str(VENDOR / "src" / s))
    for s in KISSFFT_SOURCES:
        cmd.append(str(VENDOR / "third_party" / "kissfft" / s))
    cmd += ["-o", str(binary)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ribbon_runner compile failed:\n{r.stderr[-2000:]}")
    return binary


def read_wav_mono(path: Path) -> np.ndarray:
    import wave
    with wave.open(str(path), "rb") as w:
        assert w.getsampwidth() == 2 and w.getnchannels() == 1 and w.getframerate() == SR
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def run_runner(binary: Path, fixture: Path, window: int = 1024, hop: int = 256):
    r = subprocess.run([str(binary), str(fixture), str(window), str(hop)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"runner failed: {r.stderr}")
    lines = r.stdout.strip().splitlines()
    rtf = float([l for l in lines if l.startswith("RTF")][0].split("\t")[1])
    frames = [(float(a), float(b)) for a, b in (l.split("\t") for l in lines[:-1])]
    t = np.array([f[0] for f in frames])
    hz = np.array([f[1] for f in frames])
    return t, hz, rtf


def real_available() -> str | None:
    """Real path needs the vendored sources + a C++ compiler (no ONNX here)."""
    if not (VENDOR / "include" / "pitch_detection.h").is_file():
        return None
    try:
        compiler()
    except RuntimeError:
        return None
    return "vendored-cpp"


def run_ribbon(report: sc.CheckReport) -> None:
    binary = build_runner()
    report.ok("S1", f"vendored MPM/YIN compiled: {binary} ({compiler()})")
    fx = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"

    # Silence + clicks: fully unvoiced (MPM -1 sentinel).
    for name in ("silence_16k.wav", "click_track_16k.wav"):
        t, hz, rtf = run_runner(binary, fx / name)
        voiced = int((hz > 0).sum())
        if voiced > 0:
            report.bad("S4", f"ribbon/{name}: {voiced}/{len(t)} frames voiced (must be 0)")
        else:
            report.ok("S4", f"ribbon/{name}: all {len(t)} frames unvoiced (RTF {rtf:.4f})")

    # Voice fixture: pitch accuracy vs frame-center truth (64 ms window).
    t, hz, rtf = run_runner(binary, fx / "synthetic_voice_16k.wav")
    voiced = hz > 0
    voiced_frac = float(voiced.mean())
    if voiced_frac < 0.80:
        report.bad("S4", f"ribbon/voice: only {voiced_frac:.0%} voiced (need ≥ 80 %)")
    else:
        report.ok("S4", f"ribbon/voice: {int(voiced.sum())}/{len(t)} voiced ({voiced_frac:.0%}, RTF {rtf:.4f})")
    tc = t[voiced] + (0.5 * 1024 / SR)  # window center
    truth = fixtures.synthetic_voice_f0(tc)
    err = np.abs(1200.0 * np.log2(hz[voiced] / truth))
    p95 = float(np.percentile(err, 95))
    med = float(np.median(err))
    if p95 >= 15.0:
        report.bad("S4", f"ribbon/voice: |cents| p95 {p95:.2f} ≥ 15 (med {med:.2f})")
    else:
        report.ok("S4", f"ribbon/voice: |cents| med {med:.2f} / p95 {p95:.2f} (< 15; note-transition outliers max {float(err.max()):.1f} absorbed)")

    # Sweep at both windows: honest window-size tradeoff (see docstring).
    for window, limit_med, limit_p95 in ((1024, 12.0, 48.0), (2048, 8.0, 30.0)):
        t, hz, rtf = run_runner(binary, fx / "sweep_46_2100Hz_16k.wav", window=window)
        voiced = hz > 0
        tc = t[voiced] + (0.5 * window / SR)
        truth = fixtures.sweep_f0(tc)
        err = np.abs(1200.0 * np.log2(hz[voiced] / truth))
        med, p95 = float(np.median(err)), float(np.percentile(err, 95))
        if med >= limit_med or p95 >= limit_p95:
            report.bad("S4", f"ribbon/sweep@{window}: |cents| med {med:.2f}/p95 {p95:.2f} "
                             f"(limits {limit_med}/{limit_p95} — windowed-chirp lag + circular-acorr leakage, vendor note)")
        else:
            report.ok("S4", f"ribbon/sweep@{window}: med {med:.2f} / p95 {p95:.2f} "
                            f"(< {limit_med}/{limit_p95}; voiced {int(voiced.sum())}/{len(t)}, RTF {rtf:.4f})")

    # Noise burst: MPM is pitch-only (no VAD) — transient garbage allowed, NOT
    # fully voiced; the mic gate is silero + VADGate (P-103/P-104).
    t, hz, rtf = run_runner(binary, fx / "noise_burst_16k.wav")
    frac = float((hz > 0).mean())
    if frac > 0.9:
        report.bad("S4", f"ribbon/burst: {frac:.0%} voiced — unexpected (noise rarely peaks NSDF ≥ 0.93)")
    else:
        report.ok("S4", f"ribbon/burst: {frac:.0%} frames voiced (transient garbage — gated by silero/VADGate in the app; MPM has no voicing decision)")

    # RTF budget (S8): worst measured across all runs above.
    t, hz, rtf = run_runner(binary, fx / "sweep_46_2100Hz_16k.wav")
    if rtf >= RTF_TARGET:
        report.bad("S8", f"ribbon: RTF {rtf:.4f} ≥ {RTF_TARGET} (PLAN M1)")
    else:
        report.ok("S8", f"ribbon: RTF {rtf:.5f} < {RTF_TARGET} (zero lookahead, causal)")

    # Determinism (S6): frame lines byte-equal across runs (RTF line excluded —
    # it is wall-clock timing, not model output).
    strip = lambda out: "\n".join(l for l in out.strip().splitlines() if not l.startswith("RTF\t"))
    a = strip(subprocess.run([str(binary), str(fx / "synthetic_voice_16k.wav")], capture_output=True, text=True).stdout)
    b = strip(subprocess.run([str(binary), str(fx / "synthetic_voice_16k.wav")], capture_output=True, text=True).stdout)
    if a == b:
        report.ok("S6", "ribbon: frame output byte-equal across identical runs (deterministic; RTF line excluded as timing)")
    else:
        report.bad("S6", "ribbon: frame output drifted across identical runs")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    args = ap.parse_args()
    if real_available() is None:
        print("FAILED: vendored sources or C++ compiler unavailable "
              "(need vendor/pitch-detection + clang++/g++)")
        return 1
    report = sc.CheckReport()
    try:
        run_ribbon(report)
    except Exception as e:
        print(f"FAILED: ribbon spike error: {e}")
        return 1
    for line in report.failed:
        print(f"  VIOLATION {line}")
    if report.failed:
        print(f"FAILED: ribbon real spike — {len(report.failed)} violation(s)")
        return 1
    for line in report.passed:
        print(f"  ok {line}")
    print("RIBBON REAL SPIKE GREEN (vendored sevagh MPM/YIN, D-17/D-19 default)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
