#!/usr/bin/env python3
"""The SwiftF0 ↔ basic-pitch cross-check — the artifact dumper (P-305, PAUL lane).

WHAT THIS DOES: it runs BOTH real models over the same source audio and dumps
their outputs as a DETERMINISTIC, COMMITTED artifact:

  · SwiftF0 (lars76/swift-f0, MIT) — a MONOPHONIC neural pitch tracker. It
    answers "what single pitch is loudest here".
  · basic-pitch (sevagh/basicpitch.cpp; the ICASSP-2022 WEIGHTS ARE TIER C per
    D-46 — study-only for commercial distribution) — a POLYPHONIC transcriber.
    It answers "which notes are sounding".

The artifact is what `EngineCore`'s cross-check (PitchCrossCheck.swift) and
the P-306 benchmark harness consume, so neither needs a model download at
benchmark time (the `bench-v2` CI job installs only numpy+onnxruntime and
reads committed artifacts — the `bench_report_v1.json` convention).

THE METRIC (one definition, two implementations):
  · the Swift side segments SwiftF0's frames into notes and compares them
    with basic-pitch's note events;
  · this script computes the SAME numbers in Python (the mirror below);
  · the artifact stores the Python-computed values as `expected`, and the
    Swift test asserts its own computation agrees — so a drift between the two
    implementations is a RED TEST, not a silently different number.

HONESTY (AGENTS §11 / C-12): the metric is REPORTED, never used to filter,
gate or hide a note. A disagreement may be the transcriber's fault (an octave
artefact), the tracker's fault (a polyphonic mixture defeats a monophonic
tracker), or the truth (a real octave leap). The report says "these two
disagree here" and nothing more.

Usage:
    python3 Tests/Spikes/crosscheck_dump.py            # write the artifact
    python3 Tests/Spikes/crosscheck_dump.py --print    # print the summary
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "Tests" / "Spikes"))

import basicpitch_ref as bp  # noqa: E402

FIXTURES = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
ARTIFACT = FIXTURES / "crosscheck_swiftf0_vs_basicpitch.json"

SWIFTF0_SR = 16000
SWIFTF0_HOP = 256
SWIFTF0_PERIOD = 0.016
FMIN, FMAX = 46.875, 2093.75
VOICED_THRESHOLD = 0.5

# The segmentation knobs — the SAME values as EngineCore's
# SwiftF0NoteSegmenter.Options (the artifact's `config` block names them, so
# a reader never has to guess what produced the numbers).
SEG_MIN_CONFIDENCE = VOICED_THRESHOLD
SEG_MAX_GAP_SECONDS = 0.050
SEG_MIN_DURATION_SECONDS = 0.050

# The matching rule — the SAME as EngineCore's TranscriptionCrossCheck.Options.
CC_MIN_OVERLAP_FRACTION = 0.5
CC_PITCH_TOLERANCE_CENTS = 0.0


# --------------------------------------------------------------------------
# The resampler (each model runs at ITS native rate; the source audio is the
# same musical content either way)
# --------------------------------------------------------------------------

def resample(x: np.ndarray, sr_in: int, sr_out: int, taps: int = 32) -> np.ndarray:
    """A deterministic windowed-sinc resampler (Kaiser beta 8.6).

    WHY NOT LINEAR: linear interpolation folds energy back into the audio
    (a 440 Hz tone gains harmonics), and the cross-check would then be
    measuring the resampler instead of the two estimators. The kernel is
    low-passed at the OUTPUT Nyquist, so the downsampling case is properly
    anti-aliased.
    """
    if sr_in == sr_out:
        return np.asarray(x, dtype=np.float64)
    ratio = sr_out / sr_in
    n_out = int(math.floor(len(x) * ratio))
    if n_out <= 0:
        return np.zeros(0, dtype=np.float64)
    positions = np.arange(n_out, dtype=np.float64) / ratio
    base = np.floor(positions).astype(np.int64)
    offsets = positions - base
    # The kernel taps: input samples base-idx for idx in [-(taps-1) .. taps].
    idx = np.arange(-(taps - 1), taps + 1, dtype=np.int64)
    # The anti-alias cutoff (cycles per INPUT sample): at most the output
    # Nyquist, so a downsample is filtered before it is decimated.
    cutoff = 0.5 * min(1.0, ratio)
    window = np.kaiser(2 * taps, 8.6)
    # h(x) = cutoff · sinc(cutoff·x) · window(x / taps)
    delta = (offsets[:, None] - idx[None, :])
    kernel = cutoff * np.sinc(cutoff * delta) * window[None, :]
    sample_idx = base[:, None] + idx[None, :]
    valid = (sample_idx >= 0) & (sample_idx < len(x))
    np.clip(sample_idx, 0, len(x) - 1, out=sample_idx)
    gathered = np.asarray(x, dtype=np.float64)[sample_idx]
    gathered = gathered * valid
    return np.sum(gathered * kernel, axis=1)


# --------------------------------------------------------------------------
# The two engines
# --------------------------------------------------------------------------

def run_swiftf0(audio: np.ndarray, model_path: Path) -> list[dict]:
    """SwiftF0's frames on the contract grid (t = i·0.016)."""
    import onnxruntime as ort

    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    sess = ort.InferenceSession(str(model_path), so, providers=["CPUExecutionProvider"])
    pitch, conf = sess.run(
        ["pitch", "confidence"],
        {"audio": audio[None, :].astype(np.float32),
         "fmin": np.asarray(FMIN, dtype=np.float32),
         "fmax": np.asarray(FMAX, dtype=np.float32)})
    pitch = np.asarray(pitch[0], dtype=np.float64)
    conf = np.asarray(conf[0], dtype=np.float32)
    frames = []
    for i in range(len(conf)):
        voiced = float(conf[i]) >= VOICED_THRESHOLD and float(pitch[i]) > 0
        frames.append({"t": round(i * SWIFTF0_PERIOD, 6),
                       "hz": float(pitch[i]) if voiced else 0.0,
                       "confidence": float(conf[i])})
    return frames


