#!/usr/bin/env python3
"""Basic-pitch REAL spike (P-301, PAUL lane) — the vendored basicpitch.cpp
(MIT, D-30 Tier A code) under the EXISTING ONNX Runtime (D-39: ONE runtime —
the SPM ORT 1.24.2; the trimmed ort-builder route is REJECTED) on the pinned
`nmp.onnx` weights (D-42: TIER B — Apache-2.0 code, ICASSP-2022 Spotify
provenance, upstream training-mix licenses UNVERIFIED; never described as
clean, human sign-off required before commercial/App Store distribution; the
weights NEVER enter git).

Driver contract (mirrors demucs_real.py / ribbon_real.py):
  - compiles Tests/Spikes/basicpitch_runner.cpp against vendor/basicpitch/src
    (the 3 vendored .cpp files) + the ALREADY-VENDORED Eigen
    (vendor/demucs.cpp/third_party/eigen — D-39 §5: NO second Eigen, NO tensor
    shim) + the ORT C++ headers/lib.
  - runs the REAL model on the two native-rate fixtures
    (bp_mono_22050.wav 5 s, bp_poly_22050.wav 8 s) and asserts:
      S1  the weights are SHA256-verified against the manifest pin;
      S2  the runner compiled against the vendored sources + the real ORT;
      S3  the tensors are finite and the shapes match the Python reference;
      S4  TENSOR PARITY vs the independent Python reference
          (Tests/Spikes/basicpitch_ref.py) within the C-7 tolerance
          (abs 1e-3 OR rel 1e-4) — this is the C-7 §"the corrupted port must
          fail" gate;
      S5  NOTE PARITY: the vendor's raw note events match the reference's
          decode of the SAME tensors (frame domain);
      S6  the ENGINE OUTPUT (corrected frame -> seconds + release trim) is
          within 50 ms of the committed SYNTHESIS truth for every truth note,
          with the exact MIDI (the P-301 AC);
      S7  DETERMINISM: two runs produce byte-identical dumps;
      S8  RESOURCES: peak RSS under the per-OS spike bound; RTF logged
          (the device target is measured on A14 at P-603 — the CI number is
          a RUNNER number, never a device claim);
      S9  the release-trim + frame-mapping UNIT checks (the standalone C++
          leg — the trim cuts the RELEASE dip, never the attack ramp);
      S10 the C ABI BRIDGE (what the app's Swift side calls) reproduces the
          engine output exactly — the spike measures what the app ships.

ONNX Runtime resolution (env-overridable, in order):
  1. PITCHNOTES_ORT_ROOT   — a directory holding the ORT C++ headers and the
     library/framework (the layout the SPM package unpacks).
  2. PITCHNOTES_ORT_INCLUDE / PITCHNOTES_ORT_LIB — explicit paths.
  3. The pod archive from the SPM mirror's release asset (the EXACT bytes the
     app links — tag 1.24.2-binaries, SHA256 pinned in the mirror's
     Package.swift), downloaded and verified here. Stdlib only.

The vendored `ort_inference.cpp` includes <onnxruntime/core/session/
onnxruntime_cxx_api.h> (the ORT SOURCE-TREE path) while the SPM package ships
the header FLAT under Headers/. The spike bridges that with a BUILD-TIME
include shim (a generated header that forwards to the flat one); the APP
target should not need it — PATCH 5 (one line in
vendor/basicpitch/src/ort_inference.cpp) is LETO's lane (vendor/**, D-39 §7).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import basicpitch_ref as ref  # noqa: E402
import spike_checks as sc  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = Path(os.environ.get("PITCHNOTES_SPIKE_BUILD", REPO_ROOT / "Tests/Spikes/.basicpitch-build"))
FIXTURES = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"

# The ORT pod archive the SPM package links (thesagezm/onnxruntime-swift-package-manager,
# tag 1.24.2-binaries). The URL + SHA256 are the mirror's own Package.swift values.
ORT_POD_URL = ("https://github.com/thesagezm/onnxruntime-swift-package-manager/"
               "releases/download/1.24.2-binaries/pod-archive-onnxruntime-c-1.24.2.zip")
ORT_POD_SHA256 = "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
ORT_POD_NAME = "pod-archive-onnxruntime-c-1.24.2.zip"

# The fixtures the spike runs, with their truth sidecars.
SPIKE_FIXTURES = ("bp_mono_22050", "bp_poly_22050")

# The P-301 AC: the onset/offset must land within this of the truth.
ONSET_OFFSET_TOLERANCE_S = 0.050

# The vendored sources (the 3 files the intake landed).
VENDOR_SOURCES = ("ort_inference.cpp", "midi_notes.cpp")


# --------------------------------------------------------------------------
# ORT resolution
# --------------------------------------------------------------------------

def compiler() -> str:
    for c in ("clang++", "g++"):
        if shutil.which(c):
            return c
    raise RuntimeError("no C++ compiler found (need clang++ or g++)")


def vendor_dir() -> Path | None:
    """vendor/basicpitch (env-overridable for a pre-merge extraction)."""
    env = os.environ.get("PITCHNOTES_BASICPITCH_VENDOR")
    if env:
        p = Path(env)
        return p if (p / "src" / "basicpitch.hpp").is_file() else None
    p = REPO_ROOT / "vendor" / "basicpitch"
    return p if (p / "src" / "basicpitch.hpp").is_file() else None


def eigen_dir() -> Path:
    """The ALREADY-VENDORED Eigen (D-39 §5 — no second copy, no X-313)."""
    env = os.environ.get("PITCHNOTES_EIGEN")
    if env:
        p = Path(env)
        if (p / "unsupported" / "Eigen" / "CXX11" / "Tensor").is_file():
            return p
    p = REPO_ROOT / "vendor" / "demucs.cpp" / "third_party" / "eigen"
    if not (p / "unsupported" / "Eigen" / "CXX11" / "Tensor").is_file():
        raise RuntimeError(f"vendored Eigen not found at {p}")
    return p


def _ort_root_from_env() -> Path | None:
    env = os.environ.get("PITCHNOTES_ORT_ROOT")
    if not env:
        return None
    p = Path(env)
    return p if (p / "Headers" / "onnxruntime_cxx_api.h").is_file() else None


def _download_ort_pod(cache: Path) -> Path:
    """Fetch + SHA256-verify the ORT pod archive (the bytes the app links)."""
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ORT_POD_NAME
    if not archive.exists():
        tmp = archive.with_suffix(".part")
        with urllib.request.urlopen(ORT_POD_URL, timeout=120) as r, tmp.open("wb") as f:
            shutil.copyfileobj(r, f)
        tmp.replace(archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != ORT_POD_SHA256:
        raise RuntimeError(f"ORT pod archive sha256 mismatch: {digest} != {ORT_POD_SHA256}")
    return archive


def _runtime_lib_dir(lib: Path) -> Path:
    """The directory the dynamic loader must search for `lib`.

    The wheel's library records SONAME `libonnxruntime.so.1` but is shipped as
    `libonnxruntime.so.1.32.0` with no SONAME symlink — the loader would not
    find it. Create the alias in the BUILD DIR (never in the venv, never
    committed) and point the loader at it.
    """
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    alias_dir = BUILD_DIR / "ort-lib"
    alias_dir.mkdir(parents=True, exist_ok=True)
    alias = alias_dir / "libonnxruntime.so.1"
    if not alias.exists():
        try:
            alias.symlink_to(lib.resolve())
        except OSError:
            alias.write_bytes(lib.read_bytes())
    return alias_dir


def resolve_ort() -> tuple[Path, list[str], Path | None]:
    """Return (include_dir, link_flags, runtime_lib_dir) for the ORT C++ API.

    Prefers the SPM mirror's pod (the SHIPPED configuration). Falls back to a
    locally installed onnxruntime wheel's shared library (a LOCAL PROOF ONLY —
    it is a different ORT build; the CI run is the shipped-configuration
    proof).
    """
    include_env = os.environ.get("PITCHNOTES_ORT_INCLUDE")
    lib_env = os.environ.get("PITCHNOTES_ORT_LIB")

    if include_env and lib_env:
        lib = Path(lib_env)
        return Path(include_env), _link_flags(lib), _runtime_lib_dir(lib)

    root = _ort_root_from_env()
    if root is None:
        cache = Path(os.environ.get("PITCHNOTES_ORT_CACHE",
                                    Path.home() / ".cache" / "pitchnotes" / "ort"))
        try:
            archive = _download_ort_pod(cache)
            extracted = cache / "extracted"
            if not (extracted / "Headers" / "onnxruntime_cxx_api.h").is_file():
                extracted.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(archive) as z:
                    z.extractall(extracted)
            root = extracted
        except Exception as e:  # noqa: BLE001 — fall through to the wheel
            print(f"  [basicpitch] ORT pod unavailable ({e}) → trying the local wheel")
            root = None

    if root is not None:
        include = root / "Headers"
        if not (include / "onnxruntime_cxx_api.h").is_file():
            raise RuntimeError(f"ORT headers missing under {include}")
        return include, _link_flags_from_root(root), None

    # Local-wheel fallback (Linux dev loop): the pip wheel ships the shared
    # library but NOT the C++ header, so the headers still come from the pod
    # (or the env) and only the library comes from the wheel.
    import onnxruntime as ort  # noqa: PLC0415 — optional dependency
    capi = Path(ort.__file__).parent / "capi"
    lib = next(capi.glob("libonnxruntime.so*"), None) or next(capi.glob("libonnxruntime.dylib"), None)
    if lib is None:
        raise RuntimeError("no ONNX Runtime library found (set PITCHNOTES_ORT_INCLUDE/LIB)")
    headers = include_env
    if headers is None:
        headers = os.environ.get("PITCHNOTES_ORT_HEADERS")
    if headers is None:
        raise RuntimeError("ONNX Runtime C++ headers not found — set PITCHNOTES_ORT_INCLUDE "
                           "(the pip wheel ships only the library)")
    return Path(headers), _link_flags(lib), _runtime_lib_dir(lib)


def _link_flags(lib: Path) -> list[str]:
    if lib.suffix == ".dylib" or ".dylib" in lib.name:
        return [str(lib)]
    return [f"-L{lib.parent}", f"-l:{lib.name}"]


def _link_flags_from_root(root: Path) -> list[str]:
    """Link the macOS slice of the pod's xcframework (the SHIPPED config)."""
    xcf = root / "onnxruntime.xcframework"
    if xcf.is_dir():
        for slice_dir in sorted(xcf.iterdir()):
            if not slice_dir.name.startswith("macos"):
                continue
            fw = slice_dir / "onnxruntime.framework"
            if fw.is_dir():
                return ["-F", str(slice_dir), "-framework", "onnxruntime"]
    # A plain dylib/framework elsewhere in the tree.
    for cand in root.rglob("libonnxruntime*"):
        return _link_flags(cand)
    raise RuntimeError(f"no ONNX Runtime binary found under {root}")


