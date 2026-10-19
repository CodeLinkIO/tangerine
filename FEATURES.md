# Tangerine-style Converter for macOS: Feature Spec

Goal: convert any common file into the format you need, and make quick image edits, without
leaving Finder or uploading anything. Everything runs locally on the Mac.

Focus: **(1) a broad, reliable file converter** and **(2) image editing**. Anything else is secondary.

Legend: **P0** first build · **P1** next · **P2** later · `*` needs the ffmpeg engine (see §7)

## Decisions (2026-10-19, revised)
- **UI:** every screen uses the tangerineformac.com style:
  - soft off-white page, white rounded cards, orange chips, rounded labels
  - presets instead of sliders; no stock form look
- **Editor:** reduced to crop, rotate, flip and resize, plus save as a format at Small/Balanced/Best quality.
  Adjustments, filters, background removal and straighten were removed from the UI.
  - The ⌘ wheel keeps only simple edits: Edit…, Compress, Resize 50%, Fit 1080, Rotate, Flip, and Merge PDF for
    multiple files.
  - The other engine tools stay available in the CLI.
- **Converter:** one Quality choice (Small/Balanced/Best) replaces the per-format options.
  The advanced per-format options keep their defaults.

## Decisions (2026-10-19, initial)
- Image editing: **quick edits (⌘ wheel) + editor window**
- v1 categories: **images, video, audio, PDF & documents**; data, subtitles and archives are deferred
- **ffmpeg** used for formats macOS cannot encode natively
- Interaction: **drag wheel + Converter window**
- The wheel shows up to ~9 favorite targets per type plus **More…**, which opens the Converter window
  listing every supported target

---

## 1. Ways to start a conversion

| # | Entry point | How it works | Priority |
|---|---|---|---|
| 1 | **Drag wheel** | Drag file(s) anywhere, tap ⇧ for the **Convert** wheel or ⌘ for the **Edit** wheel, then drop on a petal. The wheel stays open until you drop. | P0 |
| 2 | **Converter window** | Drop zone and batch queue. Each row shows its target format, options, progress, and result. Best for large batches and fine-tuning. | P0 |
| 3 | **Menu-bar drop** | Drop files on the menu-bar icon to open the wheel there. | P0 |
| 4 | **Finder right-click** | Services or Quick Action menu: "Convert with Tangerine" and "Edit Image". | P1 |
| 5 | **Global shortcut** | ⌃⌥T opens the wheel for the current Finder selection, driven by the keyboard (arrows, Enter, Esc). | P1 |
| 6 | **CLI** | `tangerine convert photo.heic --to jpg --quality 80`, useful for scripting and tests. | P0 |

## 2. Conversion matrix

### Images (P0)
- **Inputs:** JPG, PNG, HEIC/HEIF, WebP, AVIF, TIFF, BMP, GIF (incl. animated), SVG, ICO, ICNS, PSD,
  TGA, JPEG 2000, JPEG XL, EXR, and camera RAW (DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2, …)
- **Outputs:** JPG, PNG, HEIC, WebP\*, AVIF, TIFF, BMP, GIF, PDF, ICO, ICNS, JP2, TGA
- **Extras:** many images → one PDF; image → **TXT via OCR** (Vision); animated GIF ↔ WebP\* / MP4

### Video (P0)
- **Inputs:** MP4, MOV, M4V, 3GP, plus MKV\*, WebM\*, AVI\*, WMV\*, FLV\*, MPEG\*, TS\*
- **Outputs:** MP4, MOV, M4V, MKV\*, WebM\*, AVI\*, WMV\*, **GIF**
- **Audio extraction:** MP3\*, M4A, WAV, AIFF, FLAC

### Audio (P0)
- **Inputs:** MP3, M4A/AAC, ALAC, WAV, AIFF, FLAC, CAF, AMR, plus OGG\*, Opus\*, WMA\*
- **Outputs:** MP3\*, M4A (AAC), ALAC, WAV, AIFF, FLAC, CAF, **M4R (iPhone ringtone)**, OGG\*, Opus\*, WMA\*

### PDF (v1)
- PDF → PNG / JPG / TIFF / HEIC (every page, 300 DPI), TXT, MD, DOCX, RTF, HTML
- **OCR fallback** for scanned PDFs
- Images → PDF

### Documents (v1)
- **Inputs:** DOCX, DOC, RTF, RTFD, ODT, HTML, TXT, Markdown, WebArchive
- **Outputs:** DOCX, RTF, ODT, HTML, TXT, Markdown, PDF, EPUB

### Data, subtitles, archives (deferred, not in v1)
- CSV ↔ TSV ↔ XLSX ↔ JSON, plus HTML or PDF table export
- SRT ↔ VTT, or → TXT
- ZIP / TAR / TAR.GZ ↔ each other; RAR and 7Z input; extract

**Not planned:** Pages, Keynote, and Numbers (proprietary formats); PPTX rendering; layout-faithful
PDF → DOCX (extraction is text and basic styling only).

