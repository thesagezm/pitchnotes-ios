# Tests/Spikes — spike contract harness (P-002, PAUL lane)

Structural spike-contract testing for the five model spikes (AGENTS §6). In M0 the
harness runs a **deterministic MOCK model** — no weights are downloaded (D-2 repo
pending) — so CI passes structurally and the real models slot in at M1/M2/M3 with
only the mock swapped out.

## CI invocation (Leto's frozen job names, one line each)

```bash
python3 Tests/Spikes/run_spike.py --spike swiftf0
python3 Tests/Spikes/run_spike.py --spike nanopitch
python3 Tests/Spikes/run_spike.py --spike separation
python3 Tests/Spikes/run_spike.py --spike basicpitch
python3 Tests/Spikes/run_spike.py --spike silero-vad
python3 Tests/Spikes/run_spike.py --spike all   # local dev
```

Job names with the `-spike` suffix are normalized automatically. Exit 0 = green,
1 = violations (the runner lists every fired rule). macOS runners have python3 +
numpy or install it via `pip install numpy` in the job step.

## Files

- `spike_checks.py` — assertion library. Rule IDs (referenced in Docs/ENGINE.md):
  **S1** pitch in [46.9, 2093.75] Hz / 0.0 unvoiced (contract V11) · **S2** confidence
  [0,1] (V12) · **S3** finite samples · **S4** non-silence (RMS > −60 dBFS where
  expected) · **S5** tensor shape/dtype per contract · **S6** byte-identical
  determinism across runs · **S7** uniform 16 ms grid (V13) · **S8** note events
  (midi 24–96, start<end, conf [0,1], sorted/non-overlapping — V7–V9 semantics).
  Swift-side parity lives in `Engine/Sources/EngineCore/Validators.swift` (V-rules),
  so J-004 and the real engines assert the same contract.
- `mock_model.py` — deterministic content-derived mocks: zero-crossing pitch with
  SwiftF0-style band filter (swiftf0/nanopitch), RMS-gated causal VAD (nanopitch),
  RMS→sigmoid speech probability (silero-vad), seeded envelope stems (separation),
  seeded in-band note events (basicpitch). REAL-MODEL WIRING POINTS documented in
  its docstring (M1: SwiftF0 ONNX / NanoPitch C / silero ONNX; M2: demucs.cpp;
  M3: basicpitch.cpp).
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
