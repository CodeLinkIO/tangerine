#!/bin/bash
# Builds build/Tangerine.app (menu-bar app + bundled `tangerine` CLI) and signs it ad hoc.
#   CONFIG=debug scripts/build-app.sh     # faster, unoptimized build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product TangerineApp
swift build -c "$CONFIG" --product tangerine
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Tangerine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TangerineApp" "$APP/Contents/MacOS/Tangerine"
cp "$BIN/tangerine" "$APP/Contents/Resources/tangerine"
cp Support/Info.plist "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$APP/Contents/MacOS/Tangerine" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --deep --sign - "$APP"
echo "Built $APP"
echo "Install: cp -R \"$APP\" /Applications/   (Finder Services need the app in /Applications)"