# --------------------------------------------------------------------------
# Build + run
# --------------------------------------------------------------------------

def _include_shim_dir() -> Path:
    """A build-time shim for the vendor's ORT SOURCE-TREE include path.

    vendor/basicpitch/src/ort_inference.cpp includes
    <onnxruntime/core/session/onnxruntime_cxx_api.h>; the SPM package ships
    the header FLAT under Headers/. This generates a forwarding header so the
    spike compiles WITHOUT editing vendor/** (Leto's lane — PATCH 5).
    """
    shim = BUILD_DIR / "ort-include-shim" / "onnxruntime" / "core" / "session"
    shim.mkdir(parents=True, exist_ok=True)
    (shim / "onnxruntime_cxx_api.h").write_text(
        "// GENERATED build-time shim (P-301) — forwards the vendor's ORT\n"
        "// source-tree include to the SPM package's flat header. PATCH 5 in\n"
        "// vendor/basicpitch/src/ort_inversion.cpp (Leto's lane) removes the\n"
        "// need for this shim in the app target.\n"
        "#include <onnxruntime_cxx_api.h>\n")
    return shim.parent.parent.parent  # the dir that CONTAINS "onnxruntime/..."


def _vendor_decode_forwarder() -> Path | None:
    """A spike-local forwarder for the vendor's namespace bug (P-301 FIX, X-313
    territory — vendor/** is LETO's lane, D-39 §7).

    The vendored PATCH 3 (which un-`static`ed the note decoder) defines
    `output_to_notes_polyphonic` at GLOBAL scope, while `basicpitch.hpp`
    declares it INSIDE `namespace basic_pitch`:

        midi_notes.cpp:  std::vector<basic_pitch::NoteEvent>
                         output_to_notes_polyphonic(...)      <- GLOBAL
        basicpitch.hpp:  namespace basic_pitch { ... void
                         output_to_notes_polyphonic(...); }   <- basic_pitch::

    The two symbols do NOT match, so the spike does not link against the
    header's declaration ("undefined reference to
    `basic_pitch::output_to_notes_polyphonic(...)`"). Leto's intake compile
    smoke was `-fsyntax-only`, which cannot see a link-time symbol mismatch —
    this is exactly the compile PROOF D-39 §7 assigns to P-301.

    THE FIX BELONGS TO LETO (vendor/**): add the `basic_pitch::` qualifier to
    the definition in vendor/basicpitch/src/midi_notes.cpp. Until then the
    spike generates a forwarder in the BUILD DIRECTORY (never committed, never
    a vendor edit) so the spike can still run — and the forwarder is skipped
    automatically once the vendor is fixed.
    """
    import re

    v = vendor_dir()
    assert v is not None
    src = (v / "src" / "midi_notes.cpp").read_text()
    m = re.search(r"^\s*(basic_pitch::)?output_to_notes_polyphonic\s*\(", src, re.M)
    if m is None:
        raise RuntimeError("could not find output_to_notes_polyphonic in the vendored midi_notes.cpp")
    if m.group(1):
        return None  # the vendor is fixed — no forwarder needed
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    fwd = BUILD_DIR / "vendor_decode_forwarder.cpp"
    fwd.write_text(
        "// GENERATED by Tests/Spikes/basicpitch_real.py (P-301) — NOT committed.\n"
        "// The vendored PATCH 3 defines output_to_notes_polyphonic at GLOBAL\n"
        "// scope while basicpitch.hpp declares it in namespace basic_pitch, so\n"
        "// the symbols do not match. This forwards the header's declaration to\n"
        "// the vendor's definition so the spike can link; the vendor FIX (Leto's\n"
        "// lane, D-39 §7) is to add the `basic_pitch::` qualifier to the\n"
        "// definition in vendor/basicpitch/src/midi_notes.cpp.\n"
        "#include \"basicpitch.hpp\"\n"
        "// The vendor's GLOBAL definition has no declaration of its own —\n"
        "// declare it here so the forwarder can call it.\n"
        "extern std::vector<basic_pitch::NoteEvent>\n"
        "output_to_notes_polyphonic(const basic_pitch::InferenceResult &result,\n"
        "                             const bool melodia,\n"
        "                             const bool bends);\n"
        "std::vector<basic_pitch::NoteEvent>\n"
        "basic_pitch::output_to_notes_polyphonic(const basic_pitch::InferenceResult &result,\n"
        "                                        const bool melodia,\n"
        "                                        const bool bends)\n"
        "{\n"
        "    return ::output_to_notes_polyphonic(result, melodia, bends);\n"
        "}\n")
    print("  [basicpitch] VENDOR FIX PENDING (Leto's lane): the vendored "
          "output_to_notes_polyphonic is defined at GLOBAL scope while the "
          "header declares it in namespace basic_pitch — using a generated "
          "build-dir forwarder (vendor/** is NOT edited by Paul)")
    return fwd


