# Docs/ENGINE.md — PitchNotes-iOS audio engine plan

> **Owner:** Paul (Audio Engine & ML lane). **Version:** v0 (M0, P-003).
> Sources of truth: `Docs/RESEARCH.md` (verified source pack), `CONTRACTS.md` v0.0,
> `PLAN.md` (targets §0), `DECISIONS.md` (rulings). Facts below were re-verified
> against RESEARCH.md — repo names, licenses, sizes, and benchmark numbers cite §-refs.
> Change log at the bottom. Leto arbitrates license/routing rulings (see §5 flags).

---

## 1. Architecture (M0 state → target)

```
┌─ App (Jess: SwiftUI) ─────────────────────────────────────────────┐
│  consumes EngineAPI + SongBundle; MockEngine until real engines  │
└──────────────────────┬───────────────────────────────────────────┘
                       │ CONTRACTS v0.0 (C-1/C-2/C-3, frozen)
┌──────────────────────┴───────────────────────────────────────────┐
│ EngineCore (Engine/ — Foundation-ONLY, portable; P-001 SHIPPED)  │
│  Part · SongManifest · NoteTrack · PitchFrame · EngineAPI        │
│  PitchFrameStream · BundleValidator (V1–V13) · MockEngine        │
├──────────────────────────────────────────────────────────────────┤
│ M1 pitch layer (P-101/P-103 SHIPPED — portable Foundation-only)  │
│  SwiftF0Core · SileroVADCore · VADGate · kaiser-sinc Resampler   │
│  PCMWaveReader · inference SEAMS (SwiftF0/SileroVAD protocols)   │
├──────────────────────────────────────────────────────────────────┤
│ Apple/ORT layer                                                  │
│  Engine/PitchORT pkg (X-008): OnnxSwiftF0 + OnnxSileroVAD        │
│  AVFoundation I/O (P-104/P-203) · ORT mirror 1.24.2 (D-13)       │
│  C/C++ vendored: sevagh MPM/YIN (P-102) · demucs.cpp (M2)        │
└──────────────────────────────────────────────────────────────────┘
```

- **M0 delivered:** `EngineCore` SPM package (`Engine/`): C-1 Part enum, C-2 schemas +
  V1–V13 validators, C-3 EngineAPI + PitchFrameStream, MockEngine (8 seeded scenarios:
  perfect / flat −30c / sharp +35c / octaveError / silent / breathy / lateOnset +120 ms /
  vibrato ±25c @5.5 Hz), atomic SongBundle writer, 45 unit tests green (Linux swift
  6.0.3 + same code targets macOS CI). Mock honesty notes: **WAV stems** (ALAC arrives
  with the real writer, P-204), **pseudo-hash `sourceHash.hex`** (real BLAKE3 at P-203),
  **fixed-timestamp ULID** (wall-clock ULIDs at P-203). Jess consumes via
  `.package(path: "../Engine")`.
- **M1 delivered (P-101/P-103, branch paul @291b084):** portable pitch cores
  (`Engine/Sources/EngineCore/Pitch/`) are Foundation-only and Linux-tested
  (63/63 green, swift 6.0.3); the neural forward passes live in the Apple-only
  `Engine/PitchORT` package (ORT mirror 1.24.2, CPU EP, D-13) behind the
  `SwiftF0Inference` / `SileroVADInference` protocols — a direct ORT dependency
  inside EngineCore's Package.swift would break `cd Engine && swift test` on
  Linux (ObjC bindings are iOS15/macOS14-only). PitchORT is wired into the app
  target by Leto (X-008: project.yml 2 lines + optional CI test line). Real-model
  spikes are SELF-UPGRADING: `Tests/Spikes/run_spike.py` downloads +
  SHA256-verifies the D-19-pinned ONNX via download.py and runs it when
  `onnxruntime` is importable; loud mock fallback keeps CI green until the
  spike-venv one-liner lands; `PITCHNOTES_SPIKE_REAL=required` hard-fails at
  the L-101 gate.
- **Spike harness (P-002):** `Tests/Spikes/run_spike.py --spike <name>` — S1–S8 rules,
  deterministic mock models, fixture-integrity preflight. Leto's five frozen CI jobs
  call it one line each (Tests/Spikes/README.md). Real-model wiring points documented
  in `mock_model.py`.

## 2. Model table (v0 — verified against Docs/RESEARCH.md)