def run_basicpitch(audio: np.ndarray, model_path: Path) -> list[dict]:
    """basic-pitch's decoded note events, in seconds."""
    result = bp.run_reference(audio, model_path)
    notes = []
    for event in result["events"]:
        notes.append({"start_s": round(bp.frame_to_seconds(event["start_idx"]), 6),
                      "end_s": round(bp.frame_to_seconds(event["end_idx"]), 6),
                      "midi": int(event["midi"]),
                      "amplitude": float(event["amplitude"])})
    notes.sort(key=lambda n: (n["start_s"], n["midi"]))
    return notes


# --------------------------------------------------------------------------
# The Python mirror of EngineCore's segmenter + comparison
# --------------------------------------------------------------------------

def midi_number(hz: float) -> int:
    """The nearest MIDI note (Swift's `.rounded()` = half away from zero, so
    `floor(x + 0.5)` — Python's own `round()` is banker's rounding and would
    disagree on an exact half)."""
    return int(math.floor(69.0 + 12.0 * math.log2(hz / 440.0) + 0.5))


def cents_deviation(hz: float, midi: int) -> float:
    reference = 440.0 * (2.0 ** ((midi - 69.0) / 12.0))
    return 1200.0 * math.log2(hz / reference)


def segment(frames: list[dict]) -> list[dict]:
    """The mirror of EngineCore's SwiftF0NoteSegmenter.segment."""
    notes: list[dict] = []
    open_midi = None
    open_start = 0.0
    open_last = 0.0
    open_cents: list[float] = []
    open_conf: list[float] = []

    def close():
        nonlocal open_midi, open_cents, open_conf
        if open_midi is None:
            return
        end = open_last + SWIFTF0_PERIOD
        if end - open_start >= SEG_MIN_DURATION_SECONDS:
            notes.append({"start_s": open_start,
                          "end_s": end,
                          "midi": open_midi,
                          "cents": sum(open_cents) / len(open_cents),
                          "mean_confidence": sum(open_conf) / len(open_conf)})
        open_midi = None
        open_cents = []
        open_conf = []

    for frame in frames:
        hz = frame["hz"]
        conf = frame["confidence"]
        voiced = hz > 0 and conf >= SEG_MIN_CONFIDENCE
        if not voiced:
            if open_midi is not None and frame["t"] - open_last > SEG_MAX_GAP_SECONDS:
                close()
            continue
        midi = midi_number(hz)
        cents = cents_deviation(hz, midi)
        if (open_midi is not None and open_midi == midi
                and frame["t"] - open_last <= SEG_MAX_GAP_SECONDS):
            open_last = frame["t"]
            open_cents.append(cents)
            open_conf.append(conf)
        else:
            close()
            open_midi = midi
            open_start = frame["t"]
            open_last = frame["t"]
            open_cents = [cents]
            open_conf = [conf]
    close()
    notes.sort(key=lambda n: (n["start_s"], n["midi"]))
    return notes