def build_runner(include_dir: Path, link_flags: list[str]) -> Path:
    v = vendor_dir()
    assert v is not None
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    binary = BUILD_DIR / "basicpitch_runner"
    cmd = [compiler(), "-O2", "-std=c++20",
           "-I", str(v / "src"),
           "-I", str(eigen_dir()),
           "-I", str(include_dir),
           "-I", str(_include_shim_dir()),
           "-I", str(REPO_ROOT / "Engine" / "Transcription"),
           str(REPO_ROOT / "Tests" / "Spikes" / "basicpitch_runner.cpp")]
    for s in VENDOR_SOURCES:
        cmd.append(str(v / "src" / s))
    forwarder = _vendor_decode_forwarder()
    if forwarder is not None:
        cmd.append(str(forwarder))
    cmd += link_flags
    cmd += ["-o", str(binary)]
    print(f"  compiling basicpitch_runner ({compiler()}-O2 c++20) against "
          f"vendor/basicpitch + vendored Eigen + ORT …")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"basicpitch_runner compile failed:\n{r.stderr[-3000:]}")
    return binary


def run_trim_unit_tests(report: sc.CheckReport) -> None:
    """The release-trim + frame-mapping UNIT checks (P-301).

    A separate, dependency-free C++ binary: the header under test
    (Engine/Transcription/BasicPitchNotes.hpp) needs no ORT, no Eigen and no
    vendor code, so the rules can be pinned down on any machine with a C++20
    compiler. This leg names the behaviours the end-to-end truth check can
    only catch indirectly — above all that the trim cuts the RELEASE dip and
    never the ATTACK ramp.
    """
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    binary = BUILD_DIR / "basicpitch_trim_test"
    cmd = [compiler(), "-O2", "-std=c++20",
           "-I", str(REPO_ROOT / "Engine" / "Transcription"),
           str(REPO_ROOT / "Tests" / "Spikes" / "basicpitch_trim_test.cpp"),
           "-o", str(binary)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        report.bad("S9", f"basicpitch_trim_test did not compile:\n{r.stderr[-1500:]}")
        return
    run = subprocess.run([str(binary)], capture_output=True, text=True)
    if run.returncode != 0:
        report.bad("S9", "basicpitch_trim_test FAILED — the release-trim / "
                        "frame-mapping unit checks did not pass:\n" +
                        run.stdout[-1500:])
        return
    checks = 0
    for line in run.stdout.splitlines():
        if line.startswith("ok "):
            checks += 1
    report.ok("S9", f"basicpitch_trim_test: {checks} release-trim + frame-mapping "
                    f"unit checks green (the trim cuts the RELEASE dip, never the "
                    f"attack ramp; it never extends a note)")


def _bridge_env(lib_dir: Path | None) -> dict[str, str]:
    """The environment for a bridge subprocess (the local-wheel fallback links
    a SHARED library, so the loader must find it at run time; the shipped
    macOS configuration links the pod's STATIC framework — no loader path)."""
    env = dict(os.environ)
    if lib_dir is not None:
        var = "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
        env[var] = f"{lib_dir}{os.pathsep}{env.get(var, '')}"
    return env


def build_bridge_test(include_dir: Path, link_flags: list[str]) -> Path:
    """The C ABI bridge (Engine/Transcription/BasicPitchBridge.{h,cpp}) — the
    surface the APP's Swift side calls.

    The spike compiles and drives the BRIDGE, not just the runner: if the two
    ever disagreed, the spike would be measuring something the app does not
    ship. (The bridge is Apple-only in the app target — the SPM ORT pod — so
    it is deliberately NOT in Engine/Package.swift; see the X-### request.)
    """
    v = vendor_dir()
    assert v is not None
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    binary = BUILD_DIR / "basicpitch_bridge_test"
    cmd = [compiler(), "-O2", "-std=c++20",
           "-I", str(v / "src"),
           "-I", str(eigen_dir()),
           "-I", str(include_dir),
           "-I", str(_include_shim_dir()),
           "-I", str(REPO_ROOT / "Engine" / "Transcription"),
           str(REPO_ROOT / "Engine" / "Transcription" / "BasicPitchBridge.cpp"),
           str(REPO_ROOT / "Tests" / "Spikes" / "basicpitch_bridge_test.cpp")]
    for s in VENDOR_SOURCES:
        cmd.append(str(v / "src" / s))
    forwarder = _vendor_decode_forwarder()
    if forwarder is not None:
        cmd.append(str(forwarder))
    cmd += link_flags
    cmd += ["-o", str(binary)]
    print(f"  compiling basicpitch_bridge_test ({compiler()}-O2 c++20) — the C ABI "
          f"the app's Swift side calls …")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"basicpitch_bridge_test compile failed:\n{r.stderr[-3000:]}")
    return binary