## 3. Conversion options and behavior (P0)

- **Image presets:** quality (High / Balanced / Small, plus a slider), max size (Original / 4K / 1080p /
  custom), keep or strip metadata, convert to sRGB, and a background color when flattening
  transparency to JPG.
- **Video presets:** resolution (Original / 1080p / 720p / 480p), codec (H.264 / HEVC), quality.
  GIF settings: fps and width.
- **Audio presets:** bitrate or VBR quality, sample rate.
- **Defaults:** set in Settings and overridable per job in the Converter window.
- **Batch:** multi-file drops offer the formats every file supports. Mixed selections are grouped by type.
  Dropping a folder converts every supported file inside it.
- **Output:** saved next to the original by default, or to a fixed folder. Naming is `name.ext`, and
  conflicts become `name 2.ext`. An optional "Replace original" moves the source to the Trash.
- **Feedback:** a HUD shows progress, can be cancelled, reports the size change (e.g. "−63%"), and
  offers **Show in Finder**. A Recents list sits in the menu.

## 4. Image editing

### 4a. Quick edits, one shot from the ⌘ wheel, batch-capable (P0)
- Rotate left or right; flip horizontally or vertically
- Resize: 50%, long edge 2048 / 1080, or a custom preset
- **Compress (smart):** keeps the format, lowers the quality, and reports the saving
- **Remove background** (Vision, on-device, macOS 14+)
- Auto-enhance; grayscale
- Strip metadata and GPS location
- Trim transparent edges; make square by padding
- Copy text (OCR → clipboard)
- Make an app icon set (ICNS / ICO)
- **Edit…** opens the editor (4b)

### 4b. Editor window (P0 core, P1 extras)
- **Canvas:** zoom and pan; hold Space to compare before and after
- **Crop:** drag handles; aspect presets (Free, Original, 1:1, 4:5, 3:2, 4:3, 16:9, 9:16);
  straighten slider; rotate or flip
- **Resize:** width × height in px or %, aspect lock
- **Adjust:** exposure, brightness, contrast, highlights, shadows, saturation, vibrance, temperature,
  tint, sharpness, vignette; one-click Auto
- **Filters:** Mono, Noir, Chrome, Fade, Instant, Process, Tonal, Transfer, Sepia
- **Remove background:** toggle, then fill with transparent or a color
- **Export:** any image output format, quality slider, **live file-size estimate**, metadata on or off,
  Save as Copy or Overwrite
- **History:** undo, redo, reset. Edits are non-destructive (Core Image) and rendered at full
  resolution on export.
- **P1:** redact a region (blur or pixelate)
- **P2:** annotate (text, arrows, boxes); watermark (text or logo); apply the same edit recipe to
  other images

## 5. App shell (P0)
- Menu-bar app with no Dock icon. Menu: Converter window, Recents, Settings, Quit.
- **Settings:**
  - wheel keys
  - output location and naming
  - default presets
  - which formats appear on the wheel, and in what order
  - engine status (ffmpeg found or missing)
  - launch at login
- **Onboarding:** a "drag this sample file" tutorial.

## 6. Out of scope for now
File actions (AirDrop, Float, Copy, Move, Terminal), cloud features, App Store sandboxing,
and a paid conversion allowance.

## 7. Engines
- **Native first:**
  - ImageIO and Core Image: images and editing
  - Vision: OCR and background removal
  - AVFoundation and `afconvert`: video and audio
  - PDFKit: PDF
  - AppKit text system: documents
- **ffmpeg** covers what macOS can't encode: WebP, MP3, OGG, Opus, WMA, MKV, WebM, AVI, WMV, and
  better GIFs. Development uses Homebrew's copy. A release build must bundle an LGPL-compliant
  ffmpeg.

## 8. Build phases
1. **Core engine and CLI:** images, video, audio, quick image edits, tests
2. **Mac app:** drag wheel, menu-bar drop, HUD, Settings, Converter window
3. **Image editor window**
4. Finder right-click and global shortcut
5. Packaging (bundled ffmpeg, signing, notarization); later, data, subtitles and archives

PDF and documents are built in phase 1, alongside images, video and audio.

## Status (2026-10-19)
- ✅ Phase 1: core engine and CLI. Images, video, audio, PDF and documents; quick image edits; 88 tests passing
- ✅ Phase 2: Mac app. Drag wheel, menu-bar drop, HUD, Converter window, Settings, onboarding
- ✅ Phase 3: image editor window
- ✅ Phase 4: Finder Services and ⌃⌥T shortcut
- ⏳ Not yet done: region redact, annotate, watermark, batch edit recipes, editor zoom at full resolution, bundled
  ffmpeg/libwebp, Developer ID signing and notarization. Data, subtitles and archives are deferred.
- ⚠️ The drag-and-tap gesture itself still needs a manual test on a real desktop; automated runs can't send input events.
