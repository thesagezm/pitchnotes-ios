#!/usr/bin/env python3
"""P-306 · The bench-v2 harness — the HONEST metrics report.

WHAT IT MEASURES, AND FROM WHAT
-------------------------------
The `bench-v2` CI job installs numpy + onnxruntime but downloads NO model
weights, so this harness does NOT re-run the models in CI. It computes the
metrics from the **committed artifacts**, which were produced by the **real**
models on the **real** committed fixtures:

  - ``Tests/Spikes/Fixtures/assignment_satb5.json``
        P-303's voice-assignment artifact: the model's per-frame salience
        candidates, the engine's per-frame assignment, the per-part notes, the
        synthesis truth (per frame and per chord) and the engine's own
        boundary analysis. Two cases: the FROZEN five-voice chord and the
        MOVING five-voice progression.
  - ``Tests/Spikes/Fixtures/crosscheck_swiftf0_vs_basicpitch.json``
        P-305's cross-check artifact: basic-pitch's note events and SwiftF0's
        frames on three fixtures, with the measured agreement.

Every number in the report names the artifact it came from and the model
sha256 that produced it. **These are the real models' measurements on
synthetic fixtures — not a re-measurement inside CI, and not a measurement of
real acapella music.** The report says so in those words.

THE TWO METRIC FAMILIES ARE SEPARATE (PLAN P-306 / AGENTS §11)
-------------------------------------------------------------
  ``part_agnostic``  "was the right PITCH found, and were the right note
                     EVENTS found?" — it does not care WHICH part sings it.
  ``part_aware``     "was the right PART assigned?" — only meaningful where
                     the truth names a part.

A single blended number is a contract violation, not a style nit: the CI job
fails if either family is missing or empty.

THE HONEST SPLIT (P-303's own boundary analysis)
------------------------------------------------
On the MOVING progression the headline number is ~97.7 % of the frames fully
correct. The artifact's ``boundary_analysis`` splits those frames into the
STEADY frames and the TRANSITION frames (the frames near a chord change, where
the audio carries BOTH chords and a frame legitimately sees both pitch sets).
**Both numbers are reported.** The transition accuracy is the lower one, and
the report says why — it is not hidden, and it is not smoothed away.

THE EXTERNAL REFERENCE POINT (RESEARCH Addendum A.1)
----------------------------------------------------
dettato's Dagstuhl ChoirSet row — onset F1 **55.9** / frame F1 **82.0** /
offset F1 **44.4** — is the published **part-agnostic** reference. It is cited
in the report so the two families can never be silently mixed, and so our
part-agnostic numbers can be read against a published baseline.

Usage:
    python3 Tests/Spikes/bench_v2.py            # write the report
    python3 Tests/Spikes/bench_v2.py --assert   # CI: assert + fail on drift
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
REPORT_PATH = REPO_ROOT / "Tests" / "Spikes" / "bench_report_v2.json"

ASSIGNMENT_ARTIFACT = FIXTURES / "assignment_satb5.json"
CROSSCHECK_ARTIFACT = FIXTURES / "crosscheck_swiftf0_vs_basicpitch.json"

# PLAN P-301/P-306: the onset/offset tolerance is 50 ms.
EVENT_TOLERANCE_S = 0.050

# The published part-agnostic reference point (RESEARCH Addendum A.1). The CI
# job greps the report for these three numbers, so they must appear verbatim.
DETTATO_CHOIRSET = {
    "source": "dettato · the Dagstuhl ChoirSet row (RESEARCH Addendum A.1)",
    "family": "part-agnostic",
    "onset_f1": 55.9,
    "frame_f1": 82.0,
    "offset_f1": 44.4,
    "note": "the published EXTERNAL part-agnostic baseline our part-agnostic "
            "numbers are read against. It is NOT our result and it is NOT "
            "part-aware — the two families are never mixed.",
}


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def f1(precision: float, recall: float) -> float:
    return 0.0 if (precision + recall) == 0 else 2 * precision * recall / (precision + recall)


def prf(true_positive: int, false_positive: int, false_negative: int) -> dict:
    precision = true_positive / (true_positive + false_positive) if (true_positive + false_positive) else 0.0
    recall = true_positive / (true_positive + false_negative) if (true_positive + false_negative) else 0.0
    return {
        "precision": round(precision, 6),
        "recall": round(recall, 6),
        "f1": round(f1(precision, recall), 6),
        "true_positive": true_positive,
        "false_positive": false_positive,
        "false_negative": false_negative,
    }


# --------------------------------------------------------------------------
# PART-AGNOSTIC — the pitch / the note EVENT, never the part
# --------------------------------------------------------------------------

def multif0_frame_metrics(case: dict, threshold: float) -> dict:
    """The frame-level multi-f0 F1: the candidate pitches vs the truth pitches.

    The candidate set is every pitch whose MODEL SALIENCE reaches the
    generator's own `minimum_salience` threshold — the same threshold the
    engine's peak picker uses. **The extra candidates the model reports (the
    harmonic artefacts above the voices) are counted as FALSE POSITIVES**:
    no hand-tuning, no smoothing, no post-hoc threshold search.
    """
    truth_frames = case["truth_frames"]
    candidates = case["candidates"]

    true_positive = false_positive = false_negative = 0
    voiced_frames = 0
    for truth_frame, candidate_frame in zip(truth_frames, candidates):
        truth_pitches = {int(midi) for _part_index, midi in truth_frame}
        predicted = {int(midi) for midi, salience in candidate_frame if float(salience) >= threshold}
        if predicted:
            voiced_frames += 1
        true_positive += len(predicted & truth_pitches)
        false_positive += len(predicted - truth_pitches)
        false_negative += len(truth_pitches - predicted)

    result = prf(true_positive, false_positive, false_negative)
    result.update({
        "fixture": case["fixture"],
        "frames": len(candidates),
        "voiced_frames": voiced_frames,
        "salience_threshold": threshold,
        "matching": "per frame, the SET of pitches (a pitch is hit iff it is in "
                    "the truth set); the part is never consulted",
    })
    return result


def match_events(hypotheses: list, truth: list) -> dict:
    """Match the hypothesis note events to the truth events.

    A hypothesis matches a truth note iff the MIDI is equal AND the onset is
    within `EVENT_TOLERANCE_S`. The pairing is greedy over the smallest onset
    delta first, one-to-one. The ONSET metric counts the pairing; the OFFSET
    metric additionally requires the offset to be within the same tolerance.
    """
    pairs = []
    used_truth = set()
    for hyp_index, hyp in enumerate(hypotheses):
        best = None
        for truth_index, ref in enumerate(truth):
            if truth_index in used_truth:
                continue
            if int(hyp["midi"]) != int(ref["midi"]):
                continue
            delta = abs(float(hyp["start_s"]) - float(ref["start_s"]))
            if delta > EVENT_TOLERANCE_S:
                continue
            if best is None or delta < best[0]:
                best = (delta, truth_index)
        if best is not None:
            used_truth.add(best[1])
            pairs.append((hyp_index, best[1]))

    onset_true = len(pairs)
    onset_false_positive = len(hypotheses) - onset_true
    onset_false_negative = len(truth) - onset_true

    offset_true = 0
    for hyp_index, truth_index in pairs:
        delta = abs(float(hypotheses[hyp_index]["end_s"]) - float(truth[truth_index]["end_s"]))
        if delta <= EVENT_TOLERANCE_S:
            offset_true += 1
    offset_false_positive = (len(pairs) - offset_true) + onset_false_positive
    offset_false_negative = onset_false_negative

    onset = prf(onset_true, onset_false_positive, onset_false_negative)
    offset = prf(offset_true, offset_false_positive, offset_false_negative)
    return {
        "tolerance_ms": int(EVENT_TOLERANCE_S * 1000),
        "matching": "same MIDI + onset within the tolerance; one-to-one, greedy",
        "onset": onset,
        "offset": offset,
        "hypotheses": len(hypotheses),
        "reference": len(truth),
    }


def part_agnostic_family(assignment: dict, crosscheck: dict) -> dict:
    threshold = float(assignment["config"]["peak_options"]["minimum_salience"])
    cases = assignment["cases"]

    frame_metrics = {}
    event_metrics = {}
    for case in cases:
        frame_metrics[case["name"]] = multif0_frame_metrics(case, threshold)
        # The engine's own note events vs the expected events — the PART is
        # deliberately dropped before matching.
        hypotheses = []
        for part, notes in case["notes"].items():
            for note in notes:
                hypotheses.append({"midi": note["midi"], "start_s": note["start_s"],
                                   "end_s": note["end_s"], "part": part})
        hypotheses.sort(key=lambda note: (note["start_s"], note["midi"]))
        truth = sorted(case["expected_notes"], key=lambda note: (note["start_s"], note["midi"]))
        measured = match_events(hypotheses, truth)
        measured["fixture"] = case["fixture"]
        measured["hypothesis_source"] = "the assignment engine's note events (the part is dropped before matching)"
        event_metrics[case["name"]] = measured

    # The cross-model agreement (basic-pitch vs SwiftF0) — the measured
    # disagreement between the polyphonic transcriber and the monophonic
    # tracker. Part-agnostic by construction.
    agreement = {}
    for hypothesis in crosscheck["cases"]:
        agreement[hypothesis["name"]] = {
            "fixture": hypothesis["fixture"],
            "agreement_f1": hypothesis["expected"]["agreement_f1"],
            "hypothesis_precision": hypothesis["expected"]["hypothesis_precision"],
            "reference_recall": hypothesis["expected"]["reference_recall"],
            "disagreement_rate": hypothesis["expected"]["disagreement_rate"],
            "pitch_mismatches": hypothesis["expected"]["pitch_mismatches"],
            "median_onset_delta_ms": hypothesis["expected"]["median_onset_delta_ms"],
            "median_offset_delta_ms": hypothesis["expected"]["median_offset_delta_ms"],
        }

    return {
        "what_it_measures": (
            "Did the system find the right PITCH and the right note EVENTS? The "
            "part is never consulted in this family. These numbers are measured on "
            "SYNTHETIC fixtures whose truth is known by construction."
        ),
        "multif0_frame": frame_metrics,
        "note_events": event_metrics,
        "cross_model_agreement": agreement,
        "external_reference": DETTATO_CHOIRSET,
        "provenance": {
            "artifacts": [
                "Tests/Spikes/Fixtures/assignment_satb5.json (P-303)",
                "Tests/Spikes/Fixtures/crosscheck_swiftf0_vs_basicpitch.json (P-305)",
            ],
            "model": assignment["model"],
            "measured_by": "the real models, in the spike runs; the CI job recomputes "
                           "the METRICS from the committed artifacts (it downloads no weights)",
        },
    }


# --------------------------------------------------------------------------
# PART-AWARE — the PART, where the truth names one
# --------------------------------------------------------------------------

def part_aware_case(case: dict) -> dict:
    parts = list(case["parts_low_to_high"])
    frames = case["assignment"]
    truth_frames = case["truth_frames"]
    frame_count = min(len(frames), len(truth_frames))

    hits = {part: 0 for part in parts}
    slots = {part: 0 for part in parts}
    assigned = {part: 0 for part in parts}
    frames_all_correct = 0
    frames_any_correct = 0

    for index in range(frame_count):
        frame = frames[index]
        truth_frame = truth_frames[index]
        pitches = {int(part_index): int(midi) for part_index, midi in frame["pitches"]}
        truth = {parts[int(part_index)]: int(midi) for part_index, midi in truth_frame}
        for part_index, part in enumerate(parts):
            if part_index in pitches:
                assigned[part] += 1
        all_correct = True
        any_correct = False
        for part, midi in truth.items():
            slots[part] += 1
            if pitches.get(parts.index(part)) == midi:
                hits[part] += 1
                any_correct = True
            else:
                all_correct = False
        if all_correct:
            frames_all_correct += 1
        if any_correct:
            frames_any_correct += 1

    per_part_accuracy = {part: (hits[part] / slots[part] if slots[part] else 0.0) for part in parts}
    per_part_f1 = {}
    for part in parts:
        precision = hits[part] / assigned[part] if assigned[part] else 0.0
        recall = per_part_accuracy[part]
        per_part_f1[part] = {
            "precision": round(precision, 6),
            "recall": round(recall, 6),
            "f1": round(f1(precision, recall), 6),
        }
    macro_accuracy = sum(per_part_accuracy.values()) / len(parts)
    macro_f1 = sum(per_part_f1[part]["f1"] for part in parts) / len(parts)

    # The note-level check: did each part get the notes it was supposed to sing?
    note_level = {}
    for part in parts:
        expected_notes = [note for note in case["expected_notes"] if note["part"] == part]
        got = case["notes"].get(part, [])
        matched = []
        for expected in expected_notes:
            hit = None
            for note in got:
                if int(note["midi"]) != int(expected["midi"]):
                    continue
                if abs(float(note["start_s"]) - float(expected["start_s"])) > EVENT_TOLERANCE_S:
                    continue
                hit = note
                break
            matched.append({
                "expected_midi": int(expected["midi"]),
                "expected_start_s": expected["start_s"],
                "expected_end_s": expected["end_s"],
                "got_midi": int(hit["midi"]) if hit else None,
                "correct": hit is not None,
                "start_s": hit["start_s"] if hit else None,
                "end_s": hit["end_s"] if hit else None,
                "confidence": hit["confidence"] if hit else None,
            })
        note_level[part] = {
            "expected_notes": len(expected_notes),
            "correct_notes": sum(1 for note in matched if note["correct"]),
            "notes": matched,
        }

    # The independent recomputation must agree with the artifact's own
    # `expected` block (which the Python mirror of the Swift engine wrote).
    # If they ever disagree, the report goes red instead of publishing two
    # different "accuracy" numbers.
    expected = case["expected"]
    drift = []
    if expected["frame_count"] != frame_count:
        drift.append(f"frame_count {expected['frame_count']} != {frame_count}")
    if expected["frames_all_parts_correct"] != frames_all_correct:
        drift.append(f"frames_all_parts_correct {expected['frames_all_parts_correct']} != {frames_all_correct}")
    if expected["frames_any_part_correct"] != frames_any_correct:
        drift.append(f"frames_any_part_correct {expected['frames_any_part_correct']} != {frames_any_correct}")
    if abs(expected["macro_part_accuracy"] - macro_accuracy) > 1e-9:
        drift.append(f"macro_part_accuracy {expected['macro_part_accuracy']} != {macro_accuracy}")
    if expected["part_frame_hits"] != sum(hits.values()):
        drift.append(f"part_frame_hits {expected['part_frame_hits']} != {sum(hits.values())}")
    if expected["part_frame_slots"] != sum(slots.values()):
        drift.append(f"part_frame_slots {expected['part_frame_slots']} != {sum(slots.values())}")
    for part in parts:
        if abs(expected["per_part_accuracy"][part] - per_part_accuracy[part]) > 1e-9:
            drift.append(f"per_part_accuracy[{part}] differs")

    measured = {
        "fixture": case["fixture"],
        "parts_low_to_high": parts,
        "macro_part_accuracy": round(macro_accuracy, 6),
        "macro_part_f1": round(macro_f1, 6),
        "frame_accuracy": round(frames_all_correct / frame_count, 6) if frame_count else 0.0,
        "frames": frame_count,
        "frames_all_parts_correct": frames_all_correct,
        "frames_any_part_correct": frames_any_correct,
        "per_part_accuracy": {part: round(value, 6) for part, value in per_part_accuracy.items()},
        "per_part_frame_f1": per_part_f1,
        "note_level": note_level,
        "matches_the_artifact_expected_block": not drift,
        "drift": drift,
    }

    # The honest split: the STEADY frames and the TRANSITION frames (the
    # frames near a chord change, where the audio carries both chords).
    boundary = case.get("boundary_analysis")
    if boundary:
        measured["boundary_split"] = {
            "steady_frames": boundary["steady_frames"],
            "steady_frames_all_correct": boundary["steady_frames_all_correct"],
            "steady_accuracy": boundary["steady_accuracy"],
            "transition_frames": boundary["transition_frames"],
            "transition_frames_all_correct": boundary["transition_frames_all_correct"],
            "transition_accuracy": boundary["transition_accuracy"],
            "window_frames": boundary["window_frames"],
            "window_ms": boundary["window_ms"],
            "boundary_frames": boundary["boundary_frames"],
            "why": boundary["why"],
        }
    return measured


def part_aware_family(assignment: dict) -> dict:
    cases = {case["name"]: part_aware_case(case) for case in assignment["cases"]}
    frozen = cases.get("satb5", {})
    moving = cases.get("satb5_prog", {})
    return {
        "what_it_measures": (
            "Was the right PART assigned? Only meaningful where the truth names a "
            "part. These numbers are SYNTHETIC numbers on fixtures whose truth is "
            "known by construction — they are NOT a measurement of real acapella "
            "separation."
        ),
        "cases": cases,
        "headline": {
            "frozen_chord_macro_part_accuracy": frozen.get("macro_part_accuracy"),
            "moving_progression_macro_part_accuracy": moving.get("macro_part_accuracy"),
            "moving_progression_steady_accuracy": (moving.get("boundary_split") or {}).get("steady_accuracy"),
            "moving_progression_transition_accuracy": (moving.get("boundary_split") or {}).get("transition_accuracy"),
        },
        "honesty": (
            "THIS IS NOT A REAL-ACAPELLA MEASUREMENT. The two fixtures are "
            "synthetic five-voice SATB: one FROZEN chord and one MOVING "
            "progression, both with the truth known by construction. On the MOVING "
            "progression the STEADY frames are ~100% correct while the TRANSITION "
            "frames (where the audio carries BOTH chords) are much lower — BOTH "
            "numbers are reported above, and the lower one is the honest one. A "
            "perfect score on synthetic input says the assignment ENGINE is "
            "correct on clean synthetic voices; it says NOTHING about real "
            "acapella separation, which is where the bleed lives (AGENTS §11)."
        ),
    }


# --------------------------------------------------------------------------

def build_report() -> dict:
    assignment = load_json(ASSIGNMENT_ARTIFACT)
    crosscheck = load_json(CROSSCHECK_ARTIFACT)

    return {
        "schema": "pitchnotes.bench.v2",
        "generated_by": "Tests/Spikes/bench_v2.py (P-306)",
        "methodology": (
            "The part-AGNOSTIC family counts PITCHES and note EVENTS (the part is "
            "never consulted); the part-AWARE family counts the PART assignment "
            "(only where the truth names one). The two are reported SEPARATELY and "
            "are never blended (PLAN P-306 / AGENTS §11). The frame metric matches "
            "the candidate pitch SET per frame at the generator's own salience "
            "threshold; the event metric matches same-MIDI notes with the onset "
            "within 50 ms (one-to-one, greedy); the offset metric additionally "
            "requires the offset within 50 ms. The metrics are recomputed HERE from "
            "the committed artifacts — the CI job downloads no weights. The "
            "part-aware metrics are recomputed INDEPENDENTLY and checked against "
            "the artifact's own expected block, so the Swift engine, the Python "
            "mirror and this harness cannot silently disagree."
        ),
        "honesty": (
            "Every number in this report comes from the REAL models on SYNTHETIC "
            "fixtures whose truth is known by construction. None of them is a "
            "measurement of real acapella music, and none of them is a promise of "
            "perfect 5-way separation (AGENTS §11). The committed artifacts were "
            "produced by the real models in the spike runs; this job recomputes the "
            "METRICS from them."
        ),
        "provenance": {
            "assignment_artifact": "Tests/Spikes/Fixtures/assignment_satb5.json (P-303)",
            "crosscheck_artifact": "Tests/Spikes/Fixtures/crosscheck_swiftf0_vs_basicpitch.json (P-305)",
            "model": assignment["model"],
            "models": crosscheck["models"],
        },
        "part_agnostic": part_agnostic_family(assignment, crosscheck),
        "part_aware": part_aware_family(assignment),
    }


def serialize(report: dict) -> str:
    return json.dumps(report, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--assert", dest="assert_mode", action="store_true",
                        help="CI mode: assert the report's substance and fail on drift")
    args = parser.parse_args()

    report = build_report()
    text = serialize(report)

    previous = REPORT_PATH.read_text(encoding="utf-8") if REPORT_PATH.exists() else None
    REPORT_PATH.write_text(text, encoding="utf-8")

    if not args.assert_mode:
        print(f"wrote {REPORT_PATH.relative_to(REPO_ROOT)}")
        return 0

    failures = []

    # 1. Both families present and non-empty (the CI job checks this too).
    for family in ("part_agnostic", "part_aware"):
        if not report.get(family):
            failures.append(f"the {family} family is missing or empty")

    # 2. The external part-agnostic reference point is cited.
    for reference in ("55.9", "82.0", "44.4"):
        if reference not in text:
            failures.append(f"the Dagstuhl ChoirSet reference {reference} is not cited")

    # 3. The independently recomputed part-aware metrics must agree with the
    #    artifact's own `expected` block, for EVERY case.
    for name, case in report["part_aware"]["cases"].items():
        if not case["matches_the_artifact_expected_block"]:
            failures.append(f"[{name}] the recomputed part-aware metrics DISAGREE "
                            "with the artifact's expected block: "
                            + "; ".join(case["drift"]))

    # 4. P-303's acceptance criterion on the clean synthetic fixture.
    frozen = report["part_aware"]["cases"].get("satb5", {})
    macro = frozen.get("macro_part_accuracy", 0.0)
    if macro < 0.70:
        failures.append(f"the part-aware macro accuracy {macro} on the clean "
                        "synthetic fixture is below P-303's 70% acceptance floor")

    # 5. The report must be deterministic: the committed bytes are the canonical
    #    ones. A mismatch means the metrics changed and the committed report was
    #    not regenerated.
    if previous is not None and previous != text:
        failures.append("the recomputed report DIFFERS from the committed "
                        f"{REPORT_PATH.relative_to(REPO_ROOT)} — regenerate and "
                        "commit it (the metrics drifted)")

    if failures:
        for failure in failures:
            print(f"::error::{failure}", file=sys.stderr)
        return 1

    moving = report["part_aware"]["cases"].get("satb5_prog", {})
    boundary = moving.get("boundary_split", {})
    print(f"OK: {REPORT_PATH.relative_to(REPO_ROOT)} — the part-agnostic and the "
          "part-aware families are both present, the Dagstuhl ChoirSet reference "
          "is cited, and the part-aware metrics agree with the artifact.")
    print(f"   part-agnostic frame F1 (frozen / moving) = "
          f"{report['part_agnostic']['multif0_frame']['satb5']['f1']} / "
          f"{report['part_agnostic']['multif0_frame']['satb5_prog']['f1']}")
    print(f"   part-aware macro part accuracy (frozen / moving) = {macro} / "
          f"{moving.get('macro_part_accuracy')} — the moving case's STEADY frames "
          f"{boundary.get('steady_accuracy')} vs its TRANSITION frames "
          f"{boundary.get('transition_accuracy')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