| Model | Repo | License | Params / size | SR | Frame rate | Pitch range | Outputs | RTF target (A14) | Export path (Linux/CI Python) | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| **SwiftF0** (primary pitch + grading) | lars76/swift-f0 (+ -training) | MIT | 14,386 params (~60 KB) | 16 kHz | 16 ms | F#1–C7 (46.875–2093.75 Hz) | hz, confidence, loudness_db; `segment_notes()`, `export_to_midi()`; streaming 176 ms lookahead | RTF ≪ 0.3 (179.6× RT, 1 core, pitch-benchmark) | bundled ONNX pinned HF rev 7877fba (D-19; HF repo re-host when D-2 lands — sha256 must not change) | **SHIP (M1: ±20c AC met, RTF 0.009–0.016 @1–4 thr)** |
| **NanoPitch** (zero-lookahead ribbon candidate) | smulelabs/NanoPitch | **VERIFY (D-7)** + weights trained on GTSinger (CC BY-NC-SA) + FSDNoisy18k — see flag X-002-proposed | ~333K (gru96) / ~200K (gru64), ~1.3 MB | 16 kHz | ~? ms causal | 6 octaves, 360 sigmoid bins @20¢ | hz, VAD head; Viterbi (offline+realtime) | RTF 0.1–0.3 WASM ⇒ native ≪ 0.3 | train gru64 on HF smulelabs/NanoPitch-PreExtract → export weights JSON → C array; OR fallback below | **VERIFY → likely FALLBACK** |
| **sevagh/pitch-detection** (ribbon FALLBACK per D-7) | sevagh/pitch-detection | MIT | DSP only (MPM/YIN/ACF, C++) | any | callback | n/a (per-frame) | hz | zero-lag, ≪ 0.3 | vendor per `vendor/README.md` intake (L-008) | **SHIP (fallback default)** |
| **demucs.cpp** (separation baseline, M2) | sevagh/demucs.cpp | MIT | htdemucs fp16 ggml **81 MB**; 6s 53 MB; ft bag 4×81 MB; v3 160 MB | 44.1 kHz | windowed (chunk 5–10 s overlap-add) | n/a | 2 stems first (vocals/instrumental, D-9), 4-stem optional | ≤2× song length (stretch ≤1×) | `convert-pth-to-ggml.py` fp16 → HF manifest; OpenMP→std::thread/GCD port | **SHIP** |
| **basicpitch.cpp** (note transcription, M3) | sevagh/basicpitch.cpp | MIT; model spotify/basic-pitch nmp.onnx **Apache-2.0** | ~2 MB | 22.05 kHz (resample 44.1k→22.05k) | n/a (note events) | MIDI 24–96 typical | polyphonic note events → MIDI | RTF logged at P-301 | ort-builder: trim ops/types, weights→.c/.h | **SHIP** |
| **silero-vad** (mic gating, M1) | snakers4/silero-vad | MIT | ~2 MB ONNX | 16 kHz | 30 ms chunks | n/a | speech prob | <1 ms/chunk | official ONNX pinned commit bfdc019 (D-19) → HF manifest | **SHIP (M1: 0.23 ms/chunk, speech-VAD semantics verified)** |
| **windowed-roformer** (stretch eval, P-206 M2, non-gating) | smulelabs/windowed-roformer | MIT | MB-R-class (large; fp16/int8 + bench) | 44.1 kHz | windowed | n/a | stems | 11.17 dB SDR = 92% of full MB-R, 44.5× fewer attention FLOPs (WSA W=10 S=8) | FlexAttention is CUDA-only → ONNX export must re-express window+sink as additive attention-mask bias (`|i−j|≤W/2 ∨ i<S ∨ j<S`); Bleedless worse (30.14 vs 41.00) in silent segments | **STUDY → P-206 eval only** |
| **RMVPE** (optional offline reference) | RVC-Project (ONNX assets) / Dream-High | **VERIFY weights (X-601, M6)** | ~180 MB | 16 kHz | 16 ms | wide | hz + salience | 13.6× RT | ONNX → manifest (optional user download) | **VERIFY (post-v1)** |

Reference ranking (pitch-benchmark, MIT code / CC BY-NC-SA dataset — eval-harness design only, dataset NOT shipped): SwiftF0 **0.781** F1@50c @179.6× RT · RMVPE 0.768 @13.6× · FCPE 0.728 @27.8× · CREPE 0.689 @0.4× (too slow live) · PESTO 0.680 @20× (**LGPL — study only**) · pYIN 0.506 (weakest). RESEARCH §4a.