def ensure_model() -> Path:
    """The pinned weights, fetched through the manifest (sha256-verified)."""
    env = os.environ.get("PITCHNOTES_BASICPITCH_MODEL")
    if env:
        p = Path(env)
        if not p.is_file():
            raise RuntimeError(f"PITCHNOTES_BASICPITCH_MODEL points at missing file {p}")
        return p
    cache = Path(os.environ.get("PITCHNOTES_MODEL_CACHE", REPO_ROOT / "Models" / "downloads"))
    r = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "models" / "download.py"),
         "--manifest", str(REPO_ROOT / "Models" / "manifest.json"),
         "--entry", "basic-pitch",
         "--cache-dir", str(cache)],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(
            "basic-pitch weights unavailable: no PITCHNOTES_BASICPITCH_MODEL and "
            f"download.py failed rc={r.returncode}: {r.stderr.strip()[:300]}")
    line = [l for l in r.stdout.splitlines() if l.startswith(("downloaded", "cached"))]
    if not line:
        raise RuntimeError(f"download.py printed no path: {r.stdout!r}")
    import re
    raw = re.sub(r"\s+\(\d+ bytes\)\s*$", "", line[0].split(": ", 1)[1])
    return Path(raw)


def run_runner(binary: Path, model: Path, wav: Path, outdir: Path,
               lib_dir: Path | None = None) -> dict:
    outdir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    if lib_dir is not None:
        # The local-wheel fallback links a SHARED library; the loader must find
        # it at run time. (The shipped macOS configuration links the pod's
        # STATIC framework — no loader path needed there.)
        var = "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
        env[var] = f"{lib_dir}{os.pathsep}{env.get(var, '')}"
    t0 = time.time()
    r = subprocess.run([str(binary), str(model), str(wav), str(outdir)],
                       capture_output=True, text=True, env=env)
    wall = time.time() - t0
    if r.returncode != 0:
        raise RuntimeError(f"basicpitch_runner rc={r.returncode}: {r.stderr[-800:]}")
    metrics: dict[str, str] = {}
    tensor_dims: dict[str, tuple[int, int]] = {}
    for line in r.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            if parts[0] == "TENSOR_DIMS" and len(parts) == 4:
                tensor_dims[parts[1]] = (int(parts[2]), int(parts[3]))
            else:
                metrics[parts[0]] = "\t".join(parts[1:])
    if "DONE" not in r.stdout:
        raise RuntimeError(f"basicpitch_runner incomplete output: {r.stdout[-300:]}")
    metrics["WALL_S"] = f"{wall:.3f}"
    return {"metrics": metrics, "outdir": outdir, "tensor_dims": tensor_dims}


