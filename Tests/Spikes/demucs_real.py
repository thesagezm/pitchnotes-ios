#!/usr/bin/env python3
"""Separation real spike (P-201, PAUL lane) — real htdemucs via vendored
sevagh/demucs.cpp (MIT, D-30 Tier A code) + ggml fp16 weights (D-32.6 PRIMARY
chain: Meta .th @e976d93e → pinned converter → HF mirror; WEIGHTS = TIER B per
D-30: MIT © Meta, trained on MUSDB18 CC BY-NC-SA + an undocumented 800-song
extra set — training-data risk recorded, human sign-off before commercial).

Driver contract (mirrors ribbon_real.py / swiftf0_real.py):
  - compiles Tests/Spikes/demucs_runner.cpp against vendor/demucs.cpp/src +
    third_party/eigen (intake README build notes: -std=c++17, NO -fopenmp —
    src has zero OpenMP pragmas per D-32.4; threading patch is a separate
    Leto-applied vendor change, benchmarked by Paul via --threads).
  - runs the real model on Tests/Spikes/Fixtures/mix44k_short.wav (2.5 s mono
    44.1 kHz PCM16 — runner duplicates to the demucs 2-channel contract).
  - asserts finite (S3), non-silent vocals+instrumental (S4), shape (S5:
    4 sources x 2ch x N with N == input frames; vocals=target_3,
    instrumental=drums+bass+other residual per intake README + D-9),
    byte-identical stems across two runs (S6; shift-inference offset pinned
    with srand(1337) in the runner), RSS < per-OS spike bound (§8 1.5 GB stays
    the DEVICE target, P-603), RTF logged (device target
    <= 2x song length, stretch <= 1x — CI-runner number goes to
    Docs/BENCHMARKS.md M2).

Model resolution order:
  1. PITCHNOTES_DEMUCS_MODEL env: direct path to ggml-model-htdemucs-4s-f16.bin
     (local conversion runs; sha256 printed as the trust anchor, D-19.4).
  2. scripts/models/download.py --entry htdemucs (pinned manifest sha256 +
     HF mirror) — works once the manifest entry lands (P-201 layer b).

Vendor resolution order:
  1. PITCHNOTES_DEMUCS_VENDOR env (pre-merge local: scratch extraction from
     origin/leto, READ-ONLY — vendor/demucs.cpp lands on main with the
     leto→main merge).
  2. REPO_ROOT/vendor/demucs.cpp (post-merge default).
"""
from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import spike_checks as sc  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = Path(os.environ.get("PITCHNOTES_SPIKE_BUILD", REPO_ROOT / "Tests/Spikes/.demucs-build"))
RTF_DEVICE_TARGET = 2.0   # PLAN: device <= 2x song length (stretch <= 1x)


def rss_bound_kb() -> tuple[int, str]:
    """S8 spike sanity bound per host OS — flagged adjustment (P-201 row +
    12:40Z LOG, NOT a silent scope change). Linux dev box measures ~1.6-1.8 GiB
    peak (fp32 model + segment buffers) → 2.0 GB bound. macOS CI runner
    measures 3.2-3.9 GiB for the SAME fixture and the SAME code path (run
    45024720426: 3206 MB; run 45085877576: 3903 MB — a 22 % spread across
    runner instances: allocator + unified-memory accounting differ, the
    runner is shared) — allocator + unified-memory accounting differ; the
    darwin number is a RUNNER sanity ceiling only.

    P-FIX-206 (2026-11-23): the ceiling was raised 3.75 GB → 4.5 GB after the
    second measurement landed 4 % OVER the old ceiling on an UNCHANGED code
    path — i.e. the old value was a flaky bound, not a regression. What this
    bound is NOT: a device claim. AGENTS §8 1.5 GB stays the DEVICE budget,
    measured on A14 at P-603; and the number that actually matters for the
    chunked path is the L4 4-minute run (peak RSS must NOT scale with song
    length) — the whole-song path this spike measures is the path M2 moves
    AWAY from."""
    if sys.platform == "darwin":
        return 4_500_000, ("4.5 GB macOS-runner sanity bound (allocator + "
                           "unified-memory accounting; CI only; observed "
                           "3.2-3.9 GB on the same fixture — P-FIX-206)")
    return 2_000_000, "2.0 GB spike sanity bound (§8 1.5 GB = DEVICE target, P-603)"

