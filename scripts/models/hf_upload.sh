#!/usr/bin/env bash
# hf_upload.sh — create thesagezm/pitchnotes-models (D-2) and upload the
# manifest-verified models, byte-identical (D-19.4 trust anchor: URLs may
# change, sha256 MUST NOT).
#
# REQUIRES: HF_TOKEN env var (Write scope, https://huggingface.co/settings/tokens).
#   export HF_TOKEN=hf_...   (human one-time setup, 2026-11-21)
#
# Steps: create public repo (D-2) -> download each manifest entry via
# scripts/models/download.py (the SAME verify path CI uses) -> upload to HF ->
# re-verify SHA256 of the re-hosted bytes -> print the swapped manifest URLs.
# The Models/manifest.json URL swap is a MANUAL review commit afterwards
# (Leto), never done blind by this script.
#
# Runbook (execution BLOCKED(human) until HF_TOKEN exists — recorded in LOG):
#   export HF_TOKEN=hf_...
#   bash scripts/models/hf_upload.sh swiftf0 silero-vad test-blob
set -euo pipefail

REPO="thesagezm/pitchnotes-models"
MANIFEST="Models/manifest.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -n "${HF_TOKEN:-}" ] || { echo "error: HF_TOKEN not set (Write scope)"; exit 2; }
[ $# -ge 1 ] || { echo "usage: $0 <manifest-entry...>"; exit 1; }

python3 - << 'PYEOF'
import os, sys, urllib.request, json
req = urllib.request.Request(
    "https://huggingface.co/api/repos/create",
    data=json.dumps({"type": "model", "name": "pitchnotes-models", "private": False}).encode(),
    headers={"Authorization": f"Bearer {os.environ['HF_TOKEN']}",
             "Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req) as r:
        print("repo create:", r.read().decode()[:200])
except Exception as e:
    print("repo create (may already exist):", e)
PYEOF

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet "huggingface_hub>=0.26"

# Bootstrap special case: an entry whose manifest URL already points at $REPO
# (test-blob.bin) 404s until the first upload — pass its committed source via
# --from anywhere in the args:
#   bash scripts/models/hf_upload.sh test-blob --from Models/test-blob.bin
FROM=""
ENTRIES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    *) ENTRIES+=("$1"); shift ;;
  esac
done

for ENTRY in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
  echo "=== $ENTRY ==="
  # Same download+verify path CI uses; cached file is the trust anchor.
  # download.py prints "cached: <path>" (hit) or "downloaded + verified: <path> (<size> bytes)" (fresh).
  # A bootstrap entry (manifest URL points at $REPO before its first upload) 404s
  # here on purpose — fall back to --from. dl.log is per-entry scratch.
  DLOG="$WORK/dl.log"
  LOCAL=""
  if python3 -I scripts/models/download.py --manifest "$MANIFEST" --entry "$ENTRY" --cache-dir "$HOME/pitchnotes-model-cache" >"$DLOG" 2>&1; then
    LOCAL=$(sed -n -E 's/^(cached|downloaded \+ verified): ([^ ]+).*/\2/p' "$DLOG")
  elif [ -n "$FROM" ] && [ -f "$FROM" ]; then
    echo "bootstrap override: uploading committed $FROM"
    LOCAL="$FROM"
  fi
  [ -f "$LOCAL" ] || { echo "error: no source for $ENTRY (download log: $(tail -c 200 "$DLOG"))"; exit 3; }
  REMOTE="$ENTRY/$(python3 -c "import json;m=json.load(open('$MANIFEST'));u=[x['url'] for x in m['models'] if x['name']=='$ENTRY'][0];print(u.rsplit('/',1)[-1].split('?')[0])")"
  echo "upload -> $REPO/$REMOTE"
  HF_TOKEN="$HF_TOKEN" "$WORK/venv/bin/python" - "$LOCAL" "$REPO" "$REMOTE" << 'PYEOF'
import os, sys, hashlib
from huggingface_hub import HfApi
local, repo, remote = sys.argv[1], sys.argv[2], sys.argv[3]
sha = hashlib.sha256(open(local, "rb").read()).hexdigest()
api = HfApi(token=os.environ["HF_TOKEN"])
api.upload_file(path_or_fileobj=local, path_in_repo=remote, repo_id=repo, repo_type="model")
print(f"uploaded {remote} sha256={sha}")
PYEOF
  # Trust anchor: re-download from HF and compare bytes to the manifest sha.
  HF_URL="https://huggingface.co/$REPO/resolve/main/$REMOTE"
  python3 -I scripts/models/download.py --manifest "$MANIFEST" --entry "$ENTRY" --url "$HF_URL" --cache-dir "$WORK/verify"
  echo "VERIFIED byte-identical on HF: $ENTRY -> $HF_URL"
done

echo "=== NEXT (manual, Leto) ==="
echo "Swap Models/manifest.json url fields to $REPO/resolve/main/<entry>/... — sha256/size fields MUST NOT change."
