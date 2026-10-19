import Foundation

/// Broad groups used to pick wheel contents and tools.
public enum FormatCategory: String, CaseIterable, Sendable, Codable {
    case image, video, audio, pdf, document

    public var title: String {
        switch self {
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .document: "Documents"
        }
    }
}

/// Every format the app can read or write. Some cases are output-only (`alac`) or input-only
/// (`svg`, `jxl`, `raw`); see `TargetCatalog` for what each category converts to.
public enum FileFormat: String, CaseIterable, Sendable, Codable {
    // Images
    case jpg, png, heic, webp, avif, tiff, bmp, gif, svg, ico, icns, psd, tga, jp2, jxl, exr, raw
    // PDF
    case pdf
    // Audio
    case mp3, m4a, alac, m4r, aac, wav, aiff, flac, caf, amr, ogg, opus, wma
    // Video
    case mp4, mov, m4v, threeGP = "3gp", mkv, webm, avi, wmv, flv, mpg, mts
    // Documents
    case docx, doc, rtf, rtfd, odt, html, txt, md, webarchive, epub

    public var category: FormatCategory {
        switch self {
        case .jpg, .png, .heic, .webp, .avif, .tiff, .bmp, .gif, .svg, .ico, .icns, .psd, .tga, .jp2,
             .jxl, .exr, .raw:
            .image
        case .pdf:
            .pdf
        case .mp3, .m4a, .alac, .m4r, .aac, .wav, .aiff, .flac, .caf, .amr, .ogg, .opus, .wma:
            .audio
        case .mp4, .mov, .m4v, .threeGP, .mkv, .webm, .avi, .wmv, .flv, .mpg, .mts:
            .video
        case .docx, .doc, .rtf, .rtfd, .odt, .html, .txt, .md, .webarchive, .epub:
            .document
        }
    }

    /// Label shown on wheel petals and in menus.
    public var displayName: String {
        switch self {
        case .webp: "WebP"
        case .webm: "WebM"
        case .opus: "Opus"
        case .md: "Markdown"
        case .threeGP: "3GP"
        case .webarchive: "Web Archive"
        default: rawValue.uppercased()
        }
    }

    /// Short label for the wheel, where space is tight.
    public var shortName: String {
        switch self {
        case .md: "MD"
        case .webarchive: "WEBARCH"
        default: displayName
        }
    }

    /// Extension used when writing a file of this format.
    public var fileExtension: String {
        switch self {
        case .alac: "m4a"
        case .raw: "dng"
        default: rawValue
        }
    }

    private static let aliases: [String: FileFormat] = [
        "jpeg": .jpg, "jpe": .jpg, "jfif": .jpg,
        "tif": .tiff, "heif": .heic, "heics": .heic, "hif": .heic,
        "j2k": .jp2, "jpf": .jp2, "jpx": .jp2,
        "dng": .raw, "cr2": .raw, "cr3": .raw, "crw": .raw, "nef": .raw, "nrw": .raw, "arw": .raw,
        "srf": .raw, "sr2": .raw, "raf": .raw, "orf": .raw, "rw2": .raw, "pef": .raw, "srw": .raw,
        "3fr": .raw, "iiq": .raw, "erf": .raw, "mrw": .raw, "x3f": .raw, "rwl": .raw,
        "aif": .aiff, "aifc": .aiff, "oga": .ogg,
        "qt": .mov, "3gpp": .threeGP, "mpeg": .mpg, "m2ts": .mts,
        "htm": .html, "xhtml": .html,
        "markdown": .md, "mdown": .md, "mkd": .md, "text": .txt,
    ]

    /// Detects a format from a file URL. Folders and unknown extensions return nil.
    public static func detect(_ url: URL) -> FileFormat? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        guard let format = aliases[ext] ?? FileFormat(rawValue: ext), format != .alac else { return nil }
        // RTFD documents are bundles; everything else must be a regular file.
        if format != .rtfd {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return nil
            }
        }
        return format
    }

    /// File name without its extension.
    public static func baseName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