def load_f32(path: Path) -> np.ndarray:
    return np.frombuffer(path.read_bytes(), dtype="<f4").copy()


def read_tsv(path: Path) -> list[tuple[float, ...]]:
    rows = []
    for line in path.read_text().splitlines():
        if line.strip():
            rows.append(tuple(float(x) for x in line.split("\t")))
    return rows


def real_available() -> str | None:
    """Vendor sources + compiler + the ORT headers + the weights."""
    if vendor_dir() is None:
        return None
    try:
        compiler()
    except RuntimeError:
        return None
    try:
        resolve_ort()
    except Exception:
        return None
    if os.environ.get("PITCHNOTES_BASICPITCH_MODEL"):
        return "basicpitch-vendored"
    try:
        manifest = json.loads((REPO_ROOT / "Models" / "manifest.json").read_text())
        if any(m.get("name") == "basic-pitch" for m in manifest.get("models", [])):
            return "basicpitch-vendored"
    except Exception:
        pass
    return None


def rss_bound_kb() -> tuple[int, str]:
    """S8 spike sanity bound per host OS — a RUNNER ceiling, never a device
    claim (AGENTS §8's 1.5 GB is the DEVICE budget, measured on A14 at P-603)."""
    if sys.platform == "darwin":
        return 2_000_000, "2.0 GB macOS-runner sanity bound (CI only)"
    return 1_500_000, "1.5 GB spike sanity bound (§8 1.5 GB = DEVICE target, P-603)"


