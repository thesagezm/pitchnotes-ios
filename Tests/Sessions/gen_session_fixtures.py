#!/usr/bin/env python3
"""L-402 — the synthetic M4 session fixtures: a sung-like pitch stream vs a
reference note track, per grading scenario.

WHAT THIS IS (CONTRACTS v1.2 C-18/C-19/C-20 + D-54; AGENTS §6's logic-tests
job): committed JSON fixtures a SCORING ENGINE (Jess's J-401, pure Swift) and
the CI `scoring-suite` gate both consume. Each fixture carries

  * a REFERENCE note track (the C-2.3/C-10 shape — `notes`, with v1.1
    metadata where the scenario needs it),
  * an OPTIONAL C-11 correction overlay / C-16 score-edit list,
  * the LIVE pitch frames (the C-2.4 shape, the 16 ms grid, engine_id/lookahead
    set per C-6.0's grading source),
  * the session ENVIRONMENT (C-20: tuningCents / transpositionSemitones /
    tempoScale / latencyOffset_ms),
  * `invariants` — data-level properties the GENERATOR guarantees and
    `--check` re-derives (grid uniformity, V-ranges, exact cents/dB offsets,
    the pinned C-20 transform math). They are properties of the DATA, checkable
    WITHOUT a scoring engine.

WHAT THIS DELIBERATELY DOES NOT CONTAIN: expected HIT/MISS verdicts or
expected scores. Computing those is the scoring engine's job (J-401) — a
fixture that carries its own grading answers cannot test the grader. The only
expected values here are ones the CONTRACT itself determines (the C-20
transform math, D-54's UNASSIGNED exclusion), and each is labelled with the
rule it pins.

DETERMINISM: every value is a closed-form formula or a fixed-seed LCG —
re-running this script reproduces the committed bytes exactly. `--check`
re-derives everything, verifies the invariants AND the sha256 manifest, and
exits non-zero on any drift (the gen.py integrity-gate precedent).

Usage:
    python3 -I gen_session_fixtures.py --write   # regenerate + refresh the manifest
    python3 -I gen_session_fixtures.py --check   # verify committed bytes + invariants
"""

import argparse
import hashlib
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DIR = os.path.join(HERE, "fixtures")

HOP_MS = 16
HOP_S = HOP_MS / 1000.0
VOICED_DB = -30.0
BREATH_DB = -75.0          # below C-19's default breathGate_db (-60.0)
SWIFTF0_LOOKAHEAD_MS = 176  # C-6.0's grading source


def lcg(seed):
    """A tiny deterministic LCG (the only 'randomness' anywhere here)."""
    state = seed

    def nxt():
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        return (state >> 33) / float(1 << 31)

    return nxt


def hz_of(midi_cents):
    """Equal-tempered frequency for a pitch expressed in cents (A4 = 6900)."""
    return 440.0 * (2.0 ** ((midi_cents - 6900.0) / 1200.0))


def cents_of(hz):
    """Inverse of hz_of — the pitch a frame's hz encodes, in cents."""
    return 6900.0 + 1200.0 * math.log2(hz / 440.0)


def frame(t, midi_cents, voiced=True, confidence=0.95, loudness=None):
    return {
        "t": round(t, 6),
        "hz": round(hz_of(midi_cents), 6) if voiced else 0.0,
        "confidence": confidence if voiced else 0.02,
        "loudness_db": loudness if loudness is not None else (VOICED_DB if voiced else BREATH_DB),
        "engine_id": "SWIFTF0",
        "lookahead_ms": SWIFTF0_LOOKAHEAD_MS,
    }



def session_stream(notes, cents_fns=None, voiced_fns=None, holes=()):
    """A SESSION's live frame stream (what the grader actually receives).

    The mic keeps sampling: the grid is CONTIGUOUS from the first covered tick
    to the last — inter-note silence is UNVOICED frames (breath/room tone at
    the breath level), never absent frames. The ONLY absent frames are the
    declared `holes` — uncovered spans (J-402's weak-phrase loop: the session
    sang selected spans, so a note outside every covered span has no frames at
    all). That is precisely the reality C-18's `notAssessableReason:
    "noLiveFrames"` exists for, so the fixture models it as a hole and the
    checker verifies it is the ONLY one.
    """
    if not notes:
        return []
    t0 = math.ceil(min(n["start_s"] for n in notes) / HOP_S) * HOP_S
    t1 = max(n["end_s"] for n in notes)
    out = []
    i = int(round(t0 / HOP_S))
    while i * HOP_S < t1 - 1e-9:
        t = i * HOP_S
        i += 1
        if any(h0 - 1e-9 <= t < h1 - 1e-9 for h0, h1 in holes):
            continue
        idx = None
        for k, n in enumerate(notes):
            if n["start_s"] - 1e-9 <= t < n["end_s"] - 1e-9:
                idx = k
                break
        if idx is None:
            out.append(frame(t, 0.0, voiced=False))
            continue
        if cents_fns is not None:
            cents = cents_fns[idx](t)
        else:
            cents = notes[idx]["midi"] * 100 + notes[idx]["cents_ref"]
        voiced = voiced_fns[idx](t) if voiced_fns is not None else True
        out.append(frame(t, cents if voiced else 0.0, voiced=voiced))
    return out


