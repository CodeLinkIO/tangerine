# Tangerine (clone): offline file converter and image editor for macOS

A native macOS menu-bar app inspired by [tangerineformac.com](https://tangerineformac.com/).

- Drag any file and tap **⇧** to open the **Convert** wheel, or **⌘** for the **Edit** wheel.
- Drop the file on a petal. The result is saved next to the original.
- Everything runs locally; nothing is uploaded.

See [FEATURES.md](FEATURES.md) for the full spec and roadmap.

The UI follows the tangerineformac.com look. Every screen uses the components in
`Sources/TangerineApp/Theme.swift`:
- off-white page with white rounded cards
- orange format chips and pill segmented controls
- keycap legends

Light and dark mode are both supported.

## What's in v1

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
  The CLI also exposes the engine tools that the simplified UI hides: removeBackground, autoEnhance, grayscale,
  stripMetadata, copyText, trimTransparent, makeSquare, makeIcon.

## Build and run

Requirements: Xcode 15 or later, macOS 13 or later on Apple silicon.

```bash
brew install ffmpeg webp        # optional: MP3/OGG/MKV/WebM/AVI/WMV and WebP output
scripts/build-app.sh            # → build/Tangerine.app (release, ad-hoc signed)
open build/Tangerine.app
cp -R build/Tangerine.app /Applications/   # needed for Finder Services
```

Tests: `swift test` (images, media, documents and engine routing). Engines that need ffmpeg or libwebp skip
their tests when the tool isn't installed.

Debug builds accept `TANGERINE_DEMO=wheel|tools|converter|settings|welcome|editor|hud`, `TANGERINE_DEMO_FILE=<a:b>` and
`TANGERINE_DEMO_DARK=1`.
These open UI without any input events, for screenshots.

## Architecture

```
TangerineCore       formats, options, backend protocols, output naming, Shell, FFmpeg, OCR
TangerineImage      ImageIO/Core Image engine, quick edits, EditRecipe pipeline, PNG quantizer, WebP
TangerineMedia      AVFoundation + afconvert + ffmpeg engines (video/audio), compress/mute
TangerineDocuments  PDFKit rasterizing/extraction, Markdown, AppKit text formats, EPUB, PDF tools
TangerineKit        Engine: routes (from → to) and tools to backends, batches, folders, progress, reports
TangerineApp        menu-bar app: Theme (design system), drag monitor, wheel, HUD, converter, editor, settings, onboarding
TangerineCLI        `tangerine` command-line tool
```

The wheel detects drags without Accessibility permission. A mouse-down starts a short timer that watches the
system drag pasteboard and the global modifier state; the wheel itself is a non-activating panel that accepts
the drop.

## Before shipping

- **Rename and rebrand.** "Tangerine" is another company's product name.
- **Bundle engines.** Ship libwebp's `cwebp`/`gif2webp` (BSD) and an **LGPL** build of ffmpeg (no `--enable-gpl`) in
  `Contents/Resources`. The app looks there first. Homebrew's ffmpeg links Homebrew dylibs and isn't redistributable as is.
- **Sign and notarize** with a Developer ID. For the Mac App Store you'd also need sandboxing work: security-scoped
  output folders, and helper tools signed inside the bundle.
