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
        let contentSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        fitImages(in: storage, to: CGSize(width: contentSize.width, height: contentSize.height - 24))
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

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

    /// Shrinks images larger than the text area (keeping their aspect ratio) so they print whole instead of
    /// running off the page. `size` leaves room for the line's spacing.
    private static func fitImages(in storage: NSTextStorage, to size: CGSize) {
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? NSTextAttachmentCell,
                  let image = cell.image, image.size.width > 0, image.size.height > 0
            else { return }
            let scale = min(1, size.width / image.size.width, size.height / image.size.height)
            if scale < 1 { image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale) }
        }
    }
}
