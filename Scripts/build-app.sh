#!/bin/bash
# Builds Vedimac.app into dist/. Run on a Mac with Xcode or the Command Line Tools installed.
#
#   Scripts/build-app.sh                          ad-hoc signed (runs on this Mac only, not notarized)
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Vedimac"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUNDLE_ID="${BUNDLE_ID:-local.chargewatch.ChargeWatch}"
IDENTITY="${CODESIGN_IDENTITY:--}"

echo "==> Building (release)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN_DIR/ChargeWatch" "$APP/Contents/MacOS/ChargeWatch"
cp "$BIN_DIR/gaugectl" "$APP/Contents/Helpers/gaugectl"
chmod 755 "$APP/Contents/MacOS/ChargeWatch" "$APP/Contents/Helpers/gaugectl"

if [ -f "$ROOT/Resources/AppIcon.png" ]; then
  echo "==> Creating the icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ChargeWatch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Signing with: $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP/Contents/Helpers/gaugectl"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/gaugectl"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"
