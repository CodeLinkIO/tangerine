#!/bin/bash
# Builds the conversion engines that ship inside Tangerine.app, so the app needs nothing from Homebrew:
#   ffmpeg   a light LGPL build (no GPL or non-free parts) with only the codecs, containers and filters that
#            Tangerine uses: Apple's VideoToolbox/AudioToolbox encoders, LAME (MP3), Vorbis, Opus and VP9, and
#            dav1d to read AV1 video (Macs before M3 have no AV1 hardware decoder)
#   cwebp, gif2webp   from libwebp, with libpng and giflib
# Everything is linked statically for arm64 and runs on macOS 13 or later; only system libraries stay dynamic.
# ffmpeg has no network code: Tangerine is offline.
# Output: build/engines/bin and build/engines/licenses. Re-running is a no-op until the versions change.
#   scripts/build-engines.sh            # first run downloads ~35 MB of source and builds for ~5–10 min
#   FORCE=1 scripts/build-engines.sh    # rebuild from scratch
# Needs Xcode's command-line tools and pkg-config (brew install pkgconf). Meson and Ninja, which dav1d builds
# with, are fetched from PyPI (pinned, hash-checked) into build/engines/tools, so nothing else gets installed.
set -euo pipefail
cd "$(dirname "$0")/.."

# name  version  url  sha256: the same sources and checksums as Homebrew's formulas.
SOURCES=(
    "libpng   1.6.59 https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.xz d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389"
    "giflib   6.1.3  https://downloads.sourceforge.net/project/giflib/giflib-6.x/giflib-6.1.3.tar.gz b65b66b99f0424b93525f987386f22fc5efb9da2bfc92ad4a532249aaffbab0e"
    "libwebp  1.6.0  https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
    "lame     4.0    https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz 3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"
    "libogg   1.3.6  https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-1.3.6.tar.gz 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638"
    "libvorbis 1.3.7 https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.xz b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b"
    "opus     1.6.1  https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
    "libvpx   1.17.0 https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz 1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a"
    "dav1d    1.5.4  https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2 2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011"
    "ffmpeg   9.0.2  https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
)

# Build tools for dav1d. Meson 1.11 is the newest that runs on the Python 3.9 in Xcode's command-line tools.
BUILD_TOOLS=(
    "meson==1.11.2 --hash=sha256:7e4f6e83fec83e3eaac928e058b073c7557b282c35b6a2024cea143a39926a39"
    "ninja==1.13.2 --hash=sha256:fd82e26c0706ad4ab88e5fdd26f3fab0a987a90f810160f6c322e752c6af298b"
)

ROOT="$PWD/build/engines"
SRC="$ROOT/src" PREFIX="$ROOT/prefix" BIN="$ROOT/bin" LICENSES="$ROOT/licenses"
STAMP="$ROOT/versions"
TOOLS=(ffmpeg cwebp gif2webp)

up_to_date() {
    [[ -f "$STAMP" && "$(cat "$STAMP")" == "$(printf '%s\n' "${SOURCES[@]}" "${BUILD_TOOLS[@]}")" ]] || return 1
    for tool in "${TOOLS[@]}"; do [[ -x "$BIN/$tool" ]] || return 1; done
}
if [[ "${FORCE:-0}" != 1 ]] && up_to_date; then
    echo "Engines up to date in $BIN"
    exit 0
fi

PKG_CONFIG="$(command -v pkg-config || true)"
[[ -n "$PKG_CONFIG" ]] || { echo "error: pkg-config is needed to build the engines: brew install pkgconf" >&2; exit 1; }

rm -rf "$ROOT"
mkdir -p "$SRC" "$PREFIX/bin" "$BIN" "$LICENSES" "$ROOT/tools"

# A clean toolchain: Apple's compiler and only the libraries built here. Homebrew stays off PATH so no
# configure script can find (and link) a Homebrew library; pkg-config only sees $PREFIX.
ln -s "$PKG_CONFIG" "$ROOT/tools/pkg-config"
export PATH="$PREFIX/bin:$ROOT/tools:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH
export MACOSX_DEPLOYMENT_TARGET=13.0
export CC=clang CXX=clang++
export CFLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -L$PREFIX/lib"
JOBS="$(sysctl -n hw.ncpu)"
LOG="$ROOT/build.log"
: >"$LOG"

# Downloads one source tarball, checks its SHA-256 and unpacks it into $SRC/<name>.
fetch() {
    local name="$1" version="$2" url="$3" sha="$4"
    local file="$SRC/${url##*/}"
    curl -fsSL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c --quiet - || { echo "error: checksum mismatch for $name $version" >&2; exit 1; }
    mkdir "$SRC/$name"
    tar -xf "$file" -C "$SRC/$name" --strip-components 1
}

# Runs a build step quietly; on failure shows the end of the log.
step() {
    local label="$1"; shift
    echo "  $label"
    if ! "$@" >>"$LOG" 2>&1; then
        echo "error: $label failed; last lines of $LOG:" >&2
        tail -30 "$LOG" >&2
        exit 1
    fi
}

