# Tangerine (clone): offline file converter and image editor for macOS

A native macOS menu-bar app inspired by [tangerineformac.com](https://tangerineformac.com/).

- Drag any file and tap **⇧** to open the **Convert** wheel, or **⌘** for the **Edit** wheel.
- Drop the file on a petal. The result is saved next to the original.
- Everything runs locally; nothing is uploaded.

## Install

**[⬇ Download Tangerine.dmg](https://github.com/CodeLinkIO/tangerine/raw/main/Tangerine.dmg)**: it's the
`Tangerine.dmg` at the top of this repo (about 1.5 MB). You need a Mac with Apple silicon (M1 or later) and
macOS 13 Ventura or later.

1. Open `Tangerine.dmg` and drag **Tangerine** onto **Applications**.
2. Open Tangerine from Applications. The app isn't notarized by Apple yet, so the first time macOS says it
   can't verify it. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down to *"Tangerine" was blocked…*, click
   **Open Anyway**, and confirm with your password. On macOS 13 and 14, right-click the app → **Open** also works.
   This is only needed once. If you prefer Terminal: `xattr -dr com.apple.quarantine /Applications/Tangerine.app`.
4. The welcome window shows a sample file to try the wheel on. *Open at login* is on by default; macOS confirms
   it with a "Login Item Added" notice. Tangerine lives in the menu bar, not the Dock.

**More formats (optional).** MP3, OGG, Opus, WMA, MKV, WebM, AVI, WMV, FLV, MPG, MTS, GIF → MP4 and WebP output
need [Homebrew](https://brew.sh)'s ffmpeg and libwebp. Install them, then quit and reopen Tangerine:

```bash
brew install ffmpeg webp
```

Everything else works without them.

**Permissions.** The first time you press ⌃⌥T, macOS asks whether Tangerine may control Finder (to read the
selected files). Nothing else needs a permission.

**Uninstall.** Turn off *Open at login* in Tangerine → Settings, quit it from the menu-bar icon, and move
`/Applications/Tangerine.app` to the Trash.

## What it converts

| Area | Highlights |
|---|---|
| **Images** | **Inputs:** JPG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, SVG, ICO, ICNS, PSD, TGA, JPEG 2000, JPEG XL, EXR, camera RAW.<br>**Outputs:** JPG, PNG, HEIC, WebP, AVIF, TIFF, GIF, PDF, BMP, ICO, ICNS, JP2, TGA, plus **TXT via OCR**.<br>Animated GIF → WebP or MP4. |
| **Quick edits** (⌘ wheel) | Edit…, Compress (pngquant-style palette PNG, re-encoded JPG/HEIC), Resize 50%, Fit 1080, Rotate (lossless for JPEG/HEIC/TIFF), Flip, Merge into PDF |
| **Editor window** | Kept simple: crop (Free, Original, Square, 4:3, 3:2, 16:9), rotate, flip, resize (25/50/75%, 1080/2048 px, custom), then save as JPG/PNG/HEIC/WebP… with Small/Balanced/Best quality and a live size estimate. Undo/redo |
| **Video** | MP4, MOV, M4V, 3GP natively; MKV, WebM, AVI, WMV, FLV, MPG and MTS via ffmpeg. Outputs any of these plus GIF and audio extraction. Compress (HEVC), Mute |
| **Audio** | MP3, M4A/AAC, ALAC, WAV, AIFF, FLAC, CAF, M4R ringtone, OGG, Opus, WMA |
| **PDF** | → PNG/JPG/TIFF/HEIC (every page, 300 DPI); → TXT/MD/DOCX/RTF/HTML/EPUB with OCR for scans. Merge, split, compress |
| **Documents** | DOCX, DOC, RTF, RTFD, ODT, HTML, TXT, Markdown, Web Archive ↔ each other, plus → PDF and EPUB |

There are 560+ conversion options. Run `tangerine engines` to see the count on your Mac.

## Ways to convert

- **Drag wheel:** drag files anywhere, tap ⇧ (convert) or ⌘ (edit), drop on a petal. **More…** opens the Converter.
- **Converter window:** a batch queue with a target per file, options (quality, size, codec, bitrate, DPI), an output folder, and tools.
- **Menu-bar icon:** drop files on it, or use *Convert Files…* and *Edit Image…*.
- **Finder:** right-click → Services → *Convert with Tangerine* / *Edit Image with Tangerine*.
- **⌃⌥T:** opens the wheel for the current Finder selection. Pick a petal with the arrow keys and Return.
- **CLI:** `tangerine convert photo.heic --to jpg --quality 80`, `tangerine tool compress *.png`, `tangerine formats file.pdf`.
  The CLI is inside the app at `Tangerine.app/Contents/Helpers/tangerine`. It also exposes the engine tools that the
  simplified UI hides: removeBackground, autoEnhance, grayscale, stripMetadata, copyText, trimTransparent, makeSquare,
  makeIcon.

## Build from source

Requirements: Xcode 15 or later, macOS 13 or later on Apple silicon.

```bash
brew install ffmpeg webp          # optional: MP3/OGG/MKV/WebM/AVI/WMV and WebP output
scripts/install.sh --login        # build → /Applications/Tangerine.app, open it, turn on Open at Login
scripts/package.sh                # build → Tangerine.dmg, the download linked above
```

| Script | Does |
|---|---|
| `scripts/build-app.sh` | Release build of `build/Tangerine.app`: the app, the `tangerine` CLI in `Contents/Helpers`, the icon, and a signature. |
| `scripts/install.sh [--login]` | Builds, quits any running copy, replaces `/Applications/Tangerine.app` (only if it's this app), refreshes Launch Services and the Services menu, and opens it. |
| `scripts/package.sh` | Builds and wraps the app in a compressed disk image with an Applications shortcut: `build/Tangerine-<version>.dmg`, copied to `Tangerine.dmg` here. Commit that file to update the download. |
| `scripts/smoke-test.sh [app]` | Checks the signature and the disk image, then runs 60+ real conversions with the engine inside the app. |

**Open at login** uses `SMAppService`, so it appears in System Settings → General → Login Items.
- It can be turned on from the welcome screen (on by default), from Settings, or with `scripts/install.sh --login`.
- When the app is started from outside Applications (a disk image, Downloads), it offers to move itself there
  first, so the login item and Finder Services point at a stable copy.

**Signing.** By default the app is signed ad hoc, which is why other Macs need *Open Anyway* the first time. For a
disk image that opens anywhere without that step, sign with a Developer ID (Apple Developer Program) and
notarize. `notarytool store-credentials` is a one-time setup step.

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=tangerine scripts/package.sh
```

ffmpeg and cwebp are not inside the app (see *Before shipping*). On a Mac without them, the formats that
need them simply don't appear.

## Testing

```bash
swift test                               # 293 unit tests (~2 min), edge cases and security regressions included
swift test --filter TangerineImageTests  # one suite
scripts/package.sh && scripts/smoke-test.sh   # the built app and Tangerine.dmg, end to end (~15 s)
```

- **Unit tests** cover the image, media and document engines, routing and batches, the CLI, and the editor and
  Converter logic. Tests that need ffmpeg or libwebp skip themselves when those aren't installed.
- **The smoke test** makes its fixtures on the fly (a PNG, a Markdown note, a spoken AIFF, a short ffmpeg clip),
  prints ✓/✗ per conversion, and exits non-zero on a failure. It also reports Gatekeeper and Open at Login status.
- **By hand**, since automated runs can't send drag events: drag a file and tap ⇧, then ⌘; drop on a petal;
  try the Converter window, the editor, ⌃⌥T, Finder Services, dark mode, and log out and in to check Open at
  Login. For a first-run experience, run `defaults delete dev.tangerine.converter` before opening the app.

Debug builds open any screen directly, without input events, for screenshots:

```bash
swift build
TANGERINE_DEMO=wheel TANGERINE_DEMO_FILE=~/Pictures/photo.jpg .build/debug/TangerineApp
# TANGERINE_DEMO = wheel | tools | converter | settings | welcome | editor | hud,  TANGERINE_DEMO_DARK=1 for dark mode
```

## Architecture

```
TangerineCore       formats, options, backend protocols, output naming, Shell, FFmpeg, OCR
TangerineImage      ImageIO/Core Image engine, quick edits, EditRecipe pipeline, PNG quantizer, WebP
TangerineMedia      AVFoundation + afconvert + ffmpeg engines (video/audio), compress/mute
TangerineDocuments  PDFKit rasterizing/extraction, Markdown, AppKit text formats, EPUB, PDF tools, HTML sanitizer
TangerineKit        Engine: routes (from → to) and tools to backends, batches, folders, progress, reports
TangerineApp        menu-bar app: Theme (design system), drag monitor, wheel, HUD, converter, editor, settings, onboarding
TangerineCLI        `tangerine` command-line tool
```

The UI follows the tangerineformac.com look: an off-white page with white rounded cards, orange format chips,
pill segmented controls and keycap legends, in light and dark mode. Every screen uses the components in
`Sources/TangerineApp/Theme.swift`.

The wheel detects drags without Accessibility permission. A mouse-down starts a short timer that watches the
system drag pasteboard and the global modifier state; the wheel itself is a non-activating panel that accepts
the drop.

## Before shipping

- **Rename and rebrand.** "Tangerine" is another company's product name.
- **Bundle engines.** Ship libwebp's `cwebp`/`gif2webp` (BSD) and an **LGPL** build of ffmpeg (no `--enable-gpl`) in
  `Contents/Helpers`. The app looks there first. Homebrew's ffmpeg links Homebrew dylibs and isn't redistributable as is.
- **Sign and notarize** with a Developer ID. For the Mac App Store you'd also need sandboxing work: security-scoped
  output folders, and helper tools signed inside the bundle.
- **Not built yet:** region redact, annotate, watermark, batch edit recipes, full-resolution zoom in the editor, and
  data (CSV/XLSX/JSON), subtitle (SRT/VTT) and archive (ZIP/TAR) conversions.