def compare(reference: list[dict], hypothesis: list[dict]) -> dict:
    """The mirror of EngineCore's TranscriptionCrossCheck.compare."""
    pairs = []
    for r, ref in enumerate(reference):
        for h, hyp in enumerate(hypothesis):
            if abs(ref["midi"] - hyp["midi"]) * 100.0 > CC_PITCH_TOLERANCE_CENTS:
                continue
            overlap = max(0.0, min(ref["end_s"], hyp["end_s"]) - max(ref["start_s"], hyp["start_s"]))
            shorter = min(ref["end_s"] - ref["start_s"], hyp["end_s"] - hyp["start_s"])
            if shorter <= 0 or overlap < shorter * CC_MIN_OVERLAP_FRACTION:
                continue
            pairs.append((overlap, r, h,
                          (hyp["start_s"] - ref["start_s"]) * 1000.0,
                          (hyp["end_s"] - ref["end_s"]) * 1000.0))
    pairs.sort(key=lambda p: (-p[0], p[1]))
    used_ref: set[int] = set()
    used_hyp: set[int] = set()
    onsets: list[float] = []
    offsets: list[float] = []
    for overlap, r, h, onset_delta, offset_delta in pairs:
        if r in used_ref or h in used_hyp:
            continue
        used_ref.add(r)
        used_hyp.add(h)
        onsets.append(abs(onset_delta))
        offsets.append(abs(offset_delta))

    pitch_mismatches = 0
    for h, hyp in enumerate(hypothesis):
        if h in used_hyp:
            continue
        for ref in reference:
            shorter = min(ref["end_s"] - ref["start_s"], hyp["end_s"] - hyp["start_s"])
            if shorter <= 0:
                continue
            overlap = max(0.0, min(ref["end_s"], hyp["end_s"]) - max(ref["start_s"], hyp["start_s"]))
            if overlap >= shorter * CC_MIN_OVERLAP_FRACTION:
                if ref["midi"] != hyp["midi"]:
                    pitch_mismatches += 1
                break

    matched = len(used_ref)
    recall = matched / len(reference) if reference else 0.0
    precision = matched / len(hypothesis) if hypothesis else 0.0
    if not reference and not hypothesis:
        f1 = 1.0
    elif recall + precision == 0:
        f1 = 0.0
    else:
        f1 = 2 * recall * precision / (recall + precision)

    return {
        "reference_count": len(reference),
        "hypothesis_count": len(hypothesis),
        "matched_count": matched,
        "unmatched_reference": len(reference) - matched,
        "unmatched_hypothesis": len(hypothesis) - matched,
        "pitch_mismatches": pitch_mismatches,
        "median_onset_delta_ms": _median(onsets),
        "median_offset_delta_ms": _median(offsets),
        "reference_recall": recall,
        "hypothesis_precision": precision,
        "agreement_f1": f1,
        "disagreement_rate": 1.0 - f1,
    }


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2 == 1:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


# --------------------------------------------------------------------------
# The cases
# --------------------------------------------------------------------------

CASES = [
    {
        "name": "bp_mono",
        "fixture": "bp_mono_22050.wav",
        "source_rate": 22050,
        "why": "MONOPHONIC — one voice, five notes. The case where two honest "
               "estimators SHOULD agree; the baseline for the metric.",
    },
    {
        "name": "synthetic_voice",
        "fixture": "synthetic_voice_16k.wav",
        "source_rate": 16000,
        "why": "MONOPHONIC with vibrato — the case where the two engines differ "
               "in their frame handling (a monophonic tracker follows the "
               "vibrato; a transcriber quantizes to notes).",
    },
    {
        "name": "satb5",
        "fixture": "satb5_22050.wav",
        "source_rate": 22050,
        "why": "POLYPHONIC — five voices at once. A monophonic tracker CANNOT "
               "see them all, so a high disagreement here is EXPECTED and is "
               "the honest limit of the cross-check (AGENTS §11: never promise "
               "perfect 5-way separation).",
    },
]