def track(part, notes, engine_version=None):
    t = {"contractVersion": "v1.1", "part": part, "notes": notes}
    if engine_version:
        t["engineVersion"] = engine_version
    return t


def note(start, end, midi, cents_ref=0, confidence=0.9, band=None, unison=None):
    n = {
        "start_s": start,
        "end_s": end,
        "midi": midi,
        "cents_ref": cents_ref,
        "confidence": confidence,
    }
    if band is not None:
        n["assignmentBand"] = band
    if unison is not None:
        n["unison"] = unison
    return n


ENV_ZERO = {"tuningCents": 0, "transpositionSemitones": 0, "tempoScale": 1.0,
            "latencyOffset_ms": 0}


def fixture(name, description, reference, live, environment, invariants,
            overlay=None, score_edits=None, contract_pins=None):
    f = {
        "fixture": name,
        "description": description,
        "contractVersion": "v1.2",
        "reference": reference,
        "live": {
            "contractVersion": "v0.0",
            "part": reference["part"],
            "hopMs": HOP_MS,
            "frames": live,
        },
        "environment": environment,
        "invariants": invariants,
    }
    if overlay is not None:
        f["correctionOverlay"] = overlay
    if score_edits is not None:
        f["scoreEdits"] = score_edits
    if contract_pins:
        f["contractPins"] = contract_pins
    return f


# --------------------------------------------------------------------------
# The scenarios. Each is (fixture-dict, check-function). The check functions
# re-derive the invariants from the emitted data — the fixture cannot drift
# from its own claims.
# --------------------------------------------------------------------------

def c20_transform(notes, start_s, semitones, tempo_scale):
    """C-20 §1/§2's mapping, applied to a composed reference — the SAME
    function the checker re-runs, pinned by the `key_tempo_shift` fixture."""
    out = []
    for n in notes:
        s2 = start_s + (n["start_s"] - start_s) / tempo_scale
        e2 = start_s + (n["end_s"] - start_s) / tempo_scale
        out.append({**n, "start_s": round(s2, 9), "end_s": round(e2, 9),
                    "midi": n["midi"] + semitones})
    return out


