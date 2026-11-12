#!/bin/bash
# Packages dist/Vedimac.app into dist/Vedimac-<version>.dmg (builds the app first if needed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
APP="$ROOT/dist/Vedimac.app"
DMG="$ROOT/dist/Vedimac-$VERSION.dmg"

# Always rebuild, so the disk image can never contain an older app.
"$ROOT/Scripts/build-app.sh"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Vedimac" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
echo "==> Created $DMG"
