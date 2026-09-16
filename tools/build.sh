#!/bin/bash
# Generate, build, and install FractalSaver.saver for local testing.
# With tools/local-signing.env present, signs with Developer ID (like Matrix3DSaverX)
# so System Settings can load ScreenSaverThumbnail instead of the default blue swirl.
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

SIGN_ARGS=(
  CODE_SIGN_IDENTITY="-"
  CODE_SIGNING_REQUIRED=NO
  DEVELOPMENT_TEAM=""
)
LOCAL_ENV="$ROOT/tools/local-signing.env"
if [[ -f "$LOCAL_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_ENV"
  if [[ -n "${TEAM_ID:-}" && -n "${SIGN_ID:-}" ]]; then
    SIGN_ARGS=(
      CODE_SIGN_IDENTITY="$SIGN_ID"
      CODE_SIGNING_REQUIRED=YES
      DEVELOPMENT_TEAM="$TEAM_ID"
      OTHER_CODE_SIGN_FLAGS="--timestamp"
    )
    echo "Signing with $SIGN_ID (team $TEAM_ID)"
  fi
fi

xcodegen generate

xcodebuild \
  -project FractalSaver.xcodeproj \
  -scheme FractalSaver \
  -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  "${SIGN_ARGS[@]}" \
  build

SAVER="$ROOT/build/DerivedData/Build/Products/${CONFIG}/FractalSaver.saver"
if [[ ! -d "$SAVER" ]]; then
  echo "Build succeeded but $SAVER is missing" >&2
  exit 1
fi

# Drop WallpaperAgent's empty/stale thumbnail cache markers for this saver.
CACHE_ROOT="$HOME/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/screenSaver-"
rm -rf "$CACHE_ROOT/Users/$USER/Library/Screen Savers/FractalSaver.saver"
rm -rf "$CACHE_ROOT/Users/$USER/Library/Screen Savers/MandelSaver.saver"

osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1 || true
killall WallpaperAgent 2>/dev/null || true
killall "legacyScreenSaver" 2>/dev/null || true
killall "legacyScreenSaver-x86_64" 2>/dev/null || true

DEST="$HOME/Library/Screen Savers/FractalSaver.saver"
rm -rf "$DEST"
cp -R "$SAVER" "$DEST"
# Clear quarantine/provenance so Settings can read Resources.
xattr -cr "$DEST" 2>/dev/null || true
rm -rf "$HOME/Library/Screen Savers/MandelSaver.saver"

echo "Installed $DEST"
codesign -dv --verbose=2 "$DEST" 2>&1 | rg -i 'Authority|Signature|Identifier|flags' || true
echo "Reopen System Settings → Screen Saver and select Fractal."