def build_scenarios():
    scenarios = []

    # 1 — steady, on-pitch singing. Every graded note should be a clean hit
    # under the default config; cents offsets come from cents_ref alone.
    notes = [note(0.5, 1.5, 48, cents_ref=+12), note(1.6, 2.6, 50, cents_ref=-30)]
    live = session_stream(notes)
    scenarios.append(fixture(
        "steady_sung",
        "On-pitch steady singing: two notes, gap 100 ms (both STEADY per D-54 "
        "§4 — the gap exceeds the 50 ms transition window).",
        track("BASS", notes), live, ENV_ZERO,
        ["every voiced frame sits at exactly midi*100 + cents_ref cents",
         "both notes are STEADY-class (inter-note gap 100 ms > 50 ms)",
         "the stream is CONTIGUOUS on the 16 ms grid — inter-note silence is "
         "unvoiced frames, not absent ones",
         "all voiced frames at -30 dB; unvoiced at the breath level"],
    ))

    # 2/3 — the D-22 pin: a faithful singer of a detuned recording is never
    # marked flat. The live stream sits at tuningCents; the grader offsets the
    # REFERENCE (D-22 §2) and must score hits.
    for name, tuning in (("detuned_sharp_35", +35), ("detuned_flat_35", -35)):
        notes = [note(0.4, 1.4, 48), note(1.5, 2.5, 50)]
        live = session_stream(notes,
                              cents_fns=[(lambda t, m=n["midi"] * 100 + tuning: m)
                                         for n in notes])
        scenarios.append(fixture(
            name,
            "The recording is %+d cents from A440 and the singer reproduces it "
            "faithfully (D-22). tuningCents is %d." % (tuning, tuning),
            track("BASS", notes), live,
            {**ENV_ZERO, "tuningCents": tuning},
            ["every voiced frame sits at exactly midi*100 %+d cents" % tuning,
             "reference notes carry cents_ref == 0 (the detune is the "
             "RECORDING's, not the note's)",
             "D-22 pin: with tuningCents consumed, deviation ~= 0 on every "
             "note; with tuningCents ignored, deviation ~= %+d" % tuning],
            contract_pins=["D-22 §2 (grading offsets the reference, never the "
                           "audio) — J-401's detuned-recording AC"],
        ))

    # 4 — the octave error. Frames sit EXACTLY one octave above the reference;
    # C-19's octaveEquivalence decides fold (hit) vs miss. The fixture is
    # deliberately ambiguous so Jess's test runs it BOTH ways.
    notes = [note(0.5, 1.5, 48), note(1.6, 2.6, 53)]
    live = session_stream(notes,
                          cents_fns=[lambda t, m=n["midi"] + 12: m * 100
                                     for n in notes])
    scenarios.append(fixture(
        "octave_error",
        "The singer reproduces the notes one octave high (the classic octave "
        "error). C-19's octaveEquivalence toggle (default TRUE) decides "
        "fold-then-measure vs miss.",
        track("BASS", notes), live, ENV_ZERO,
        ["every voiced frame sits at exactly (midi+12)*100 cents",
         "with octaveEquivalence true the fold maps the frames onto the "
         "reference (deviation ~= 0); with false the deviation is +1200 cents",
         "octave equivalence FOLDS FIRST, then measures cents (C-19)"],
        contract_pins=["C-19 octaveEquivalence (default true)"],
    ))

    # 5 — vibrato, mean-centered. 5.5 Hz swing ±40 cents about the note's
    # pitch; C-19's vibratoExtentCents=50 accepts it.
    n0 = note(0.5, 2.5, 48, cents_ref=0)
    rate, extent = 5.5, 40.0
    live = session_stream([n0],
                          cents_fns=[lambda t: 48 * 100 + extent * math.sin(2 * math.pi * rate * t)])
    scenarios.append(fixture(
        "vibrato_mean_centered",
        "A 5.5 Hz vibrato swinging ±40 cents MEAN-CENTERED about the note's "
        "pitch (C-19's vibrato model). The mean is the pitch; the swing is not "
        "an error.",
        track("BASS", [n0]), live, ENV_ZERO,
        ["|frame cents - note cents| <= 40.5 at every voiced frame",
         "the mean cents offset over any 220 ms window is within ±10 cents of "
         "the note's pitch",
         "every deviation stays inside C-19's default vibratoExtentCents=50"],
    ))

    # 6 — late onset vs the onset grace. A starts 90 ms late (INSIDE the
    # [80,120] grace), B 150 ms late (BEYOND it), C on time. The stream stays
    # contiguous: the pre-onset time is unvoiced frames, not absent ones.
    notes = [note(0.5, 1.5, 48), note(1.6, 2.6, 50), note(2.7, 3.7, 52)]
    late = [0.090, 0.150, 0.0]
    live = session_stream(notes,
                          voiced_fns=[(lambda t, s=n["start_s"] + late[k]:
                                       t >= s - 1e-9)
                                      for k, n in enumerate(notes)])
    scenarios.append(fixture(
        "late_onset_grace",
        "Three on-pitch notes with different onset latencies: +90 ms (inside "
        "C-19's onset grace [80,120]), +150 ms (outside it), on time. The "
        "stream is contiguous — pre-onset time is unvoiced frames.",
        track("BASS", notes), live, ENV_ZERO,
        ["note 0's first VOICED frame is the first grid tick at/after "
         "start+90 ms (grace applies)",
         "note 1's first VOICED frame is the first grid tick at/after "
         "start+150 ms (grace does NOT apply)",
         "note 2's first voiced frame is its first grid tick",
         "post-onset cents deviation is ~0 on all three notes"],
    ))

    # 7 — breath, silence, dropout. A: a 300 ms breath THEN on-pitch (sustain
    # starts late). B: all frames at breath level (the singer is silent). C: a
    # HOLE — no frames at all in its span (the uncovered-span reality C-18's
    # noLiveFrames reason exists for). D: clean.
    notes = [note(0.5, 1.5, 48), note(1.6, 2.6, 50), note(2.7, 3.7, 52),
             note(3.8, 4.8, 53)]
    holes = [(notes[2]["start_s"], notes[2]["end_s"])]
    live = session_stream(
        notes,
        voiced_fns=[lambda t, s=notes[0]["start_s"] + 0.300: t >= s - 1e-9,
                    lambda t: False,
                    lambda t: True,   # unreachable — the hole removes these ticks
                    lambda t: True],
        holes=holes)
    scenarios.append(fixture(
        "breath_silence_dropout",
        "Four notes: a leading breath (300 ms below the -60 dB breath gate, "
        "then on-pitch), a fully silent note (every frame below the gate), a "
        "note whose span is a GRID HOLE (no frames at all — the uncovered-span "
        "reality of the weak-phrase loop), and a clean note.",
        track("BASS", notes), live, ENV_ZERO,
        ["note 0: frames 0.5-0.784 s are UNVOICED at -75 dB; the rest voiced "
         "on-pitch (C-19 breathGate_db=-60 applies to the first 300 ms)",
         "note 1: every frame unvoiced at -75 dB (coverage 0 — a miss, not a "
         "pitch error)",
         "note 2: the ONLY grid hole in the stream — NO frames in [2.7, 3.7); "
         "C-18's notAssessable reason 'noLiveFrames' is the contract's answer",
         "note 3: fully voiced and on-pitch",
         "everywhere else the stream is contiguous on the 16 ms grid"],
        contract_pins=["C-18 notAssessableReason 'noLiveFrames' (uncovered span)",
                       "C-19 breathGate_db default -60.0"],
    ))

    # 8 — the D-54 confidence/unison policy. On-pitch singing against a
    # reference that carries all three assignment bands + a unison flag.
    notes = [
        note(0.5, 1.5, 48, confidence=0.90, band="CONFIRMED"),
        note(1.6, 2.6, 50, confidence=0.60, band="PROVISIONAL"),
        note(2.7, 3.7, 52, confidence=0.30, band="UNASSIGNED"),
        note(3.8, 4.8, 53, confidence=0.90, band="CONFIRMED", unison=True),
    ]
    live = session_stream(notes)
    scenarios.append(fixture(
        "low_confidence_unison",
        "On-pitch singing against a reference carrying all three C-10 "
        "assignment bands plus a unison note — the D-54 policy scenario.",
        track("BASS", notes), live, ENV_ZERO,
        ["bands are COHERENT with confidence (V18): 0.90 CONFIRMED, 0.60 "
         "PROVISIONAL, 0.30 UNASSIGNED, 0.90 CONFIRMED+unison",
         "note 2 (UNASSIGNED) is excluded from grading by default and the "
         "exclusion is VISIBLE (C-18 notAssessable reason 'unassigned')",
         "notes 0/1/3 are graded at FULL weight — confidence is reported, "
         "never a weight (D-54 §2)",
         "note 3 is graded PER-PART (unison never merges singers, D-54 §3)"],
        contract_pins=["D-54 §1 (UNASSIGNED excluded, visibly)",
                       "D-54 §2 (PROVISIONAL graded, full weight)",
                       "D-54 §3 (unison per-part)",
                       "C-14 (UNASSIGNED excluded by default)"],
    ))

    # 9 — the correction overlay. A C-11 overlay exercising all three ops in
    # order against a 4-note reference; `--check` validates it against C-11's
    # own rules (op order, indices in range, splitAt strictly inside).
    notes = [note(0.5, 1.5, 48), note(1.6, 2.6, 50), note(2.7, 3.7, 52),
             note(3.8, 4.8, 53)]
    overlay = {
        "contractVersion": "v1.1",
        "part": "BASS",
        "engineVersion": "corrections-0.1.0",
        "operations": [
            {"op": "reassign", "fromPart": "BASS", "toPart": "BARITONE",
             "noteIndex": 1, "midi": 50},
            {"op": "delete", "fromPart": "BASS", "noteIndex": 3},
            {"op": "split", "fromPart": "BASS", "noteIndex": 0,
             "splitAt_s": 1.0, "toParts": ["BASS", "BASS"]},
        ],
    }
    live = session_stream(notes)
    scenarios.append(fixture(
        "correction_overlay",
        "A C-11 overlay with all three ops in application order (reassign "
        "note 1 to BARITONE, delete note 3, split note 0 at 1.0 s) over "
        "on-pitch singing. The overlay WINS as the grading reference (C-14 "
        "case 1).",
        track("BASS", notes), live, ENV_ZERO,
        ["overlay ops are ordered and reference the ENGINE's original indices "
         "(0-based)",
         "splitAt_s 1.0 is strictly inside note 0 [0.5, 1.5]",
         "reassign carries the corrected midi (50)",
         "the engine's notes/<PART>.json is NEVER mutated by any of this "
         "(C-11 rule 1)"],
        overlay=overlay,
    ))

    # 10 — the C-20 transform pin. A 3-note reference + overlay; the fixture
    # carries the EXPECTED transformed track at +2 semitones / 1.25x tempo,
    # recomputed by --check from the C-20 formulas.
    notes = [note(1.0, 2.0, 48, cents_ref=+12), note(2.15, 3.15, 50),
             note(3.5, 4.5, 52, cents_ref=-30)]
    expected = c20_transform(notes, 0.0, +2, 1.25)
    scenarios.append(fixture(
        "key_tempo_shift",
        "The C-20 view transform pinned: the SAME reference at "
        "transpositionSemitones=+2, tempoScale=1.25. midi moves +2; every time "
        "scales about the session start by 1/1.25; tuningCents is PRESERVED.",
        track("BASS", notes),
        [],  # no live stream — this fixture pins the transform math only
        {**ENV_ZERO, "transpositionSemitones": 2, "tempoScale": 1.25},
        ["expectedTransformed is the C-20 mapping of `reference` (midi+2, "
         "times scaled about start by 1/tempoScale)",
         "cents_ref is UNCHANGED by the transform (C-20 §3: a semitone shift "
         "preserves the cents offset)",
         "the overlay's splitAt_s transforms by the SAME time map (C-20 §2)"],
        overlay={
            "contractVersion": "v1.1",
            "part": "BASS",
            "operations": [
                {"op": "split", "fromPart": "BASS", "noteIndex": 0,
                 "splitAt_s": 1.5, "toParts": ["BASS", "BASS"]},
            ],
        },
        contract_pins=["C-20 §1/§2/§3 (the view transform; overlay maps "
                       "identically; tuningCents preserved)"],
    ))
    # attach the expected transform (kept OUT of `invariants` — it is data)
    scenarios[-1]["expectedTransformed"] = expected

    # 11 — the steady/transition class pin. A legato pair (gap 30 ms <= 50 ms
    # → the second note is TRANSITION-class) and an isolated note.
    notes = [note(0.5, 1.5, 48), note(1.53, 2.53, 50), note(3.0, 4.0, 52)]
    expected_classes = ["steady", "transition", "steady"]
    scenarios.append(fixture(
        "steady_vs_transition",
        "D-54 §4's class computation pinned: a legato pair (gap 30 ms ≤ the "
        "50 ms window → note 1 is TRANSITION-class) and an isolated note "
        "(gap 470 ms → STEADY).",
        track("BASS", notes), [], ENV_ZERO,
        ["note 0 → steady (first note of the part)",
         "note 1 → TRANSITION (starts 30 ms after note 0 ends, ≤ 50 ms)",
         "note 2 → steady (gap 470 ms > 50 ms)",
         "expectedClasses mirrors D-54 §4 exactly"],
        contract_pins=["D-54 §4 (steady vs transition, 50 ms window)"],
    ))
    scenarios[-1]["expectedClasses"] = expected_classes

    return scenarios