def build_case(case: dict, swiftf0_model: Path, basicpitch_model: Path) -> dict:
    path = FIXTURES / case["fixture"]
    audio, sr = bp.read_wav_mono(path)
    if sr != case["source_rate"]:
        raise RuntimeError(f"{path.name}: expected {case['source_rate']} Hz, got {sr}")

    swiftf0_audio = resample(audio, sr, SWIFTF0_SR)
    basicpitch_audio = resample(audio, sr, bp.SAMPLE_RATE)

    frames = run_swiftf0(swiftf0_audio, swiftf0_model)
    notes = run_basicpitch(basicpitch_audio, basicpitch_model)

    segmented = segment(frames)
    report = compare(segmented, [{"start_s": n["start_s"], "end_s": n["end_s"], "midi": n["midi"]}
                                  for n in notes])
    return {
        "name": case["name"],
        "fixture": case["fixture"],
        "source_sample_rate": sr,
        "why": case["why"],
        "swiftf0": {"sample_rate": SWIFTF0_SR, "frames": frames},
        "basicpitch": {"sample_rate": bp.SAMPLE_RATE, "notes": notes},
        "segmented_swiftf0_notes": segmented,
        "expected": report,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--print", action="store_true", help="print the summary")
    parser.add_argument("--out", default=str(ARTIFACT))
    args = parser.parse_args()

    swiftf0_model = _ensure_model("swiftf0")
    basicpitch_model = _ensure_model("basic-pitch")

    cases = [build_case(case, swiftf0_model, basicpitch_model) for case in CASES]

    artifact = {
        "artifact": "SwiftF0 vs basic-pitch cross-check (P-305)",
        "generated_by": "Tests/Spikes/crosscheck_dump.py",
        "models": {
            "swiftf0": {"sha256": _sha256(swiftf0_model), "role": "reference (monophonic tracker)"},
            "basicpitch": {"sha256": _sha256(basicpitch_model), "role": "hypothesis (polyphonic transcriber)"},
        },
        "config": {
            "segment_min_confidence": SEG_MIN_CONFIDENCE,
            "segment_max_gap_seconds": SEG_MAX_GAP_SECONDS,
            "segment_min_duration_seconds": SEG_MIN_DURATION_SECONDS,
            "crosscheck_min_overlap_fraction": CC_MIN_OVERLAP_FRACTION,
            "crosscheck_pitch_tolerance_cents": CC_PITCH_TOLERANCE_CENTS,
            "swiftf0_hop_seconds": SWIFTF0_PERIOD,
        },
        "note": "The `expected` block is computed by the PYTHON mirror of "
                "EngineCore's SwiftF0NoteSegmenter + TranscriptionCrossCheck; "
                "the Swift test asserts its own computation agrees with it, so "
                "the two implementations cannot drift apart silently.",
        "cases": cases,
    }

    out = Path(args.out)
    out.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    for case in cases:
        report = case["expected"]
        print(f"  {case['name']:>16}: agreement F1 {report['agreement_f1']:.3f} "
              f"(disagreement {report['disagreement_rate']:.3f}) — matched "
              f"{report['matched_count']}/{report['reference_count']} reference, "
              f"{report['matched_count']}/{report['hypothesis_count']} hypothesis, "
              f"{report['pitch_mismatches']} pitch mismatch(es)")
    return 0


def _ensure_model(entry: str) -> Path:
    import re
    import subprocess

    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "models" / "download.py"),
         "--entry", entry],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"download.py --entry {entry} failed: {result.stderr.strip()}")
    for line in result.stdout.splitlines():
        if line.startswith(("downloaded", "cached")):
            raw = line.split(": ", 1)[1]
            return Path(re.sub(r"\s+\(\d+ bytes\)\s*$", "", raw))
    raise RuntimeError(f"download.py printed no path for {entry}: {result.stdout!r}")


def _sha256(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
