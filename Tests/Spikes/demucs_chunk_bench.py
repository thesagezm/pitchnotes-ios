#!/usr/bin/env python3
"""D-25 chunk-policy benchmark (P-202 L3, PAUL lane).

DECIDES the M2 chunk policy BY MEASUREMENT (Leto's D-25 L3 decision protocol,
QUEUE.md LOG 2026-11-22T21:00Z §6): the muskey arm (4.5 s window / 1 s overlap)
vs the §8 plan arm (8 s window / 2 s overlap), against the whole-song vendor
path as the REFERENCE.

WHY A C++ HARNESS AND NOT THE SWIFT DRIVER: the Swift `ChunkedSeparationDriver`
is portable, but `DemucsEngine` (the real vendor bridge) is Apple-only, and
EngineCore must stay vendor-free/Linux-clean (AGENTS §0). The spike harness is
therefore the established measurement path (same as P-201's separation spike):
`demucs_runner.cpp` drives the REAL vendored demucs.cpp + the REAL htdemucs
fp16 ggml weights. The runner's chunked mode MIRRORS the Swift driver's window
plan and linear-crossfade blend EXACTLY (see the runner's header comment); the
Swift driver's own blend math is separately unit-proven in EngineCore
(167/167 Linux green), so the two proofs cover each other.

MEASURED PER ARM (same fixture, same weights, same runner class, paired runs):
  - wall time + RTF (wall / audio duration) — median + spread over repeats
  - peak RSS (getrusage ru_maxrss, normalized to KiB per OS)
  - external window count + INTERNAL vendor segment count (the real cost
    driver: the vendor segments internally at 7.8 s / stride 5.85 s and pads
    every chunk to a FULL segment)
  - SDR of each arm's stems against the whole-song REFERENCE stems of the
    SAME repeat (paired), and NSDR (SDR minus the reference's own error
    against the input mixture — BENCHMARKS §1 definition)

The benchmark input is GENERATED (deterministic, seeded) rather than committed:
a 30 s synthetic mix would be >1 MB (AGENTS §4 forbids committing fixtures
>1 MB) and the chunk effects are what matter here, not the audio identity.

Usage:
  PITCHNOTES_DEMUCS_MODEL=/path/ggml-model-htdemucs-4s-f16.bin \
    python3 Tests/Spikes/demucs_chunk_bench.py --seconds 30 --repeats 3
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = Path(os.environ.get("PITCHNOTES_SPIKE_BUILD", REPO_ROOT / "Tests/Spikes/.demucs-build"))
SR = 44100
STEM_NAMES = ("drums", "bass", "other", "vocals")

# The arms under test. `None` policy = the whole-song vendor path (REFERENCE).
ARMS: dict[str, tuple[float, float] | None] = {
    "reference": None,
    "muskeyRecipe": (4.5, 1.0),
    "planDefault": (8.0, 2.0),
}


# --------------------------------------------------------------------------
# Fixture generation (deterministic; not committed — >1 MB policy)
# --------------------------------------------------------------------------

def midi_hz(midi: float) -> float:
    return 440.0 * 2.0 ** ((midi - 69.0) / 12.0)


def _place(buf: np.ndarray, start_s: float, sr: int, piece: np.ndarray) -> None:
    i = int(start_s * sr)
    j = min(i + len(piece), len(buf))
    if j > i:
        buf[i:j] += piece[: j - i]


def _tone(freq: float, n: int, sr: int, amp: float,
          harmonics=((1, 1.0), (2, 0.3), (3, 0.15))) -> np.ndarray:
    t = np.arange(n, dtype=np.float64) / sr
    out = np.zeros(n, dtype=np.float64)
    for mult, a in harmonics:
        out += a * np.sin(2.0 * np.pi * freq * mult * t)
    fade = min(n, int(0.02 * sr))
    if fade > 0:
        env = np.ones(n)
        env[:fade] = np.linspace(0.0, 1.0, fade, endpoint=False)
        env[-fade:] = np.linspace(1.0, 0.0, fade, endpoint=False)
        out *= env
    return amp * out


def make_bench_mix(seconds: float, sr: int = SR) -> np.ndarray:
    """A deterministic, music-shaped mix: a voice-like lead (5 harmonics + 5.5 Hz
    vibrato, note sequence), a sustained chord accompaniment and a bass line.
    Same synthesis family as the committed fixtures (scripts/fixtures/gen.py),
    extended in time so that BOTH arms cross several chunk boundaries."""
    n = int(sr * seconds)
    buf = np.zeros(n, dtype=np.float64)
    rng = np.random.default_rng(0xC4017)

    # --- lead (voice-like: harmonic stack, vibrato, note envelope) ---
    notes = [60, 62, 64, 62, 60, 57, 59, 60]
    note_len = seconds / len(notes)
    for k, midi in enumerate(notes):
        start = k * note_len
        i0 = int(start * sr)
        i1 = min(n, int((start + note_len) * sr))
        if i1 <= i0:
            continue
        tt = np.arange(i1 - i0, dtype=np.float64) / sr
        f0 = midi_hz(midi) * (1.0 + 0.008 * np.sin(2.0 * np.pi * 5.5 * tt))
        phase = 2.0 * np.pi * np.cumsum(f0) / sr
        lead = np.zeros(i1 - i0)
        for mult, a in ((1, 1.0), (2, 0.60), (3, 0.45), (4, 0.28), (5, 0.18)):
            lead += a * np.sin(mult * phase)
        env = np.ones(i1 - i0)
        f = min(int(0.03 * sr), (i1 - i0) // 2)
        if f > 0:
            env[:f] = np.linspace(0.0, 1.0, f, endpoint=False)
            env[-f:] = np.linspace(1.0, 0.0, f, endpoint=False)
        buf[i0:i1] += 0.30 * lead * env

    # --- chord accompaniment (C major / A minor alternation, sustained) ---
    for k in range(int(seconds / (2.0 * note_len)) + 1):
        start = k * 2.0 * note_len
        chord = (48, 52, 55) if (k % 2 == 0) else (45, 52, 57)
        for midi in chord:
            _place(buf, start, sr,
                   _tone(midi_hz(midi), int(2.0 * note_len * sr), sr, 0.10,
                         harmonics=((1, 1.0), (2, 0.2))))

    # --- bass line (root notes, one per bar) ---
    for k in range(int(seconds / (2.0 * note_len)) + 1):
        start = k * 2.0 * note_len
        root = 36 if (k % 2 == 0) else 33
        _place(buf, start, sr,
               _tone(midi_hz(root), int(2.0 * note_len * sr), sr, 0.16,
                     harmonics=((1, 1.0), (2, 0.15))))

    buf += 0.001 * rng.standard_normal(n)
    peak = float(np.max(np.abs(buf))) or 1.0
    return (buf / peak * 0.7).astype(np.float64)


def write_wav(path: Path, samples: np.ndarray, sr: int = SR) -> None:
    import wave
    pcm = np.clip(samples, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def read_wav_mono(path: Path) -> np.ndarray:
    import wave
    with wave.open(str(path)) as w:
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------

def sdr(ref: np.ndarray, est: np.ndarray) -> float:
    """Standard SDR (BENCHMARKS §1): 10·log10( Σref² / Σ(est−ref)² ), ref = target."""
    ref = np.asarray(ref, dtype=np.float64)
    est = np.asarray(est, dtype=np.float64)
    n = min(ref.size, est.size)
    if n == 0:
        return float("-inf")
    r, e = ref[:n], est[:n]
    err_e = float(np.sum((e - r) ** 2))
    sig_e = float(np.sum(r ** 2))
    if sig_e <= 0:
        return float("-inf")
    return 10.0 * np.log10(sig_e / max(err_e, 1e-20))


def nsdr(ref: np.ndarray, est: np.ndarray, mix: np.ndarray) -> float:
    """NSDR (BENCHMARKS §1): SDR(estimate) − SDR(mixture), i.e. the gain over
    using the raw mixture. `ref` stands in for the (unknown) clean target —
    here the whole-song vendor REFERENCE output — and `mix` is the input."""
    return sdr(ref, est) - sdr(ref, mix)


def load_stems(outdir: Path, frames: int) -> dict[str, np.ndarray]:
    stems: dict[str, np.ndarray] = {}
    for name in STEM_NAMES:
        raw = (outdir / f"stem_{name}.f32").read_bytes()
        stems[name] = np.frombuffer(raw, dtype="<f4").astype(np.float64)
    return stems


def stems_all(stems: dict[str, np.ndarray]) -> np.ndarray:
    return np.concatenate([stems[n] for n in STEM_NAMES])


def stems_instrumental(stems: dict[str, np.ndarray]) -> np.ndarray:
    return np.concatenate([stems["drums"] + stems["bass"] + stems["other"]])


# --------------------------------------------------------------------------
# Runner plumbing
# --------------------------------------------------------------------------

def build_runner() -> Path:
    sys.path.insert(0, str(REPO_ROOT / "Tests" / "Spikes"))
    import demucs_real
    return demucs_real.build_runner()


def ensure_model() -> Path:
    sys.path.insert(0, str(REPO_ROOT / "Tests" / "Spikes"))
    import demucs_real
    return demucs_real.ensure_model()


def run_arm(binary: Path, model: Path, wav: Path, outdir: Path,
            policy: tuple[float, float] | None, threads: int) -> dict:
    outdir.mkdir(parents=True, exist_ok=True)
    cmd = [str(binary), str(model), str(wav), str(outdir), "--threads", str(threads)]
    if policy is not None:
        cmd += ["--chunk-window", str(policy[0]), "--chunk-overlap", str(policy[1])]
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    wall = time.time() - t0
    if r.returncode != 0:
        raise RuntimeError(f"demucs_runner rc={r.returncode}: {r.stderr[-800:]}")
    metrics: dict[str, str] = {}
    rms: dict[str, float] = {}
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if parts[0] == "STEM_RMS_DB":
            rms[parts[1]] = float(parts[2])
        elif len(parts) >= 2:
            metrics[parts[0]] = "\t".join(parts[1:])
    if "DONE" not in r.stdout:
        raise RuntimeError(f"demucs_runner incomplete (wall {wall:.1f}s)")
    return {"metrics": metrics, "rms": rms, "outdir": outdir, "wall_s": wall}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seconds", type=float, default=30.0,
                    help="benchmark input length (default 30 s)")
    ap.add_argument("--repeats", type=int, default=3,
                    help="paired repeats per arm (BENCHMARKS §1: median of >=3)")
    ap.add_argument("--threads", type=int, default=1,
                    help="vendor thread count (1 = stock serial, matches the §4 rows)")
    ap.add_argument("--arms", default="reference,muskeyRecipe,planDefault")
    ap.add_argument("--out", default=str(BUILD_DIR / "chunk_bench_report.json"))
    ap.add_argument("--markdown", default=str(BUILD_DIR / "chunk_bench_table.md"))
    args = ap.parse_args()

    arms = [a.strip() for a in args.arms.split(",") if a.strip()]
    for a in arms:
        if a not in ARMS:
            print(f"FAILED: unknown arm {a} (known: {', '.join(ARMS)})")
            return 1

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    binary = build_runner()
    model = ensure_model()
    sha = subprocess.run(["sha256sum", str(model)], capture_output=True,
                         text=True).stdout.split()[0]

    fixture = BUILD_DIR / f"bench_mix_{int(args.seconds)}s.wav"
    if not fixture.exists():
        write_wav(fixture, make_bench_mix(args.seconds))
    mix = read_wav_mono(fixture)

    report: dict = {
        "fixture": str(fixture),
        "fixture_seconds": args.seconds,
        "model": str(model),
        "model_sha256": sha,
        "threads": args.threads,
        "repeats": args.repeats,
        "runs": [],
    }

    for rep in range(args.repeats):
        for arm in arms:
            policy = ARMS[arm]
            tag = f"{arm}-r{rep}"
            outdir = BUILD_DIR / f"out-{tag}"
            if outdir.exists():
                shutil.rmtree(outdir)
            print(f"[{tag}] running … (policy={policy})", flush=True)
            res = run_arm(binary, model, fixture, outdir, policy, args.threads)
            m = res["metrics"]
            frames = int(m["SAMPLES"].split("\t")[0])
            stems = load_stems(outdir, frames)
            row = {
                "arm": arm,
                "repeat": rep,
                "policy": policy,
                "windows": int(m.get("WINDOWS", "1")),
                "vendor_segments": int(m.get("SEGMENTS", "0")),
                "wall_s": float(m["WALL_S"]),
                "rtf": float(m["RTF"]),
                "rss_kb": int(m["RSS_KB"]),
                "model_load_s": float(m["MODEL_LOAD_S"]),
                "rms_db": res["rms"],
                "outdir": str(outdir),
            }
            # SDR against the REFERENCE of the SAME repeat (paired).
            ref_dir = BUILD_DIR / f"out-reference-r{rep}"
            if arm != "reference" and ref_dir.exists():
                ref_stems = load_stems(ref_dir, frames)
                row["sdr_vocals"] = sdr(ref_stems["vocals"], stems["vocals"])
                row["sdr_instrumental"] = sdr(stems_instrumental(ref_stems),
                                              stems_instrumental(stems))
                row["sdr_all_sources"] = sdr(stems_all(ref_stems), stems_all(stems))
                # NSDR: the reference's own distance from the input mixture is
                # the baseline the chunked arm has to beat (BENCHMARKS §1).
                ref_recon = 0.5 * (ref_stems["vocals"][0::2] + ref_stems["vocals"][1::2])
                ref_recon += 0.5 * ((ref_stems["drums"] + ref_stems["bass"]
                                    + ref_stems["other"])[0::2]
                                   + (ref_stems["drums"] + ref_stems["bass"]
                                      + ref_stems["other"])[1::2])
                row["nsdr_all_sources"] = (row["sdr_all_sources"]
                                           - sdr(ref_recon, mix))
            report["runs"].append(row)
            print(f"[{tag}] windows={row['windows']} segments={row['vendor_segments']} "
                  f"wall={row['wall_s']:.1f}s rtf={row['rtf']:.3f} rss={row['rss_kb']/1024:.0f}MB"
                  + (f" sdr_voc={row.get('sdr_vocals', float('nan')):.2f}dB "
                     f"sdr_instr={row.get('sdr_instrumental', float('nan')):.2f}dB "
                     f"sdr_all={row.get('sdr_all_sources', float('nan')):.2f}dB"
                     if "sdr_vocals" in row else ""), flush=True)
            out_path = Path(args.out)
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(json.dumps(report, indent=2))

    # Summary (median + spread per arm).
    summary: dict[str, dict] = {}
    for arm in arms:
        rows = [r for r in report["runs"] if r["arm"] == arm]
        if not rows:
            continue
        def stats(key: str) -> dict:
            vals = [r[key] for r in rows if key in r]
            if not vals:
                return {"median": None, "min": None, "max": None, "n": 0}
            return {"median": float(np.median(vals)), "min": min(vals),
                    "max": max(vals), "n": len(vals)}
        summary[arm] = {
            "rtf": stats("rtf"),
            "wall_s": stats("wall_s"),
            "rss_kb": stats("rss_kb"),
            "windows": stats("windows"),
            "vendor_segments": stats("vendor_segments"),
            "sdr_vocals": stats("sdr_vocals"),
            "sdr_instrumental": stats("sdr_instrumental"),
            "sdr_all_sources": stats("sdr_all_sources"),
            "nsdr_all_sources": stats("nsdr_all_sources"),
        }
    report["summary"] = summary
    Path(args.out).write_text(json.dumps(report, indent=2))

    # Markdown table (BENCHMARKS §4 shape + the measured extras).
    lines = ["| Arm | Window/Overlap | External windows | Vendor segments | Wall (s) | "
             "RTF | Peak RSS (MB) | SDR vocals | SDR instrumental | SDR all src | NSDR all src |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for arm in arms:
        s = summary[arm]
        pol = ARMS[arm]
        pol_s = "whole-song (reference)" if pol is None else f"{pol[0]} s / {pol[1]} s"
        def fmt(d: dict, scale: float = 1.0, digits: int = 2) -> str:
            if d["median"] is None:
                return "n/a"
            return f"{d['median']*scale:.{digits}f} ({d['min']*scale:.{digits}f}–{d['max']*scale:.{digits}f})"
        lines.append(
            f"| {arm} | {pol_s} | {s['windows']['median']:.0f} | {s['vendor_segments']['median']:.0f} | "
            f"{fmt(s['wall_s'], 1.0, 1)} | {fmt(s['rtf'], 1.0, 3)} | {fmt(s['rss_kb'], 1/1024, 0)} | "
            f"{fmt(s['sdr_vocals'])} | {fmt(s['sdr_instrumental'])} | "
            f"{fmt(s['sdr_all_sources'])} | {fmt(s['nsdr_all_sources'])} |")
    table = "\n".join(lines)
    Path(args.markdown).write_text(table + "\n")
    print("\n" + table)
    print(f"\nreport: {args.out}\ntable:  {args.markdown}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
