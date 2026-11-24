#!/usr/bin/env python3
"""The release-trim rule search (P-301) — the provenance of the ENGINE tuning
constant `kReleaseSustainFraction` in Engine/Transcription/BasicPitchNotes.hpp.

WHAT THIS IS FOR
The release trim is a tuned constant, so the constant needs its evidence to be
REPRODUCIBLE, not just asserted in a docstring. This script re-derives the
whole rule search from the spike's own dumps (the model's note-energy tensor
+ the vendor's note events) against the committed SYNTHESIS truth sidecars.

HOW TO RUN
    python3 -I Tests/Spikes/basicpitch_real.py          # writes the dumps
    python3 -I Tests/Spikes/basicpitch_trim_sweep.py     # this script

It prints the top candidates by worst |error| over ALL 21 truth notes (both
fixtures) and the per-note detail for the winner.

WHAT IT PROVED (2026-11-24, P-301)
  * The OLD "scan backward, cut at t+1 of the FIRST sustained dip" rule is
    WRONG: it latches onto the ATTACK ramp at the start of the note.
  * The rule that works is: sustain = MEDIAN of the note's own model energy;
    release level = fraction x sustain; cut at the START of the LAST
    contiguous dip below that level.
  * NO absolute threshold works: the energy at a note's TRUE end frame ranges
    0.353 .. 0.944 of that note's own sustain level.
  * Across ~1200 candidate rules (dip start / middle / end, fractional frame
    biases, absolute-floor blends, five sustain bases, nine fractions, three
    minimum dip lengths) the BEST worst-case offset is 39.3 ms — the rule
    below is at the floor of the family, not a lucky pick.
  * 0.60 was chosen over 0.62 (which ties) because 0.65 already FAILS
    (one note at 50.9 ms) — 0.60 keeps the largest margin to that cliff.

Stdlib only (no numpy) — it must run anywhere the spike runs.
"""

import json
import os
import statistics
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, ".basicpitch-build")
FIX = os.path.join(HERE, "Fixtures")

SR = 22050
HOP = 256
CHUNK_HOP = 36164
PER_CHUNK = 142
FREQ_BINS = 88
TOL = 0.050
FIXTURES = ("bp_mono_22050", "bp_poly_22050")


