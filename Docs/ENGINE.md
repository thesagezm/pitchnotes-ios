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
│  RibbonEngine (Swift MPM, P-102) · LivePitchFacade (P-105)       │
│  PartRangePresets (C-6.1) · PitchEngineID (C-6.0)                │
├──────────────────────────────────────────────────────────────────┤
│ M2 separation layer (P-201 — portable pieces Linux-tested)       │
│  DemucsOutputMapper (4-source → C-1 two-stem, D-9)               │
│  PCMWavWriter (staging; ALAC at P-204) · ImportProgress (C-8)    │
├──────────────────────────────────────────────────────────────────┤
│ Apple/ORT layer                                                  │
│  Engine/PitchORT pkg (X-008): OnnxSwiftF0 + OnnxSileroVAD        │
│  AVFoundation I/O (P-104/P-203) · ORT mirror 1.24.2 (D-13)       │
│  C/C++ vendored: sevagh MPM/YIN (P-102) · demucs.cpp (M2)        │
│  Engine/Separation: DemucsShim C-ABI + DemucsEngine (X-201)      │
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

### 1.1 Live pitch facade (P-105, CONTRACTS v0.1 C-6)

`LivePitchFacade` (EngineCore/Pitch/LivePitchFacade.swift) implements C-6.0
verbatim: `PitchEngineID` (rawValues `RIBBON_MPM_YIN` / `SWIFTF0`, STABLE
FOREVER) + `LivePitchEngine: EngineAPI` (`ribbonFrame` causal vs
`gradingFrames` post-hoc). Both inferences are INJECTED seams — ORT-backed
construction lands with X-008 (PitchORT); MockEngine conforms additively with
the same real engine IDs (C-6.0), so J-101/J-103 build against the true shape
today.

- **Ribbon path** (`RIBBON_MPM_YIN`, lookahead 0): EngineCore `RibbonEngine`
  (Swift MPM, direct NSDF — P-102). One `PitchFrame` per `ribbonFrame` call =
  LAST frame emitted for that push; sub-hop pushes return the previous frame
  unchanged (sticky — the UI cursor holds between hops) or an unvoiced
  placeholder before the first window fill. Frame `t` is on the ribbon's own
  16 ms hop grid (seconds from session start); `confidence` = NSDF clarity
  clamped to [0,1] at the contract surface (parabolic interpolation can
  overshoot a flat peak by ~1e-3 — V12), `loudness_db` = chunk RMS dBFS.
- **VAD fusion** (optional injected `SileroVADInference`): SileroVADStream +
  `VADGate` hysteresis (on 0.5 / off 0.35 / 5-chunk hang, P-103). Gate CLOSED
  forces `hz = 0` while confidence keeps the clarity (the deviation UI can
  still show certainty). VAD inference errors FAIL OPEN — a broken gate must
  never kill the ribbon. Non-16 kHz chunks are answered defensively unvoiced
  and never reach the state machine (C-3 declares MicChunk 16 kHz mono).
- **Grading path** (`SWIFTF0`, lookahead 176 ms contract constant):
  `SwiftF0PitchEngine.detect` over the decoded mix (portable RIFF-WAV decode
  via PCMWaveReader incl. stereo downmix; compressed decodes arrive with the
  Apple layer P-203), band-limited by fmin/fmax, every frame tagged
  `engine_id = SWIFTF0`, `lookahead_ms = 176`. `EngineAPI.pitchFrames`
  delegates here; `livePitch` delegates to the ribbon.
- **M2 stubs:** `importAudio`/`separate`/`noteTrack` throw honest EngineErrors
  until P-203/P-204 — MockEngine covers those UI flows (C-3 rule).
- **C-6.1 presets** (LivePitchPresets.swift): the seven-part table VERBATIM
  (Hz via `EngineContract.hzForMidi`, rounded 0.1); `calibratedBand(for
  part, nudgeSemitones, micOffsetCents)` shifts the band by the clamped
  −2…+2 nudge + mic cents WITHOUT mutating the fixed table. Filtering only —
  never a hard gate (D-12).
- **Reset:** `reset()` clears ribbon history/context, VAD gate, sticky frame —
  call on interruptions (P-104 hooks).