Multi-f0 / voice-assignment lineage (M3 design inputs): Cuesta ISMIR 2020 (multif0-estimation-polyvocals), Cuesta TISMIR 2022 (voice assignment from pitch salience), Schramm ISMIR 2017 (a cappella multi-pitch + assignment — our exact problem), **PawCT arXiv 2610.09861: part-aware note F1 0.225 real (0.382 part-agnostic) = honest ceiling**; assignment = Viterbi/HMM with costs (range prior, melodic smoothness ≤~240c/frame, cross-part ordering via C-1 voice-rank, harmonic plausibility) + optional score-DTW snap (P-304). Per-singer separation evidence: ACappellaSet fine-tuned HTDemucs NSDR S4.05/A4.41/T7.91/B10.50 (two-stage VP-first beats one-stage; wet reverb degrades 8.73→4.84 VP); jaCappella MRDLA SI-SDR lead8.7/S11.8/A14.7/T11.3/B10.2/VP22.1 (**license "see dataset page" → VERIFY**); SepACap (ETH-DISCO, 7 stems incl finger_snap, 24 kHz, **license VERIFY**). Honesty rule (AGENTS §11): design for bleed — T1/T2/baritenor WILL bleed; unison is pitch-inseparable.

## 3. Export plan (all weights → HF repo per D-2, never git)

1. **SwiftF0 (P-101) — DONE @291b084:** pinned `aaatmy/swift-f0-onnx` rev 7877fba (D-19 interim; swap `url` to `thesagezm/pitchnotes-models` when the D-2 upload lands — sha256 6385e8c2…b0a22 MUST NOT change). SHA independently verified twice (Leto at pin time; Paul via download.py). No conversion (ONNX native). 48k mic → 16 kHz via AVAudioConverter (P-104); portable kaiser-sinc resampler in EngineCore covers offline/tests.
2. **NanoPitch (P-102):** FIRST record license verdict (D-7) + weights provenance ruling (flag X-002-proposed, §5). If ruled usable: train gru64 (~200K params, 6–8 h risk per PLAN) on `smulelabs/NanoPitch-PreExtract`, export weights JSON → C array, compile `nanopitch.c/h` vendored per L-008. If not: **v1 ribbon = sevagh/pitch-detection MPM/YIN (MIT, zero training data)** — already the D-7 fallback; retrain-on-clean-data is a post-v1 X-301-adjacent option.
3. **silero-vad (P-103) — DONE @01e4b13→291b084:** pinned upstream commit bfdc019 (D-19). Upstream-exact streaming in EngineCore: 512-sample (32 ms) chunks, 64-sample context, recurrent state [2,1,128] fed back per call. Spike asserts SPEECH-VAD semantics: silence max 0.009, clicks 0.015, noise burst 0.125 (correctly non-speech — M0 mock asserted energy-VAD ≥0.5; real model differs by design), voice-like fixture max 0.961.
4. **demucs.cpp (P-201):** `convert-pth-to-ggml.py` fp16 for htdemucs (81 MB) → HF manifest; vendored per L-008 (license file + version pin + patches log); OpenMP → std::thread/GCD port; Eigen NEON.
5. **basicpitch.cpp (P-301):** vendored per L-008; `ort-builder` minimal ORT (trim ops/types, weights→.c/.h); source model = spotify/basic-pitch `saved_models/icassp_2022/nmp.onnx` (Apache-2.0); resample 44.1k→22.05k in engine.
6. **windowed-roformer (P-206 stretch):** ONNX export with additive attention-mask bias replacing FlexAttention; fp16; benchmark vs demucs.cpp before ANY swap proposal (swap only via DECISIONS ruling).

CI model flow (all): HF repo (D-2, BLOCKED(human) until created) → `scripts/models/download.py` (SHA256 verify + cache, exit codes documented) → spike job asserts contract on fixtures. M0 uses the committed 1 KB test blob (L-005) + structural mocks (P-002) — **no weights in M0**.

## 4. Benchmark plan (details in Docs/BENCHMARKS.md)

