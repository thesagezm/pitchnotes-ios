#!/usr/bin/env python3
"""Pitch bench harness v1 (P-106, PAUL lane) — F1@50c per Docs/BENCHMARKS.md §1.

Metrics (§1, fixed v0 — do not drift without a Leto ruling):
  hit       = est voiced AND ref voiced AND |1200·log2(f_est/f_ref)| < 50 cents
  precision = hits / est-voiced    recall = hits / ref-voiced
  F1        = 2·P·R/(P+R)          (0 when P+R == 0)
  RPA       = hits / ref-voiced    (raw pitch accuracy, mir_eval convention)
  RCA       = hits / ref-voiced with octave errors folded (min |cents| over
              est·2^s, s ∈ [−2..2] — raw chroma accuracy)
Voicing: hz > 0 (contract V11 semantics); ref voiced: truth > 0.

Engines × fixtures (all synthetic, seeded, committed):
  swiftf0     (pinned ONNX 1-thread, real)   sweep_46_2100Hz_16k + synthetic_voice_16k
  ribbon-cpp  (vendored sevagh MPM, D-19)    synthetic_voice_16k + sweep@1024
  ribbon-swift(EngineCore RibbonEngine)      synthetic_voice_16k + sweep@1024
              — built from ribbon_swift_bench/main.swift via swiftc; SKIPPED
                (loud note) when swiftc or EngineCore sources are absent, e.g.
                CI ubuntu — the dev-box numbers live in BENCHMARKS.md.

Truth pairing: swiftf0 frames are attributed to their 256-sample frame CENTER
(spike convention); ribbon frames to their 1024-sample window CENTER (Swift
emits window END → center = t − 32 ms; the C++ runner emits window START →
center = t + 32 ms — same physical convention, P-102).

Output: markdown table on stdout + Tests/Spikes/bench_report_v1.json
(committed artifact; deterministic — timing/RSS are stdout-only).

Run locally:
  ~/.venvs/pitchnotes/bin/python -I Tests/Spikes/bench_f1.py            # report
  ~/.venvs/pitchnotes/bin/python -I Tests/Spikes/bench_f1.py --assert   # exit 1 on target miss
  (PATH needs swiftc for the ribbon-swift rows; CI: numpy + onnxruntime venv)

AC (PLAN P-106 / §2 target): synthetic clean F1@50c ≥ 0.75 — asserted on every
engine row that RAN (skipped rows are excluded loudly, never silently).
"""
from __future__ import annotations

import argparse
import json
import resource
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "fixtures"))

import gen as fixtures  # noqa: E402  (P-001 generator — shared truth functions)
import swiftf0_real as sfr  # noqa: E402  (P-101 machinery: model, grid, gating)
import ribbon_real as rr  # noqa: E402  (P-102 machinery: vendored C++ runner)

REPO_ROOT = Path(__file__).resolve().parents[2]
SPIKES = Path(__file__).resolve().parent
FX = SPIKES / "Fixtures"
SR = 16000
WINDOW = 1024
CENTS_TOL = 50.0
TARGET_F1 = 0.75  # PLAN §0 / BENCHMARKS §2: live monophonic pitch F1@50c (synthetic clean)

ROW_FIXTURES = (("sweep_46_2100Hz_16k", fixtures.sweep_f0),
                ("synthetic_voice_16k", fixtures.synthetic_voice_f0))


def truth_at(t_center: np.ndarray, truth_fn) -> np.ndarray:
    """Truth F0 at frame-center times (0.0 where silent — V11 semantics)."""
    f = truth_fn(np.asarray(t_center, dtype=np.float64))
    return np.where(np.isfinite(f) & (f > 0), f, 0.0)