### 1.2 Capture → feedback latency budget (P-104, §8 < 100 ms)

| Stage | Cost | Note |
|---|---|---|
| AVAudioEngine input tap | 21.33 ms | 1024 frames @48 kHz (`CaptureSpec.frameSamples`) |
| AVAudioConverter 48k→16k | < 1 ms | stateful, Apple-side; portable twin = StreamingResampler (carry-tail, continuity-tested) |
| Ring submit/drain | < 0.1 ms | memcpy-bounded critical sections (CapturePipeline) |
| Drain cadence | ≤ 16 ms | one 16 ms hop before the facade sees samples |
| Ribbon estimate | ~4 ms | Swift MPM measured (BENCHMARKS.md); ~0.1 ms via vendored C++ (X-009) |
| First-frame warm-up | 64 ms | ribbon window of PAST audio — once per session, not per frame |

Steady-state ≈ 40–45 ms typical → budget met on paper with ~2× margin. TRUE
end-to-end loopback is measured on device via the J-403 hook (P-104 row):
capture → PitchFrame.t delta. Ring = newest-wins (1 s): a consumer stall degrades
to counted drops + contiguous recent audio, never stale feedback.

- Tests: `LivePitchFacadeTests` (9) — synthetic-stream AC (provenance,
  220 Hz ±10 c accuracy, 16 ms grid, loudness), gate closed/open/fail-open,
  sticky + reset, defensive rate, grading tagging/grid/errors, C-6.1 table
  verbatim + calibration immutability, MockEngine facade surface, PitchFrame
  v0.0/v0.1 JSON round-trip. EngineCore 79/79 Linux green.

### 1.3 M2 separation stack (P-201, CONTRACTS v1.0)

```
DemucsEngine (Engine/Separation/DemucsEngine.swift, app target — X-201 wiring)
  │  ProgressReportingEngine: C-8 emitter (monotonic clamp), Task cancellation
  │  separate(): PCMWaveReader → shim infer → DemucsOutputMapper → PCM16 staging
  │  (the staged stems are STREAMED to disk — P-209, no whole-song arrays)
  ▼
DemucsShim (DemucsShim.h/.cpp, plain-C ABI — no C++/Eigen types cross the seam)
  │  load/num_sources/set_threads/infer(status codes, finite gate, progress cb)
  ▼
vendor/demucs.cpp src/*.cpp (MIT, D-30 Tier A; Eigen headers MPL-2.0, D-32.5)
  │  htdemucs fp16 ggml → fp32 Eigen tensors; 7.8 s segments @ 0.25 overlap,
  │  triangular transition weighting; 4-source out (drums, bass, other, vocals)
  ▼
DemucsOutputMapper (EngineCore, Linux-tested): vocals = target_3,
  instrumental = drums+bass+other residual (D-9 always-two-stem); D-8 stems:
  vocals MONO / instrumental STEREO (PCM16 staging now, ALAC at P-204)
```

- **Weights (TIER B per D-30, D-32.6):** htdemucs fp16 ggml ~81–84 MB. Provenance
  chain: Meta .th @e976d93e (PRIMARY, dl.fbaipublicfiles.com) OR Retrobear/demucs.cpp
  HF dataset (FALLBACK, linked from the demucs.cpp README) — Paul picks operationally;
  either way sha256 is the trust anchor (D-19.4), the mirror is
  `thesagezm/pitchnotes-models` via hf_upload.sh, manifest license field = "MIT
  (Tier B per D-30: training-data risk recorded)", attribution in NOTICE + J-204
  licenses screen. HUMAN SIGN-OFF before any commercial/App Store distribution;
  NEVER represented as "clean" (MUSDB18 CC BY-NC-SA + undocumented 800-song set).
