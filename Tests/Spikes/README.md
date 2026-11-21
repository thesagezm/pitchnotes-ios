# Tests/Spikes — spike contract harness (P-002, PAUL lane)

Structural spike-contract testing for the five model spikes (AGENTS §6). In M0 the
harness ran a **deterministic MOCK model** — no weights downloaded. From M1 (P-101)
the harness **self-upgrades to the real pinned models** when the environment allows:
if `onnxruntime` is importable, the spike downloads + SHA256-verifies the D-19-pinned
ONNX via `scripts/models/download.py` and asserts the real-model contract (accuracy
vs synthetic truth, gating, RTF/threads). Otherwise it prints a loud fallback banner
and runs the mock, so CI stays green until the spike venv gains `onnxruntime`.

## CI invocation (Leto's frozen job names, one line each)

```bash
python3 Tests/Spikes/run_spike.py --spike swiftf0
python3 Tests/Spikes/run_spike.py --spike nanopitch    # ribbon-spike job (D-19 rename) until P-102 renames it
python3 Tests/Spikes/run_spike.py --spike separation
python3 Tests/Spikes/run_spike.py --spike basicpitch
python3 Tests/Spikes/run_spike.py --spike silero-vad
python3 Tests/Spikes/run_spike.py --spike all   # local dev
```

Job names with the `-spike` suffix are normalized automatically. Exit 0 = green,
1 = violations (the runner lists every fired rule). macOS runners have python3 +
numpy or install it via `pip install numpy` in the job step.

## M1 REAL-model wiring (L-101 / Leto — one-line change per spike job)

The `swiftf0-spike` (and later `silero-vad-spike`) jobs go REAL by adding
`onnxruntime` to the spike venv in `.github/workflows/build.yml`:

```yaml
- name: Set up harness deps (numpy + onnxruntime in venv)
  run: |
    python3 -m venv "$HOME/spike-venv"
    "$HOME/spike-venv/bin/pip" install --quiet numpy onnxruntime
```

Nothing else changes: the spike downloads + verifies the pinned model itself
(135 KB SwiftF0 / 2.3 MB silero) into `Models/downloads` (gitignored cache) and
asserts the real contract. To make "real unavailable" a HARD failure (M1 gate —
no silent mock at merge time), set `PITCHNOTES_SPIKE_REAL=required` in the job env.
Until then jobs stay non-blocking with the mock fallback banner in the log.

## Files

- `spike_checks.py` — assertion library. Rule IDs (referenced in Docs/ENGINE.md):
  **S1** pitch in [46.9, 2093.75] Hz / 0.0 unvoiced (contract V11) · **S2** confidence
  [0,1] (V12) · **S3** finite samples · **S4** non-silence (RMS > −60 dBFS where
  expected) + accuracy-vs-truth behaviors · **S5** tensor shape/dtype per contract ·
  **S6** byte-identical determinism across runs · **S7** uniform 16 ms grid (V13) ·
  **S8** note events (midi 24–96, start<end, conf [0,1], sorted/non-overlapping —
  V7–V9 semantics) + RTF/budget checks. Swift-side parity lives in
  `Engine/Sources/EngineCore/Validators.swift` (V-rules) and the SwiftF0 core tests
  (pinned-model reference vectors), so the real engines assert the same contract.
- `run_spike.py` — runner; mock fallback with loud banner; `PITCHNOTES_SPIKE_REAL=required`
  hard-fails when the real path is unavailable (gate mode).
- `swiftf0_real.py` — P-101 real SwiftF0 spike: D-19-pinned ONNX (SHA-verified), ±20 c
  accuracy on sweep + synthetic-voice truth (`gen.sweep_f0`/`gen.synthetic_voice_f0`),
  silence gating, contract mapping hz==0 ⇔ conf<0.5, determinism, RTF table
  intra_op 1/2/4. Also runs standalone (`--threads-only`).
- `mock_model.py` — deterministic content-derived mocks (fallback only for spikes
  whose real runner has landed): zero-crossing pitch with SwiftF0-style band filter
  (swiftf0/nanopitch), RMS-gated causal VAD (nanopitch), RMS→sigmoid speech
  probability (silero-vad), seeded envelope stems (separation), seeded in-band note
  events (basicpitch). REAL-MODEL WIRING POINTS documented in its docstring.
- `Fixtures/` — committed synthetic fixtures + hash manifest (see Fixtures/README.md).
  The runner preflights fixture integrity against `fixtures.sha256` before every run
  (tampered bytes → red, verified).

## Mock behavior sanity (asserted, not just structural)

- silero-vad: silence fixture → mean prob ≤ 0.2; noise burst → max prob ≥ 0.5;
  clicks detected.
- swiftf0: the 8 s log sweep through the full contract band yields > 100 voiced
  in-band frames.
- nanopitch: VAD fires on the voiced fixture.
- separation/basicpitch: finite, non-silent, deterministic; SDR/accuracy are NOT
  asserted until the real models land (honesty rule — no fake quality numbers).

## Real-model results (local Linux run, P-101 — CI numbers logged per run)

SwiftF0 pinned ONNX (6385e8c2…): sweep |cents| med 7.39 / p95 17.41 (< 20 AC);
synthetic voice med 3.06 / p95 9.35; silence 125/125 frames gated; RTF (4 s audio,
median of 5): 0.0156 (1 thread) / 0.0098 (2) / 0.0089 (4) — target < 0.3.
Full history goes in Docs/BENCHMARKS.md (P-106 aggregates per environment).

