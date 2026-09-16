#!/bin/bash
# Capture System Settings picker thumbnails from the built FractalSaver.saver.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SAVER="${1:-$ROOT/build/DerivedData/Build/Products/Debug/FractalSaver.saver}"
OUT="$ROOT/Resources"
CACHE="$ROOT/build/thumbnail-cache"
HOST="$CACHE/capture_thumbnail"

if [[ ! -d "$SAVER" ]]; then
  echo "Building FractalSaver first…"
  ./tools/build.sh Debug
  SAVER="$ROOT/build/DerivedData/Build/Products/Debug/FractalSaver.saver"
fi

mkdir -p "$CACHE" "$OUT"

echo "Compiling capture host…"
swiftc -O \
  -framework AppKit -framework Metal -framework MetalKit -framework ScreenSaver \
  -o "$HOST" \
  "$ROOT/tools/capture_thumbnail.swift"

echo "Capturing from $SAVER …"
"$HOST" "$SAVER" "$CACHE"

cp "$CACHE/thumbnail.png" "$OUT/thumbnail.png"
cp "$CACHE/thumbnail@2x.png" "$OUT/thumbnail@2x.png"

# HiDPI multi-rep TIFF (what ScreenSaverThumbnail resolves as "thumbnail").
tiffutil -cathidpicheck \
  "$OUT/thumbnail.png" \
  "$OUT/thumbnail@2x.png" \
  -out "$OUT/thumbnail.tiff"

echo "Wrote:"
ls -la "$OUT"/thumbnail*

echo "Re-run ./tools/build.sh to install into ~/Library/Screen Savers/"