# --------------------------------------------------------------------------
# Checking — re-derive every claim from the emitted data.
# --------------------------------------------------------------------------

def check_common(f):
    """The V-rule layer every fixture must satisfy (C-2.3/C-10 + C-2.4)."""
    errs = []
    ref = f["reference"]
    notes = ref["notes"]
    if ref["part"] != f["live"]["part"] and f["live"]["frames"]:
        errs.append("reference part != live part")
    prev_end = None
    for i, n in enumerate(notes):
        if not (24 <= n["midi"] <= 96):
            errs.append("note %d midi out of V9 range" % i)
        if not (-50 <= n["cents_ref"] <= 50):
            errs.append("note %d cents_ref out of V9 range" % i)
        if not (0.0 <= n["confidence"] <= 1.0):
            errs.append("note %d confidence out of [0,1]" % i)
        if n["start_s"] >= n["end_s"]:
            errs.append("note %d fails V7 (start >= end)" % i)
        if prev_end is not None and n["start_s"] < prev_end - 1e-9:
            errs.append("note %d overlaps the previous note (V8)" % i)
        prev_end = n["end_s"]
        band = n.get("assignmentBand")
        if band is not None:
            c = n["confidence"]
            want = ("CONFIRMED" if c >= 0.80 else
                    "PROVISIONAL" if c >= 0.50 else "UNASSIGNED")
            if band != want:
                errs.append("note %d band %s disagrees with confidence %s (V18)"
                            % (i, band, want))
    frames = f["live"]["frames"]
    # Declared grid holes: spans with NO frames (uncovered spans — the C-18
    # noLiveFrames reality). Every fixture must declare exactly the holes it
    # intends; an undeclared gap fails V13.
    allowed_holes = 1 if f["fixture"] == "breath_silence_dropout" else 0
    prev_t = None
    holes = []
    for i, fr in enumerate(frames):
        if not (0.0 <= fr["confidence"] <= 1.0):
            errs.append("frame %d confidence out of [0,1] (V12)" % i)
        hz = fr["hz"]
        if hz == 0.0:
            if fr["loudness_db"] > -60.0:
                errs.append("frame %d unvoiced but loudness above the gate" % i)
        else:
            if not (46.9 <= hz <= 2093.75):
                errs.append("frame %d hz out of V11 range" % i)
        t = fr["t"]
        if prev_t is not None:
            dt = t - prev_t
            if dt < HOP_S - 0.001 or dt > HOP_S + 0.001:
                holes.append((prev_t, t))
        prev_t = t
    if len(holes) != allowed_holes:
        errs.append("%s: %d undeclared grid holes (allowed %d): %r"
                    % (f["fixture"], len(holes), allowed_holes, holes))
    if f["fixture"] == "breath_silence_dropout" and len(holes) == 1:
        n2 = notes[2]
        h0, h1 = holes[0]
        if not (h0 <= n2["start_s"] + 1e-9 and h1 >= n2["end_s"] - 1e-9):
            errs.append("breath_silence_dropout: the hole does not cover note "
                        "2's span (%r vs [%r, %r])" % (holes[0], n2["start_s"],
                                                       n2["end_s"]))
    return errs