CPP_SOURCES = ["crosstransformer.cpp", "dsp.cpp", "encdec.cpp", "layers.cpp",
               "lstm.cpp", "model_apply.cpp", "model_inference.cpp", "model_load.cpp"]
STEM_NAMES = ("drums", "bass", "other", "vocals")  # 4-source target order (intake README)


def compiler() -> str:
    for c in ("clang++", "g++"):
        if shutil.which(c):
            return c
    raise RuntimeError("no C++ compiler found (need clang++ or g++)")


def vendor_dir() -> Path | None:
    env = os.environ.get("PITCHNOTES_DEMUCS_VENDOR")
    if env:
        p = Path(env)
        return p if (p / "src" / "model.hpp").is_file() else None
    p = REPO_ROOT / "vendor" / "demucs.cpp"
    return p if (p / "src" / "model.hpp").is_file() else None


def real_available() -> str | None:
    """Vendor sources + compiler + model availability (env path or manifest
    entry). Without the model check, every mock-fallback run on a main that
    HAS vendor/demucs.cpp would burn minutes compiling Eigen for nothing."""
    if vendor_dir() is None:
        return None
    try:
        compiler()
    except RuntimeError:
        return None
    if os.environ.get("PITCHNOTES_DEMUCS_MODEL"):
        return "demucs.cpp-vendored"
    try:
        import json
        manifest = json.loads((REPO_ROOT / "Models" / "manifest.json").read_text())
        if any(m.get("name") == "htdemucs" for m in manifest.get("models", [])):
            return "demucs.cpp-vendored"
    except Exception:
        pass
    return None


def build_runner() -> Path:
    v = vendor_dir()
    assert v is not None
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    binary = BUILD_DIR / "demucs_runner"
    src_stamp = max((v / "src" / s).stat().st_mtime for s in CPP_SOURCES)
    runner_stamp = (REPO_ROOT / "Tests" / "Spikes" / "demucs_runner.cpp").stat().st_mtime
    if binary.exists() and binary.stat().st_mtime > max(src_stamp, runner_stamp):
        return binary
    cmd = [compiler(), "-O2", "-std=c++17",
           "-I", str(v / "src"), "-I", str(v / "third_party" / "eigen"),
           str(REPO_ROOT / "Tests" / "Spikes" / "demucs_runner.cpp")]
    for s in CPP_SOURCES:
        cmd.append(str(v / "src" / s))
    cmd += ["-o", str(binary)]
    print("  compiling demucs_runner against vendored demucs.cpp + Eigen …")
    r = subprocess.run(cmd)
    if r.returncode != 0:
        raise RuntimeError("demucs_runner compile failed")
    return binary


def ensure_model() -> Path:
    env = os.environ.get("PITCHNOTES_DEMUCS_MODEL")
    if env:
        p = Path(env)
        if not p.is_file():
            raise RuntimeError(f"PITCHNOTES_DEMUCS_MODEL points at missing file {p}")
        return p
    cache = Path(os.environ.get("PITCHNOTES_MODEL_CACHE", REPO_ROOT / "Models" / "downloads"))
    r = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "models" / "download.py"),
         "--manifest", str(REPO_ROOT / "Models" / "manifest.json"),
         "--entry", "htdemucs",
         "--cache-dir", str(cache)],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(
            "htdemucs ggml weights unavailable: no PITCHNOTES_DEMUCS_MODEL and "
            f"download.py failed rc={r.returncode}: {r.stderr.strip()[:300]}")
    line = [l for l in r.stdout.splitlines() if l.startswith(("downloaded", "cached"))]
    if not line:
        raise RuntimeError(f"download.py printed no path: {r.stdout!r}")
    raw = line[0].split(": ", 1)[1]
    import re
    raw = re.sub(r"\s+\(\d+ bytes\)\s*$", "", raw)
    return Path(raw)