Matches PLAN §0 targets exactly (live F1@50c ≥ 0.75 synthetic clean; RTF < 0.3; feedback < 100 ms; separation vocals SDR ≥ 8 dB synthetic; per-part NSDR 4–14 dB post-v1 honest; part-aware note F1 0.2–0.4 honest; peak RSS < 1.5 GB; core bundle < 200 MB). Harness = pitch-benchmark design (F1@50c, RPA/RCA) + mir_eval/museval (SDR/NSDR) as study-reference implementations — reimplement metrics in our harness, ship no NC dataset. Measured on CI macOS runner + human-assisted A14 device runs; every engine task logs RTF/RSS in BENCHMARKS.md (honesty rule).

## 5. License flags (proposed X-tasks — LETO RULES in DECISIONS.md)

- **X-002 → RULED as D-17 + D-19 (2026-11-21):** GTSinger-trained NanoPitch weights BANNED; v1 ribbon = vendored sevagh/pitch-detection (Leto-verified MIT @v2023.12; vendor/pitch-detection + kissfft v131 BSD-3 via pd_fft seam). NanoPitch only on clean LICENSE + clean weights/retrain. Original proposal text: NanoPitch CODE license is unverified (D-7) AND its pretrained weights are trained on **GTSinger (CC BY-NC-SA)** + FSDNoisy18k (RESEARCH §4b) — NC-trained weights are commercially encumbered even if code is permissive. PROPOSAL: v1 causal ribbon = **sevagh/pitch-detection (MIT, pure DSP, no training data)** as the DEFAULT; NanoPitch ships only if (i) LICENSE verified ship-safe AND (ii) Leto rules the weight provenance usable, or (iii) weights retrained on clean synthetic/CC-BY data (VocalSet CC-BY, SingStyle111 CC-BY, own synth per X-301). Do NOT silently ship GTSinger-trained weights.
- **X-601 (exists, M6) — RMVPE/FCPE weight licenses:** SwiftF0 remains the reference pitch engine until ruled. No change.
- **X-003 (proposed, pre-M3) — jaCappella MRDLA/XUMX + SepACap license verification memo:** model licenses "see dataset page"/unverified → research-only until ruled; feeds X-302 (per-singer model evaluation memo). No integration before a DECISIONS verdict.
- **Study-only confirmation (no new task — already D-15 baseline):** PESTO (LGPL), aubio (GPL), essentia (AGPL), TARSOSDSP (GPL), Verovio (LGPL), FluidSynth (LGPL), Rubber Band (GPL), Nightingale/Performous/USDX/Vocaluxe/UltraStar Play (GPL), GNU Solfege (GPL) — never linked/shipped; ideas reimplemented only.

## 6. Open questions (for Leto / future rulings)

1. **C-1 prose vs sortOrder direction (logged 2026-11-21T00:43Z):** C-1's "bass < baritone < …" is the voice-rank reading (P-303 no-crossing) while the ratified sortOrder switch is numeric layout order (soprano 0 … bass 6). EngineCore implements the switch verbatim; tests assert both readings. Optional: one clarifying sentence in CONTRACTS (Leto's call; additive doc change).
2. ~~NanoPitch frame size~~ MOOT for v1 (D-19: fallback = default; MPM/YIN is per-frame causal — no internal frame/hop). Measure only if a clean retrain ever lands (D-17.2).
3. **RESOLVED by CONTRACTS v0.1 (L-102, main @6cfbb1f):** `PitchFrame` += `engine_id`/`lookahead_ms`; C-6 LivePitchEngine facade = ribbonSource (RIBBON_MPM_YIN, causal) + gradingSource (SWIFTF0, 176 ms). P-105 implements; P-401 aligns via the explicit field.
4. **RESOLVED by C-6.1 (v0.1):** part range presets ratified (UX §3.6 verbatim, X-001 routing done); P-105 consumes calibratable — single source = CONTRACTS, no hardcode duplicates.

## Change log

| Version | Date (UTC) | Change |
|---|---|---|
| v0 | 2026-11-21 | P-003: model table + export plan + benchmark plan + open questions + license flags (X-002/X-003 proposed, X-601 referenced). M0 engine state documented (EngineCore + MockEngine + spike harness). |
| v1 | 2026-11-21 | P-101/P-103: SwiftF0 + silero-vad SHIPPED (portable cores, PitchORT seam, self-upgrading real spikes). Architecture M1 layer + Engine/PitchORT split rationale; SwiftF0 I/O + streaming semantics (176 ms lookahead); silero 512/64/state + speech-VAD semantics; X-002 resolved (D-17/D-19); open questions 2–4 closed by CONTRACTS v0.1. |