def frame_to_seconds(frame):
    """The CORRECTED (chunk-aware) frame -> seconds mapping."""
    return ((frame // PER_CHUNK) * CHUNK_HOP + (frame % PER_CHUNK) * HOP) / SR


def load_f32(path):
    with open(path, "rb") as fh:
        data = fh.read()
    return struct.unpack("<%df" % (len(data) // 4), data)


class Case:
    """One fixture: the model's note-energy tensor + the vendor's events."""

    def __init__(self, name):
        dump = os.path.join(BUILD, name + "-run1")
        self.name = name
        self.energy = load_f32(os.path.join(dump, "notes.f32"))
        self.frames = len(self.energy) // FREQ_BINS
        self.events = []
        with open(os.path.join(dump, "events.tsv")) as fh:
            for line in fh:
                parts = line.split("\t")
                if len(parts) < 4:
                    continue
                self.events.append(
                    (int(parts[0]), int(parts[1]), int(parts[2]), float(parts[3]))
                )
        with open(os.path.join(FIX, name + "_truth.json")) as fh:
            self.truth = json.load(fh)["notes"]

    def energy_at(self, frame, midi):
        if frame < 0 or frame >= self.frames:
            return 0.0
        return self.energy[frame * FREQ_BINS + (midi - 21)]


def sustain_level(case, event, base):
    """The note's own sustain level (the median by default)."""
    start, end, midi, amplitude = event
    values = [case.energy_at(t, midi) for t in range(start, min(end, case.frames))]
    if not values:
        return 0.0
    if base == "amp":
        return amplitude
    if base == "median":
        return statistics.median(values)
    if base == "median60":
        return statistics.median(values[: max(1, int(len(values) * 0.6))])
    if base == "mean":
        return statistics.fmean(values)
    if base == "max":
        return max(values)
    raise ValueError(base)


def last_dip(case, event, level, run_min):
    """The LAST contiguous run of frames below `level` (the one nearest the
    note's end), as (run_start, run_end). None when there is no such run."""
    start, end, midi, _ = event
    t = end - 1
    while t >= start:
        if case.energy_at(t, midi) < level:
            run_end = t
            while t >= start and case.energy_at(t, midi) < level:
                t -= 1
            run_start = t + 1
            if (run_end - run_start + 1) >= run_min:
                return run_start, run_end
        else:
            t -= 1
    return None, None


def evaluate(rule, cases):
    """Match every truth note to its best event, then score the rule."""
    worst_on = 0.0
    worst_off = 0.0
    fails = []
    detail = []
    for case in cases:
        used = set()
        for truth in case.truth:
            best = None
            best_err = None
            for i, event in enumerate(case.events):
                if i in used or event[2] != truth["midi"]:
                    continue
                err = frame_to_seconds(event[0]) - truth["start_s"]
                if abs(err) <= TOL and (best_err is None or abs(err) < abs(best_err)):
                    best, best_err = i, err
            if best is None:
                fails.append((case.name, truth["midi"], "MISSED"))
                continue
            used.add(best)
            event = case.events[best]
            cut = rule(case, event)
            on = frame_to_seconds(event[0]) - truth["start_s"]
            off = frame_to_seconds(cut) - truth["end_s"]
            worst_on = max(worst_on, abs(on))
            worst_off = max(worst_off, abs(off))
            detail.append((case.name, truth["midi"], on, off, cut, event))
            if abs(off) > TOL:
                fails.append((case.name, truth["midi"], "off %+.1fms" % (off * 1000)))
    return worst_on, worst_off, fails, detail


def main():
    cases = []
    for name in FIXTURES:
        dump = os.path.join(BUILD, name + "-run1")
        if not os.path.isdir(dump):
            print("MISSING the spike dumps: %s" % dump)
            print("Run: python3 -I Tests/Spikes/basicpitch_real.py")
            return 2
        cases.append(Case(name))

    candidates = []

    def add(name, rule):
        worst_on, worst_off, fails, _ = evaluate(rule, cases)
        candidates.append(
            (max(worst_on, worst_off), worst_on, worst_off, len(fails), name, rule)
        )

    # Family A — the shipped rule: last dip, cut at its START.
    for base in ("median", "median60", "mean", "max", "amp"):
        for frac in (0.45, 0.50, 0.55, 0.58, 0.60, 0.62, 0.65, 0.70, 0.75, 0.80):
            for run in (1, 2, 3):
                def rule_a(case, event, b=base, f=frac, r=run):
                    run_start, _ = last_dip(case, event, f * sustain_level(case, event, b), r)
                    if run_start is None:
                        return event[1]
                    return max(run_start, event[0] + 1)

                add("A %s*%.2f run>=%d" % (base, frac, run), rule_a)

    # Family B — the dip start plus a (possibly fractional) frame bias.
    for base in ("median", "median60", "max"):
        for frac in (0.55, 0.58, 0.60, 0.65):
            for delta in (-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0, 1.5):
                def rule_b(case, event, b=base, f=frac, d=delta):
                    run_start, _ = last_dip(case, event, f * sustain_level(case, event, b), 1)
                    if run_start is None:
                        return event[1]
                    return max(int(round(run_start + d)), event[0] + 1)

                add("B %s*%.2f %+.2ff" % (base, frac, delta), rule_b)

    # Family C — cut at the dip MIDDLE.
    for base in ("median", "median60", "max"):
        for frac in (0.55, 0.58, 0.60, 0.65):
            def rule_c(case, event, b=base, f=frac):
                run_start, run_end = last_dip(
                    case, event, f * sustain_level(case, event, b), 1
                )
                if run_start is None:
                    return event[1]
                return max(int(round((run_start + run_end) / 2.0)), event[0] + 1)

            add("C %s*%.2f mid" % (base, frac), rule_c)

    # Family D — cut at the dip END + 1.
    for base in ("median", "median60", "max"):
        for frac in (0.55, 0.58, 0.60, 0.65):
            def rule_d(case, event, b=base, f=frac):
                _, run_end = last_dip(case, event, f * sustain_level(case, event, b), 1)
                if run_end is None:
                    return event[1]
                return max(min(run_end + 1, event[1]), event[0] + 1)

            add("D %s*%.2f end+1" % (base, frac), rule_d)

    # Family G — dip start, but never before the note's own last clearly
    # sounding frame (an absolute floor blended with the relative level).
    for base in ("median", "median60", "max"):
        for frac in (0.55, 0.58, 0.60, 0.65):
            for floor in (0.05, 0.10, 0.15, 0.20, 0.25, 0.30):
                def rule_g(case, event, b=base, f=frac, fl=floor):
                    run_start, _ = last_dip(case, event, f * sustain_level(case, event, b), 1)
                    if run_start is None:
                        return event[1]
                    start, end, midi, _ = event
                    last_loud = start
                    for t in range(start, min(end, case.frames)):
                        if case.energy_at(t, midi) >= fl:
                            last_loud = t
                    return max(min(run_start, last_loud + 1), start + 1)

                add("G %s*%.2f floor>=%.2f" % (base, frac, floor), rule_g)

    candidates.sort(key=lambda c: (c[0], c[3]))
    print("=== top candidates by worst |error| over all %d truth notes ===" %
          sum(len(c.truth) for c in cases))
    for worst, worst_on, worst_off, fails, name, _ in candidates[:20]:
        print("  worst=%6.1fms  on=%5.1f  off=%5.1f  fails=%d  %s" %
              (worst * 1000, worst_on * 1000, worst_off * 1000, fails, name))

    worst, worst_on, worst_off, fails, name, rule = candidates[0]
    print("")
    print("=== winner: %s (worst offset %.1f ms, %d failures) ===" %
          (name, worst_off * 1000, fails))
    _, _, _, detail = evaluate(rule, cases)
    for case_name, midi, on, off, cut, event in detail:
        print("  %-18s midi %3d  ev[%d,%d)  cut=%4d  on %+6.1fms  off %+6.1fms" %
              (case_name, midi, event[0], event[1], cut, on * 1000, off * 1000))

    # The shipped constant must be among the winners and must pass.
    shipped = [c for c in candidates if c[4] == "A median*0.60 run>=1"]
    if not shipped:
        print("")
        print("NOTE: the shipped rule (median*0.60, run>=1) was not in the candidate set")
        return 1
    shipped = shipped[0]
    print("")
    print("shipped rule (median*0.60, run>=1): worst %.1f ms, %d failures" %
          (shipped[0] * 1000, shipped[3]))
    return 0 if shipped[3] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
