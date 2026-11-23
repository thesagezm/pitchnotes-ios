#!/usr/bin/env python3
"""C-7 sidecar writer (D-24 / CONTRACTS C-7; P-208 parity harness, PAUL lane).

Emits the parity sidecars consumed by the SWIFT tests (Engine/PitchORTTests):
per fixture one JSON manifest + one flat little-endian binary tensor file per
model output, under Tests/Spikes/ReferenceTensors/<slug>/. The npz exports
(--export-ref) stay the Python-side regression format; this module writes the
C-7-ratified JSON + raw-bin shape so Swift can consume the tensors without a
zip/npy parser. Regenerable:

    python3 Tests/Spikes/swiftf0_real.py --export-c7
    python3 Tests/Spikes/silero_real.py  --export-c7

Additive metadata beyond the C-7 example: `model_sha256` (the pinned manifest
entry) — ReferenceTensors/README.md documents the parity invariant "model SHA
travels with the reference"; a model bump without regeneration fails loudly.
Tolerances come from the C-7 example (abs 1e-3 OR rel 1e-4) and are documented
per engine in Docs/ENGINE.md — never tightened silently.
"""
from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
REF_ROOT = REPO_ROOT / "Tests" / "Spikes" / "ReferenceTensors"

# C-7 example tolerances; per-engine overrides only via a recorded ruling.
TOLERANCE = {"abs": 1e-3, "rel": 1e-4}
REFERENCE_VERSION = 1


def _bin_suffix(dtype: np.dtype) -> str:
    # float32 -> f32, float64 -> f64 (only these two are produced/consumed).
    return {np.dtype("float32"): "f32", np.dtype("float64"): "f64"}[np.dtype(dtype)]


def export_c7(engine: str, slug: str, stems: list[str],
              tensors_by_stem: dict[str, dict[str, np.ndarray]],
              model_entry: dict, source: str, script: str) -> Path:
    """Write <slug>/<stem>.json + tensor bins for every stem.

    engine        C-7 engine id (e.g. "SWIFTF0"; C-6/PitchEngineID-style).
    slug          directory under Tests/Spikes/ReferenceTensors/.
    stems         fixture stems ("sweep_46_2100Hz_16k" for .../sweep_46_2100Hz_16k.wav).
    tensors_by_stem  {stem: {tensor_name: ndarray}} — 1-D arrays, float32/64.
    model_entry   pinned Models/manifest.json entry (name/sha256/version used).
    source/script C-7 `export` provenance fields.
    """
    out_dir = REF_ROOT / slug
    out_dir.mkdir(parents=True, exist_ok=True)
    date = time.strftime("%Y-%m-%d", time.gmtime())
    for stem in stems:
        fixture_name = f"{stem}.wav"
        fx_path = FIXTURE_DIR / fixture_name
        fixture_bytes = fx_path.read_bytes()
        tensors = tensors_by_stem[stem]
        entries = []
        for tname, arr in tensors.items():
            a = np.ascontiguousarray(arr)
            assert a.ndim == 1, f"{stem}/{tname}: C-7 v1 tensors are 1-D (got {a.shape})"
            assert a.dtype in (np.dtype("float32"), np.dtype("float64")), \
                f"{stem}/{tname}: unsupported dtype {a.dtype}"
            fname = f"{stem}.{tname}.{_bin_suffix(a.dtype)}.bin"
            (out_dir / fname).write_bytes(a.tobytes(order="C"))  # little-endian host
            entries.append({"name": tname, "file": fname,
                            "shape": [int(n) for n in a.shape],
                            "dtype": "float32" if a.dtype == np.dtype("float32") else "float64"})
        manifest = {
            "referenceVersion": REFERENCE_VERSION,
            "engine": engine,
            "fixture": fixture_name,
            "fixture_sha256": hashlib.sha256(fixture_bytes).hexdigest(),
            "model_sha256": model_entry["sha256"],
            "export": {"source": source, "script": script, "date": date},
            "tensors": entries,
            "tolerance": dict(TOLERANCE),
        }
        mpath = out_dir / f"{stem}.json"
        mpath.write_text(json.dumps(manifest, indent=2) + "\n")
    return out_dir


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
