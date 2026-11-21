#!/usr/bin/env python3
"""Model manifest download tool (L-005).

Reads Models/manifest.json, validates its schema, downloads the requested
entry, verifies SIZE + SHA256, caches it, and prints the local path.

Exit codes:
  0  success
  1  manifest missing / schema invalid
  2  entry not found
  3  download failed (network / HTTP)
  4  verification failed (size or sha256 mismatch)

Usage:
  python3 -I scripts/models/download.py --validate-only
  python3 -I scripts/models/download.py --entry test-blob
  python3 -I scripts/models/download.py --entry test-blob --url <override-url> --cache-dir <dir>

--url overrides the manifest URL for one run (CI D-2 placeholder points at the
committed test blob's raw URL until HF repo thesagezm/pitchnotes-models exists).
"""

import argparse
import hashlib
import json
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

CHUNK = 8192
REQUIRED_FIELDS = {
    "name": str,
    "version": str,
    "url": str,
    "sha256": str,
    "size": int,
    "license": str,
    "runtime": str,
    "io": dict,
}


def fail(code: int, message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def validate_manifest(manifest: object, source: str) -> list:
    if not isinstance(manifest, dict):
        fail(1, f"{source}: top level must be an object")
    if manifest.get("schemaVersion") != 1:
        fail(1, f"{source}: schemaVersion must be 1")
    models = manifest.get("models")
    if not isinstance(models, list) or not models:
        fail(1, f"{source}: 'models' must be a non-empty array")
    names = set()
    for i, entry in enumerate(models):
        where = f"{source}: models[{i}]"
        if not isinstance(entry, dict):
            fail(1, f"{where}: entry must be an object")
        for field, expected in REQUIRED_FIELDS.items():
            if field not in entry:
                fail(1, f"{where}: missing required field '{field}'")
            if entry[field] is None or not isinstance(entry[field], expected):
                fail(1, f"{where}: field '{field}' must be {expected.__name__}")
        sha = entry["sha256"]
        if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha.lower()):
            fail(1, f"{where}: 'sha256' must be 64 hex chars")
        if entry["size"] < 0:
            fail(1, f"{where}: 'size' must be >= 0")
        if entry["name"] in names:
            fail(1, f"{where}: duplicate model name '{entry['name']}'")
        names.add(entry["name"])
    return models


def load_manifest(path: Path) -> list:
    if not path.is_file():
        fail(1, f"manifest not found: {path}")
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(1, f"{path}: unreadable manifest ({exc})")
    return validate_manifest(raw, str(path))


def fetch(entry: dict, cache_dir: Path, url_override: str) -> Path:
    url = url_override or entry["url"]
    cache_dir.mkdir(parents=True, exist_ok=True)
    dest = cache_dir / f"{entry['name']}-{entry['sha256'][:16]}"

    if dest.is_file() and dest.stat().st_size == entry["size"]:
        print(f"cached: {dest}")
        return dest

    part = dest.with_suffix(".part")
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            with part.open("wb") as out:
                while True:
                    chunk = response.read(CHUNK)
                    if not chunk:
                        break
                    out.write(chunk)
    except (urllib.error.URLError, OSError) as exc:
        part.unlink(missing_ok=True)
        fail(3, f"download failed ({url}): {exc}")

    if part.stat().st_size != entry["size"]:
        actual = part.stat().st_size
        part.unlink(missing_ok=True)
        fail(4, f"size mismatch for {url}: expected {entry['size']}, got {actual}")

    digest = hashlib.sha256(part.read_bytes()).hexdigest()
    if digest != entry["sha256"].lower():
        part.unlink(missing_ok=True)
        fail(4, f"sha256 mismatch for {url}: expected {entry['sha256']}, got {digest}")

    shutil.move(str(part), str(dest))
    print(f"downloaded + verified: {dest} ({entry['size']} bytes)")
    return dest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", default="Models/manifest.json",
                        help="path to manifest.json (default: Models/manifest.json)")
    parser.add_argument("--entry", help="model name to download")
    parser.add_argument("--url", help="override the entry's URL for this run (D-2 placeholder)")
    parser.add_argument("--cache-dir", default="Models/downloads",
                        help="cache directory (default: Models/downloads, gitignored)")
    parser.add_argument("--validate-only", action="store_true",
                        help="validate the manifest schema and exit")
    args = parser.parse_args()

    models = load_manifest(Path(args.manifest))
    if args.validate_only:
        print(f"manifest OK: {len(models)} entr{'y' if len(models) == 1 else 'ies'} validated")
        return

    if not args.entry:
        parser.error("--entry is required unless --validate-only is given")
    matches = [m for m in models if m["name"] == args.entry]
    if not matches:
        fail(2, f"entry '{args.entry}' not in {args.manifest} (have: {', '.join(m['name'] for m in models)})")

    fetch(matches[0], Path(args.cache_dir), args.url)


if __name__ == "__main__":
    main()
