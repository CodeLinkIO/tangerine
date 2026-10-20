import AppKit
import TangerineCore

/// A loaded document in whichever representation is cheapest to get from its source format.
/// Each accessor converts lazily to what a writer needs.
enum DocumentSource {
    case markdown(String, baseURL: URL?)
    case html(String, baseURL: URL?)
    case plainText(String)
    case rich(NSAttributedString)
    case pdf([PDFPageText])

    static let richTypes: [FileFormat: NSAttributedString.DocumentType] = [
        .docx: .officeOpenXML, .doc: .docFormat, .rtf: .rtf, .rtfd: .rtfd, .odt: .openDocument,
        .webarchive: .webArchive,
    ]

    static func load(_ url: URL, format: FileFormat, context: ConversionContext) async throws -> DocumentSource {
        let baseURL = url.deletingLastPathComponent()
        switch format {
        case .md:
            return .markdown(try readText(url), baseURL: baseURL)
        case .txt:
            return .plainText(try readText(url))
        case .html:
            return .html(try readText(url), baseURL: baseURL)
        case .pdf:
            return .pdf(try PDFTextExtractor.extract(url, progress: context.progress))
        case .webarchive:
            // Read through the sanitizer rather than WebKit's archive loader, which fetches anything not archived.
            return .rich(try await importHTML(try WebArchive.html(url), baseURL: nil))
        default:
            guard var type = richTypes[format] else { throw ConversionError.unsupported(from: format, to: "text") }
            // Many ".doc" files are really RTF (Word's and older exporters' "Rich Text" saves).
            if format == .doc, (try? Data(contentsOf: url, options: .alwaysMapped))?.starts(with: Array("{\\rtf".utf8)) == true {
                type = .rtf
            }
            return .rich(try readRich(url, type: type))
        }
    }

    // MARK: - Representations

    var attributedString: NSAttributedString {
        get async throws {
            switch self {
            case let .markdown(source, baseURL):
                let html = MarkdownRenderer.htmlDocument(title: "", body: MarkdownRenderer.body(markdown: source),
                                                         stylesheet: MarkdownRenderer.Stylesheet.base)
                return try await Self.importHTML(html, baseURL: baseURL)
            case let .html(source, baseURL):
                return try await Self.importHTML(source, baseURL: baseURL)
            case let .plainText(text):
                return Self.plain(text)
            case let .rich(text):
                return text
            case let .pdf(pages):
                let result = NSMutableAttributedString()
                for (index, page) in pages.enumerated() {
                    if index > 0 { result.append(Self.plain("\n\n")) }
                    result.append(page.rich ?? Self.plain(page.text))
                }
                return result
            }
        }
    }

    var markdown: String {
        get async throws {
            switch self {
            case let .markdown(source, _):
                return source
            case let .plainText(text):
                return text
            case .html, .rich:
                return MarkdownWriter.markdown(from: try await attributedString)
            case let .pdf(pages):
                let body = pages
                    .map { MarkdownWriter.escapePlainText($0.text).trimmingCharacters(in: .newlines) }
                    .joined(separator: "\n\n---\n\n")
                return body.isEmpty ? "" : body + "\n"
            }
        }
    }

    func html(title: String) async throws -> String {
        switch self {
        case let .markdown(source, _):
            return MarkdownRenderer.htmlDocument(title: title, body: MarkdownRenderer.body(markdown: source))
        case let .html(source, _):
            return source
        case let .plainText(text):
            return MarkdownRenderer.htmlDocument(title: title, body: MarkdownRenderer.body(MarkdownRenderer.plainTextBlocks(text)))
        case let .rich(text):
            let box = Unchecked(text)
            return try await MainActor.run { try Self.exportHTML(box.value) }
        case .pdf:
            // Semantic HTML reads better than PDFKit's absolutely-styled runs.
            return MarkdownRenderer.htmlDocument(title: title, body: MarkdownRenderer.body(markdown: try await markdown))
        }
    }

    var plainText: String {
        get async throws {
            switch self {
            case let .plainText(text):
                return text
            case let .rich(text):
                return Self.cleanPlainText(text.string)
            case let .pdf(pages):
                return pages.map(\.text).joined(separator: "\n\n")
            case .markdown, .html:
                return Self.cleanPlainText(try await attributedString.string)
            }
        }
    }

    /// Blocks for EPUB chapters; always rendered through the Markdown pipeline so the XHTML is well-formed.
    var epubBlocks: [MarkdownBlock] {
        get async throws {
            switch self {
            case let .plainText(text):
                return MarkdownRenderer.plainTextBlocks(text)
            default:
                return MarkdownParser.parse(try await markdown)
            }
        }
    }

    // MARK: - Helpers

    static let bodyFont = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)

    static func plain(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        return NSAttributedString(string: text, attributes: [.font: bodyFont, .paragraphStyle: style])
    }

    /// Reads text as UTF-8 (with or without BOM), UTF-16 with a BOM, the encoding saved with the file,
    /// or a detected legacy encoding (Windows-1252, Shift-JIS, GB 18030…), else Latin-1.
    static func readText(_ url: URL) throws -> String {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ConversionError.unreadable(url) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        // Latin-1 would turn Windows-1252 quotes and euro signs into control characters and garble CJK text.
        // Suggesting the common encodings (without excluding others) gives the most reliable detection.
        var converted: NSString?
        let detected = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.shiftJIS.rawValue],
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: nil)
        if detected != 0, let converted { return converted as String }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func readRich(_ url: URL, type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw ConversionError.unreadable(url)
        }
    }

    /// HTML import goes through WebKit, which must run on the main thread. The HTML is sanitized first so
    /// the import stays offline and only reads images inside the document's folder.
    static func importHTML(_ html: String, baseURL: URL?) async throws -> NSAttributedString {
        let html = HTMLSanitizer.sanitize(html) { HTMLSanitizer.localReference($0, allowRelative: baseURL != nil) }
        return try await MainActor.run { () throws -> Unchecked<NSAttributedString> in
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .timeout: 15,
            ]
            if let baseURL { options[.baseURL] = baseURL }
            do {
                return Unchecked(try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil))
            } catch {
                throw ConversionError.failed("Couldn't read the HTML: \(error.localizedDescription)")
            }
        }.value
    }

    static func exportHTML(_ text: NSAttributedString) throws -> String {
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes attachment placeholders and normalizes AppKit line separators.
    static func cleanPlainText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}

/// Carries AppKit text objects across the main-actor hop used for WebKit-backed import/export.
/// Safe because each value is confined to one conversion and never mutated concurrently.
struct Unchecked<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) { self.value = value }
}
