#!/bin/bash
# Build the .saver if needed, then open it in a normal window (no System Settings).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SAVER="${1:-$ROOT/build/DerivedData/Build/Products/Debug/FractalSaver.saver}"
if [[ ! -d "$SAVER" ]]; then
  "$ROOT/tools/build.sh" Debug
  SAVER="$ROOT/build/DerivedData/Build/Products/Debug/FractalSaver.saver"
fi

mkdir -p "$ROOT/build"
HOST="$ROOT/build/FractalTest"
SRC="$ROOT/tools/TestHost.swift"
if [[ ! -x "$HOST" || "$SRC" -nt "$HOST" ]]; then
  ARCH="$(uname -m)"
  swiftc \
    -O \
    -target "${ARCH}-apple-macos13.0" \
    -framework Cocoa \
    -framework ScreenSaver \
    -o "$HOST" \
    "$SRC"
fi

echo "Opening test window with $SAVER"
exec "$HOST" "$SAVER"