def check_scenario(f):
    """The per-scenario invariants — re-derived from the data, not trusted."""
    name = f["fixture"]
    errs = []
    notes = f["reference"]["notes"]
    frames = f["live"]["frames"]
    env = f["environment"]

    def voiced_cents_and_t():
        return [(fr["t"], cents_of(fr["hz"])) for fr in frames if fr["hz"] != 0.0]

    if name == "steady_sung":
        for n in notes:
            want = n["midi"] * 100 + n["cents_ref"]
            for t, c in voiced_cents_and_t():
                if n["start_s"] - 1e-6 <= t < n["end_s"] + 1e-6:
                    if abs(c - want) > 0.5:
                        errs.append("frame at %.3f off the reference pitch" % t)
        gaps = [notes[i + 1]["start_s"] - notes[i]["end_s"] for i in range(len(notes) - 1)]
        if any(g <= 0.050 for g in gaps):
            errs.append("steady_sung must have no legato gap")

    elif name in ("detuned_sharp_35", "detuned_flat_35"):
        tuning = env["tuningCents"]
        want_sign = 35 if name.endswith("sharp_35") else -35
        if tuning != want_sign:
            errs.append("%s environment tuningCents must be %+d" % (name, want_sign))
        for n in notes:
            if n["cents_ref"] != 0:
                errs.append("%s reference must carry cents_ref 0" % name)
            for t, c in voiced_cents_and_t():
                if n["start_s"] - 1e-6 <= t < n["end_s"] + 1e-6:
                    if abs(c - (n["midi"] * 100 + tuning)) > 0.5:
                        errs.append("frame at %.3f not at the tuning offset" % t)

    elif name == "octave_error":
        for n in notes:
            for t, c in voiced_cents_and_t():
                if n["start_s"] - 1e-6 <= t < n["end_s"] + 1e-6:
                    if abs(c - (n["midi"] + 12) * 100) > 0.5:
                        errs.append("frame at %.3f is not an exact octave up" % t)

    elif name == "vibrato_mean_centered":
        n0 = notes[0]
        base = n0["midi"] * 100 + n0["cents_ref"]
        for t, c in voiced_cents_and_t():
            if abs(c - base) > 40.5:
                errs.append("vibrato frame at %.3f exceeds the ±40 extent" % t)
        # the mean over any sliding 220 ms window stays within ±10 cents
        w = 0.220
        step = HOP_S
        t0 = frames[0]["t"]
        t1 = frames[-1]["t"]
        wt = t0
        while wt + w <= t1 + 1e-9:
            xs = [c for t, c in voiced_cents_and_t() if wt <= t < wt + w]
            if len(xs) >= 8 and abs(sum(xs) / len(xs) - base) > 10.0:
                errs.append("vibrato mean over window at %.3f exceeds ±10 cents" % wt)
            wt += step

    elif name == "late_onset_grace":
        lates = [0.090, 0.150, 0.0]
        for idx, n in enumerate(notes):
            firsts = [t for t, _ in voiced_cents_and_t() if n["start_s"] - 1e-6 <= t < n["end_s"]]
            if not firsts:
                errs.append("note %d has no voiced frames" % idx)
                continue
            # the first VOICED frame is the first grid tick at/after
            # start + late (the pre-onset ticks are unvoiced, present)
            want = math.ceil((n["start_s"] + lates[idx]) / HOP_S - 1e-9) * HOP_S
            if abs(firsts[0] - want) > 1e-6:
                errs.append("note %d onset mismatch: got %r want %r"
                            % (idx, firsts[0], want))

    elif name == "breath_silence_dropout":
        n0, n1, n2, n3 = notes
        # note 0: unvoiced (breath) until +0.300, then voiced on-pitch
        breath = [fr for fr in frames
                  if n0["start_s"] - 1e-6 <= fr["t"] < n0["start_s"] + 0.300 - 1e-6]
        if breath and any(fr["hz"] != 0.0 for fr in breath):
            errs.append("note 0 breath window contains voiced frames")
        after = [fr for fr in frames
                 if n0["start_s"] + 0.300 - 1e-6 <= fr["t"] < n0["end_s"]]
        if not after or any(fr["hz"] == 0.0 for fr in after):
            errs.append("note 0 post-breath frames must all be voiced")
        # note 1: all unvoiced
        sil = [fr for fr in frames if n1["start_s"] - 1e-6 <= fr["t"] < n1["end_s"]]
        if not sil or any(fr["hz"] != 0.0 for fr in sil):
            errs.append("note 1 must be fully unvoiced")
        # note 2: NO frames at all
        drop = [fr for fr in frames if n2["start_s"] - 1e-6 <= fr["t"] < n2["end_s"]]
        if drop:
            errs.append("note 2 must have no frames (dropout)")
        # note 3: clean
        clean = [fr for fr in frames if n3["start_s"] - 1e-6 <= fr["t"] < n3["end_s"]]
        if not clean or any(fr["hz"] == 0.0 for fr in clean):
            errs.append("note 3 must be fully voiced")

    elif name == "low_confidence_unison":
        bands = [n.get("assignmentBand") for n in notes]
        if bands != ["CONFIRMED", "PROVISIONAL", "UNASSIGNED", "CONFIRMED"]:
            errs.append("low_confidence_unison bands drifted")
        if notes[3].get("unison") is not True:
            errs.append("note 3 must carry unison=true")
        for n in notes:  # the singer sang everything on-pitch
            for t, c in voiced_cents_and_t():
                if n["start_s"] - 1e-6 <= t < n["end_s"] + 1e-6:
                    if abs(c - n["midi"] * 100) > 0.5:
                        errs.append("frame at %.3f off pitch" % t)

    elif name == "correction_overlay":
        ov = f["correctionOverlay"]
        if ov["contractVersion"] != "v1.1":
            errs.append("overlay contractVersion must be v1.1")
        if [op["op"] for op in ov["operations"]] != ["reassign", "delete", "split"]:
            errs.append("overlay must exercise the three ops in order")
        by_idx = {op["noteIndex"]: op for op in ov["operations"]}
        for op in ov["operations"]:
            if not (0 <= op["noteIndex"] < len(notes)):
                errs.append("overlay op targets a nonexistent noteIndex")
        if abs(by_idx[0]["splitAt_s"] - 1.0) > 1e-9:
            errs.append("split op drifted")
        n0 = notes[0]
        if not (n0["start_s"] < by_idx[0]["splitAt_s"] < n0["end_s"]):
            errs.append("splitAt_s is not strictly inside note 0")

    elif name == "key_tempo_shift":
        env_semi = env["transpositionSemitones"]
        env_scale = env["tempoScale"]
        if (env_semi, env_scale) != (2, 1.25):
            errs.append("key_tempo_shift environment drifted")
        recomputed = c20_transform(notes, 0.0, env_semi, env_scale)
        want = f["expectedTransformed"]
        if len(recomputed) != len(want):
            errs.append("expectedTransformed length mismatch")
        else:
            for a, b in zip(recomputed, want):
                if a["midi"] != b["midi"] or abs(a["start_s"] - b["start_s"]) > 1e-9 \
                        or abs(a["end_s"] - b["end_s"]) > 1e-9 \
                        or a["cents_ref"] != b["cents_ref"]:
                    errs.append("expectedTransformed disagrees with the C-20 math")
        ov = f["correctionOverlay"]
        # C-20 §2: the overlay's splitAt_s is in UNTRANSPOSED time — the same
        # time map applies: t' = (t - start)/scale + start.
        sa = ov["operations"][0]["splitAt_s"]
        mapped = 0.0 + (sa - 0.0) / env_scale
        if abs(mapped - 1.2) > 1e-9:
            errs.append("overlay splitAt_s transform drifted")

    elif name == "steady_vs_transition":
        want = f["expectedClasses"]
        got = ["steady"]
        for i in range(1, len(notes)):
            gap = notes[i]["start_s"] - notes[i - 1]["end_s"]
            got.append("transition" if gap <= 0.050 else "steady")
        if got != want:
            errs.append("expectedClasses disagree with D-54 §4: %r vs %r"
                        % (got, want))

    else:
        errs.append("unknown fixture %s — add a check branch" % name)

    return errs


