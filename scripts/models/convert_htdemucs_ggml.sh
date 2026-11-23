#!/usr/bin/env bash
# convert_htdemucs_ggml.sh — P-201 layer b (D-32.6 PRIMARY weights source).
#
# Converts the OFFICIAL Meta htdemucs checkpoint (.th @e976d93e, hosted at
# https://dl.fbaipublicfiles.com/demucs/ per demucs/pretrained.py:20) into the
# demucs.cpp ggml fp16 format using the PINNED upstream converter
# vendor/demucs.cpp/scripts/convert-pth-to-ggml.py (byte-identical intake,
# patches.log: "NO source patches yet").
#
# Provenance (D-30 / D-32.6 — MANDATORY trust requirements):
#   - htdemucs WEIGHTS = TIER B: MIT © Meta Platforms (verified @e976d93e),
#     trained on MUSDB18 (CC BY-NC-SA) + an undocumented 800-song extra set.
#     Ships with recorded risk; HUMAN SIGN-OFF before any commercial/App Store
#     distribution; NEVER represented as "clean". Manifest license field reads:
#     "MIT (Tier B per D-30: training-data risk recorded)".
#   - sha256 computed at first verification is the trust anchor (D-19.4): the
#     HF mirror must re-verify byte-identical; URLs may change, sha MUST NOT.
#
# Requirements (Linux/CI only — never on device):
#   python3 venv with: torch (CPU), demucs==4.0.1 (official Meta PyPI package,
#   MIT — loads the checkpoint + resolves the .th from dl.fbaipublicfiles.com).
#   Example:
#     python3 -m venv ~/.venvs/demucs-convert
#     ~/.venvs/demucs-convert/bin/pip install --index-url \
#       https://download.pytorch.org/whl/cpu torch
#     ~/.venvs/demucs-convert/bin/pip install demucs==4.0.1
#
# Usage:
#   bash scripts/models/convert_htdemucs_ggml.sh <dest_dir> [python-bin]
#     <dest_dir>   output directory for ggml-model-htdemucs-4s-f16.bin
#     [python-bin] interpreter with torch+demucs (default: $PY or python3)
#
# Output: <dest_dir>/ggml-model-htdemucs-4s-f16.bin + a sha256 sidecar +
# manifest-entry JSON snippet on stdout (paste into Models/manifest.json after
# human/Leto review, then upload via scripts/models/hf_upload.sh htdemucs
# --from <dest_dir>/ggml-model-htdemucs-4s-f16.bin).
set -euo pipefail

DEST="${1:?usage: $0 <dest_dir> [python-bin]}"
PY="${2:-${PY:-python3}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONVERTER="$REPO_ROOT/vendor/demucs.cpp/scripts/convert-pth-to-ggml.py"

[ -f "$CONVERTER" ] || {
  echo "error: pinned converter missing at $CONVERTER" >&2
  echo "       vendor/demucs.cpp intake lives on origin/leto until the leto→main" >&2
  echo "       merge (patches.log @ef63422+1815a47); fetch+rebase first." >&2
  exit 2
}

"$PY" -c "import torch, demucs" 2>/dev/null || {
  echo "error: $PY lacks torch+demucs (see header comment for venv setup)" >&2
  exit 3
}

mkdir -p "$DEST"
echo "== provenance: Meta htdemucs @e976d93ecc3865e5757426930257e200846a520a ==";
echo "== converter: vendor/demucs.cpp/scripts/convert-pth-to-ggml.py @4edae497 ==";
echo "== weights tier: TIER B per D-30 (MIT © Meta; MUSDB18 CC BY-NC-SA + undocumented extra set) ==";
"$PY" "$CONVERTER" "$DEST"

BIN="$DEST/ggml-model-htdemucs-4s-f16.bin"
[ -f "$BIN" ] || { echo "error: converter did not produce $BIN" >&2; exit 4; }

SHA=$(sha256sum "$BIN" | cut -d' ' -f1)
SIZE=$(stat -c%s "$BIN")
printf '%s  %s\n' "$SHA" "$BIN" > "$BIN.sha256"
cat "$BIN.sha256"

cat <<EOF

== Models/manifest.json entry (paste after review; sha256 = trust anchor) ==
{
  "name": "htdemucs",
  "version": "4.0.1+ggml@4edae497",
  "url": "https://huggingface.co/thesagezm/pitchnotes-models/resolve/main/htdemucs/ggml-model-htdemucs-4s-f16.bin",
  "sha256": "$SHA",
  "size": $SIZE,
  "license": "MIT (Tier B per D-30: training-data risk recorded)",
  "runtime": "ggml-cpp",
  "io": {
    "role": "two-stem separation engine (P-201..P-205; D-9 hasInstrumental). Converted from the official Meta .th @e976d93e via the pinned demucs.cpp converter @4edae497 (D-32.6 PRIMARY path). htdemucs weights = D-30 TIER B: MIT (c) Meta; trained on MUSDB18 (CC BY-NC-SA) + undocumented 800-song extra set. Human sign-off required before commercial/App Store distribution; sideload builds unaffected; licenses screen copy per D-30.",
    "format": "demucs.cpp ggml fp16 (magic dmc4); 44.1 kHz stereo in, VOCALS/INSTRUMENTAL stems out; ~81 MB"
  }
}

== upload (trust-anchor flow) ==
  bash scripts/models/hf_upload.sh htdemucs --from "$BIN"
EOF
