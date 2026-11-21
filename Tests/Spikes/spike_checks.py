#!/usr/bin/env python3
"""Spike assertion helpers (P-002, PAUL lane) — the CONTRACT checks every model
spike must pass before its real implementation lands (AGENTS §6 spike jobs).

Rule IDs are referenced in Tests/Spikes/README.md and Docs/ENGINE.md:
  S1 pitch range   — voiced hz in [46.9, 2093.75] (contract V11 band); 0.0 = unvoiced
  S2 confidence    — every confidence in [0, 1] (contract V12)
  S3 finite        — all numeric outputs finite (no NaN/inf)
  S4 non-silence   — expected-voiced outputs have RMS > threshold (dBFS)
  S5 shape/dtype   — outputs match the model's declared shape/dtype contract
  S6 determinism   — two independent runs produce byte-identical outputs
  S7 grid          — pitch frames on the uniform 16 ms grid (contract V13)
  S8 note events   — midi 24–96, start_s < end_s, confidence [0,1],
                     sorted + non-overlapping (contract V7–V9 semantics)

Python-side by design (Leto's frozen CI job names invoke run_spike.py); Swift
engines re-assert the same rules in EngineCore validators (J-004 parity).
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

# Contract constants (CONTRACTS.md v0.0 / AGENTS §8).
HZ_MIN = 46.9
HZ_MAX = 2093.75
HOP_S = 0.016
SILENCE_RMS_DB = -60.0  # S4 threshold


class SpikeFailure(Exception):
    """One or more spike-contract violations; message lists every rule that fired."""


@dataclass
class CheckReport:
    passed: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)

    def ok(self, rule: str, detail: str = "") -> None:
        self.passed.append(f"{rule}: {detail}" if detail else rule)

    def bad(self, rule: str, detail: str) -> None:
        self.failed.append(f"{rule}: {detail}")

    def raise_if_failed(self, context: str) -> None:
        if self.failed:
            raise SpikeFailure(f"[{context}] " + " | ".join(self.failed))


def rms_db(x: np.ndarray) -> float:
    if len(x) == 0:
        return -120.0
    r = float(np.sqrt(np.mean(np.square(x.astype(np.float64)))))
    return 20.0 * math.log10(max(r, 1e-12))


def check_pitch_frames(frames: np.ndarray, report: CheckReport, context: str,
                       expect_some_voiced: bool = True) -> None:
    """frames: float array [N, 3] = (t, hz, confidence). S1/S2/S3/S7."""
    t, hz, conf = frames[:, 0], frames[:, 1], frames[:, 2]
    # S3 finite.
    if not np.all(np.isfinite(frames)):
        report.bad("S3", f"{context}: non-finite values in pitch frames")
    else:
        report.ok("S3", f"{context} finite")
    # S1 pitch range (0.0 allowed = unvoiced).
    voiced = hz != 0.0
    bad = hz[voiced & ((hz < HZ_MIN) | (hz > HZ_MAX))]
    if bad.size:
        report.bad("S1", f"{context}: {bad.size} voiced frames outside [{HZ_MIN}, {HZ_MAX}] (e.g. {bad[0]:.3f})")
    else:
        report.ok("S1", f"{context}: {int(voiced.sum())}/{len(hz)} voiced, all in band")
    # S2 confidence.
    if np.any((conf < 0.0) | (conf > 1.0)):
        report.bad("S2", f"{context}: confidence outside [0,1]")
    else:
        report.ok("S2", f"{context} confidence in [0,1]")
    # S7 uniform grid.
    expected_t = np.arange(len(frames)) * HOP_S
    if len(frames) and np.max(np.abs(t - expected_t)) > 0.001:
        report.bad("S7", f"{context}: grid deviation > 1 ms (max {np.max(np.abs(t - expected_t)):.6f} s)")
    else:
        report.ok("S7", f"{context}: uniform 16 ms grid")
    # S4 non-silence (voiced expectation).
    if expect_some_voiced and not voiced.any():
        report.bad("S4", f"{context}: expected voiced frames, none present")
    elif expect_some_voiced:
        report.ok("S4", f"{context}: voiced frames present")


def check_vad_probs(probs: np.ndarray, report: CheckReport, context: str) -> None:
    """probs: float array [N] speech probability per chunk. S2/S3."""
    if np.any((probs < 0.0) | (probs > 1.0)):
        report.bad("S2", f"{context}: VAD probs outside [0,1]")
    else:
        report.ok("S2", f"{context} VAD probs in [0,1]")
    if not np.all(np.isfinite(probs)):
        report.bad("S3", f"{context}: non-finite VAD probs")
    else:
        report.ok("S3", f"{context} finite")


def check_note_events(notes: list[dict], report: CheckReport, context: str,
                      expect_some: bool = True) -> None:
    """notes: [{start_s, end_s, midi, confidence}]. S8."""
    if expect_some and not notes:
        report.bad("S8", f"{context}: expected note events, none produced")
        return
    if expect_some:
        report.ok("S8", f"{context}: {len(notes)} note events")
    prev_end = -math.inf
    for i, n in enumerate(notes):
        if not (24 <= n["midi"] <= 96):
            report.bad("S8", f"{context}: note {i} midi {n['midi']} outside 24–96")
        if not n["start_s"] < n["end_s"]:
            report.bad("S8", f"{context}: note {i} start_s >= end_s")
        if not (0.0 <= n["confidence"] <= 1.0):
            report.bad("S8", f"{context}: note {i} confidence outside [0,1]")
        if n["start_s"] < prev_end:
            report.bad("S8", f"{context}: note {i} overlaps previous (unsorted?)")
        prev_end = max(prev_end, n["end_s"])
    if all(24 <= n["midi"] <= 96 and n["start_s"] < n["end_s"] and 0.0 <= n["confidence"] <= 1.0 and n["start_s"] >= prev_end
           for n in []):
        pass  # unreachable; per-note checks above feed report


def check_stems(stems: list[np.ndarray], report: CheckReport, context: str,
                expect_non_silent: bool = True) -> None:
    """stems: list of float arrays. S3/S4 (+equal length implicitly via S5 caller)."""
    for k, s in enumerate(stems):
        if not np.all(np.isfinite(s)):
            report.bad("S3", f"{context}: stem {k} non-finite samples")
        if expect_non_silent and rms_db(s) <= SILENCE_RMS_DB:
            report.bad("S4", f"{context}: stem {k} silent (RMS {rms_db(s):.1f} dB)")
    if all(np.all(np.isfinite(s)) for s in stems):
        report.ok("S3", f"{context} stems finite")
    if expect_non_silent and all(rms_db(s) > SILENCE_RMS_DB for s in stems):
        report.ok("S4", f"{context} stems non-silent")


def check_shape(actual: tuple, expected: tuple, dtype, arr: np.ndarray, report: CheckReport, context: str) -> None:
    """S5 shape/dtype."""
    if actual != expected:
        report.bad("S5", f"{context}: shape {actual} != expected {expected}")
    elif arr.dtype != dtype:
        report.bad("S5", f"{context}: dtype {arr.dtype} != expected {dtype}")
    else:
        report.ok("S5", f"{context}: shape {actual} dtype {arr.dtype}")


def check_determinism(run_a: dict[str, bytes], run_b: dict[str, bytes], report: CheckReport, context: str) -> None:
    """S6 — two runs, byte-identical per-output."""
    if set(run_a) != set(run_b):
        report.bad("S6", f"{context}: output sets differ across runs")
        return
    for k in run_a:
        if run_a[k] != run_b[k]:
            report.bad("S6", f"{context}: output '{k}' differs across runs")
    if not any(f"{context}: output" in f for f in report.failed):
        report.ok("S6", f"{context}: byte-identical across runs")