def metrics(hz_est: np.ndarray, hz_ref: np.ndarray) -> dict:
    """F1@50c / RPA / RCA per BENCHMARKS §1 over 1:1 frame-aligned arrays."""
    assert hz_est.shape == hz_ref.shape, f"grid mismatch: {hz_est.shape} vs {hz_ref.shape}"
    est_v = hz_est > 0
    ref_v = hz_ref > 0
    both = est_v & ref_v
    n_est, n_ref = int(est_v.sum()), int(ref_v.sum())
    n_hits = 0
    n_hits_chroma = 0
    cents_abs = np.array([])
    if both.any():
        cents = 1200.0 * np.log2(hz_est[both] / hz_ref[both])
        cents_abs = np.abs(cents)
        n_hits = int((cents_abs < CENTS_TOL).sum())
        # RCA: octave-folded error (min |cents + 1200·s| over s ∈ [−2..2]).
        folded = np.min(np.abs(cents[None, :] + 1200.0 * np.arange(-2, 3)[:, None]), axis=0)
        n_hits_chroma = int((folded < CENTS_TOL).sum())
    p = n_hits / n_est if n_est else 0.0
    r = n_hits / n_ref if n_ref else 0.0
    f1 = 2.0 * p * r / (p + r) if (p + r) > 0 else 0.0
    rca = n_hits_chroma / n_ref if n_ref else 0.0
    return {
        "F1": round(f1, 4), "RPA": round(r, 4), "RCA": round(rca, 4),
        "precision": round(p, 4),
        "n_est_voiced": n_est, "n_ref_voiced": n_ref, "n_hits": n_hits,
        "n_frames": int(hz_est.shape[0]),
        "cents_med": round(float(np.median(cents_abs)), 2) if cents_abs.size else None,
        "cents_p95": round(float(np.percentile(cents_abs, 95)), 2) if cents_abs.size else None,
    }


