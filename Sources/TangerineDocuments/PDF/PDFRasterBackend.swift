import PDFKit
import TangerineCore

/// Renders every PDF page to an image file.
struct PDFRasterBackend: ConversionBackend {
    let id = "pdf-raster"

    static let imageTypes: [FileFormat: String] = [
        .png: "public.png", .jpg: "public.jpeg", .tiff: "public.tiff", .heic: "public.heic",
    ]

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from == .pdf && Self.imageTypes[to] != nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                 context: ConversionContext) async throws -> [URL] {
        guard supports(from: from, to: to), let type = Self.imageTypes[to] else {
            throw ConversionError.unsupported(from: from, to: to.displayName)
        }
        let document = try PDFTextExtractor.open(input)
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw ConversionError.failed("“\(input.lastPathComponent)” has no pages.") }
        let dpi = Double(min(max(context.options.pdfDPI, 36), 1200))
        let quality = context.options.imageQuality

        func renderPage(_ index: Int, to url: URL) throws {
            guard let page = document.page(at: index) else { return }
            try autoreleasepool {
                try PDFRasterizer.write(PDFRasterizer.render(page, dpi: dpi), to: url, typeIdentifier: type,
                                        dpi: dpi, quality: quality)
            }
        }

        if pageCount == 1 {
            let url = output.file(extension: to.fileExtension)
            try renderPage(0, to: url)
            context.progress(1)
            return [url]
        }

        let folder = try output.makeFolder()
        let pages = OutputPlan(directory: folder, baseName: output.baseName)
        do {
            for index in 0..<pageCount {
                try Task.checkCancellation()
                try renderPage(index, to: pages.file(extension: to.fileExtension, suffix: "\(index + 1)"))
                context.progress(Double(index + 1) / Double(pageCount))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return [folder]
    }
}
