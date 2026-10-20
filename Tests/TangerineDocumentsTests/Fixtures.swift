import AppKit
import CoreText
import ImageIO
import PDFKit
import TangerineCore
import XCTest
@testable import TangerineDocuments

/// Programmatic fixtures so tests don't depend on checked-in binaries.
enum Fixtures {
    enum Page {
        /// Text lines drawn with Core Text (extractable text layer).
        case text([String])
        /// Text baked into an image, so the page has no text layer (needs OCR).
        case imageText(String)
        /// A black 100×100 pt square in the top-left corner (for orientation checks).
        case cornerMark
        /// A large noisy photo-like image (for compression).
        case noisyImage
        /// Small text near the bottom-left corner, for tiny pages.
        case caption(String)
        /// Text baked into an image drawn sideways (rotated 90° counterclockwise), as a scanner does
        /// before setting /Rotate 90 to show it upright.
        case sidewaysImageText(String)
        /// Nothing at all.
        case blank
    }

    static let letter = CGSize(width: 612, height: 792)
    static let a4Landscape = CGSize(width: 842, height: 595)

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TangerineDocumentsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a PDF; `sizes` gives each page's media box (Letter by default). `info` is passed to Core
    /// Graphics (e.g. owner passwords and permissions).
    static func pdf(_ pages: [Page], at url: URL, sizes: [CGSize]? = nil, info: [CFString: Any]? = nil) throws {
        var mediaBox = CGRect(origin: .zero, size: letter)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary?) else {
            throw ConversionError.failed("fixture")
        }
        for (index, page) in pages.enumerated() {
            let size = sizes?[index] ?? letter
            var box = CGRect(origin: .zero, size: size)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            switch page {
            case let .text(lines):
                for (index, line) in lines.enumerated() {
                    draw(line, in: context, at: CGPoint(x: 72, y: size.height - 92 - CGFloat(index) * 32), size: 22)
                }
            case let .imageText(text):
                context.draw(textImage(text), in: CGRect(x: 36, y: 420, width: 540, height: 135))
            case .cornerMark:
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: size.height - 100, width: 100, height: 100))
            case .noisyImage:
                context.draw(noiseImage(width: 1600, height: 1600), in: CGRect(x: 36, y: 126, width: 540, height: 540))
            case let .caption(text):
                draw(text, in: context, at: CGPoint(x: 6, y: 8), size: 12)
            case let .sidewaysImageText(text):
                // (x, y) → (width − y, x): text runs bottom to top along the page.
                context.translateBy(x: size.width, y: 0)
                context.rotate(by: .pi / 2)
                context.draw(textImage(text), in: CGRect(x: 126, y: 200, width: 540, height: 135))
            case .blank:
                break
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Re-saves `url` with `/Rotate` set per page.
    static func rotate(_ url: URL, _ rotations: [Int], to destination: URL) throws {
        let document = try XCTUnwrap(PDFDocument(url: url))
        for (index, rotation) in rotations.enumerated() { document.page(at: index)?.rotation = rotation }
        XCTAssertTrue(document.write(to: destination))
    }

    /// Unpacks an EPUB (or any zip) with ditto and returns the folder.
    static func extract(_ archive: URL, in directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let (status, log) = try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
        XCTAssertEqual(status, 0, log)
        return folder
    }

    /// Contents of every attachment that carries data (embedded images).
    static func attachmentData(in text: NSAttributedString) -> [Data] {
        var result: [Data] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let data = (value as? NSTextAttachment)?.fileWrapper?.regularFileContents { result.append(data) }
        }
        return result
    }

    /// Every file under `directory`, relative and sorted.
    static func listing(_ directory: URL) -> [String] {
        (FileManager.default.subpaths(atPath: directory.path) ?? []).sorted()
    }

    static func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    static func textImage(_ text: String) -> CGImage {
        let context = bitmap(width: 1600, height: 400)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 400))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        draw(text, in: context, at: CGPoint(x: 40, y: 140), size: 150)
        return context.makeImage()!
    }

    static func noiseImage(width: Int, height: Int) -> CGImage {
        let context = bitmap(width: width, height: height)
        let data = context.data!.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_103_515_245 &+ 12345
                let noise = Int(seed >> 24) % 48
                let offset = y * context.bytesPerRow + x * 4
                data[offset] = UInt8(min(255, x * 255 / width + noise / 2))
                data[offset + 1] = UInt8(min(255, y * 255 / height + noise / 3))
                data[offset + 2] = UInt8(min(255, 128 + noise))
                data[offset + 3] = 255
            }
        }
        return context.makeImage()!
    }

    static func png(at url: URL, width: Int, height: Int) throws {
        let context = bitmap(width: width, height: height)
        context.setFillColor(CGColor(red: 0.95, green: 0.36, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("png fixture") }
    }

    static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    // MARK: - Inspection

    static func imageSize(_ url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Brightness (0...255) of a pixel, with y measured from the top edge.
    static func brightness(of url: URL, x: Int, yFromTop: Int) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let context = bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data?.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height) else {
            return nil
        }
        // Bitmap memory rows run top to bottom.
        let offset = yFromTop * context.bytesPerRow + x * 4
        return (Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])) / 3
    }

    /// Darkest pixel (0...255 brightness) inside `rect`, measured in pixels from the top-left corner.
    static func minBrightness(of url: URL, in rect: CGRect) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let context = bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data?.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height) else {
            return nil
        }
        let area = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var darkest = 255
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let offset = y * context.bytesPerRow + x * 4
                darkest = min(darkest, (Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])) / 3)
            }
        }
        return darkest
    }

    static func assertWellFormedXML(_ data: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let parser = XMLParser(data: data)
        XCTAssertTrue(parser.parse(), "\(name) is not well-formed: \(String(describing: parser.parserError))", file: file, line: line)
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Runs a conversion through whichever documents backend supports it.
func convert(_ url: URL, to target: FileFormat, options: ConversionOptions = ConversionOptions()) async throws -> URL {
    let source = try XCTUnwrap(FileFormat.detect(url), "unknown format for \(url.lastPathComponent)")
    let backend = try XCTUnwrap(DocumentsEngine.conversionBackends.first { $0.supports(from: source, to: target) },
                                "no backend for \(source) → \(target)")
    let outputs = try await backend.convert(url, from: source, to: target, output: OutputPlan(for: url),
                                            context: ConversionContext(options: options))
    return try XCTUnwrap(outputs.first)
}

func runTool(_ tool: ToolID, _ inputs: [URL]) async throws -> ToolOutput {
    let format = try XCTUnwrap(FileFormat.detect(inputs[0]))
    let backend = try XCTUnwrap(DocumentsEngine.toolBackends.first { $0.supports(tool, format: format) })
    return try await backend.run(tool, inputs: inputs, output: OutputPlan(for: inputs[0]), context: ConversionContext())
}

func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}
