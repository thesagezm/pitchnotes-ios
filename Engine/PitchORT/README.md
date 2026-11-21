# Engine/PitchORT — Apple-only ONNX Runtime seam (P-101, PAUL lane)

`PitchORT` implements the portable `SwiftF0Inference` seam (EngineCore) against
the ONX Runtime ObjC wrapper (mirror 1.24.2, D-13) — the ONNX forward pass for
the SwiftF0 pitch engine (grading-grade source per D-17.3).

**Why a separate package:** the ORT mirror's bindings are Apple-only
(iOS 15/macOS 14). A dependency declared inside `Engine/Package.swift` would
force the ObjC bindings to compile on Linux and break `cd Engine && swift test`
(the portable core's fast loop + Leto's logic-tests step). The portable core
stays Foundation-only; this package is compiled by the app target (project.yml,
Leto wiring = X-008) and testable via `cd Engine/PitchORT && swift test` on
macOS.

**Contents**
- `OnnxSwiftF0Inference` — thread-safe ORT session wrapper: inputs
  `audio` f32 `[1, samples]` @16 kHz + scalar `fmin`/`fmax`; outputs
  `pitch` f64 `[1, frames]` Hz + `confidence` f32. CPU execution provider
  (CoreML EP = M6 phase, same model, D-13).
- `SwiftF0ModelStore` — locates the SHA-verified cached model
  (`<name>-<sha16>` scheme of `scripts/models/download.py`). Download/verify
  lives in download.py (single source of truth); the app triggers it on
  first run (D-2 HF repo pending → D-19-pinned upstream URLs today).

**Tests** (`cd Engine/PitchORT && swift test`, macOS): real-model end-to-end —
steady tone ±20 c, silence gating, stream==batch parity, 44.1k→16k resampled
path. Skips (XCTSkip) when the model is not in a known cache location.
