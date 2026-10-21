#!/bin/bash
# Installs (or updates) Tangerine from GitHub in one step:
#   curl -fsSL https://raw.githubusercontent.com/CodeLinkIO/tangerine/main/scripts/get.sh | bash
# Downloads Tangerine.dmg, checks it, copies Tangerine.app to Applications and opens it. No sudo, no other changes.
# The app isn't notarized by Apple. Browsers, AirDrop and chat apps mark downloads as quarantined, and macOS then
# wants "Open Anyway" in System Settings; files that curl downloads aren't marked, so the app just opens.
# TANGERINE_DMG_URL=file:///path/Tangerine.dmg installs a local disk image instead (for testing).
set -euo pipefail

# Everything runs from main(), so bash has read the whole script before acting on it, even when it arrives
# through a pipe that's cut short.
main() {
    URL="${TANGERINE_DMG_URL:-https://github.com/CodeLinkIO/tangerine/raw/main/Tangerine.dmg}"
    BUNDLE_ID=dev.tangerine.converter

    fail() { echo "error: $*" >&2; exit 1; }
    plist_id() { /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true; }

    [[ "$(uname -m)" == arm64 ]] || fail "Tangerine needs a Mac with Apple silicon (M1 or later)."
    (( "$(sw_vers -productVersion | cut -d. -f1)" >= 13 )) || fail "Tangerine needs macOS 13 Ventura or later."

    WORK="$(mktemp -d)"
    MOUNT="$WORK/mnt"
    NEW=""
    cleanup() {
        [[ -d "$MOUNT" ]] && hdiutil detach -quiet "$MOUNT" 2>/dev/null
        rm -rf "$WORK" ${NEW:+"$NEW"}
    }
    trap cleanup EXIT

    echo "Downloading Tangerine…"
    curl -fL --progress-bar --retry 3 -o "$WORK/Tangerine.dmg" "$URL" || fail "couldn't download $URL"
    # Attaching checks the image's own checksum, so a damaged download stops here.
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$WORK/Tangerine.dmg" </dev/null ||
        fail "the download is damaged; run the command again"
    APP="$MOUNT/Tangerine.app"
    [[ "$(plist_id "$APP")" == "$BUNDLE_ID" ]] || fail "the disk image doesn't contain Tangerine"
    codesign --verify --strict --deep "$APP" 2>/dev/null || fail "Tangerine.app's signature is broken; run the command again"

    # /Applications when this account can write to it (administrators can), otherwise ~/Applications.
    DIR=/Applications
    [[ -w "$DIR" ]] || { DIR="$HOME/Applications"; mkdir -p "$DIR"; }
    DEST="$DIR/Tangerine.app"
    [[ ! -e "$DEST" || "$(plist_id "$DEST")" == "$BUNDLE_ID" ]] || fail "$DEST is a different app; not replacing it"

    # Quit a running Tangerine (this one, not another app with the same name) so the new copy takes over the menu bar.
    for pid in $(pgrep -x Tangerine || true); do
        exe="$(ps -o comm= -p "$pid" || true)"
        [[ "$(plist_id "${exe%/Contents/MacOS/*}")" == "$BUNDLE_ID" ]] && kill "$pid" 2>/dev/null || true
    done
    for _ in {1..50}; do
        pgrep -f "^$DEST/Contents/MacOS/Tangerine" >/dev/null || break
        sleep 0.1
    done

    # Copy next to the old app first, so a failed copy never leaves you without one.
    NEW="$DIR/.Tangerine.app.new"
    rm -rf "$NEW"
    ditto "$APP" "$NEW"
    rm -rf "$DEST"
    mv "$NEW" "$DEST"

    # Register the app (Finder's Services menu, "Open with") and open it.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
    /System/Library/CoreServices/pbs -update 2>/dev/null || true
    open "$DEST"
    echo "Installed $DEST. Tangerine lives in the menu bar; run this command again any time to update it."
}

main "$@"
