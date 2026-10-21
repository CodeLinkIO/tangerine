#!/bin/bash
# End-to-end check of a built app: signature and bundle layout, the disk image, and real
# conversions through the engine bundled inside the app (the same code the wheel and Converter run).
#   scripts/smoke-test.sh                               # tests build/Tangerine.app (+ Tangerine.dmg if built)
#   scripts/smoke-test.sh /Applications/Tangerine.app   # tests the installed copy
set -uo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Tangerine.app}"
APP_BIN="$APP/Contents/MacOS/Tangerine"
CLI="$APP/Contents/Helpers/tangerine"
WORK="$(mktemp -d)"
IN="$WORK/in" OUT="$WORK/out"
mkdir -p "$IN" "$OUT"
cleanup() { [[ -d "$WORK/mnt" ]] && hdiutil detach -quiet "$WORK/mnt" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
passed=0 failed=0 skipped=0

ok()    { echo "  ✓ $1"; passed=$((passed + 1)); }
bad()   { echo "  ✗ $1"; tail -4 "$WORK/log" | sed 's/^/      /'; failed=$((failed + 1)); }
skip()  { echo "  – $1 (skipped: $2)"; skipped=$((skipped + 1)); }
check() { local name="$1"; shift; if "$@" >"$WORK/log" 2>&1; then ok "$name"; else bad "$name"; fi; }

# Runs the bundled CLI and checks that every file it reports exists and isn't empty.
produces() {
    local outputs
    outputs="$("$CLI" "$@" --out "$OUT" | grep '^/')" || return 1
    while IFS= read -r path; do
        [[ -s "$path" || -d "$path" ]] || { echo "missing or empty: $path"; return 1; }
    done <<<"$outputs"
}
converts() { produces convert "$1" --to "$2"; }
convert_all() { local input="$1"; shift; for to in "$@"; do check "$(basename "$input") → $to" converts "$input" "$to"; done; }
# `offers yes|no file words…`: whether `tangerine formats` lists each word for the file.
offers() {
    local want="$1" file="$2" list word; shift 2
    list="$("$CLI" formats "$file")" || return 1
    for word in "$@"; do
        if grep -qw -- "$word" <<<"$list"; then [[ $want == yes ]]; else [[ $want == no ]]; fi || { echo "$list"; return 1; }
    done
}
# `fails_with message cli-args…`: the CLI fails and says `message`.
fails_with() { local message="$1" log; shift; ! log="$("$CLI" "$@" --out "$OUT" 2>&1)" && grep -qF -- "$message" <<<"$log"; }
# `compresses_to ext file`: Compress writes one file with that extension.
compresses_to() { local out; out="$("$CLI" tool compress "$2" --out "$OUT" | grep '^/')" && [[ -s "$out" && $out == *."$1" ]]; }

[[ -x "$APP_BIN" ]] || { echo "No app at $APP. Run scripts/build-app.sh first." >&2; exit 1; }
echo "Testing $APP"

echo "App bundle"
check "code signature is valid" codesign --verify --strict --deep "$APP"
check "bundle id is dev.tangerine.converter" test "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = dev.tangerine.converter
check "runs as a menu-bar app (LSUIElement)" test "$(plutil -extract LSUIElement raw "$APP/Contents/Info.plist")" = true
check "app icon is bundled" test -s "$APP/Contents/Resources/AppIcon.icns"
check "app binary starts" "$APP_BIN" --render-iconset "$WORK/icons"
check "bundled engine starts" "$CLI" engines
ENGINES="$("$CLI" engines 2>/dev/null)"
has_ffmpeg() { grep -q '^ffmpeg: */' <<<"$ENGINES"; }
has_webp() { grep -q '^Images:.*WebP' <<<"$ENGINES"; }
# Only macOS's own libraries may be linked dynamically, or the tool breaks on a Mac without Homebrew.
system_libs_only() { ! otool -L "$1" | tail -n +2 | grep -v -e $'^\t/usr/lib/' -e $'^\t/System/Library/'; }

if [[ -x "$APP/Contents/Helpers/ffmpeg" ]]; then
    echo "Bundled engines"
    for tool in ffmpeg cwebp gif2webp; do
        check "$tool is the app's own copy" grep -qE "^$tool: +/.*Contents/Helpers/$tool\$" <<<"$ENGINES"
        check "$tool links only macOS libraries" system_libs_only "$APP/Contents/Helpers/$tool"
    done
    check "ffmpeg is an LGPL build" grep -q "GNU Lesser General Public" <<<"$("$APP/Contents/Helpers/ffmpeg" -hide_banner -L)"
    check "ffmpeg has no network protocols" test -z "$("$APP/Contents/Helpers/ffmpeg" -hide_banner -protocols | grep -E '^ +(https?|tcp|udp|rtmp|ftp)$')"
    check "licenses are bundled" test -s "$APP/Contents/Resources/Licenses/README.txt"
fi

# The newest disk image: Tangerine.dmg (from package.sh) or one in build/.
DMG="$(ls -t Tangerine.dmg build/Tangerine-*.dmg 2>/dev/null | head -1)"
if [[ "$APP" == build/Tangerine.app && -n "$DMG" ]]; then
    echo "Disk image ($DMG)"
    check "image checksum is valid" hdiutil verify -quiet "$DMG"
    mkdir -p "$WORK/mnt"
    if hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/mnt" "$DMG"; then
        check "contains a signed Tangerine.app" codesign --verify --strict --deep "$WORK/mnt/Tangerine.app"
        check "contains an Applications shortcut" test "$(readlink "$WORK/mnt/Applications")" = /Applications
        hdiutil detach -quiet "$WORK/mnt"
    else
        echo "  ✗ image mounts"; failed=$((failed + 1))
    fi
    rmdir "$WORK/mnt" 2>/dev/null
fi

# Fixtures: a PNG drawn by the app itself, a Markdown note, a spoken AIFF, a 1-second clip with sound (needs
# ffmpeg; made only with what the app ships), and files derived from them.
cp "$WORK/icons/icon_512x512@2x.png" "$IN/photo.png" 2>/dev/null
cat >"$IN/notes.md" <<'EOF'
# Smoke test

Tangerine converts **images**, video, audio, PDFs and documents, all *offline*.

- First item
- Second item with a [link](https://example.com)
EOF
"$CLI" convert "$IN/photo.png" --to jpg --out "$IN" >/dev/null 2>&1
"$CLI" convert "$IN/photo.png" --to gif --out "$IN" >/dev/null 2>&1
"$CLI" convert "$IN/photo.png" --to pdf --out "$IN" >/dev/null 2>&1
"$CLI" convert "$IN/notes.md" --to pdf --out "$IN" >/dev/null 2>&1
"$CLI" convert "$IN/notes.md" --to docx --out "$IN" >/dev/null 2>&1
"$CLI" tool mergePDF "$IN/notes.pdf" "$IN/photo.pdf" --out "$IN" >/dev/null 2>&1
say -o "$IN/voice.aiff" "Tangerine smoke test" 2>/dev/null
FFMPEG="$(sed -n 's/^ffmpeg: *\(\/.*\)/\1/p' <<<"$ENGINES")"
if [[ -n "$FFMPEG" ]]; then   # the still GIF becomes a 1-second H.264 clip, then gets the spoken audio
    "$CLI" convert "$IN/photo.gif" --to mp4 --out "$WORK" >/dev/null 2>&1
    "$FFMPEG" -v error -i "$WORK/photo.mp4" -i "$IN/voice.aiff" -map 0:v -map 1:a -c:v copy -c:a aac -shortest \
        "$IN/clip.mp4" 2>/dev/null
fi

echo "Images"
convert_all "$IN/photo.png" jpg heic avif tiff gif bmp ico icns pdf
convert_all "$IN/photo.jpg" png
if has_webp; then convert_all "$IN/photo.png" webp; else skip "photo.png → webp" "brew install webp"; fi
check "compress PNG" produces tool compress "$IN/photo.png"
check "compress TIFF keeps it a TIFF" compresses_to tiff "$OUT/photo.tiff"
check "compress isn't offered for BMP" offers no "$OUT/photo.bmp" Compress
check "image without text → txt says so" fails_with "No text found" convert "$IN/photo.png" --to txt
check "rotate JPG (lossless)" produces tool rotateRight "$IN/photo.jpg"
check "resize 50%" produces tool resizeHalf "$IN/photo.png"
check "flip" produces tool flipHorizontal "$IN/photo.png"

echo "Video"
if [[ -s "$IN/clip.mp4" ]]; then
    convert_all "$IN/clip.mp4" mov m4v gif m4a wav mkv webm avi wmv mp3
    check "compress video" produces tool compress "$IN/clip.mp4"
    check "mute video" produces tool mute "$IN/clip.mp4"
    check "clip with sound is offered audio formats and Mute" offers yes "$IN/clip.mp4" MP3 M4A Mute
    check "clip without sound isn't" offers no "$WORK/photo.mp4" MP3 M4A WAV Mute
    convert_all "$IN/photo.gif" mp4
    # Formats only ffmpeg reads, from the files just written.
    for input in clip.mkv clip.webm clip.avi clip.wmv; do
        [[ -s "$OUT/$input" ]] && convert_all "$OUT/$input" mp4
    done
    # AV1, which the app reads but can't write: a full ffmpeg (Homebrew's) makes the test clips if it's there.
    MAKER="$(command -v /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg | head -1 || true)"
    if [[ -n "$MAKER" ]] && "$MAKER" -hide_banner -encoders 2>/dev/null | grep -q libsvtav1; then
        for ext in mkv webm mp4; do
            audio=libopus; [[ $ext == mp4 ]] && audio=aac
            "$MAKER" -v error -i "$IN/clip.mp4" -c:v libsvtav1 -preset 12 -c:a $audio "$IN/av1.$ext" 2>/dev/null
        done
        convert_all "$IN/av1.mkv" mp4 gif m4a
        convert_all "$IN/av1.webm" mp4 mov
        convert_all "$IN/av1.mp4" mov gif
    else
        skip "AV1 video" "needs a full ffmpeg with libsvtav1 to make the test clip"
    fi
else
    skip "video" "no ffmpeg to make the test clip (swift test covers native video)"
fi

echo "Audio"
if [[ -s "$IN/voice.aiff" ]]; then
    convert_all "$IN/voice.aiff" m4a wav flac alac caf m4r
    cp "$OUT/voice.m4a" "$WORK/song.mp4" 2>/dev/null
    check "MP4 with only sound is offered audio formats only" offers yes "$WORK/song.mp4" M4A WAV
    check "… and no video formats or Mute" offers no "$WORK/song.mp4" MOV GIF MKV Mute
    if has_ffmpeg; then
        convert_all "$IN/voice.aiff" mp3 ogg opus wma
        for input in voice.ogg voice.opus voice.wma voice.mp3; do
            [[ -s "$OUT/$input" ]] && convert_all "$OUT/$input" m4a
        done
    else
        skip "aiff → mp3, ogg, opus, wma" "brew install ffmpeg"
    fi
else
    skip "audio" "the say command couldn't record a sample"
fi

echo "PDF"
convert_all "$IN/notes.pdf" png jpg txt md docx
check "PDF without text → txt says so" fails_with "No text found" convert "$IN/photo.pdf" --to txt
check "merge PDFs" produces tool mergePDF "$IN/notes.pdf" "$IN/photo.pdf"
check "split PDF" produces tool splitPDF "$IN/notes merged.pdf"
check "compress PDF" produces tool compress "$IN/notes merged.pdf"

echo "Documents"
convert_all "$IN/notes.md" docx rtf html txt pdf epub odt
convert_all "$IN/notes.docx" md pdf

echo "System"
if spctl --assess --type execute "$APP" 2>/dev/null; then
    echo "  · Gatekeeper: accepted, so it opens on any Mac"
else
    echo "  · Gatekeeper: not notarized, so other Macs need System Settings → Privacy & Security → Open Anyway"
fi
echo "  · Open at login: $("$APP_BIN" --login-item status 2>/dev/null)"

echo
echo "$passed passed, $failed failed, $skipped skipped"
[[ $failed -eq 0 ]]
