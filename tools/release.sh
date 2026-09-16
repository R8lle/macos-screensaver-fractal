#!/bin/zsh
# FractalSaver — Release-Build, Notarisierung, DMG (ohne .saver-Staple)
# Usage: ./tools/release.sh
#
# Requires tools/local-signing.env and `xcrun notarytool store-credentials`.
# Do NOT staple the .saver (Contents/CodeResources breaks the Auswahlbild).
# The DMG may be stapled safely.
set -euo pipefail

cd "$(dirname "$0")/.."

LOCAL_ENV="tools/local-signing.env"
if [[ ! -f "$LOCAL_ENV" ]]; then
  echo "ERROR: $LOCAL_ENV missing. Copy tools/local-signing.env.example and fill in TEAM_ID, BUNDLE_ID, PROFILE."
  exit 1
fi
# shellcheck disable=SC1090
source "$LOCAL_ENV"
: "${TEAM_ID:?TEAM_ID missing in $LOCAL_ENV}"
: "${BUNDLE_ID:?BUNDLE_ID missing in $LOCAL_ENV}"
: "${PROFILE:?PROFILE missing in $LOCAL_ENV}"
SIGN_ID="${SIGN_ID:-Developer ID Application}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ERROR: xcodegen required (brew install xcodegen)" >&2
  exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "ERROR: create-dmg required (brew install create-dmg)" >&2
  exit 1
fi

DERIVED="build/DerivedData"
SAVER="$DERIVED/Build/Products/Release/FractalSaver.saver"
ZIP="build/FractalSaver-notarize.zip"
DMG_STAGING="build/dmg-staging"

echo "╔══════════════════════════════════════════╗"
echo "║  0/5  Version hochzählen                 ║"
echo "╚══════════════════════════════════════════╝"

CURRENT_BUILD=$(rg 'CURRENT_PROJECT_VERSION:\s*(\d+)' project.yml -o --replace '$1' | head -1)
if [[ -z "$CURRENT_BUILD" ]]; then
  echo "ERROR: CURRENT_PROJECT_VERSION nicht in project.yml" >&2
  exit 1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))
MARKETING=$(rg 'MARKETING_VERSION:\s*"([^"]+)"' project.yml -o --replace '$1' | head -1)

sed -i '' "s/CURRENT_PROJECT_VERSION: $CURRENT_BUILD/CURRENT_PROJECT_VERSION: $NEW_BUILD/g" project.yml

echo "  Marketing-Version : $MARKETING"
echo "  Build-Nummer      : $CURRENT_BUILD → $NEW_BUILD"
echo ""

DMG="build/FractalSaver-${MARKETING}-${NEW_BUILD}.dmg"

echo "╔══════════════════════════════════════════╗"
echo "║  1/5  Release-Build                      ║"
echo "╚══════════════════════════════════════════╝"

xcodegen generate

xcodebuild -scheme FractalSaver -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build | grep -E "error:|Signing Identity|SUCCEEDED|FAILED"

# Never ship a stapled .saver
rm -f "$SAVER/Contents/CodeResources"
echo "✅ Build OK (unstapled .saver)"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  2/5  .saver notarisieren                ║"
echo "╚══════════════════════════════════════════╝"

rm -f "$ZIP"
ditto -c -k --keepParent "$SAVER" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
echo "✅ .saver Notarisierung Accepted (kein Staple)"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  3/5  DMG erstellen                      ║"
echo "╚══════════════════════════════════════════╝"

rm -f "$DMG" "build/FractalSaver.dmg"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$SAVER" "$DMG_STAGING/"

cat > "$DMG_STAGING/INSTALL.txt" << 'README'
Fractal — Installation
======================

1. Doppelklick auf "FractalSaver.saver"
2. macOS fragt: "Nur für mich" oder "Für alle Benutzer" → wählen
3. Systemeinstellungen → Bildschirmschoner → "Fractal" auswählen

Falls der Doppelklick nicht greift:
  FractalSaver.saver nach ~/Library/Screen Savers/ kopieren
  (Finder → Gehe zu → Ordner… → ~/Library/Screen Savers)

Systemvoraussetzungen: macOS 13 oder neuer, Intel oder Apple Silicon
README

create-dmg \
  --volname "Fractal" \
  --volicon "Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "FractalSaver.saver" 180 185 \
  --icon "INSTALL.txt" 420 185 \
  --hide-extension "FractalSaver.saver" \
  --no-internet-enable \
  "$DMG" \
  "$DMG_STAGING"

cp "$DMG" "build/FractalSaver.dmg"
echo "✅ DMG: $DMG ($(du -sh "$DMG" | cut -f1))"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  4/5  DMG notarisieren + stapeln         ║"
echo "╚══════════════════════════════════════════╝"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG" || {
  echo "⚠️  DMG-Staple fehlgeschlagen — Notarisierung war Accepted."
}
cp "$DMG" "build/FractalSaver.dmg"
echo "✅ DMG fertig"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  5/5  Lokal installieren + Cache-Purge   ║"
echo "╚══════════════════════════════════════════╝"

DARWIN_CACHE="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
if [[ -n "${DARWIN_CACHE:-}" ]]; then
  rm -rf "$DARWIN_CACHE/com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
  rm -f  "$DARWIN_CACHE/com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.legacy-screenSaver"
fi
killall WallpaperAgent 2>/dev/null || true

DEST="${HOME}/Library/Screen Savers/FractalSaver.saver"
rm -rf "$DEST"
cp -R "$SAVER" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
rm -f "$DEST/Contents/CodeResources"

echo ""
echo "✅ Release fertig"
echo "  DMG:      $DMG"
echo "  Alias:    build/FractalSaver.dmg"
echo "  Version:  $MARKETING ($NEW_BUILD)"
echo "  Größe:    $(du -sh "$DMG" | cut -f1)"
echo "  Install:  $DEST"
xcrun stapler validate "$DMG" 2>/dev/null || echo "  (stapler validate DMG: optional)"
