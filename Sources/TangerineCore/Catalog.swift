import Foundation

/// Preferred order of conversion targets per category. Engines decide what is actually possible;
/// this list decides how the options are ordered on the wheel and in menus.
public enum TargetCatalog {
    public static func orderedTargets(for category: FormatCategory) -> [FileFormat] {
        switch category {
        case .image:
            [.jpg, .png, .heic, .webp, .avif, .tiff, .gif, .pdf, .bmp, .ico, .icns, .jp2, .tga, .txt, .mp4]
        case .video:
            [.mp4, .mov, .gif, .mp3, .m4a, .webm, .mkv, .avi, .wmv, .m4v, .wav, .aiff, .flac]
        case .audio:
            [.mp3, .m4a, .wav, .flac, .aiff, .m4r, .ogg, .opus, .alac, .wma, .caf]
        case .pdf:
            [.png, .jpg, .docx, .txt, .md, .html, .rtf, .tiff, .heic, .epub]
        case .document:
            [.pdf, .docx, .md, .txt, .html, .rtf, .odt, .epub]
        }
    }

    /// How many targets fit on the wheel before the rest move behind "More…".
    public static let wheelCapacity = 8
}

/// One-shot tools shown on the ⌘ wheel.
public enum ToolID: String, CaseIterable, Sendable, Codable {
    case openEditor
    case compress
    case resizeHalf, resizeLong2048, resizeLong1080
    case rotateLeft, rotateRight, flipHorizontal, flipVertical
    case removeBackground, autoEnhance, grayscale
    case stripMetadata, trimTransparent, makeSquare
    case copyText, makeIcon
    case mute
    case mergePDF, splitPDF

    public var title: String {
        switch self {
        case .openEditor: "Edit…"
        case .compress: "Compress"
        case .resizeHalf: "Resize 50%"
        case .resizeLong2048: "Fit 2048"
        case .resizeLong1080: "Fit 1080"
        case .rotateLeft: "Rotate Left"
        case .rotateRight: "Rotate"
        case .flipHorizontal: "Flip"
        case .flipVertical: "Flip Vertical"
        case .removeBackground: "Remove BG"
        case .autoEnhance: "Enhance"
        case .grayscale: "Mono"
        case .stripMetadata: "Strip Info"
        case .trimTransparent: "Trim Edges"
        case .makeSquare: "Square"
        case .copyText: "Copy Text"
        case .makeIcon: "App Icon"
        case .mute: "Mute"
        case .mergePDF: "Merge PDF"
        case .splitPDF: "Split Pages"
        }
    }

    /// Longer description for menus and tooltips.
    public var detail: String {
        switch self {
        case .openEditor: "Open in the image editor"
        case .compress: "Make the file smaller"
        case .resizeHalf: "Scale to half the size"
        case .resizeLong2048: "Fit within 2048 px"
        case .resizeLong1080: "Fit within 1080 px"
        case .rotateLeft: "Rotate 90° counter-clockwise"
        case .rotateRight: "Rotate 90° clockwise"
        case .flipHorizontal: "Mirror horizontally"
        case .flipVertical: "Mirror vertically"
        case .removeBackground: "Cut out the subject (PNG)"
        case .autoEnhance: "Auto-fix exposure and color"
        case .grayscale: "Convert to black & white"
        case .stripMetadata: "Remove EXIF and GPS location"
        case .trimTransparent: "Crop away transparent edges"
        case .makeSquare: "Pad to a square canvas"
        case .copyText: "Recognize text and copy it"
        case .makeIcon: "Create an ICNS app icon"
        case .mute: "Remove the audio track"
        case .mergePDF: "Combine files into one PDF"
        case .splitPDF: "Save each page as a PDF"
        }
    }

    /// SF Symbol shown on the petal.
    public var symbol: String {
        switch self {
        case .openEditor: "slider.horizontal.3"
        case .compress: "rectangle.compress.vertical"
        case .resizeHalf: "arrow.down.right.and.arrow.up.left"
        case .resizeLong2048, .resizeLong1080: "aspectratio"
        case .rotateLeft: "rotate.left"
        case .rotateRight: "rotate.right"
        case .flipHorizontal: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .flipVertical: "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .removeBackground: "person.crop.rectangle"
        case .autoEnhance: "wand.and.stars"
        case .grayscale: "circle.lefthalf.filled"
        case .stripMetadata: "location.slash"
        case .trimTransparent: "crop"
        case .makeSquare: "square.dashed"
        case .copyText: "text.viewfinder"
        case .makeIcon: "app.dashed"
        case .mute: "speaker.slash"
        case .mergePDF: "doc.on.doc"
        case .splitPDF: "scissors"
        }
    }

    /// Tools that take every dropped file at once instead of running per file.
    public var combinesInputs: Bool { self == .mergePDF }

    /// Tools that produce text rather than files (the app puts it on the clipboard).
    public var producesText: Bool { self == .copyText }

    /// Tools handled by the app UI rather than an engine.
    public var isInteractive: Bool { self == .openEditor }

    /// Preferred order of tools per category on the ⌘ wheel.
    public static func orderedTools(for category: FormatCategory) -> [ToolID] {
        switch category {
        case .image:
            // Kept deliberately short: simple edits only. Other tools remain available from the CLI.
            [.openEditor, .compress, .resizeHalf, .resizeLong1080, .rotateRight, .rotateLeft, .flipHorizontal, .mergePDF]
        case .video: [.compress, .mute]
        case .audio: [.compress]
        case .pdf: [.compress, .splitPDF, .mergePDF]
        case .document: []
        }
    }
}
