import AppKit
import PDFKit
import TangerineCore
import XCTest
@testable import TangerineDocuments

final class PDFTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try Fixtures.directory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMultiPagePDFToPNGWritesFolderAtRequestedDPI() async throws {
        let pdf = dir.appendingPathComponent("report.pdf")
        try Fixtures.pdf([.text(["Page one"]), .text(["Page two"]), .text(["Page three"])], at: pdf)
        var options = ConversionOptions()
        options.pdfDPI = 150

        let folder = try await convert(pdf, to: .png, options: options)

        XCTAssertEqual(folder.lastPathComponent, "report")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["report 1.png", "report 2.png", "report 3.png"])
        for name in files {
            let size = try XCTUnwrap(Fixtures.imageSize(folder.appendingPathComponent(name)))
            XCTAssertEqual(size.0, 1275) // 8.5 in × 150 DPI
            XCTAssertEqual(size.1, 1650) // 11 in × 150 DPI
        }
    }

    func testSinglePagePDFToJPGWritesOneFile() async throws {
        let pdf = dir.appendingPathComponent("one.pdf")
        try Fixtures.pdf([.text(["Only page"])], at: pdf)
        var options = ConversionOptions()
        options.pdfDPI = 72

        let jpg = try await convert(pdf, to: .jpg, options: options)

        XCTAssertEqual(jpg.lastPathComponent, "one.jpg")
        let size = try XCTUnwrap(Fixtures.imageSize(jpg))
        XCTAssertEqual(size.0, 612)
        XCTAssertEqual(size.1, 792)
    }

    func testRenderingHonorsPageRotation() async throws {
        var options = ConversionOptions()
        options.pdfDPI = 72
        let upright = dir.appendingPathComponent("upright.pdf")
        try Fixtures.pdf([.cornerMark], at: upright)
        let uprightPNG = try await convert(upright, to: .png, options: options)
        XCTAssertLessThan(try XCTUnwrap(Fixtures.brightness(of: uprightPNG, x: 20, yFromTop: 20)), 30, "mark top-left")
        XCTAssertGreaterThan(try XCTUnwrap(Fixtures.brightness(of: uprightPNG, x: 590, yFromTop: 20)), 225)

        // Rotating 90° clockwise moves the top-left mark to the top-right and swaps the dimensions.
        let document = try XCTUnwrap(PDFDocument(url: upright))
        document.page(at: 0)?.rotation = 90
        let rotated = dir.appendingPathComponent("rotated.pdf")
        XCTAssertTrue(document.write(to: rotated))
        let rotatedPNG = try await convert(rotated, to: .png, options: options)
        let size = try XCTUnwrap(Fixtures.imageSize(rotatedPNG))
        XCTAssertEqual(size.0, 792)
        XCTAssertEqual(size.1, 612)
        XCTAssertLessThan(try XCTUnwrap(Fixtures.brightness(of: rotatedPNG, x: 770, yFromTop: 20)), 30, "mark top-right")
        XCTAssertGreaterThan(try XCTUnwrap(Fixtures.brightness(of: rotatedPNG, x: 20, yFromTop: 20)), 225)
    }

    func testRenderingUsesCropBoxOrigin() async throws {
        var options = ConversionOptions()
        options.pdfDPI = 72
        let source = dir.appendingPathComponent("full.pdf")
        try Fixtures.pdf([.cornerMark], at: source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        // Crop to a 300 pt square whose top-left corner holds the 100 pt mark.
        document.page(at: 0)?.setBounds(CGRect(x: 0, y: 492, width: 300, height: 300), for: .cropBox)
        let cropped = dir.appendingPathComponent("cropped.pdf")
        XCTAssertTrue(document.write(to: cropped))

        let png = try await convert(cropped, to: .png, options: options)

        let size = try XCTUnwrap(Fixtures.imageSize(png))
        XCTAssertEqual(size.0, 300)
        XCTAssertEqual(size.1, 300)
        XCTAssertLessThan(try XCTUnwrap(Fixtures.brightness(of: png, x: 50, yFromTop: 50)), 30)
        XCTAssertGreaterThan(try XCTUnwrap(Fixtures.brightness(of: png, x: 250, yFromTop: 250)), 225)
    }

    func testPDFToTIFFAndHEIC() async throws {
        let pdf = dir.appendingPathComponent("scan.pdf")
        try Fixtures.pdf([.text(["Hello"])], at: pdf)
        var options = ConversionOptions()
        options.pdfDPI = 100
        for target: FileFormat in [.tiff, .heic] {
            let url = try await convert(pdf, to: target, options: options)
            XCTAssertEqual(url.pathExtension, target.fileExtension)
            let size = try XCTUnwrap(Fixtures.imageSize(url), "\(target) unreadable")
            XCTAssertEqual(size.0, 850)
            XCTAssertEqual(size.1, 1100)
        }
    }

    func testPDFToTextUsesOCRForScannedPages() async throws {
        let pdf = dir.appendingPathComponent("mixed.pdf")
        try Fixtures.pdf([.text(["Alpha page about oranges"]), .imageText("TANGERINE 42")], at: pdf)

        let txt = try await convert(pdf, to: .txt)

        let text = try read(txt)
        XCTAssertTrue(text.contains("Alpha page about oranges"), text)
        XCTAssertTrue(text.uppercased().contains("TANGERINE"), "OCR text missing: \(text)")
        XCTAssertTrue(text.contains("42"), text)
    }

    func testPDFToMarkdownSeparatesPagesAndEscapes() async throws {
        let pdf = dir.appendingPathComponent("notes.pdf")
        try Fixtures.pdf([.text(["# not a heading", "First page"]), .text(["Second page *star*"])], at: pdf)

        let md = try read(try await convert(pdf, to: .md))

        XCTAssertTrue(md.contains("\\# not a heading"), md)
        XCTAssertTrue(md.contains("\n\n---\n\n"), md)
        XCTAssertTrue(md.contains("Second page \\*star\\*"), md)
        XCTAssertFalse(MarkdownRenderer.body(markdown: md).contains("<h1>"))
    }

    func testPDFToDocxKeepsText() async throws {
        let pdf = dir.appendingPathComponent("letter.pdf")
        try Fixtures.pdf([.text(["Dear reader", "Thanks for the oranges"])], at: pdf)

        let docx = try await convert(pdf, to: .docx)

        let text = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil).string
        XCTAssertTrue(text.contains("Dear reader"), text)
        XCTAssertTrue(text.contains("Thanks for the oranges"), text)
    }

    func testMergeSplitAndCompress() async throws {
        let pdf = dir.appendingPathComponent("a.pdf")
        try Fixtures.pdf([.text(["One"]), .text(["Two"])], at: pdf)
        let png = dir.appendingPathComponent("b.png")
        try Fixtures.png(at: png, width: 300, height: 200)

        let merged = try await runTool(.mergePDF, [pdf, png])
        let mergedURL = try XCTUnwrap(merged.files.first)
        XCTAssertEqual(mergedURL.lastPathComponent, "a merged.pdf")
        let mergedDoc = try XCTUnwrap(PDFDocument(url: mergedURL))
        XCTAssertEqual(mergedDoc.pageCount, 3)
        XCTAssertEqual(mergedDoc.page(at: 1)?.string?.contains("Two"), true)
        let imageBox = try XCTUnwrap(mergedDoc.page(at: 2)?.bounds(for: .mediaBox))
        XCTAssertEqual(imageBox.width, 300, accuracy: 0.5)
        XCTAssertEqual(imageBox.height, 200, accuracy: 0.5)

        let split = try await runTool(.splitPDF, [mergedURL])
        let folder = try XCTUnwrap(split.files.first)
        XCTAssertEqual(folder.lastPathComponent, "a merged pages")
        let parts = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(parts, ["a merged 1.pdf", "a merged 2.pdf", "a merged 3.pdf"])
        for part in parts {
            XCTAssertEqual(PDFDocument(url: folder.appendingPathComponent(part))?.pageCount, 1)
        }

        let heavy = dir.appendingPathComponent("photo.pdf")
        try Fixtures.pdf([.noisyImage], at: heavy)
        let compressed = try await runTool(.compress, [heavy])
        let small = try XCTUnwrap(compressed.files.first, compressed.note ?? "no output")
        XCTAssertEqual(small.lastPathComponent, "photo compressed.pdf")
        XCTAssertLessThan(small.fileSize, heavy.fileSize / 2, "\(small.fileSize) vs \(heavy.fileSize)")
        XCTAssertEqual(PDFDocument(url: small)?.pageCount, 1)

        // A text-only PDF has nothing to shrink.
        let textOnly = try await runTool(.compress, [pdf])
        if textOnly.files.isEmpty { XCTAssertEqual(textOnly.note, "Already optimized") }
    }

    func testSplitSinglePageReturnsNote() async throws {
        let pdf = dir.appendingPathComponent("single.pdf")
        try Fixtures.pdf([.text(["Only"])], at: pdf)
        let result = try await runTool(.splitPDF, [pdf])
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertNotNil(result.note)
    }

    func testLockedPDFFailsWithClearMessage() async throws {
        let pdf = dir.appendingPathComponent("plain.pdf")
        try Fixtures.pdf([.text(["Secret"])], at: pdf)
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        let locked = dir.appendingPathComponent("locked.pdf")
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        do {
            _ = try await convert(locked, to: .txt)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("password"), error.localizedDescription)
        }
    }
}
