import ImageIO
import PDFKit
import TangerineCore

/// Merge, split and compress PDFs.
struct PDFToolBackend: ToolBackend {
    let id = "pdf-tools"

    func supports(_ tool: ToolID, format: FileFormat) -> Bool {
        switch tool {
        case .mergePDF: format == .pdf || (format.category == .image && format != .svg)
        case .splitPDF, .compress: format == .pdf
        default: false
        }
    }

    func run(_ tool: ToolID, inputs: [URL], output: OutputPlan, context: ConversionContext) async throws -> ToolOutput {
        switch tool {
        case .mergePDF: try merge(inputs, output: output, context: context)
        case .splitPDF: try split(try single(inputs), output: output, context: context)
        case .compress: try compress(try single(inputs), output: output)
        default: throw ConversionError.unsupported(from: nil, to: tool.title)
        }
    }

    private func single(_ inputs: [URL]) throws -> URL {
        guard let first = inputs.first else { throw ConversionError.failed("No file to process.") }
        return first
    }

    // MARK: - Merge

    private func merge(_ inputs: [URL], output: OutputPlan, context: ConversionContext) throws -> ToolOutput {
        guard !inputs.isEmpty else { throw ConversionError.failed("No files to merge.") }
        let merged = PDFDocument()
        for (index, url) in inputs.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                if FileFormat.detect(url) == .pdf {
                    let document = try PDFTextExtractor.open(url)
                    for pageIndex in 0..<document.pageCount {
                        guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                        merged.insert(page, at: merged.pageCount)
                    }
                } else {
                    merged.insert(try Self.page(forImageAt: url), at: merged.pageCount)
                }
            }
            context.progress(Double(index + 1) / Double(inputs.count))
        }
        guard merged.pageCount > 0 else { throw ConversionError.failed("Nothing to merge.") }
        let destination = output.file(extension: "pdf", suffix: "merged")
        guard merged.write(to: destination) else {
            throw ConversionError.failed("Couldn't save “\(destination.lastPathComponent)”.")
        }
        return ToolOutput(files: [destination])
    }

    /// One PDF page sized to the image's physical size (pixels at its DPI, 72 by default).
    static func page(forImageAt url: URL) throws -> PDFPage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ConversionError.unreadable(url) }
        // A thumbnail at full size with the transform applied gives an upright image (EXIF orientation).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.unreadable(url)
        }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let pageRect = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)

        let data = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw ConversionError.failed("Couldn't create a PDF page.") }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(image, in: pageRect)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), let page = document.page(at: 0) else {
            throw ConversionError.failed("Couldn't create a PDF page.")
        }
        return page
    }

    // MARK: - Split

    private func split(_ input: URL, output: OutputPlan, context: ConversionContext) throws -> ToolOutput {
        let document = try PDFTextExtractor.open(input)
        guard document.pageCount > 1 else {
            return ToolOutput(note: "“\(input.lastPathComponent)” has only one page.")
        }
        let folder = try output.makeFolder(suffix: "pages")
        let pages = OutputPlan(directory: folder, baseName: output.baseName)
        do {
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let url = pages.file(extension: "pdf", suffix: "\(index + 1)")
                guard single.write(to: url) else {
                    throw ConversionError.failed("Couldn't save “\(url.lastPathComponent)”.")
                }
                context.progress(Double(index + 1) / Double(document.pageCount))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return ToolOutput(files: [folder])
    }

    // MARK: - Compress

    private func compress(_ input: URL, output: OutputPlan) throws -> ToolOutput {
        guard #available(macOS 13.4, *) else {
            throw ConversionError.failed("Compressing PDFs requires macOS 13.4 or later.")
        }
        let document = try PDFTextExtractor.open(input)
        // PDFKit passes an unmodified document through untouched, ignoring the image options,
        // so re-home the pages in a fresh document to force images to be re-encoded.
        let rewritten = PDFDocument()
        rewritten.documentAttributes = document.documentAttributes
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            rewritten.insert(page, at: rewritten.pageCount)
        }
        let destination = output.file(extension: "pdf", suffix: "compressed")
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ]
        guard rewritten.write(to: destination, withOptions: options) else {
            throw ConversionError.failed("Couldn't save “\(destination.lastPathComponent)”.")
        }
        if destination.fileSize >= input.fileSize {
            try? FileManager.default.removeItem(at: destination)
            return ToolOutput(note: "Already optimized")
        }
        return ToolOutput(files: [destination])
    }
}
