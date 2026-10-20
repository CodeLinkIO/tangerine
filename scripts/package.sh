#!/bin/bash
# Builds Tangerine.app and wraps it in a compressed disk image: build/Tangerine-<version>.dmg,
# copied to Tangerine.dmg at the top of the repo (the download the README links to).
# Opening the image shows the app next to an Applications shortcut; drag one onto the other.
#   scripts/package.sh                                    # ad hoc signed: fine for your own Macs
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profile> scripts/package.sh
#                                                         # signed + notarized: opens on any Mac
# Create the notary profile once with: xcrun notarytool store-credentials <profile>
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "${SKIP_BUILD:-0}" == 1 ]] || scripts/build-app.sh
APP="build/Tangerine.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="build/Tangerine-$VERSION.dmg"

VOLUME="Tangerine $VERSION"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/$VOLUME"
ditto "$APP" "$STAGE/$VOLUME/Tangerine.app"
ln -s /Applications "$STAGE/$VOLUME/Applications"

rm -f "$DMG"
# ULMO (LZMA) is the smallest format; every macOS that Tangerine supports can open it.
# `diskutil image` replaces the deprecated `hdiutil create`, which can fail with "Resource busy" on recent macOS.
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format ULMO --volumeName "$VOLUME" "$STAGE/$VOLUME" "$DMG" >/dev/null 2>"$STAGE/log" ||
        { cat "$STAGE/log" >&2; exit 1; }
else
    hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE/$VOLUME" -format ULMO -ov "$DMG"
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
hdiutil verify -quiet "$DMG"
cp -f "$DMG" Tangerine.dmg

echo "Packaged $DMG ($(du -h "$DMG" | cut -f1); app is $(du -sh "$APP" | cut -f1) unpacked) and copied it to Tangerine.dmg"
