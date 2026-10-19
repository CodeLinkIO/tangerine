import AppKit
import PDFKit
import TangerineCore

/// Text from one PDF page; `rich` is nil for pages recovered with OCR.
struct PDFPageText {
    var text: String
    var rich: NSAttributedString?
    var recognized: Bool
}

/// Pulls text out of a PDF, falling back to on-device OCR for pages without a text layer.
enum PDFTextExtractor {
    static let ocrDPI = 200.0

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        guard !document.isLocked else {
            throw ConversionError.failed("“\(url.lastPathComponent)” is password-protected.")
        }
        return document
    }

    static func extract(_ url: URL, progress: @Sendable (Double) -> Void) throws -> [PDFPageText] {
        let document = try open(url)
        var pages: [PDFPageText] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let text = clean(page.string ?? "")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(PDFPageText(text: text, rich: page.attributedString, recognized: false))
            } else {
                let recognized = try autoreleasepool {
                    try TextRecognition.recognize(PDFRasterizer.render(page, dpi: ocrDPI))
                }
                pages.append(PDFPageText(text: recognized, rich: nil, recognized: true))
            }
            progress(Double(index + 1) / Double(max(document.pageCount, 1)))
        }
        return pages
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "")
    }
}