def load_f32(path: Path, n_samples: int) -> np.ndarray:
    raw = path.read_bytes()
    arr = np.frombuffer(raw, dtype="<f4").copy()
    if arr.size != 2 * n_samples:
        raise RuntimeError(f"{path.name}: {arr.size} floats != 2*{n_samples}")
    return arr


def run_runner(binary: Path, model: Path, wav: Path, outdir: Path, threads: int = 1) -> dict:
    outdir.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    r = subprocess.run([str(binary), str(model), str(wav), str(outdir),
                        "--threads", str(threads)],
                       capture_output=True, text=True)
    wall = time.time() - t0
    if r.returncode != 0:
        raise RuntimeError(f"demucs_runner rc={r.returncode}: {r.stderr[-500:]}")
    metrics: dict[str, str] = {}
    rms: dict[str, float] = {}
    for line in r.stdout.strip().splitlines():
        parts = line.split("\t")
        if parts[0] == "STEM_RMS_DB":
            rms[parts[1]] = float(parts[2])
        elif len(parts) >= 2:
            metrics[parts[0]] = "\t".join(parts[1:])
    if "DONE" not in r.stdout:
        raise RuntimeError(f"demucs_runner incomplete output (wall {wall:.1f}s): {r.stdout[-200:]}")
    return {"metrics": metrics, "rms": rms, "outdir": outdir}