autotools() {
    (cd "$SRC/$1" && shift && ./configure --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-dependency-tracking "$@" && make -j"$JOBS" && make install)
}

echo "Downloading sources"
for entry in "${SOURCES[@]}"; do
    # shellcheck disable=SC2086
    fetch $entry
done

echo "Installing Meson and Ninja into $ROOT/tools"
printf '%s\n' "${BUILD_TOOLS[@]}" >"$ROOT/tools/requirements.txt"
step "python environment" /usr/bin/python3 -m venv "$ROOT/tools/python"
step "meson, ninja" "$ROOT/tools/python/bin/python3" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --only-binary :all: --no-deps -r "$ROOT/tools/requirements.txt"
ln -s "$ROOT/tools/python/bin/meson" "$ROOT/tools/python/bin/ninja" "$ROOT/tools/"

echo "Building into $PREFIX"
step "libpng" autotools libpng
step "giflib" bash -c "cd '$SRC/giflib' && make -j$JOBS libgif.a CC=clang CFLAGS='$CFLAGS -std=gnu99 -fPIC -Wall' &&
    install -m 644 gif_lib.h '$PREFIX/include/' && install -m 644 libgif.a '$PREFIX/lib/'"
# LIBS=-lz: the static libpng needs zlib, or libwebp's link test fails and cwebp silently loses PNG input.
step "libwebp" autotools libwebp --enable-png --enable-gif --disable-jpeg --disable-tiff --disable-sdl --disable-gl \
    --disable-wic --enable-libwebpmux --enable-libwebpdemux LIBS=-lz
step "lame" autotools lame --disable-frontend --disable-decoder
step "libogg" autotools libogg
# libvorbis's configure adds -force_cpusubtype_ALL on macOS, which today's linker rejects.
sed -i '' 's/ -force_cpusubtype_ALL//g' "$SRC/libvorbis/configure"
step "libvorbis" autotools libvorbis --disable-docs --disable-examples
step "opus" autotools opus --disable-doc --disable-extra-programs
step "dav1d" bash -c "cd '$SRC/dav1d' && meson setup build --prefix='$PREFIX' --libdir=lib --buildtype=release \
    --default-library=static -Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_docs=false &&
    ninja -C build install"
step "libvpx" bash -c "cd '$SRC/libvpx' && ./configure --prefix='$PREFIX' --target=arm64-darwin22-gcc \
    --disable-shared --enable-static --enable-pic --disable-vp8 --enable-vp9 --disable-vp9-decoder \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --extra-cflags='-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET' && make -j$JOBS && make install"

# ffmpeg starts from --disable-everything and gets back only what FFmpegMediaBackend, MediaToolBackend and the
# GIF → MP4 route use. Inputs: every video and audio format Tangerine lists, with the codecs usually found in
# them. Outputs: MP4/MOV/M4V/MKV/WebM/AVI/WMV/GIF video and MP3/M4A/ALAC/WAV/AIFF/CAF/FLAC/OGG/Opus/WMA audio.
# When adding a format to MediaFormats, add its pieces here.
join() { local IFS=,; echo "$*"; }
DEMUXERS=(mov matroska avi asf flv mpegps mpegts mpegvideo mp3 aac ac3 eac3 dts truehd wav w64 aiff flac ogg caf amr gif)
DECODERS=(
    h264 hevc libdav1d mpeg4 msmpeg4v1 msmpeg4v2 msmpeg4v3 wmv1 wmv2 wmv3 vc1 mpeg1video mpeg2video h263 h263p flv
    vp6 vp6a vp6f vp8 vp9 theora mjpeg prores dvvideo svq3 cinepak msvideo1 msrle rawvideo gif png
    aac aac_latm mp1 mp1float mp2 mp2float mp3 mp3float ac3 eac3 dca truehd mlp flac alac vorbis opus
    wmav1 wmav2 wmapro wmalossless wmavoice amrnb amrwb gsm_ms qdm2 "pcm_*" "adpcm_*"
)
ENCODERS=(
    h264_videotoolbox hevc_videotoolbox libvpx_vp9 mpeg4 wmv2 gif
    aac_at alac_at aac alac libmp3lame libvorbis libopus wmav2 flac pcm_s16le pcm_s16be
)
MUXERS=(mp4 mov ipod matroska webm avi asf gif mp3 wav aiff caf flac ogg opus)
FILTERS=(
    scale setsar fps split palettegen paletteuse tpad format null trim crop hflip vflip transpose
    aformat aresample anull atrim
)
# LGPL 2.1+: no --enable-gpl, --enable-version3 or --enable-nonfree. Autodetection is off so only what's
# listed gets linked.
FFMPEG_CONFIG=(
    --prefix="$PREFIX" --cc=clang --arch=arm64 --target-os=darwin
    --enable-static --disable-shared --pkg-config-flags=--static
    --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -I$PREFIX/include"
    --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -L$PREFIX/lib"
    --disable-autodetect --disable-everything --disable-network --disable-avdevice
    --disable-ffplay --disable-ffprobe --disable-doc --disable-debug
    --enable-videotoolbox --enable-audiotoolbox --enable-zlib
    --enable-libmp3lame --enable-libvorbis --enable-libopus --enable-libvpx --enable-libdav1d
    --enable-protocol=file,pipe --enable-parsers --enable-bsfs
    --enable-demuxer="$(join "${DEMUXERS[@]}")" --enable-decoder="$(join "${DECODERS[@]}")"
    --enable-encoder="$(join "${ENCODERS[@]}")" --enable-muxer="$(join "${MUXERS[@]}")"
    --enable-filter="$(join "${FILTERS[@]}")"
)
step "ffmpeg (the longest step)" bash -c "cd '$SRC/ffmpeg' && ./configure $(printf '%q ' "${FFMPEG_CONFIG[@]}") &&
    make -j$JOBS && make install"
