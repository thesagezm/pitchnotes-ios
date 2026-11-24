#!/usr/bin/env python3
"""The C-7 NON-VACUITY PROOF for the basicpitch spike (P-301, PAUL lane).

"A parity gate that cannot fail is not a gate."

This script corrupts the C++ side of the pipeline IN A SCRATCH COPY (the
repo's sources are never touched — `vendor/**` is Leto's lane per AGENTS §12
and is never edited here) and proves that the spike's gates REJECT the
corrupted build:

  CORRUPTION 1 — THE AXIS ORDER. The tensor dump is rewritten from the
      row-major [time][freq] layout to a column-major one. This is the exact
      confusion the vendored upstream code invites (its `swap_layout()` reshapes
      the MEMORY but keeps the logical order), it keeps the SHAPE identical,
      and it is invisible to any shape-only assertion.
      MUST BE CAUGHT by: the cross-implementation TENSOR PARITY gate (S4).

  CORRUPTION 2 — THE NAIVE FRAME MAPPING. `frameToSeconds` falls back to the
      naive `frame * 256 / 22050` instead of the chunk-aware mapping. This is
      the DRIFT bug P-301 found: ~5.2 ms per second of audio, so on a 4-minute
      song the tail is ~1.25 s late. On the SHORT fixtures the 50 ms truth
      budget may NOT see it — which is exactly why the spike also carries the
      unit checks (S9). This script measures which gate catches it and
      reports the numbers honestly.

A corruption that NO gate catches is a VACUITY RISK and the script fails.

HOW TO RUN
    python3 -I Tests/Spikes/basicpitch_real.py          # the spike (dumps)
    python3 -I Tests/Spikes/basicpitch_corruption_proof.py
It needs the same environment as the spike (the ORT headers/lib + the
pinned weights).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import basicpitch_real as br  # noqa: E402
import basicpitch_ref as ref  # noqa: E402

SCRATCH = br.BUILD_DIR / "corrupt"

# The dump line the corruption rewrites (the runner's row-major [time][freq]
# contract). The corrupted form keeps the same SHAPE and the same byte count,
# so only a VALUE comparison can see it.
DUMP_ORIGINAL = """            out[static_cast<std::size_t>(i) * static_cast<std::size_t>(freq_bins) +
                static_cast<std::size_t>(f)] = t(i, f);"""
DUMP_CORRUPTED = """            out[static_cast<std::size_t>(f) * static_cast<std::size_t>(time_frames) +
                static_cast<std::size_t>(i)] = t(i, f);"""

# The chunk-aware mapping (correct) vs the naive one (the drift bug).
MAP_ORIGINAL = """    const long long sample = chunk * kChunkHop + within * kFrameHop;"""
MAP_CORRUPTED = """    const long long sample = frame * kFrameHop;"""


def _compile(source: Path, binary: Path, include_dirs: list[Path]) -> None:
    v = br.vendor_dir()
    assert v is not None
    include_dir, link_candidates, _ = br.resolve_ort()
    cmd = [br.compiler(), "-O2", "-std=c++20",
           "-I", str(v / "src"),
           "-I", str(br.eigen_dir()),
           "-I", str(include_dir),
           "-I", str(br._include_shim_dir())]
    cmd += [f"-I{d}" for d in include_dirs]
    cmd += [str(source)]
    for s in br.VENDOR_SOURCES:
        cmd.append(str(v / "src" / s))
    forwarder = br._vendor_decode_forwarder()
    if forwarder is not None:
        cmd.append(str(forwarder))
    # The same ordered link strategies as the real spike (the SHIPPED form
    # first) — the proof must link exactly like the thing it proves.
    br._compile_and_link(cmd, link_candidates, binary, f"corrupted runner ({source.name})")


def _corrupted_runner(tag: str) -> Path:
    """A scratch copy of the runner with the column-major dump corruption."""
    SCRATCH.mkdir(parents=True, exist_ok=True)
    src = HERE / "basicpitch_runner.cpp"
    text = src.read_text()
    if DUMP_ORIGINAL not in text:
        raise RuntimeError("the runner's dump line changed — update the corruption proof")
    out = SCRATCH / f"basicpitch_runner_{tag}.cpp"
    out.write_text(text.replace(DUMP_ORIGINAL, DUMP_CORRUPTED))
    return out


def _corrupted_header(tag: str) -> Path:
    """A scratch copy of the header with the naive frame mapping."""
    SCRATCH.mkdir(parents=True, exist_ok=True)
    src = br.REPO_ROOT / "Engine" / "Transcription" / "BasicPitchNotes.hpp"
    text = src.read_text()
    if MAP_ORIGINAL not in text:
        raise RuntimeError("the frame mapping changed — update the corruption proof")
    d = SCRATCH / f"header_{tag}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "BasicPitchNotes.hpp").write_text(text.replace(MAP_ORIGINAL, MAP_CORRUPTED))
    return d


def _run_binary(binary: Path, model: Path, wav: Path, outdir: Path) -> None:
    _, _, lib_dir = br.resolve_ort()
    br.run_runner(binary, model, wav, outdir, lib_dir)


def _tensor_parity(outdir: Path, dims: dict[str, tuple[int, int]],
                   pyr: dict[str, "np.ndarray"]) -> tuple[bool, str]:
    import numpy as np
    for label in ("notes", "onsets", "contours"):
        t, f = dims[label]
        arr = np.frombuffer((outdir / f"{label}.f32").read_bytes(), dtype="<f4").copy()
        ok, msg = ref.compare_tensors(arr.reshape(t, f), pyr[label])
        if not ok:
            return False, f"{label}: {msg}"
    return True, "all three tensors matched"


def _truth_errors(outdir: Path, truth: list[dict]) -> tuple[float, float, int]:
    timed = br.read_tsv(outdir / "timed.tsv")
    detected = [{"start_s": t[0], "end_s": t[1], "midi": int(t[2]),
                 "amplitude": t[3]} for t in timed]
    matched, missed, _ = br._match_truth(truth, detected)
    if not matched:
        return float("inf"), float("inf"), len(missed)
    worst_on = max(abs(e[2]) for e in matched)
    worst_off = max(abs(e[3]) for e in matched)
    return worst_on, worst_off, len(missed)


def main() -> int:
    model = br.ensure_model()
    fixture = "bp_poly_22050"  # the longer fixture — the drift shows there
    wav = br.FIXTURES / f"{fixture}.wav"
    import json
    truth = json.loads((br.FIXTURES / f"{fixture}_truth.json").read_text())["notes"]

    failures = []

    # ---------------- CORRUPTION 1: the axis order ------------------------
    print("=== CORRUPTION 1 — the tensor dump's AXIS ORDER (row-major -> "
          "column-major; the shape is unchanged) ===")
    src = _corrupted_runner("axis")
    binary = SCRATCH / "basicpitch_runner_axis"
    _compile(src, binary, [br.REPO_ROOT / "Engine" / "Transcription"])
    outdir = SCRATCH / f"{fixture}-axis"
    _run_binary(binary, model, wav, outdir)
    audio, _sr = ref.read_wav_mono(wav)
    pyr = ref.run_reference(audio, model)
    dims = {"notes": (pyr["notes"].shape[0], pyr["notes"].shape[1]),
            "onsets": (pyr["onsets"].shape[0], pyr["onsets"].shape[1]),
            "contours": (pyr["contours"].shape[0], pyr["contours"].shape[1])}
    ok, msg = _tensor_parity(outdir, dims, pyr)
    if ok:
        failures.append("CORRUPTION 1 (axis order) was NOT caught by the parity "
                        "gate — the gate is VACUOUS")
        print("  !! NOT CAUGHT — the parity gate is vacuous")
    else:
        print(f"  CAUGHT by the TENSOR PARITY gate (S4): {msg}")
    worst_on, worst_off, missed = _truth_errors(outdir, truth)
    print(f"  (for the record, the truth gate's view of the same corruption: "
          f"worst onset {worst_on*1000:.1f} ms, worst offset {worst_off*1000:.1f} ms, "
          f"{missed} unmatched)")

    # ---------------- CORRUPTION 2: the naive frame mapping ---------------
    print("")
    print("=== CORRUPTION 2 — the naive frame mapping (frame*256/22050 instead "
          "of the chunk-aware one) ===")
    header_dir = _corrupted_header("naive")
    src2 = HERE / "basicpitch_runner.cpp"
    binary2 = SCRATCH / "basicpitch_runner_naive"
    _compile(src2, binary2, [header_dir, br.REPO_ROOT / "Engine" / "Transcription"])
    outdir2 = SCRATCH / f"{fixture}-naive"
    _run_binary(binary2, model, wav, outdir2)
    ok2, msg2 = _tensor_parity(outdir2, dims, pyr)
    if ok2:
        print("  the TENSOR PARITY gate: PASSES (the tensors are untouched by a "
              "timing bug — as expected)")
    else:
        print(f"  the TENSOR PARITY gate: FAILS: {msg2}")
    worst_on2, worst_off2, missed2 = _truth_errors(outdir2, truth)
    caught_by_truth = missed2 > 0 or worst_on2 > br.ONSET_OFFSET_TOLERANCE_S \
        or worst_off2 > br.ONSET_OFFSET_TOLERANCE_S
    print(f"  the TRUTH gate (S6, 50 ms): worst onset {worst_on2*1000:.1f} ms, "
          f"worst offset {worst_off2*1000:.1f} ms, {missed2} unmatched -> "
          f"{'CAUGHT' if caught_by_truth else 'NOT CAUGHT'}")

    # The unit checks must catch it (they pin the mapping's drift exactly).
    unit = SCRATCH / "basicpitch_trim_test_naive"
    ucmd = [br.compiler(), "-O2", "-std=c++20", f"-I{header_dir}",
            str(HERE / "basicpitch_trim_test.cpp"), "-o", str(unit)]
    ur = subprocess.run(ucmd, capture_output=True, text=True)
    if ur.returncode != 0:
        failures.append("CORRUPTION 2: the trim unit test did not compile")
        print("  !! the unit test did not compile")
    else:
        run = subprocess.run([str(unit)], capture_output=True, text=True)
        caught_by_unit = run.returncode != 0
        print(f"  the UNIT gate (S9): {'CAUGHT' if caught_by_unit else 'NOT CAUGHT'} "
              f"(exit {run.returncode})")
        for line in run.stdout.splitlines():
            if line.startswith("FAIL"):
                print(f"    {line}")
    if not caught_by_truth and not caught_by_unit:
        failures.append("CORRUPTION 2 (the naive frame mapping) was caught by "
                        "NO gate — the spike is blind to the drift bug")

    print("")
    if failures:
        for f in failures:
            print(f"FAILED: {f}")
        return 1
    print("CORRUPTION PROOF GREEN — every corruption was caught by a gate "
          "(the parity gate is non-vacuous).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
