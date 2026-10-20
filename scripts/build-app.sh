#!/bin/bash
# Builds build/Tangerine.app (menu-bar app + bundled `tangerine` CLI) and signs it.
#   scripts/build-app.sh                                            # ad hoc signature, for this Mac
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh  # hardened runtime, ready to notarize
#   CONFIG=debug scripts/build-app.sh                               # unoptimized build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
swift build -c "$CONFIG" --product TangerineApp
swift build -c "$CONFIG" --product tangerine
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Tangerine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/TangerineApp" "$APP/Contents/MacOS/Tangerine"
cp "$BIN/tangerine" "$APP/Contents/Helpers/tangerine"
cp Support/Info.plist "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$APP/Contents/MacOS/Tangerine" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Sign nested code first, then the app. A real identity also gets the hardened runtime and a
# secure timestamp, which notarization requires.
if [[ "$IDENTITY" == "-" ]]; then
    SIGN=(codesign --force --sign -)
else
    SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
fi
"${SIGN[@]}" "$APP/Contents/Helpers/tangerine"
"${SIGN[@]}" --entitlements Support/Tangerine.entitlements "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1), signed: ${IDENTITY/#-/ad hoc})"