if grep "did not match anything" "$LOG" >&2; then echo "error: unknown ffmpeg component names (above)" >&2; exit 1; fi
grep -q 'FFMPEG_LICENSE "LGPL version 2.1 or later"' "$SRC/ffmpeg/config.h" ||
    { echo "error: ffmpeg isn't an LGPL 2.1 build" >&2; exit 1; }

for tool in "${TOOLS[@]}"; do
    install -m 755 "$PREFIX/bin/$tool" "$BIN/$tool"
    strip -x "$BIN/$tool"
    codesign --force --sign - "$BIN/$tool" 2>/dev/null   # strip invalidates the linker's signature
    # Only macOS's own libraries may stay dynamic, or the app breaks on a Mac without Homebrew.
    if otool -L "$BIN/$tool" | tail -n +2 | grep -v -e $'^\t/usr/lib/' -e $'^\t/System/Library/'; then
        echo "error: $tool links a library that isn't part of macOS (above)" >&2; exit 1
    fi
    minos="$(otool -l "$BIN/$tool" | awk '/LC_BUILD_VERSION/ {b=1} b && /minos/ {print $2; exit}')"
    [[ "$minos" == "$MACOSX_DEPLOYMENT_TARGET" ]] || { echo "error: $tool needs macOS $minos" >&2; exit 1; }
done

# Each tool must actually work: a 1×1 PNG through cwebp, a 1×1 GIF through gif2webp.
CHECK="$ROOT/check"
mkdir "$CHECK"
base64 -D -o "$CHECK/dot.png" <<<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
base64 -D -o "$CHECK/dot.gif" <<<"R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="
"$BIN/cwebp" -quiet "$CHECK/dot.png" -o "$CHECK/png.webp" || { echo "error: cwebp can't read PNG" >&2; exit 1; }
"$BIN/gif2webp" -quiet "$CHECK/dot.gif" -o "$CHECK/gif.webp" || { echo "error: gif2webp can't read GIF" >&2; exit 1; }
"$BIN/ffmpeg" -hide_banner -version >/dev/null || { echo "error: ffmpeg doesn't start" >&2; exit 1; }
rm -rf "$CHECK"

# Licenses and where the source came from; build-app.sh copies these to Contents/Resources/Licenses.
license() { cp "$SRC/$1/$2" "$LICENSES/$1-$(basename "$2").txt"; }
license ffmpeg COPYING.LGPLv2.1
license lame COPYING
license libogg COPYING
license libvorbis COPYING
license opus COPYING
license libvpx LICENSE
license libvpx PATENTS
license dav1d COPYING
license libwebp COPYING
license libwebp PATENTS
license giflib COPYING
license libpng LICENSE
{
    echo "Tangerine bundles these open-source programs in Contents/Helpers:"
    echo "  ffmpeg (LGPL 2.1 or later), built with LAME (LGPL), libvorbis and libogg (BSD), Opus (BSD), libvpx (BSD)"
    echo "    and dav1d (BSD)"
    echo "  cwebp and gif2webp from libwebp (BSD), built with libpng (libpng license) and giflib (MIT)"
    echo
    echo "They are upstream releases with unmodified source code, built by scripts/build-engines.sh in Tangerine's"
    echo "repository (the only change is removing an obsolete linker flag from libvorbis's configure script)."
    echo "Source code:"
    for entry in "${SOURCES[@]}"; do
        # shellcheck disable=SC2086
        set -- $entry
        printf '  %-10s %-7s %s\n    sha256 %s\n' "$1" "$2" "$3" "$4"
    done
    echo
    echo "ffmpeg configuration:"
    "$BIN/ffmpeg" -hide_banner -buildconf | sed 's/^/  /'
} >"$LICENSES/README.txt"

printf '%s\n' "${SOURCES[@]}" "${BUILD_TOOLS[@]}" >"$STAMP"
rm -rf "$SRC" "$PREFIX"
echo "Built $(cd "$BIN" && echo *) in $BIN ($(du -sh "$BIN" | cut -f1))"