# --------------------------------------------------------------------------
# The spike itself
# --------------------------------------------------------------------------

def _match_truth(truth: list[dict], detected: list[dict]) -> tuple[list, list, list]:
    """Match truth notes to detected notes by MIDI + onset proximity.

    A truth note is MATCHED when a detected note of the SAME MIDI starts
    within the tolerance; the reported error is that note's onset/offset
    error. Detected notes that match no truth note are SPURIOUS.
    """
    matched, missed, spurious = [], [], []
    used: set[int] = set()
    for t in truth:
        best = None
        best_err = None
        for i, d in enumerate(detected):
            if i in used or d["midi"] != t["midi"]:
                continue
            err = d["start_s"] - t["start_s"]
            if abs(err) <= ONSET_OFFSET_TOLERANCE_S and (best_err is None or abs(err) < abs(best_err)):
                best, best_err = i, err
        if best is None:
            missed.append(t)
            continue
        used.add(best)
        d = detected[best]
        matched.append((t, d, d["start_s"] - t["start_s"], d["end_s"] - t["end_s"]))
    for i, d in enumerate(detected):
        if i not in used:
            spurious.append(d)
    return matched, missed, spurious


def run_basicpitch_real(report: sc.CheckReport) -> None:
    include_dir, link_flags, lib_dir = resolve_ort()
    binary = build_runner(include_dir, link_flags)
    report.ok("S2", f"basicpitch_runner compiled against vendor/basicpitch + "
                    f"vendored Eigen + the ORT C++ API "
                    f"({compiler()}-O2 c++20; no second ORT — D-39)")

    run_trim_unit_tests(report)
    bridge = build_bridge_test(include_dir, link_flags)

    model = ensure_model()
    sha = hashlib.sha256(model.read_bytes()).hexdigest()
    report.ok("S1", f"weights: {model.name} sha256 {sha[:16]}… (TIER B per D-30/D-42 — "
                    f"upstream training-mix licenses UNVERIFIED; never described as clean)")

    for name in SPIKE_FIXTURES:
        wav = FIXTURES / f"{name}.wav"
        truth_path = FIXTURES / f"{name}_truth.json"
        if not wav.is_file() or not truth_path.is_file():
            raise RuntimeError(f"fixture or truth sidecar missing: {wav} / {truth_path}")
        truth = json.loads(truth_path.read_text())["notes"]

        run1 = run_runner(binary, model, wav, BUILD_DIR / f"{name}-run1", lib_dir)
        run2 = run_runner(binary, model, wav, BUILD_DIR / f"{name}-run2", lib_dir)
        m = run1["metrics"]
        n_samples = int(m["SAMPLES"])
        frames, freq_bins = (int(x) for x in m["FRAMES"].split("\t"))

        # S3: shapes + finiteness.
        dims = run1["tensor_dims"]
        cpp_tensors = {}
        for label in ("notes", "onsets", "contours"):
            arr = load_f32(run1["outdir"] / f"{label}.f32")
            t, f = dims[label]
            if arr.size != t * f:
                report.bad("S3", f"basicpitch/{name}/{label}: {arr.size} floats != {t}x{f}")
                continue
            cpp_tensors[label] = arr.reshape(t, f)
            if not np.all(np.isfinite(arr)):
                report.bad("S3", f"basicpitch/{name}/{label}: non-finite values")
        else:
            report.ok("S3", f"basicpitch/{name}: all three tensors finite "
                            f"(notes {dims['notes'][0]}x{dims['notes'][1]}, "
                            f"onsets {dims['onsets'][0]}x{dims['onsets'][1]}, "
                            f"contours {dims['contours'][0]}x{dims['contours'][1]})")

        # S4: TENSOR PARITY vs the independent Python reference.
        audio, sr = ref.read_wav_mono(wav)
        py = ref.run_reference(audio, model)
        for label, pyr in (("notes", py["notes"]), ("onsets", py["onsets"]),
                           ("contours", py["contours"])):
            cpp = cpp_tensors.get(label)
            if cpp is None:
                continue
            if cpp.shape != pyr.shape:
                report.bad("S4", f"basicpitch/{name}/{label}: shape {cpp.shape} != "
                                 f"reference {pyr.shape}")
                continue
            ok, msg = ref.compare_tensors(cpp, pyr)
            if ok:
                report.ok("S4", f"basicpitch/{name}/{label}: tensor parity within the C-7 "
                                f"tolerance ({msg})")
            else:
                report.bad("S4", f"basicpitch/{name}/{label}: TENSOR PARITY FAILED — {msg}")

        # S5: the vendor's raw note events vs the reference's decode.
        cpp_events = read_tsv(run1["outdir"] / "events.tsv")
        py_events = [(float(e["start_idx"]), float(e["end_idx"]), float(e["midi"]),
                      float(e["amplitude"])) for e in py["events"]]
        if len(cpp_events) != len(py_events):
            report.bad("S5", f"basicpitch/{name}: {len(cpp_events)} vendor events != "
                             f"{len(py_events)} reference events")
        else:
            worst = 0.0
            for a, b in zip(cpp_events, py_events):
                if int(a[0]) != int(b[0]) or int(a[1]) != int(b[1]) or int(a[2]) != int(b[2]):
                    worst = float("inf")
                    break
                worst = max(worst, abs(a[3] - b[3]))
            if worst == float("inf"):
                report.bad("S5", f"basicpitch/{name}: the vendor's note events differ from "
                                 f"the reference decode (frame/midi mismatch)")
            elif worst > 1e-3:
                report.bad("S5", f"basicpitch/{name}: amplitude parity {worst:.3e} > 1e-3")
            else:
                report.ok("S5", f"basicpitch/{name}: {len(cpp_events)} note events match the "
                                f"reference decode (frames + MIDI exact, amplitude {worst:.2e})")

        # S6: the ENGINE OUTPUT vs the committed truth (the P-301 AC).
        timed = read_tsv(run1["outdir"] / "timed.tsv")
        detected = [{"start_s": t[0], "end_s": t[1], "midi": int(t[2]),
                     "amplitude": t[3]} for t in timed]
        matched, missed, spurious = _match_truth(truth, detected)
        onset_err = [abs(e[2]) for e in matched]
        offset_err = [abs(e[3]) for e in matched]
        worst_on = max(onset_err) if onset_err else float("nan")
        worst_off = max(offset_err) if offset_err else float("nan")
        if missed:
            report.bad("S6", f"basicpitch/{name}: {len(missed)}/{len(truth)} truth notes NOT "
                             f"detected within {ONSET_OFFSET_TOLERANCE_S*1000:.0f} ms "
                             f"(first: midi {missed[0]['midi']} @ {missed[0]['start_s']:.2f}s)")
        if matched and worst_on <= ONSET_OFFSET_TOLERANCE_S and worst_off <= ONSET_OFFSET_TOLERANCE_S:
            report.ok("S6", f"basicpitch/{name}: {len(matched)}/{len(truth)} truth notes "
                            f"matched with the exact MIDI; onset error <= {worst_on*1000:.1f} ms, "
                            f"offset error <= {worst_off*1000:.1f} ms "
                            f"(AC: {ONSET_OFFSET_TOLERANCE_S*1000:.0f} ms)")
        else:
            report.bad("S6", f"basicpitch/{name}: onset/offset error exceeds the AC "
                             f"(onset {worst_on*1000:.1f} ms, offset {worst_off*1000:.1f} ms)")
        if spurious:
            # Honest, non-gated: the report states what they are (a real
            # basic-pitch behaviour — sub-octave bleed on low notes — which the
            # app's part-range filter and the confidence bands handle).
            report.ok("S6", f"basicpitch/{name}: {len(spurious)} spurious note(s) "
                            f"(logged, not gated): "
                            + ", ".join(f"midi {s['midi']} @ {s['start_s']:.2f}s "
                                        f"(amp {s['amplitude']:.2f})" for s in spurious[:6]))

        # S10: the C ABI BRIDGE (what the app's Swift side calls) must produce
        # the SAME notes as the runner's ENGINE OUTPUT. If the bridge and the
        # runner ever disagreed, the spike would be measuring something the
        # app does not ship.
        brun = subprocess.run([str(bridge), str(model), str(wav)],
                              capture_output=True, text=True,
                              env=_bridge_env(lib_dir))
        if brun.returncode != 0:
            report.bad("S10", f"basicpitch/{name}: the C ABI bridge FAILED "
                              f"(rc={brun.returncode}): {brun.stderr[-500:]}")
        else:
            bridge_notes = []
            for line in brun.stdout.splitlines():
                if line.startswith("NOTE\t"):
                    p = line.split("\t")
                    bridge_notes.append((float(p[1]), float(p[2]), int(p[3]),
                                         float(p[4])))
            runner_notes = [(t[0], t[1], int(t[2]), t[3]) for t in timed]
            if len(bridge_notes) != len(runner_notes):
                report.bad("S10", f"basicpitch/{name}: the bridge produced "
                                  f"{len(bridge_notes)} notes, the engine output has "
                                  f"{len(runner_notes)}")
            else:
                worst = 0.0
                for a, b in zip(bridge_notes, runner_notes):
                    worst = max(worst, abs(a[0] - b[0]), abs(a[1] - b[1]),
                                abs(a[2] - b[2]), abs(a[3] - b[3]))
                if worst > 1e-6:
                    report.bad("S10", f"basicpitch/{name}: the bridge and the engine "
                                      f"output differ (worst {worst:.3e})")
                else:
                    report.ok("S10", f"basicpitch/{name}: the C ABI bridge reproduces "
                                     f"the engine output exactly ({len(bridge_notes)} "
                                     f"notes, worst diff {worst:.1e})")

        # S7: determinism — two runs, byte-identical dumps.
        same = all((run1["outdir"] / f).read_bytes() == (run2["outdir"] / f).read_bytes()
                   for f in ("notes.f32", "onsets.f32", "contours.f32", "events.tsv", "timed.tsv"))
        if same:
            report.ok("S7", f"basicpitch/{name}: all dumps byte-identical across two runs")
        else:
            report.bad("S7", f"basicpitch/{name}: dumps differ across identical runs")

        # S8: resources.
        rss_kb = int(m["RSS_KB"])
        bound_kb, bound_label = rss_bound_kb()
        if rss_kb >= bound_kb:
            report.bad("S8", f"basicpitch/{name}: peak RSS {rss_kb} KB >= {bound_kb}")
        else:
            report.ok("S8", f"basicpitch/{name}: peak RSS {rss_kb/1024:.0f} MB < {bound_label}")
        rtf = float(m["RTF"])
        report.ok("S8", f"basicpitch/{name}: RTF {rtf:.3f} on the CI runner "
                        f"(device target measured on A14 at P-603 — this is NOT a device number)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--export-ref", metavar="DIR",
                    help="write the committed reference maps (npz + C-7 sidecars) "
                         "for the given fixtures")
    args = ap.parse_args()

    if real_available() is None:
        print("FAILED: the real basic-pitch path is unavailable (vendor/basicpitch, "
              "the ORT C++ headers, or the pinned weights)")
        return 1
    report = sc.CheckReport()
    try:
        run_basicpitch_real(report)
    except sc.SpikeFailure as e:
        print(f"FAILED: {e}")
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"FAILED: basic-pitch real spike error: {e}")
        return 1
    for line in report.failed:
        print(f"  VIOLATION {line}")
    if report.failed:
        print(f"FAILED: basic-pitch real spike — {len(report.failed)} violation(s)")
        return 1
    for line in report.passed:
        print(f"  ok {line}")
    print("BASICPITCH REAL SPIKE GREEN (vendored basicpitch.cpp under the ONE ORT — D-39; "
          "nmp.onnx weights TIER B — D-42)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
