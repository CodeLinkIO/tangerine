import AppKit
import TangerineCore

/// Lays out rich text on US Letter pages and writes a PDF.
enum PaginatedPDFWriter {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 72
    static let maxPages = 10_000

    /// Returns the number of pages written.
    @discardableResult
    static func write(_ text: NSAttributedString, to url: URL, title: String) throws -> Int {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let contentSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        var containers: [NSTextContainer] = []
        while containers.count < maxPages {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let range = layoutManager.glyphRange(for: container)
            if range.length == 0, !containers.isEmpty {
                // Nothing fits (e.g. an attachment taller than a page): stop instead of looping forever.
                layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
                break
            }
            containers.append(container)
            if NSMaxRange(range) >= layoutManager.numberOfGlyphs { break }
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Tangerine"]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ConversionError.failed("Couldn't create “\(url.lastPathComponent)”.")
        }
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            // AppKit text drawing expects a flipped (top-left origin) context.
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let glyphs = layoutManager.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.current = previous
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return containers.count
    }
}