- **Threading (D-32.4):** vendored src has ZERO OpenMP pragmas (verified at
  intake + re-verified by Paul on the scratch extraction). The port = ADD
  std::thread parallelism: `Tests/Spikes/apply_demucs_threading.py` pairs the
  INDEPENDENT freq/time encoder+decoder chains (disjoint buffers, read-only
  model, deterministic ops ⇒ bit-identical output at any thread count — the
  benchmark asserts 1-thread == 2-thread bytes). DEMUCSCPP_NUM_THREADS env:
  unset/1 = exact stock serial baseline, ≥2 = parallel pairs (explicit 4 caps
  to 2 — pairs are the only free parallelism today). The per-source
  mask/ISTFT section stays SERIAL (it mutates the shared stft_buf — thread-local
  restructuring deliberately deferred). X-202 DONE: Leto applied to vendor/
  @d007780 (+ patches.log) with one ternary correction (`? 2 : n` → `? 1 : 2` —
  the emitted text had inverted env semantics); `apply_demucs_threading.py`
  mirrors it byte-for-byte (verified by diff vs origin/leto @d007780), so
  revert+re-apply on vendor reproduces the committed text exactly.
- **Honest limits:** mid-inference abort is not possible through the vendor API —
  cancellation is checked before/after `demucs_inference`. **P-202 L2 landed the abort
  seam WITHOUT a vendor patch:** the shim (`Engine/Separation/DemucsShim.{h,cpp}`, Paul
  lane) carries an atomic abort flag and throws from the vendor's progress callback —
  which the vendor calls ~26× per 7.8 s segment, always OUTSIDE any joinable
  `std::thread` scope (verified in `vendor/demucs.cpp/src/model_inference.cpp`) — so the
  throw unwinds the blocking vendor call (abort latency = one encoder stage). Swift
  arms the flag from `withTaskCancellationHandler.onCancel` (on the cancelling thread);
  the shim maps it to `DEMUCS_SHIM_ERR_ABORTED` → Swift `CancellationError`. multiStem
  mode throws in M2 (per-voice stems are the M3 assignment path). `hasInstrumental`
  (D-9 near-silence) = P-205.
