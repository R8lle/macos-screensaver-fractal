#!/bin/bash
# Generate, build, and install FractalSaver.saver for local testing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-Debug}"
case "$CONFIG" in
  Debug|Release) ;;
  *)
    echo "Usage: $0 [Debug|Release]" >&2
    exit 1
    ;;
esac

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi

xcodegen generate

xcodebuild \
  -project FractalSaver.xcodeproj \
  -scheme FractalSaver \
  -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM="" \
  build

SAVER="$ROOT/build/DerivedData/Build/Products/${CONFIG}/FractalSaver.saver"
if [[ ! -d "$SAVER" ]]; then
  echo "Build succeeded but $SAVER is missing" >&2
  exit 1
fi

DEST="$HOME/Library/Screen Savers/FractalSaver.saver"
rm -rf "$DEST"
cp -R "$SAVER" "$DEST"
rm -rf "$HOME/Library/Screen Savers/MandelSaver.saver"
echo "Installed $DEST"
echo "Reopen System Settings → Screen Saver and select Fractal."
