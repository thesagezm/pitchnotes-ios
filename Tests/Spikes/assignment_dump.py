#!/usr/bin/env python3
"""The voice-assignment artifact dumper (P-303, PAUL lane).

WHAT THIS DOES: it runs the REAL basic-pitch model over the committed
synthetic fixtures, picks the per-frame pitch candidates (the Python mirror of
P-302's `MultiFOSalience`), runs the voice assignment (the Python mirror of
EngineCore's `VoiceAssignmentEngine`), and dumps the result as a
DETERMINISTIC, COMMITTED artifact:

  Tests/Spikes/Fixtures/assignment_satb5.json

The artifact is what `EngineCore`'s assignment test and the P-306 benchmark
harness consume, so neither needs a model download at benchmark time (the
`bench-v2` CI job installs only numpy+onnxruntime and reads committed
artifacts — the `bench_report_v1.json` convention).

THE METRIC (one model, two implementations):
  · the Swift side runs `VoiceAssignmentEngine` over the committed candidates;
  · this script runs the SAME model in Python (the mirror below);
  · the artifact stores the Python-computed values as `expected`, and the
    Swift test asserts its own computation agrees — so a drift between the
    two implementations is a RED TEST, not a silently different number.

HONESTY (AGENTS §11 / C-12): the salience values are the MODEL'S POSTERIOR
STRENGTH, not calibrated probabilities. They are used here as a monotone
preference inside the assignment and are carried verbatim into the notes —
never rescaled into a "confidence". The `confidence` is the assignment
posterior (D-41 §1), a different quantity.

The basic-pitch WEIGHTS ARE TIER C per D-46 (study-only for commercial
distribution). They are never committed; the artifact records their sha256.

Usage:
    python3 Tests/Spikes/assignment_dump.py             # write the artifact
    python3 Tests/Spikes/assignment_dump.py --print     # print the summary
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "Tests" / "Spikes"))

import basicpitch_ref as bp  # noqa: E402

FIXTURES = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
ARTIFACT = FIXTURES / "assignment_satb5.json"

MIDI_OFFSET = 21
BIN_COUNT = 88

# --------------------------------------------------------------------------
# The configuration — the EXACT values of EngineCore's
# `VoiceAssignmentOptions.default`. The artifact carries them, and the Swift
# test asserts its own defaults agree, so a change on either side is visible.
# --------------------------------------------------------------------------
OPTIONS = {
    "salience_weight": 1.0,
    "range_penalty_per_semitone": 0.35,
    "range_penalty_cap_semitones": 24,
    "harmonic_weight": 0.05,
    "unison_penalty": 0.25,
    "onset_penalty": 0.15,
    "offset_penalty": 0.15,
    "smoothness_weight": 0.001,
    "smoothness_cap_cents": 240.0,
    "posterior_temperature": 0.25,
    "beam_width": 48,
    "frame_state_limit": 64,
    "allow_unisons": True,
    "minimum_note_duration_seconds": 0.050,
}

# P-302's peak picker.
PEAK_OPTIONS = {
    "minimum_salience": 0.30,
    "local_max_window_semitones": 2,
    "minimum_peak_spacing_frames": 1,
}

# C-6.1's part range presets (the same table as EngineCore's
# `PartRangePresets.all`).
RANGES = {
    "BASS": (40, 55),
    "BARITONE": (45, 62),
    "BARITENOR": (48, 65),
    "T2": (52, 69),
    "T1": (55, 76),
    "SOPRANO": (60, 79),
    "ALTO": (55, 74),
}

# The contractual display order (C-1): SOPRANO first … BASS last. The PITCH
# order (low → high) is its reverse.
SORT_ORDER = {
    "SOPRANO": 0, "ALTO": 1, "T1": 2, "T2": 3, "BARITENOR": 4,
    "BARITONE": 5, "BASS": 6,
}

# The frame → seconds mapping (P-302's chunk-aware clock — the SAME values as
# EngineCore's `BasicPitchFrameClock`).
SAMPLE_RATE = 22050
FRAME_HOP = 256
CHUNK_SAMPLES = 43844
OVERLAP_FRAMES = 30
OVERLAP_SAMPLES = OVERLAP_FRAMES * FRAME_HOP
CHUNK_HOP = CHUNK_SAMPLES - OVERLAP_SAMPLES
MODEL_FRAMES_PER_CHUNK = 172
TRIMMED_FRAMES_PER_CHUNK = MODEL_FRAMES_PER_CHUNK - OVERLAP_FRAMES


def frame_to_seconds(frame: int) -> float:
    chunk = frame // TRIMMED_FRAMES_PER_CHUNK
    within = frame % TRIMMED_FRAMES_PER_CHUNK
    sample = chunk * CHUNK_HOP + within * FRAME_HOP
    return sample / SAMPLE_RATE


# --------------------------------------------------------------------------
# P-302's candidate picker (the Python mirror)
# --------------------------------------------------------------------------

def is_local_max(table: np.ndarray, frame: int, midi: int, window: int) -> bool:
    value = table[frame, midi - MIDI_OFFSET]
    for neighbour in range(midi - window, midi + window + 1):
        if neighbour == midi:
            continue
        if not (MIDI_OFFSET <= neighbour < MIDI_OFFSET + BIN_COUNT):
            continue
        other = table[frame, neighbour - MIDI_OFFSET]
        if other > value:
            return False
        if other == value and neighbour < midi:
            return False
    return True


def pick_candidates(table: np.ndarray) -> list[list[tuple[int, float]]]:
    """The mirror of EngineCore's `MultiFOSalience.candidates`.

    The returned candidates are the (midi, salience) pairs of one frame,
    STRONGEST-FIRST with the lower MIDI number winning a tie.
    """
    frames = []
    for frame in range(table.shape[0]):
        found = []
        for midi in range(MIDI_OFFSET, MIDI_OFFSET + BIN_COUNT):
            value = float(table[frame, midi - MIDI_OFFSET])
            if value < PEAK_OPTIONS["minimum_salience"]:
                continue
            if not is_local_max(table, frame, midi,
                                PEAK_OPTIONS["local_max_window_semitones"]):
                continue
            found.append((midi, value))
        found.sort(key=lambda item: (-item[1], item[0]))
        frames.append(found)
    return frames


# --------------------------------------------------------------------------
# The assignment (the Python mirror of EngineCore's VoiceAssignmentEngine)
# --------------------------------------------------------------------------

def range_prior(part: str, midi: int) -> float:
    bounds = RANGES.get(part)
    if bounds is None:
        return 0.0
    low, high = bounds
    if midi < low:
        outside = low - midi
    elif midi > high:
        outside = midi - high
    else:
        return 0.0
    capped = min(outside, OPTIONS["range_penalty_cap_semitones"])
    return -OPTIONS["range_penalty_per_semitone"] * capped


def base_score(part: str, midi: int, salience: float) -> float:
    return OPTIONS["salience_weight"] * salience + range_prior(part, midi)


def harmonic_score(lower: int, higher: int) -> float:
    interval = abs(higher - lower) % 12
    if interval in (0, 3, 4, 7, 8, 9):
        return 1.0
    if interval in (1, 2, 6, 10, 11):
        return -1.0
    return 0.0


def enumerate_states(frame: list[tuple[int, float]], parts: list[str]):
    """The mirror of `VoiceAssignmentEngine.enumerateStates`.

    Returns a list of (pitches, score), where `pitches` is per part (-1 =
    silent), in the LOW → HIGH part order.
    """
    candidates = sorted(frame, key=lambda item: item[0])
    results: list[tuple[tuple[int, ...], float]] = []

    def recurse(part_index: int, last_index: int, last_midi: int,
                pitches: list[int], score: float) -> None:
        if part_index == len(parts):
            results.append((tuple(pitches), score))
            return
        part = parts[part_index]
        # (a) the part is silent.
        recurse(part_index + 1, last_index, last_midi, pitches, score)
        # (b) the part takes a candidate.
        # A unison is only CONSIDERED when the part has no in-range candidate
        # of its own above the last assigned pitch — otherwise it would steal
        # that part's own note (and the model would pile every part onto the
        # strongest pitch, because a unison is worth one more salience
        # reward).
        has_own_candidate = any(
            index > last_index and range_prior(part, candidates[index][0]) == 0.0
            for index in range(len(candidates)))
        for candidate_index, (midi, salience) in enumerate(candidates):
            if candidate_index < last_index:
                continue
            if candidate_index == last_index:
                if (not OPTIONS["allow_unisons"] or last_midi != midi
                        or has_own_candidate):
                    continue
                value = score + base_score(part, midi, salience) - OPTIONS["unison_penalty"]
                pitches[part_index] = midi
                recurse(part_index + 1, candidate_index, midi, pitches, value)
                pitches[part_index] = -1
            else:
                value = score + base_score(part, midi, salience)
                if last_midi >= 0:
                    value += OPTIONS["harmonic_weight"] * harmonic_score(last_midi, midi)
                pitches[part_index] = midi
                recurse(part_index + 1, candidate_index, midi, pitches, value)
                pitches[part_index] = -1

    recurse(0, -1, -1, [-1] * len(parts), 0.0)
    return results


def best_frame_score(frame: list[tuple[int, float]], parts: list[str],
                     constrained_part: str | None = None,
                     constrained_midi: int | None = None):
    """The mirror of `VoiceAssignmentEngine.bestFrameScore`."""
    candidates = sorted(frame, key=lambda item: item[0])
    state_count = len(candidates) + 1
    dp = [-math.inf] * state_count
    dp[0] = 0.0
    for part in parts:
        nxt = [-math.inf] * state_count
        is_constrained = constrained_part == part
        for state in range(state_count):
            if dp[state] == -math.inf:
                continue
            last_index = state - 1
            last_midi = candidates[last_index][0] if last_index >= 0 else -1
            if not is_constrained:
                nxt[state] = max(nxt[state], dp[state])
            for candidate_index, (midi, salience) in enumerate(candidates):
                if is_constrained and constrained_midi != midi:
                    continue
                if candidate_index < last_index:
                    continue
                if candidate_index == last_index:
                    has_own_candidate = any(
                        index > last_index
                        and range_prior(part, candidates[index][0]) == 0.0
                        for index in range(len(candidates)))
                    if (not OPTIONS["allow_unisons"] or last_midi != midi
                            or has_own_candidate):
                        continue
                    value = dp[state] + base_score(part, midi, salience) - OPTIONS["unison_penalty"]
                    nxt[candidate_index + 1] = max(nxt[candidate_index + 1], value)
                else:
                    value = dp[state] + base_score(part, midi, salience)
                    if last_midi >= 0:
                        value += OPTIONS["harmonic_weight"] * harmonic_score(last_midi, midi)
                    nxt[candidate_index + 1] = max(nxt[candidate_index + 1], value)
        dp = nxt
    best = max(dp)
    return None if best == -math.inf else best


def posterior_by_pitch(frame: list[tuple[int, float]], parts: list[str]) -> dict[int, dict[str, float]]:
    """The mirror of `VoiceAssignmentEngine.posteriorByPitch`."""
    result: dict[int, dict[str, float]] = {}
    pitches = sorted({midi for midi, _ in frame})
    temperature = max(1e-6, OPTIONS["posterior_temperature"])
    for pitch in pitches:
        scores = []
        for part in parts:
            score = best_frame_score(frame, parts, part, pitch)
            if score is not None:
                scores.append((part, score))
        if not scores:
            continue
        maximum = max(score for _, score in scores)
        weights = {part: math.exp((score - maximum) / temperature) for part, score in scores}
        total = sum(weights.values())
        if total <= 0:
            continue
        result[pitch] = {part: weight / total for part, weight in weights.items()}
    return result


def transition_cost(old: list[int], new: list[int]) -> float:
    cost = 0.0
    for before, after in zip(old, new):
        if before == after:
            continue
        if before < 0:
            cost += OPTIONS["onset_penalty"]
        elif after < 0:
            cost += OPTIONS["offset_penalty"]
        else:
            cents = abs(float(after - before) * 100.0)
            cost += OPTIONS["smoothness_weight"] * min(cents, OPTIONS["smoothness_cap_cents"])
    return cost


def lex_less(lhs: tuple[int, ...], rhs: tuple[int, ...]) -> bool:
    for left, right in zip(lhs, rhs):
        if left != right:
            return left < right
    return len(lhs) < len(rhs)


def viterbi(frame_states: list[list[tuple[tuple[int, ...], float]]]) -> list[tuple[int, ...]]:
    """The mirror of `VoiceAssignmentEngine.viterbi`."""
    beam: list[tuple[tuple[int, ...], float, int]] = []
    history: list[list[tuple[tuple[int, ...], float, int]]] = []
    for states in frame_states:
        nxt: list[tuple[tuple[int, ...], float, int]] = []
        if not beam:
            for pitches, score in states:
                nxt.append((pitches, score, -1))
        else:
            for pitches, score in states:
                best = -math.inf
                best_index = -1
                for index, (old_pitches, old_score, _) in enumerate(beam):
                    value = old_score - transition_cost(list(old_pitches), list(pitches))
                    if value > best:
                        best = value
                        best_index = index
                nxt.append((pitches, best + score, best_index))
        nxt.sort(key=lambda entry: (-entry[1], entry[0]))
        beam = nxt[:max(1, OPTIONS["beam_width"])]
        history.append(beam)

    if not history or not history[-1]:
        return [tuple([-1] * len(states[0][0])) for states in frame_states]
    path: list[tuple[int, ...]] = [tuple() for _ in history]
    cursor = 0
    back = history[-1][0][2]
    for frame_index in range(len(history) - 1, -1, -1):
        entries = history[frame_index]
        index = min(max(0, cursor), len(entries) - 1)
        path[frame_index] = entries[index][0]
        cursor = back
        back = entries[index][2]
    return path


def build_notes(frames: list[dict], candidates: list[list[tuple[int, float]]],
                parts: list[str]):
    """The mirror of `VoiceAssignmentEngine.buildNotes`."""
    result: dict[str, list[dict]] = {}
    for part in parts:
        notes: list[dict] = []
        run_start = None
        run_end = 0.0
        run_saliences: list[float] = []
        run_confidences: list[float] = []
        run_pitch = -1

        def close_run():
            nonlocal run_start, run_pitch, run_saliences, run_confidences
            if run_start is None or run_pitch < 0:
                return
            duration = run_end - run_start
            if duration >= OPTIONS["minimum_note_duration_seconds"]:
                notes.append({
                    "start_s": run_start,
                    "end_s": run_end,
                    "midi": run_pitch,
                    "confidence": sum(run_confidences) / max(1, len(run_confidences)),
                    "salience": sum(run_saliences) / max(1, len(run_saliences)),
                })
            run_start = None
            run_pitch = -1
            run_saliences = []
            run_confidences = []

        for frame_index, frame in enumerate(frames):
            pitch = frame["pitches"].get(part, -1)
            frame_end = (frames[frame_index + 1]["time"] if frame_index + 1 < len(frames)
                         else frame_to_seconds(frame_index + 1))
            if pitch == run_pitch and run_start is not None:
                run_end = frame_end
                run_saliences.append(frame["saliences"].get(part, 0.0))
                run_confidences.append(frame["confidences"].get(part, 0.0))
                continue
            close_run()
            if pitch < 0:
                continue
            run_pitch = pitch
            run_start = frame["time"]
            run_end = frame_end
            run_saliences = [frame["saliences"].get(part, 0.0)]
            run_confidences = [frame["confidences"].get(part, 0.0)]
        close_run()

        # The overlap repair (C-2.3 V8): the earlier note's sustain is
        # truncated at the later note's onset.
        ordered = sorted(notes, key=lambda n: (n["start_s"], n["midi"]))
        repaired: list[dict] = []
        for note in ordered:
            if repaired and note["start_s"] < repaired[-1]["end_s"]:
                truncated = dict(repaired[-1])
                truncated["end_s"] = note["start_s"]
                if truncated["end_s"] > truncated["start_s"]:
                    repaired[-1] = truncated
                else:
                    repaired.pop()
            repaired.append(note)
        result[part] = repaired
    return result


def assign(candidates: list[list[tuple[int, float]]], parts: list[str]):
    """The full assignment (the mirror of `VoiceAssignmentEngine.assign`)."""
    frame_states = []
    for frame in candidates:
        states = enumerate_states(frame, parts)
        states.sort(key=lambda entry: (-entry[1], entry[0]))
        frame_states.append(states[:max(1, OPTIONS["frame_state_limit"])])
    path = viterbi(frame_states)

    frames = []
    for frame_index, frame_candidates in enumerate(candidates):
        pitches = path[frame_index] if frame_index < len(path) else tuple([-1] * len(parts))
        posteriors = posterior_by_pitch(frame_candidates, parts)
        frame_pitches: dict[str, int] = {}
        frame_confidences: dict[str, float] = {}
        frame_saliences: dict[str, float] = {}
        for part_index, part in enumerate(parts):
            pitch = pitches[part_index]
            if pitch < 0:
                continue
            frame_pitches[part] = pitch
            frame_confidences[part] = posteriors.get(pitch, {}).get(part, 0.0)
            for midi, salience in frame_candidates:
                if midi == pitch:
                    frame_saliences[part] = salience
                    break
            else:
                frame_saliences[part] = 0.0
        frames.append({
            "frame_index": frame_index,
            "time": frame_to_seconds(frame_index),
            "pitches": frame_pitches,
            "confidences": frame_confidences,
            "saliences": frame_saliences,
        })

    notes = build_notes(frames, candidates, parts)
    return frames, notes


def evaluate(frames: list[dict], truth: list[dict]) -> dict:
    """The mirror of `VoiceAssignmentEvaluator.evaluate`."""
    frames_all_correct = 0
    frames_any_correct = 0
    per_part_hits: dict[str, int] = {}
    per_part_slots: dict[str, int] = {}
    total_slots = 0
    total_hits = 0
    for index, frame in enumerate(frames):
        if index >= len(truth):
            break
        frame_truth = truth[index]
        all_correct = bool(frame_truth)
        any_correct = False
        for part, pitch in frame_truth.items():
            per_part_slots[part] = per_part_slots.get(part, 0) + 1
            total_slots += 1
            if frame["pitches"].get(part) == pitch:
                per_part_hits[part] = per_part_hits.get(part, 0) + 1
                total_hits += 1
                any_correct = True
            else:
                all_correct = False
        if all_correct:
            frames_all_correct += 1
        if any_correct:
            frames_any_correct += 1
    per_part_accuracy = {
        part: per_part_hits.get(part, 0) / slots
        for part, slots in per_part_slots.items() if slots > 0
    }
    macro = (sum(per_part_accuracy.values()) / len(per_part_accuracy)
             if per_part_accuracy else 0.0)
    frame_count = min(len(frames), len(truth))
    return {
        "frame_count": frame_count,
        "frames_all_parts_correct": frames_all_correct,
        "frames_any_part_correct": frames_any_correct,
        "frame_accuracy": frames_all_correct / frame_count if frame_count else 0.0,
        "frames_any_accuracy": frames_any_correct / frame_count if frame_count else 0.0,
        "per_part_accuracy": per_part_accuracy,
        "macro_part_accuracy": macro,
        "part_frame_slots": total_slots,
        "part_frame_hits": total_hits,
    }


# --------------------------------------------------------------------------
# The cases
# --------------------------------------------------------------------------

CASES = [
    {
        "name": "satb5",
        "fixture": "satb5_22050.wav",
        "parts": ["BASS", "BARITONE", "BARITENOR", "T2", "T1"],
        "why": "FIVE VOICES AT ONCE — the assignment's AC case (P-303: "
               ">=70% of the frames correctly assigned on this fixture).",
    },
]


def build_case(case: dict, model_path: Path) -> dict:
    path = FIXTURES / case["fixture"]
    audio, sr = bp.read_wav_mono(path)
    if sr != 22050:
        raise RuntimeError(f"{path.name}: expected 22050 Hz, got {sr}")

    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    session = ort.InferenceSession(str(model_path), so, providers=["CPUExecutionProvider"])
    chunks = bp.build_input_chunks(audio)
    raw_notes, _, _ = session.run(list(bp.OUTPUT_NAMES), {bp.INPUT_NAME: chunks})
    table = bp.unwrap_output(raw_notes, len(audio))

    candidates = pick_candidates(table)
    parts = sorted(case["parts"], key=lambda part: -SORT_ORDER[part])
    frames, notes = assign(candidates, parts)

    truth_sidecar = json.loads((FIXTURES / "satb5_22050_truth.json").read_text())
    # The truth sidecar maps each part to the pitch it sings (a LIST, because
    # a part may sing more than one pitch over the song). The fixture holds
    # one sustained pitch per part, so the frame truth is that pitch.
    truth_pitches = {part: pitches[0] for part, pitches in truth_sidecar["parts"].items()
                     if pitches}
    frame_count = len(frames)
    truth = [dict(truth_pitches) for _ in range(frame_count)]
    metrics = evaluate(frames, truth)

    # The notes the truth expects (for the note-level comparison).
    expected_notes = []
    for note in truth_sidecar["notes"]:
        expected_notes.append({"midi": note["midi"], "start_s": note["start_s"],
                               "end_s": note["end_s"]})

    return {
        "name": case["name"],
        "fixture": case["fixture"],
        "parts_low_to_high": parts,
        "why": case["why"],
        "frame_count": frame_count,
        "candidates": [[[midi, round(salience, 6)] for midi, salience in frame]
                       for frame in candidates],
        "truth": truth_pitches,
        "truth_repeat": frame_count,
        "assignment": [
            {
                "frame_index": frame["frame_index"],
                "time": round(frame["time"], 9),
                "pitches": [[parts.index(part), pitch]
                            for part, pitch in sorted(frame["pitches"].items())],
                "confidences": [[parts.index(part), round(value, 9)]
                                for part, value in sorted(frame["confidences"].items())],
            }
            for frame in frames
        ],
        "notes": {
            part: [
                {"start_s": round(note["start_s"], 9), "end_s": round(note["end_s"], 9),
                 "midi": note["midi"], "confidence": round(note["confidence"], 9),
                 "salience": round(note["salience"], 9)}
                for note in part_notes
            ]
            for part, part_notes in sorted(notes.items())
        },
        "expected": metrics,
        "expected_notes": expected_notes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--print", action="store_true", help="print the summary")
    parser.add_argument("--out", default=str(ARTIFACT))
    args = parser.parse_args()

    model_path = _ensure_model("basic-pitch")
    cases = [build_case(case, model_path) for case in CASES]

    artifact = {
        "artifact": "voice assignment (P-303)",
        "generated_by": "Tests/Spikes/assignment_dump.py",
        "model": {
            "sha256": _sha256(model_path),
            "role": "the multi-f0 posterior (P-302's salience table)",
            "license": "Apache-2.0 (CODE) / WEIGHTS TIER C per D-46 — "
                       "study-only for commercial distribution; never committed",
        },
        "config": {
            "options": OPTIONS,
            "peak_options": PEAK_OPTIONS,
            "part_ranges_midi": {part: list(bounds) for part, bounds in RANGES.items()},
            "sort_order": SORT_ORDER,
            "frame_clock": {
                "sample_rate": SAMPLE_RATE,
                "frame_hop": FRAME_HOP,
                "chunk_samples": CHUNK_SAMPLES,
                "overlap_frames": OVERLAP_FRAMES,
                "trimmed_frames_per_chunk": TRIMMED_FRAMES_PER_CHUNK,
            },
        },
        "note": "The `expected` block is computed by the PYTHON mirror of "
                "EngineCore's VoiceAssignmentEngine; the Swift test asserts "
                "its own computation agrees, so the two implementations "
                "cannot drift apart silently. The salience values are the "
                "MODEL'S POSTERIOR STRENGTH (C-12), never a confidence.",
        "cases": cases,
    }

    out = Path(args.out)
    out.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    for case in cases:
        report = case["expected"]
        print(f"  {case['name']:>16}: frame accuracy (ALL parts) "
              f"{report['frame_accuracy']:.3f} — {report['frames_all_parts_correct']}/"
              f"{report['frame_count']} frames; macro part accuracy "
              f"{report['macro_part_accuracy']:.3f}")
        for part, accuracy in sorted(report["per_part_accuracy"].items()):
            print(f"      {part:>10}: {accuracy:.3f}")
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
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