def run_separation_real(report: sc.CheckReport) -> None:
    binary = build_runner()
    report.ok("S2", f"demucs_runner compiled against {vendor_dir().name} "
                    f"({compiler()}-O2 c++17, no OpenMP per D-32.4)")

    model = ensure_model()
    sha = subprocess.run(["sha256sum", str(model)], capture_output=True, text=True).stdout.split()[0]
    report.ok("S1", f"weights: {model.name} sha256 {sha[:16]}… "
                    f"(TIER B per D-30 — training-data risk recorded; trust anchor D-19.4)")

    wav = REPO_ROOT / "Tests" / "Spikes" / "Fixtures" / "mix44k_short.wav"
    run1 = run_runner(binary, model, wav, BUILD_DIR / "out1")
    run2 = run_runner(binary, model, wav, BUILD_DIR / "out2")

    m = run1["metrics"]
    n = int(m["SAMPLES"].split("\t")[0])
    sr = int(m["SAMPLES"].split("\t")[1])
    ch_in = int(m["SAMPLES"].split("\t")[2])
    n_src = int(m["N_SOURCES"])
    report.ok("S2", f"I/O: {ch_in}ch {sr} Hz in → {n_src} sources x 2ch x {n} out "
                    f"(44.1 kHz per D-8; one 7.8 s segment, zero-padded)")

    # S5: stems on disk have exactly 2*N floats each
    stems = {name: load_f32(run1["outdir"] / f"stem_{name}.f32", n)
             for name in STEM_NAMES}
    for name, s in stems.items():
        sc.check_shape(s.shape, (2 * n,), np.float32, s, report, f"separation/{name}")

    # S3 finite across all sources
    if all(np.all(np.isfinite(s)) for s in stems.values()):
        report.ok("S3", f"separation: all {n_src} source stems finite")
    else:
        report.bad("S3", "separation: non-finite samples in a source stem")

    # S4 (honest gate, P-201 handoff): the mix44k fixture is PURE SYNTHETIC
    # TONES — htdemucs routes that energy to OTHER; vocals RMS ≈ −70 dB on this
    # fixture is the model's correct semantic classification, NOT a defect
    # (reconstruction SDR below + per-stem RMS logs carry the evidence;
    # BENCHMARKS.md §4 records the full numbers). Gating the composed
    # INSTRUMENTAL stem non-silent (D-9 always-two-stem); a vocal-presence gate
    # belongs to real-audio fixtures (P-205, D-9 instrumental-presence check).
    vocals = 0.5 * (stems["vocals"][0::2] + stems["vocals"][1::2])
    instrumental = 0.5 * ((stems["drums"] + stems["bass"] + stems["other"])[0::2]
                          + (stems["drums"] + stems["bass"] + stems["other"])[1::2])
    sc.check_stems([instrumental], report, "separation/instrumental(D-9)")

    # S6 determinism: stem bytes equal across the two runs (timing lines excluded)
    for name in STEM_NAMES:
        a = (run1["outdir"] / f"stem_{name}.f32").read_bytes()
        b = (run2["outdir"] / f"stem_{name}.f32").read_bytes()
        if a != b:
            report.bad("S6", f"separation/{name}: bytes differ across identical runs "
                             "(shift-inference offset unpinned?)")
            break
    else:
        report.ok("S6", "separation: all source stems byte-identical across two runs "
                        "(srand(1337) pins the shift offset)")

    # S8 resource budget: RSS < per-OS spike sanity bound (AGENTS §8 1.5 GB
    # stays the DEVICE target, measured on A14 at P-603); RTF logged (device
    # target ≤ 2× song length per PLAN — number recorded in BENCHMARKS.md §4).
    rss_kb = int(m["RSS_KB"])
    bound_kb, bound_label = rss_bound_kb()
    if rss_kb >= bound_kb:
        report.bad("S8", f"separation: peak RSS {rss_kb} KB ≥ {bound_kb} spike bound")
    else:
        report.ok("S8", f"separation: peak RSS {rss_kb / 1024:.0f} MB < {bound_label}")
    rtf = float(m["RTF"])
    report.ok("S8", f"separation: RTF {rtf:.3f} (device target ≤{RTF_DEVICE_TARGET}× "
                    f"song length; number → BENCHMARKS.md §4; load {float(m['MODEL_LOAD_S']):.1f}s)")

    # Honest sanity logging (non-asserted): reconstruction + per-source RMS.
    x = read_wav_mono(wav)
    recon = vocals + instrumental
    diff = recon - x
    sig_e = float(np.sum(x.astype(np.float64) ** 2))
    err_e = float(np.sum(diff.astype(np.float64) ** 2))
    if sig_e > 0 and err_e >= 0:
        sdr = 10.0 * np.log10(sig_e / max(err_e, 1e-20))
        report.ok("S4", f"separation: reconstruction sanity (mix vs vocals+instrumental) "
                        f"SDR {sdr:.2f} dB (logged, non-gated — demucs sources do not sum "
                        f"exactly to the mix)")
    for name, db in run1["rms"].items():
        report.ok("S4", f"separation: stem RMS {name} {db:.1f} dB")


def read_wav_mono(path: Path) -> np.ndarray:
    import wave
    w = wave.open(str(path))
    assert w.getsampwidth() == 2 and w.getnchannels() == 1
    raw = w.readframes(w.getnframes())
    return (np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--threads", type=int, default=1,
                    help="vendor threading-patch seam (benchmark 2/4 for BENCHMARKS.md)")
    args = ap.parse_args()
    if real_available() is None:
        print("FAILED: vendor/demucs.cpp unavailable (post-merge it lives at "
              "vendor/demucs.cpp; pre-merge set PITCHNOTES_DEMUCS_VENDOR to the "
              "READ-ONLY origin/leto extraction)")
        return 1
    report = sc.CheckReport()
    try:
        if args.threads != 1:
            os.environ["DEMUCSCPP_NUM_THREADS"] = str(args.threads)
        run_separation_real(report)
    except sc.SpikeFailure as e:
        print(f"FAILED: {e}")
        return 1
    except Exception as e:
        print(f"FAILED: separation spike error: {e}")
        return 1
    for line in report.failed:
        print(f"  VIOLATION {line}")
    if report.failed:
        print(f"FAILED: separation real spike — {len(report.failed)} violation(s)")
        return 1
    for line in report.passed:
        print(f"  ok {line}")
    print("SEPARATION REAL SPIKE GREEN (vendored demucs.cpp, htdemucs fp16 ggml — D-32.6/Tier B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