def build_all():
    return build_scenarios()


def check_all(fixtures, manifest):
    errs = []
    seen = {}
    for f in fixtures:
        name = f["fixture"]
        body = json.dumps(f, sort_keys=True, indent=1) + "\n"
        digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
        seen[name + ".json"] = digest
        if name + ".json" not in manifest:
            errs.append("%s.json missing from the manifest" % name)
        elif manifest[name + ".json"] != digest:
            errs.append("%s.json: sha256 drift against the committed manifest"
                        % name)
        errs += ["%s: %s" % (name, e) for e in check_common(f)]
        errs += ["%s: %s" % (name, e) for e in check_scenario(f)]
    for k in manifest:
        if k not in seen:
            errs.append("manifest entry %s has no fixture" % k)
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true",
                    help="regenerate the fixtures + refresh the manifest")
    ap.add_argument("--check", action="store_true",
                    help="verify the committed bytes + all invariants (CI)")
    args = ap.parse_args()
    fixtures = build_all()

    manifest_path = os.path.join(FIXTURE_DIR, "fixtures.sha256")
    manifest = {}
    if os.path.exists(manifest_path):
        for line in open(manifest_path):
            line = line.strip()
            if line and not line.startswith("#"):
                digest, _, fname = line.partition("  ")
                manifest[fname.strip()] = digest

    if args.write:
        os.makedirs(FIXTURE_DIR, exist_ok=True)
        for f in fixtures:
            body = json.dumps(f, sort_keys=True, indent=1) + "\n"
            path = os.path.join(FIXTURE_DIR, f["fixture"] + ".json")
            with open(path, "w") as fh:
                fh.write(body)
        lines = ["# L-402 session fixtures — sha256 manifest (gen_session_fixtures.py)"]
        for f in fixtures:
            body = json.dumps(f, sort_keys=True, indent=1) + "\n"
            digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
            lines.append("%s  %s.json" % (digest, f["fixture"]))
        with open(manifest_path, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        print("wrote %d fixtures + the manifest" % len(fixtures))
        return 0

    if args.check:
        # the committed bytes must match the generator's output byte-for-byte
        byte_errs = []
        for f in fixtures:
            path = os.path.join(FIXTURE_DIR, f["fixture"] + ".json")
            if not os.path.exists(path):
                byte_errs.append("%s.json missing" % f["fixture"])
                continue
            want = json.dumps(f, sort_keys=True, indent=1) + "\n"
            got = open(path).read()
            if got != want:
                byte_errs.append("%s.json: committed bytes disagree with the "
                                 "generator (determinism broken)" % f["fixture"])
        errs = check_all(fixtures, manifest) if not byte_errs else []
        all_errs = byte_errs + errs
        if all_errs:
            for e in all_errs:
                print("FAIL: %s" % e, file=sys.stderr)
            return 1
        print("OK: %d fixtures, all invariants + the sha256 manifest verified"
              % len(fixtures))
        return 0

    ap.error("pass --write or --check")


if __name__ == "__main__":
    sys.exit(main())
