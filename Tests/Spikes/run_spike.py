#!/usr/bin/env python3
"""Spike harness runner (P-002, PAUL lane).

CI invocation (Leto's five frozen job names each call exactly this):
    python3 Tests/Spikes/run_spike.py --spike swiftf0
    python3 Tests/Spikes/run_spike.py --spike nanopitch
    python3 Tests/Spikes/run_spike.py --spike separation
    python3 Tests/Spikes/run_spike.py --spike basicpitch
    python3 Tests/Spikes/run_spike.py --spike silero-vad
    python3 Tests/Spikes/run_spike.py --spike all

M0: runs the DETERMINISTIC MOCK model (no weights downloaded) against the
P-001 fixtures and asserts the full spike contract (S1–S8 in spike_checks.py).
Real-model wiring points are documented in mock_model.py + README.md.

Exit codes: 0 = all checks green, 1 = contract violations / missing fixtures.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import spike_checks as sc  # noqa: E402
import mock_model as mm  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
SPIKE_NAMES = ("swiftf0", "nanopitch", "silero-vad", "separation", "basicpitch")


def normalize(name: str) -> str:
    """Accept CI job names (swiftf0-spike) and bare names (swiftf0)."""
    name = {"silero-vad-spike": "silero-vad"}.get(name, name)
    return name.removesuffix("-spike")


def preflight_fixtures() -> None:
    """Integrity gate: committed fixture bytes must match fixtures.sha256."""
    gen = REPO_ROOT / "scripts" / "fixtures" / "gen.py"
    r = subprocess.run([sys.executable, str(gen), "--check"], capture_output=True, text=True)
    if r.returncode != 0:
        raise sc.SpikeFailure(f"fixture integrity failed:\n{r.stderr.strip()}")


def run_swiftf0(report: sc.CheckReport) -> None:
    out = mm.mock_swiftf0()
    report2 = sc.CheckReport()
    sc.check_pitch_frames(out["frames"], report2, "swiftf0/sweep")
    sc.check_shape(out["frames"].shape, mm.CONTRACTS["swiftf0"]["frames"][0](out), np.float32, out["frames"], report2, "swiftf0/frames")
    sc.check_shape(out["loudness_db"].shape, mm.CONTRACTS["swiftf0"]["loudness_db"][0](out), np.float32, out["loudness_db"], report2, "swiftf0/loudness")
    # Behavioral: the sweep is in-band nearly everywhere — expect substantial voicing.
    voiced = int(np.sum(out["frames"][:, 1] > 0))
    if voiced < 100:
        report2.bad("S4", f"swiftf0/sweep: only {voiced} voiced frames (expected >100 on in-band sweep)")
    else:
        report2.ok("S4", f"swiftf0/sweep: {voiced} voiced frames")
    determinism(report2, "swiftf0", mm.mock_swiftf0)
    report.passed += report2.passed
    report.failed += report2.failed


def run_nanopitch(report: sc.CheckReport) -> None:
    out = mm.mock_nanopitch()
    r2 = sc.CheckReport()
    sc.check_pitch_frames(out["frames"], r2, "nanopitch/sweep")
    sc.check_shape(out["vad"].shape, mm.CONTRACTS["nanopitch"]["vad"][0](out), np.float32, out["vad"], r2, "nanopitch/vad")
    if not out["vad"].any():
        r2.bad("S4", "nanopitch: VAD never fires on voiced fixture")
    else:
        r2.ok("S4", f"nanopitch: VAD fires on {int(out['vad'].sum())} frames")
    determinism(r2, "nanopitch", mm.mock_nanopitch)
    report.passed += r2.passed
    report.failed += r2.failed


def run_silero(report: sc.CheckReport) -> None:
    out = mm.mock_silero_vad()
    r2 = sc.CheckReport()
    probs = out["speech_probs"]
    sc.check_vad_probs(probs, r2, "silero-vad/all-fixtures")
    sc.check_shape(probs.shape, (len(probs),), np.float32, probs, r2, "silero-vad/probs")
    silence = probs[: 66]           # silence_16k: 2 s / 30 ms
    burst = probs[66: 66 + 33]      # noise_burst: 1 s / 30 ms
    clicks = probs[99:]             # click_track: 8 s / 30 ms
    if float(np.mean(silence)) > 0.2:
        r2.bad("S4", f"silero-vad: silence mean prob {float(np.mean(silence)):.3f} > 0.2")
    else:
        r2.ok("S4", f"silero-vad: silence gated (mean prob {float(np.mean(silence)):.3f})")
    if float(np.max(burst)) < 0.5:
        r2.bad("S4", f"silero-vad: burst max prob {float(np.max(burst)):.3f} < 0.5")
    else:
        r2.ok("S4", f"silero-vad: burst detected (max prob {float(np.max(burst)):.3f})")
    if float(np.max(clicks)) < 0.5:
        r2.bad("S4", "silero-vad: clicks never exceed 0.5 prob")
    else:
        r2.ok("S4", "silero-vad: clicks detected")
    determinism(r2, "silero-vad", mm.mock_silero_vad)
    report.passed += r2.passed
    report.failed += r2.failed


def run_separation(report: sc.CheckReport) -> None:
    out = mm.mock_separation()
    r2 = sc.CheckReport()
    stems = [out["stem0"], out["stem1"]]
    x, sr = mm.load_wav("satb_mixture_16k.wav")
    for k, s in enumerate(stems):
        sc.check_shape(s.shape, (len(x),), np.float32, s, r2, f"separation/stem{k}")
    sc.check_stems(stems, r2, "separation/satb")
    determinism(r2, "separation", mm.mock_separation)
    report.passed += r2.passed
    report.failed += r2.failed


def run_basicpitch(report: sc.CheckReport) -> None:
    out = mm.mock_basicpitch()
    r2 = sc.CheckReport()
    events = out["note_events"]
    notes = [dict(start_s=float(e[0]), end_s=float(e[1]), midi=int(e[2]), confidence=float(e[3]))
             for e in events]
    sc.check_note_events(notes, r2, "basicpitch/mix44k")
    if events.dtype != np.float32:
        r2.bad("S5", f"basicpitch/events: dtype {events.dtype} != float32")
    else:
        r2.ok("S5", f"basicpitch/events: {events.shape} dtype float32")
    determinism(r2, "basicpitch", mm.mock_basicpitch)
    report.passed += r2.passed
    report.failed += r2.failed


def determinism(report: sc.CheckReport, context: str, fn) -> None:
    a = mm.serialize_outputs(fn())
    b = mm.serialize_outputs(fn())
    sc.check_determinism(a, b, report, context)


RUNNERS = {
    "swiftf0": run_swiftf0,
    "nanopitch": run_nanopitch,
    "silero-vad": run_silero,
    "separation": run_separation,
    "basicpitch": run_basicpitch,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--spike", required=True,
                    help=f"one of {', '.join(SPIKE_NAMES)} (also accepts *-spike job names) or 'all'")
    args = ap.parse_args()
    try:
        preflight_fixtures()
        print("preflight: fixture integrity OK (fixtures.sha256)")
    except sc.SpikeFailure as e:
        print(f"FAILED: {e}")
        return 1
    except Exception as e:  # numpy missing, etc.
        print(f"FAILED: harness preflight error: {e}")
        return 1

    names = list(SPIKE_NAMES) if args.spike == "all" else [normalize(args.spike)]
    report = sc.CheckReport()
    rc = 0
    for name in names:
        if name not in RUNNERS:
            print(f"FAILED: unknown spike '{name}' (known: {', '.join(SPIKE_NAMES)})")
            return 1
        before = len(report.failed)
        try:
            RUNNERS[name](report)
            if len(report.failed) > before:
                print(f"FAILED: {name}-spike (mock) — {len(report.failed) - before} violation(s)")
                rc = 1
            else:
                print(f"PASSED: {name}-spike (mock) — {len(report.passed)} checks green")
        except sc.SpikeFailure as e:
            print(f"FAILED: {name}-spike: {e}")
            rc = 1
    for line in report.failed:
        print(f"  VIOLATION {line}")
    if rc == 0:
        for line in report.passed:
            print(f"  ok {line}")
        print("ALL SPIKE CHECKS GREEN (mock; real models wire in at M1/M2/M3)")
    return rc


if __name__ == "__main__":
    sys.exit(main())