- **STREAMING SEPARATION (P-209 — the O(song) term removed):** the separation stage
  no longer holds the song in memory. `ChunkedSeparationDriver.runStreaming` blends
  into a PENDING buffer bounded by ONE window and writes the finalised frames to
  the stem files as it goes; the staged mix is read WINDOW BY WINDOW from disk
  (`PCMF32WavWindowSource` — the header is parsed by scanning chunk headers, the
  file is never loaded into memory). Two portable seams carry it: `AudioWindowSource`
  (the mix) and `StemStreamSink` (the stems — a streaming 16-bit PCM WAV writer
  whose quantisation is BYTE-IDENTICAL to `PCMWavWriter`, so the ALAC path and the
  staged-stem bytes do not change). **The output is BIT-IDENTICAL to the old
  accumulate path** (the Linux test compares both paths on the same fixture + mock
  SegmentEngine) — the refactor changes WHEN the frames are written, never WHAT is
  written. **Why one window is enough:** consecutive windows overlap and the
  crossfade is recursive (`out = out·(1−t) + next·t`), so a frame is final only
  once the next window's start has passed it — the frames still in play are exactly
  the tail of the accumulated output, i.e. one window's worth. **C-8 discipline kept:**
  a failed or cancelled run ABORTS the sinks (the partial stem file is removed — no
  residue) and the progress stays monotonic inside the separating band. **What this
  does NOT claim:** the A14 device peak-RSS number is P-603's job; the DECODE stage
  still holds the decoded song once (the decoder's own buffer) — that is a separate
  term, not part of the separation stage.

### 1.4 M2 import/decode stack (P-203, D-8 / C-2.1)

```
ImportPipeline (EngineCore, portable, Linux-tested)
  │  DecodePolicy (D-8: 44.1 kHz out, mix ∈ {1,2} ch, channel-preserving)
  │  → AudioResampler (kaiser-sinc, stateful) → PCMF32Wav staging (mix)
  │  → BLAKE3 (pure Swift, from spec — 23 official vectors) over the SOURCE bytes
  │  → ImportManifestBuilder (song.json v1.0: tuning_cents + channels + hasInstrumental)
  ▼
AVAudioFileDecoder (Engine/ImportKit — APPLE-ONLY package, AVFoundation)
  AVAudioFile → deinterleave f32 @ source rate/ch → SHARED normalizeAndStage
  (ONE policy path: the portable core owns the D-8 resample/channel policy)
```

- **Package boundary (Leto's X-204/step-5 ask, answered):** `Engine/ImportKit` is an
  Apple-only SPM package (product `ImportKit`, path-dep `..` → `EngineCore`), the same
  pattern as `Engine/PitchORT` and `Engine/MicCapture`. AVFoundation-dependent code
  (this decoder, and P-204's ALAC writer + SongBundle assembler) CANNOT live in
  `Engine/Sources/EngineCore` (Foundation-only / Linux-clean by AGENTS §0). **P-204
  extends `Engine/ImportKit`** (no new package ⇒ no new identity surprise at the gate);
  exact product name `ImportKit` for `project.yml`.
- **MP3 GAPLESS BEHAVIOUR (measured, macOS runner 45076895490 + 45078702137):**
  `AVAudioFile` does NOT apply the LAME gapless tag, so an imported MP3 keeps the
  encoder delay + trailing padding: the 2.5 s fixture decodes to **111744 frames
  (97 MPEG frames × 1152) = 2.534 s**, while ffmpeg (which honours the tag) returns
  exactly 110250 frames. The extra frames are codec padding, not duplicated source
  audio — the import leg asserts the count is a whole number of MPEG frames and that
  the decode agrees with the source WAV (SNR ≥ 18 dB; locally measured 26.0 dB,
  max |Δ| 0.045) once the encoder delay is removed. **TWO decoder delay conventions
  (measured, both):** the gapless delay is 1105 samples = 576 (encoder side) + 529
  (decoder side); ffmpeg's RAW decode (Info/LAME tag neutralised locally) aligns with
  the source at **1105**, while CoreAudio/AVAudioFile (measured on the runner) applies
  the 529-sample decoder-side delay but not the gapless trim ⇒ it aligns at
  **1105 − 529 = 576**. The test accepts both (window 512…1216) and the SNR
  assertion is the real guarantee (a wrong offset scores ≈ −2 dB, not 26 dB).
  **Consequence for the manifest:** `duration_s` for an MP3 import is up to ~51 ms
  longer than the true song length (delay 1105 + ≤1152 frames); negligible for a
  4-minute track, and NOT silently "fixed" by trimming (a trailing-silence heuristic
  would truncate quiet real endings). WAV/FLAC/ALAC are exact (bit-identical to
  ffmpeg's decode — **PROVEN on the macOS runner**, run 45078702137: ffmpeg's f32
  output is bit-for-bit `s16/32768`).
- **ALAC STEM WRITING (P-204, GREEN on the macOS runner — run 45156291152@1935a0f,
  8/8):** `ALACStemWriter` (Engine/ImportKit) writes the stems as native ALAC
  `.m4a` through `AVAudioFile(forWriting:settings:commonFormat:.pcmFormatFloat32,
  interleaved:false)` — float32 PLANAR, the only layout the ALAC encoder accepts —
  streaming 8 192-frame chunks (a 4-minute stem never materialises as one buffer,
  §8). `AVAssetWriterInput` is NOT used: on this SDK it only accepts a
  `CMSampleBuffer`. **THE RUNTIME ROOT CAUSE (measured, and worth remembering for
  every other streaming writer in this project): `AVAudioFile.read(into:frameCount:)`
  THROWS when the source has fewer frames left than the requested count** — asking
  for a full 8 192-frame chunk at the tail of a 44 100-frame stem failed with the
  opaque "Foundation._GenericObjCError error 0". The fix is to request exactly the
  frames that remain. The encode now reports the step it failed in (open / read /
  copy / write) with the NSError's domain, code and userInfo — "it didn't work" is
  not an acceptable error message for a native-codec path. The engine's failed
  import surfaces the REAL error (the cleanup can no longer mask it).

## 2. Model table (v0 — verified against Docs/RESEARCH.md)

| Model | Repo | License | Params / size | SR | Frame rate | Pitch range | Outputs | RTF target (A14) | Export path (Linux/CI Python) | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| **SwiftF0** (primary pitch + grading) | lars76/swift-f0 (+ -training) | MIT | 14,386 params (~60 KB) | 16 kHz | 16 ms | F#1–C7 (46.875–2093.75 Hz) | hz, confidence, loudness_db; `segment_notes()`, `export_to_midi()`; streaming 176 ms lookahead | RTF ≪ 0.3 (179.6× RT, 1 core, pitch-benchmark) | bundled ONNX pinned HF rev 7877fba (D-19; HF repo re-host when D-2 lands — sha256 must not change) | **SHIP (M1: ±20c AC met, RTF 0.009–0.016 @1–4 thr)** |
| **NanoPitch** (zero-lookahead ribbon candidate) | smulelabs/NanoPitch | **VERIFY (D-7)** + weights trained on GTSinger (CC BY-NC-SA) + FSDNoisy18k — see flag X-002-proposed | ~333K (gru96) / ~200K (gru64), ~1.3 MB | 16 kHz | ~? ms causal | 6 octaves, 360 sigmoid bins @20¢ | hz, VAD head; Viterbi (offline+realtime) | RTF 0.1–0.3 WASM ⇒ native ≪ 0.3 | train gru64 on HF smulelabs/NanoPitch-PreExtract → export weights JSON → C array; OR fallback below | **VERIFY → likely FALLBACK** |
| **sevagh/pitch-detection** (ribbon FALLBACK per D-7) | sevagh/pitch-detection | MIT | DSP only (MPM/YIN/ACF, C++) | any | callback | n/a (per-frame) | hz | zero-lag, ≪ 0.3 | vendor per `vendor/README.md` intake (L-008) | **SHIP (fallback default)** |
| **demucs.cpp** (separation baseline, M2) | sevagh/demucs.cpp | **MIT (code, Tier A per D-30); WEIGHTS Tier B (D-30: MUSDB18 CC BY-NC-SA + undocumented 800-song set — risk recorded, human sign-off pre-commercial)** | htdemucs fp16 ggml **81–84 MB**; 6s 53 MB; ft bag 4×81 MB; v3 160 MB | 44.1 kHz | windowed (7.8 s segments @ 0.25 overlap, vendor-owned; chunking policy re-benchmarked at P-202 per D-25) | n/a | 2 stems first (vocals/instrumental, D-9), 4-stem optional | ≤2× song length (stretch ≤1×) | D-32.6: Meta .th @e976d93e via pinned `convert-pth-to-ggml.py` (PRIMARY) or Retrobear HF ggml (FALLBACK) → sha256 anchor → HF mirror; std::thread PAIR parallelism via `apply_demucs_threading.py` (D-32.4: zero OpenMP pragmas verified) | **SHIP (M2 in flight: shim+bridge+mapper landed @2923a9a, 112/112 Linux; spike + RTF/RSS/SDR → BENCHMARKS §4)** |
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

### 4.1 Spike parity harness (P-208 — D-24 / CONTRACTS C-7)

Numerical PARITY of the Swift/ORT path against Python reference tensors, strictly
stronger than shape/range spike assertions (D-24, adopted from the Muskey
`--dettato-check` pattern):

- **Reference side (Python):** `Tests/Spikes/swiftf0_real.py --export-c7` and
  `Tests/Spikes/silero_real.py --export-c7` run the pinned manifest models
  (download.py SHA-verified) on the committed fixtures and write C-7 sidecars
  under `Tests/Spikes/ReferenceTensors/{swiftf0,silero-vad}/`: one JSON manifest
  + one little-endian f32/f64 bin per tensor. `model_sha256` + `fixture_sha256`
  bind the reference to the exact model and fixture bytes. The npz exports
  (`--export-ref`) remain the Python-side regression format.
- **Consumer side (Swift):** `Engine/PitchORT/Tests/PitchORTTests/` —
  `SwiftF0ParityTests` (3 fixtures × 4 tensors: pitch_hz, confidence_raw,
  confidence_gated, loudness_db — raw model output AND EngineCore.SwiftF0Postprocessor
  outputs, i.e. parity through the FULL device pipeline) and `SileroParityTests`
  (4 fixtures × speech_prob through SileroVADStream, Python SileroStream chunking
  semantics mirrored). Binding assertions (model sha, fixture sha) run BEFORE
  tensor comparison — a model bump without regeneration fails loudly.
- **Pass criterion (C-7):** every element within tolerance (abs 1e-3 OR rel 1e-4
  of the reference). Same tolerance for both engines at v1; changes need a
  recorded ruling (never tightened silently).
- **CI:** `engine-parity` job (macOS, X-205 spec filed) — BLOCKING at milestone
  merges like the other spike contract tests; also serves as the macOS
  compile/execute proof for the PitchORT test target.
- **Regeneration:** after any manifest model bump: run both `--export-c7`
  exporters against the new pinned model and commit the sidecar diff with the
  manifest change.

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
| v1.1 | 2026-11-21 | P-105: LivePitchFacade (C-6.0 verbatim) + C-6.1 presets + MockEngine additive conformance — §1.1 facade semantics (sticky sub-hop, VAD fail-open fusion, V12 clarity clamp, M2 stubs, reset); P-102 Swift MPM noted in the M1 layer diagram. RibbonEngine partial-window crash fixed (Int-division truncation; testTimestampsOnContractGridAndCausal red on CI arm64 + Linux, emitCount guard). |
| v1.2 | 2026-11-22 | P-201a CONTRACTS v1.0 wired in EngineCore (C-1 += VOCALS sortOrder 10, C-2.1 notesFile optional, V14/V15 era-scoped, C-8 verbatim + ImportProgressEmitter) — 103/103 Linux; P-201c M2 separation stack: §1.3 architecture (shim C-ABI + DemucsEngine bridge + DemucsOutputMapper/PCMWavWriter portable layer), demucs model row → Tier B provenance (D-30/D-32.6) + std::thread pair parallelism spec (D-32.4, apply_demucs_threading.py). EngineCore 112/112 Linux. |
| v1.3 | 2026-11-22 | P-208 (D-24/C-7): §4.1 spike parity harness — C-7 sidecar exporter (--export-c7, JSON+f32/f64 bins, model+fixture sha binding), Swift/ORT parity tests in PitchORTTests (SwiftF0 3 fixtures × 4 tensors incl. EngineCore postprocess outputs; silero 4 fixtures), tolerance abs 1e-3 OR rel 1e-4; engine-parity CI job spec = X-205 (Leto). |
| v1.4 | 2026-11-23 | P-202 L2 (chunked driver + abort seam, no vendor patch) + P-203 (import/decode): §1.4 import stack (ImportPipeline / AVAudioFileDecoder / BLAKE3 / manifest v1.0), the **ImportKit package declaration** answered for Leto's step-5 wiring (extend `Engine/ImportKit`, product `ImportKit`), and the **measured MP3 gapless behaviour** (AVAudioFile keeps the LAME encoder delay + padding → 111744 vs ffmpeg's 110250 frames; duration_s up to ~51 ms long; padding proven frame-aligned + SNR-vs-source 26.0 dB). §1.3 abort seam replaced with the landed design. |
| v1.5 | 2026-11-23 | P-204 (ALAC stem writer, GREEN on the macOS runner 45156291152@1935a0f): §1.4 gains the **ALAC stem-writing** note — `AVAudioFile` + float32 PLANAR, `AVAssetWriterInput` avoided (CMSampleBuffer-only on this SDK), 8 192-frame streaming chunks, and the **measured runtime root cause**: `AVAudioFile.read(into:frameCount:)` THROWS when fewer frames remain than requested (the tail chunk) — request exactly what remains; the encode reports the failing step (open/read/copy/write) with the NSError details; a failed import surfaces the REAL error (cleanup can no longer mask it). |
| v1.6 | 2026-11-23 | P-209 (streaming separation — the P-202 follow-up): §1.3 gains the **streaming separation** note — the separation stage no longer holds the song in memory (`AudioWindowSource` reads the staged mix window-by-window from disk; `StemStreamSink` writes each window's blended stems to the stem file as they are finalised; the driver's retained buffer is bounded by ONE window and the streamed output is BIT-IDENTICAL to the old accumulate path). C-8 kept: cancel/failure aborts the sinks (no partial stem file) and the progress stays monotonic. The A14 device peak-RSS number remains P-603's job. |

