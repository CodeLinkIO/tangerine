#!/bin/bash
# Builds Tangerine, installs it as /Applications/Tangerine.app (replacing an older copy) and opens it.
#   scripts/install.sh            # build, install, open
#   scripts/install.sh --login    # …and turn on Open at Login
#   SKIP_BUILD=1 scripts/install.sh   # install the existing build/Tangerine.app
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "${SKIP_BUILD:-0}" == 1 ]] || scripts/build-app.sh
SRC="build/Tangerine.app"
DEST="/Applications/Tangerine.app"
plist_id() { /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true; }
ID="$(plist_id "$SRC")"
[[ -n "$ID" ]] || { echo "error: no app at $SRC; run without SKIP_BUILD=1." >&2; exit 1; }

if [[ -e "$DEST" && "$(plist_id "$DEST")" != "$ID" ]]; then
    echo "error: $DEST is a different app ($(plist_id "$DEST")); not replacing it." >&2
    exit 1
fi

# Quit running copies (installed or from build/) so the new one takes over the menu bar and hotkey.
for exe in "$DEST/Contents/MacOS/Tangerine" "$PWD/$SRC/Contents/MacOS/Tangerine"; do
    pkill -f "^$exe" 2>/dev/null || true
done
for _ in {1..50}; do
    pgrep -f "^$DEST/Contents/MacOS/Tangerine" >/dev/null || break
    sleep 0.1
done

rm -rf "$DEST"
ditto "$SRC" "$DEST"

# Point Launch Services and the Services menu at the installed copy, not the build folder.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$SRC" 2>/dev/null || true
"$LSREGISTER" -f "$DEST"
/System/Library/CoreServices/pbs -update 2>/dev/null || true

if [[ "${1:-}" == "--login" ]]; then
    echo "Open at login: $("$DEST/Contents/MacOS/Tangerine" --login-item on)"
fi
open "$DEST"
echo "Installed $DEST"