def bench_swiftf0(sess, report_rows: list, skipped: list) -> None:
    model_sha = json.loads((REPO_ROOT / "Models" / "manifest.json").read_text())
    sha = [m["sha256"] for m in model_sha["models"] if m["name"] == "swiftf0"][0]
    for stem, truth_fn in ROW_FIXTURES:
        audio = sfr.read_wav_mono(FX / f"{stem}.wav")
        pitch, conf_raw = sfr.run_session(sess, audio)
        conf, _ = sfr.postprocess(audio, conf_raw)
        hz = np.where(conf >= sfr.VOICED_THRESHOLD, pitch, 0.0)
        n = conf.shape[0]
        t_center = (np.arange(n) * sfr.HOP + sfr.HOP // 2) / SR
        m = metrics(hz, truth_at(t_center, truth_fn))
        # Official RTF rows stay the median-of-5 §1 numbers in BENCHMARKS.md;
        # the JSON carries accuracy only (deterministic artifact).
        m.update(engine="swiftf0", fixture=stem, model_sha256=sha)
        report_rows.append(m)


def _build_swift_bench() -> tuple[Path | None, str | None]:
    src = SPIKES / "ribbon_swift_bench" / "main.swift"
    engine = REPO_ROOT / "Engine" / "Sources" / "EngineCore" / "Pitch"
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        return None, "swiftc not on PATH — ribbon-swift rows skipped (dev-box numbers in BENCHMARKS.md)"
    if not src.is_file() or not (engine / "RibbonMPM.swift").is_file():
        return None, "ribbon_swift_bench/main.swift or EngineCore sources missing — skipped"
    build_dir = SPIKES / ".bench-build"
    build_dir.mkdir(parents=True, exist_ok=True)
    binary = build_dir / "ribbon_swift_bench"
    newest_src = max(src.stat().st_mtime,
                     max((engine / f).stat().st_mtime for f in ("RibbonMPM.swift", "PCMWaveReader.swift")))
    if not binary.exists() or binary.stat().st_mtime < newest_src:
        cmd = [swiftc, "-O", str(src), str(engine / "RibbonMPM.swift"),
               str(engine / "PCMWaveReader.swift"), "-o", str(binary)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"ribbon_swift_bench compile failed:\n{r.stderr[-2000:]}")
    return binary, None


def bench_ribbon(report_rows: list, skipped: list) -> None:
    # Swift MPM (EngineCore RibbonEngine) — same engine the P-105 facade ships.
    binary, note = _build_swift_bench()
    if binary is None:
        skipped.append(f"ribbon-swift: {note}")
        print(f"  [bench] SKIP {note}")
    else:
        for stem, truth_fn in ROW_FIXTURES:
            tsv = SPIKES / ".bench-build" / f"{stem}.tsv"
            r = subprocess.run([str(binary), str(FX / f"{stem}.wav"), str(tsv)],
                               capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError(f"ribbon_swift_bench failed on {stem}:\n{r.stderr[-2000:]}")
            rows = [line.split("\t") for line in tsv.read_text().strip().splitlines()]
            t_end = np.array([float(x[0]) for x in rows])
            hz = np.array([float(x[1]) for x in rows])
            t_center = t_end - 0.5 * WINDOW / SR  # Swift emits window END
            m = metrics(hz, truth_at(t_center, truth_fn))
            m.update(engine="ribbon-swift", fixture=stem)  # RTF: measured at P-102/P-105 (0.093), not re-logged here
            report_rows.append(m)

    # Vendored C++ (sevagh MPM/YIN, D-19) — the shipping app hot path via X-009.
    try:
        cpp = rr.build_runner()
    except Exception as e:  # vendor/ absent (e.g. shallow CI checkout) — loud skip
        skipped.append(f"ribbon-cpp: vendored runner unavailable ({e})")
        print(f"  [bench] SKIP ribbon-cpp: {e}")
        return
    for stem, truth_fn in ROW_FIXTURES:
        t, hz, _rtf = rr.run_runner(cpp, FX / f"{stem}.wav", window=WINDOW, hop=256)
        t_center = t + 0.5 * WINDOW / SR  # C++ runner emits window START (P-102)
        m = metrics(hz, truth_at(t_center, truth_fn))
        m.update(engine="ribbon-cpp", fixture=stem)  # RTF 0.0014 measured at P-102
        report_rows.append(m)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--assert", dest="assert_target", action="store_true",
                    help="exit 1 when any engine row that RAN misses the §2 F1 ≥ 0.75 target")
    ap.add_argument("--out", default=str(SPIKES / "bench_report_v1.json"),
                    help="report JSON path (default: committed artifact)")
    args = ap.parse_args()

    if sfr.real_available() is None:
        print("FAILED: onnxruntime not importable — bench needs the spike venv "
              "`pip install numpy onnxruntime` (Tests/Spikes/README.md)")
        return 1

    report_rows: list[dict] = []
    skipped: list[str] = []
    try:
        sess = sfr.load_session(sfr.ensure_model(), threads=1)
        bench_swiftf0(sess, report_rows, skipped)
        bench_ribbon(report_rows, skipped)
    except Exception as e:
        print(f"FAILED: bench harness error: {e}")
        return 1

    rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0  # Linux: KiB
    asserted = report_rows
    misses = [r for r in asserted if r["F1"] < TARGET_F1]
    report = {
        "schema": "pitchnotes.bench.v1",
        "methodology": "BENCHMARKS.md §1 — hit iff est voiced AND ref voiced AND |cents|<50; "
                       "F1=2PR/(P+R); RPA=hits/ref-voiced; RCA=octave-folded ±2 oct; voicing hz>0 (V11)",
        "target": {"F1@50c synthetic clean": TARGET_F1, "source": "PLAN §0 / BENCHMARKS §2"},
        "rows": report_rows,
        "skipped": skipped,
        "rss_dev_box_mb_note": f"n/m for the A14 budget — dev box peak RSS ~{rss_mb:.0f} MB (stdout only)",
    }
    out = Path(args.out)
    out.write_text(json.dumps(report, indent=2) + "\n")

    print("  [bench] F1@50c report (BENCHMARKS §1; target ≥ %.2f) → %s" % (TARGET_F1, out.name))
    print("  %-14s %-22s %6s %6s %6s %6s  %s" %
          ("engine", "fixture", "F1", "RPA", "RCA", "prec", "voiced est/ref · hits · |cents| med/p95"))
    for r in report_rows:
        print("  %-14s %-22s %6.3f %6.3f %6.3f %6.3f  %d/%d · %d · %s/%s" %
              (r["engine"], r["fixture"], r["F1"], r["RPA"], r["RCA"], r["precision"],
               r["n_est_voiced"], r["n_ref_voiced"], r["n_hits"], r["cents_med"], r["cents_p95"]))
    for s in skipped:
        print(f"  [bench] SKIPPED: {s}")
    if args.assert_target:
        if misses:
            for r in misses:
                print(f"  [bench] TARGET MISS: {r['engine']}@{r['fixture']} F1 {r['F1']} < {TARGET_F1}")
            print(f"FAILED: {len(misses)} row(s) under the §2 target")
            return 1
        print(f"  [bench] ASSERT OK: all {len(asserted)} engine rows ≥ {TARGET_F1}")
    print("PITCH BENCH V1 DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
