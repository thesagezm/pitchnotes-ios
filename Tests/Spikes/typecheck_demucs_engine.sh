#!/usr/bin/env bash
# P-202 L2 — LOCAL type-check for the Apple-only DemucsEngine.swift.
#
# WHY: DemucsEngine.swift is NOT in the Linux build (it links C++), so a
# Swift-side type error in it used to surface only on the macOS CI archive —
# a ~10 minute round trip per mistake. This script type-checks the file on
# Linux against:
#   - the REAL EngineCore module (built by SwiftPM), and
#   - a C-module STUB generated from the REAL Engine/Separation/DemucsShim.h
#     (so the C interop surface cannot drift: the stub IS the real header).
#
# The stub only provides declarations — no linking — so this checks Swift
# semantics (escaping, Sendable, async, API usage), NOT the C++ side
# (DemucsShim.cpp is checked separately with g++ -fsyntax-only against the
# vendored headers, and the real compile proof is the macOS CI archive).
#
# Usage (from the repo root):
#   Tests/Spikes/typecheck_demucs_engine.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/pitchnotes-typecheck"
STUB="$WORK/shimstub"
SCRATCH="$WORK/spm-build"

rm -rf "$WORK"
mkdir -p "$STUB"
cp "$REPO_ROOT/Engine/Separation/DemucsShim.h" "$STUB/DemucsShim.h"
cat > "$STUB/module.modulemap" <<'EOF'
module DemucsShim {
    header "DemucsShim.h"
    export *
}
EOF

echo "== building EngineCore =="
( cd "$REPO_ROOT/Engine" && swift build --scratch-path "$SCRATCH" )
MODULES="$(dirname "$(find "$SCRATCH" -name 'EngineCore.swiftmodule' | head -1)")"

echo "== type-checking DemucsEngine.swift against the shim stub =="
swiftc -typecheck "$REPO_ROOT/Engine/Separation/DemucsEngine.swift" \
    -I "$MODULES" \
    -I "$STUB" \
    -Xcc -fmodule-map-file="$STUB/module.modulemap"

echo "== type-check OK =="
