import AppKit
import PDFKit
import TangerineCore
import XCTest
@testable import TangerineDocuments

/// Hostile, unusual and large PDFs through rendering, text extraction and the PDF tools.
final class PDFEdgeCaseTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try Fixtures.directory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func expectFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                               _ work: () async throws -> Void) async -> String {
        do {
            try await work()
            XCTFail("expected failure: \(message)", file: file, line: line)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Unreadable input

    func testCorruptTruncatedAndEmptyPDFsFailCleanly() async throws {
        let good = dir.appendingPathComponent("good.pdf")
        try Fixtures.pdf([.text(["One"]), .text(["Two"])], at: good)
        let bytes = try Data(contentsOf: good)
        let cases: [(String, Data)] = [
            ("random.pdf", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) })),
            ("truncated.pdf", bytes.prefix(bytes.count / 2)),
            ("header-only.pdf", Data("%PDF-1.7\n%âãÏÓ\n".utf8)),
            ("zero-bytes.pdf", Data()),
            // A catalog whose page tree has no pages.
            ("no-pages.pdf", Data("%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\ntrailer << /Root 1 0 R /Size 3 >>\n%%EOF\n".utf8)),
        ]
        for (name, data) in cases {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            let before = Fixtures.listing(dir)
            for target: FileFormat in [.png, .txt, .docx] {
                let message = await expectFailure("\(name) → \(target)") { _ = try await convert(url, to: target) }
                XCTAssertTrue(message.contains(name), "\(name) → \(target): \(message)")
            }
            for tool: ToolID in [.splitPDF, .compress, .mergePDF] {
                let message = await expectFailure("\(tool) \(name)") { _ = try await runTool(tool, [url, good]) }
                XCTAssertTrue(message.contains(name), "\(tool) \(name): \(message)")
            }
            XCTAssertEqual(Fixtures.listing(dir), before, "\(name) left files behind")
        }
    }

    // MARK: - Encryption

    func testOwnerPasswordOnlyPDFOpensAndConverts() async throws {
        // Restricts copying and printing but needs no password to open, like many "protected" PDFs.
        let pdf = dir.appendingPathComponent("restricted.pdf")
        try Fixtures.pdf([.text(["Owner restricted text"])], at: pdf, info: [
            kCGPDFContextOwnerPassword: "owner", kCGPDFContextAllowsCopying: false, kCGPDFContextAllowsPrinting: false,
        ])
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertTrue(document.isEncrypted)
        XCTAssertFalse(document.isLocked)
        XCTAssertFalse(document.allowsCopying)

        // Current behavior: the copy restriction isn't enforced (see report).
        let txt = try await convert(pdf, to: .txt)
        XCTAssertTrue(try read(txt).contains("Owner restricted text"))
        var options = ConversionOptions()
        options.pdfDPI = 72
        let png = try await convert(pdf, to: .png, options: options)
        XCTAssertEqual(Fixtures.imageSize(png)?.0, 612)
        let merge = try await runTool(.mergePDF, [pdf, pdf])
        let merged = try XCTUnwrap(merge.files.first)
        let mergedDocument = try XCTUnwrap(PDFDocument(url: merged))
        XCTAssertEqual(mergedDocument.pageCount, 2)
        XCTAssertFalse(mergedDocument.isEncrypted, "merging drops the owner restrictions")
    }

    func testMergeWithUserPasswordPDFFailsWithoutPartialOutput() async throws {
        let plain = dir.appendingPathComponent("plain.pdf")
        try Fixtures.pdf([.text(["Open"])], at: plain)
        let locked = dir.appendingPathComponent("locked.pdf")
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: plain)).write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        let before = Fixtures.listing(dir)

        for inputs in [[plain, locked], [locked, plain]] {
            let message = await expectFailure("merge") { _ = try await runTool(.mergePDF, inputs) }
            XCTAssertTrue(message.contains("locked.pdf") && message.contains("password"), message)
        }
        for tool: ToolID in [.splitPDF, .compress] {
            let message = await expectFailure("\(tool)") { _ = try await runTool(tool, [locked]) }
            XCTAssertTrue(message.contains("password"), message)
        }
        let message = await expectFailure("png") { _ = try await convert(locked, to: .png) }
        XCTAssertTrue(message.contains("password"), message)
        XCTAssertEqual(Fixtures.listing(dir), before)
    }

    // MARK: - Many pages, sizes and rotation

    func testTwoHundredPagesToPNGAreNamedInPageOrder() async throws {
        let pdf = dir.appendingPathComponent("deck.pdf")
        let small = CGSize(width: 72, height: 72)
        try Fixtures.pdf((1...200).map { .caption("\($0)") }, at: pdf, sizes: Array(repeating: small, count: 200))
        let progress = ProgressLog()

        let start = Date()
        let outputs = try await DocumentsEngine.conversionBackends[0].convert(
            pdf, from: .pdf, to: .png, output: OutputPlan(for: pdf), context: ConversionContext { progress.add($0) }
        )
        let folder = try XCTUnwrap(outputs.first)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 30, "200 small pages took \(elapsed) s")
        XCTAssertEqual(folder.lastPathComponent, "deck")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(Set(files), Set((1...200).map { "deck \($0).png" }))
        // No zero padding: Finder's natural sort keeps page order, a plain sort doesn't (see report).
        let natural = files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(natural.prefix(3), ["deck 1.png", "deck 2.png", "deck 3.png"])
        XCTAssertEqual(natural.last, "deck 200.png")
        XCTAssertEqual(Fixtures.imageSize(folder.appendingPathComponent("deck 200.png"))?.0, 300, "1 in at 300 DPI")
        let values = progress.values
        XCTAssertEqual(values.count, 200)
        XCTAssertEqual(values, values.sorted(), "progress must not go backwards")
        XCTAssertEqual(values.last ?? 0, 1, accuracy: 0.0001)
    }

    func testSplitOver100PagesKeepsOrderAndContent() async throws {
        let pdf = dir.appendingPathComponent("book.pdf")
        try Fixtures.pdf((1...120).map { .caption("Page \($0)") }, at: pdf,
                         sizes: Array(repeating: CGSize(width: 144, height: 144), count: 120))

        let split = try await runTool(.splitPDF, [pdf])
        let folder = try XCTUnwrap(split.files.first)

        XCTAssertEqual(folder.lastPathComponent, "book pages")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(Set(files), Set((1...120).map { "book \($0).pdf" }))
        for page in [1, 9, 10, 99, 100, 120] {
            let part = try XCTUnwrap(PDFDocument(url: folder.appendingPathComponent("book \(page).pdf")))
            XCTAssertEqual(part.pageCount, 1)
            XCTAssertEqual(part.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Page \(page)")
        }
    }

    func testMixedPageSizesAndRotationsRenderUpright() async throws {
        let source = dir.appendingPathComponent("source.pdf")
        try Fixtures.pdf([.cornerMark, .cornerMark, .cornerMark, .cornerMark], at: source,
                         sizes: [Fixtures.letter, Fixtures.a4Landscape, Fixtures.letter, Fixtures.letter])
        let mixed = dir.appendingPathComponent("mixed.pdf")
        try Fixtures.rotate(source, [0, 0, 180, 270], to: mixed)
        var options = ConversionOptions()
        options.pdfDPI = 72

        let folder = try await convert(mixed, to: .png, options: options)

        func page(_ n: Int) -> URL { folder.appendingPathComponent("mixed \(n).png") }
        XCTAssertEqual(Fixtures.imageSize(page(1)).map { [$0.0, $0.1] }, [612, 792])
        XCTAssertEqual(Fixtures.imageSize(page(2)).map { [$0.0, $0.1] }, [842, 595])
        XCTAssertEqual(Fixtures.imageSize(page(3)).map { [$0.0, $0.1] }, [612, 792])
        XCTAssertEqual(Fixtures.imageSize(page(4)).map { [$0.0, $0.1] }, [792, 612])
        // The mark starts top-left; 180° moves it bottom-right, 270° (counterclockwise) bottom-left.
        XCTAssertLessThan(try XCTUnwrap(Fixtures.brightness(of: page(2), x: 20, yFromTop: 20)), 30)
        XCTAssertLessThan(try XCTUnwrap(Fixtures.brightness(of: page(3), x: 590, yFromTop: 770)), 30)
        XCTAssertGreaterThan(try XCTUnwrap(Fixtures.brightness(of: page(3), x: 20, yFromTop: 20)), 225)
        XCTAssertLessThan(try XCTUnwrap(Fixtures.brightness(of: page(4), x: 20, yFromTop: 590)), 30)
        XCTAssertGreaterThan(try XCTUnwrap(Fixtures.brightness(of: page(4), x: 20, yFromTop: 20)), 225)
    }

    func testDPIIsClampedAndOversizedPagesFailCleanly() async throws {
        let pdf = dir.appendingPathComponent("letter.pdf")
        try Fixtures.pdf([.text(["Sharp"])], at: pdf)
        var options = ConversionOptions()
        for (dpi, width) in [(0, 306), (10, 306), (36, 306), (600, 5100)] {
            options.pdfDPI = dpi
            let jpg = try await convert(pdf, to: .jpg, options: options)
            XCTAssertEqual(Fixtures.imageSize(jpg)?.0, width, "\(dpi) DPI")
            try FileManager.default.removeItem(at: jpg)
        }

        // 200 × 200 in (the PDF maximum) at 300 DPI would need a 3.6-gigapixel bitmap.
        let poster = dir.appendingPathComponent("poster.pdf")
        try Fixtures.pdf([.cornerMark], at: poster, sizes: [CGSize(width: 14_400, height: 14_400)])
        options.pdfDPI = 300
        let before = Fixtures.listing(dir)
        let message = await expectFailure("poster") { _ = try await convert(poster, to: .png, options: options) }
        XCTAssertTrue(message.contains("too large"), message)
        XCTAssertEqual(Fixtures.listing(dir), before)
        options.pdfDPI = 36
        let small = try await convert(poster, to: .jpg, options: options)
        XCTAssertEqual(Fixtures.imageSize(small)?.0, 7200)
    }

    // MARK: - Text extraction

    func testBlankPDFToTextWritesEmptyFiles() async throws {
        let pdf = dir.appendingPathComponent("blank.pdf")
        try Fixtures.pdf([.blank, .blank], at: pdf)

        // No text layer and nothing for OCR: the outputs are empty rather than an error (see report).
        let txt = try await convert(pdf, to: .txt)
        XCTAssertEqual(try read(txt).trimmingCharacters(in: .whitespacesAndNewlines), "")
        let md = try read(try await convert(pdf, to: .md))
        XCTAssertEqual(md.replacingOccurrences(of: "---", with: "").trimmingCharacters(in: .whitespacesAndNewlines), "")
        let epub = try await convert(pdf, to: .epub)
        let (status, log) = try Fixtures.run("/usr/bin/unzip", ["-t", epub.path])
        XCTAssertEqual(status, 0, log)
    }

    func testSidewaysScanWithRotateFlagIsRecognized() async throws {
        let scan = dir.appendingPathComponent("scan.pdf")
        try Fixtures.pdf([.sidewaysImageText("TANGERINE 42")], at: scan)
        let upright = dir.appendingPathComponent("upright.pdf")
        try Fixtures.rotate(scan, [90], to: upright)

        let text = try read(try await convert(upright, to: .txt))

        XCTAssertTrue(text.uppercased().contains("TANGERINE"), "OCR missed the rotated scan: \(text)")
    }

    // MARK: - Tools

    func testMergeKeepsEachPagesSizeAndRotation() async throws {
        let letter = dir.appendingPathComponent("letter.pdf")
        try Fixtures.pdf([.text(["Letter"])], at: letter)
        let wide = dir.appendingPathComponent("wide.pdf")
        try Fixtures.pdf([.text(["A4"])], at: wide, sizes: [Fixtures.a4Landscape])
        let turned = dir.appendingPathComponent("turned.pdf")
        try Fixtures.rotate(letter, [90], to: turned)

        let merge = try await runTool(.mergePDF, [letter, wide, turned])
        let merged = try XCTUnwrap(merge.files.first)

        let document = try XCTUnwrap(PDFDocument(url: merged))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, Fixtures.letter)
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size, Fixtures.a4Landscape)
        XCTAssertEqual(document.page(at: 2)?.rotation, 90)
        XCTAssertEqual(document.page(at: 1)?.string?.contains("A4"), true)
    }

    func testMergeOfOneFileCopiesIt() async throws {
        let pdf = dir.appendingPathComponent("solo.pdf")
        try Fixtures.pdf([.text(["One"]), .text(["Two"])], at: pdf)

        let merge = try await runTool(.mergePDF, [pdf])
        let merged = try XCTUnwrap(merge.files.first)

        XCTAssertEqual(merged.lastPathComponent, "solo merged.pdf")
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 2)
    }

    func testCompressNeverGrowsAndKeepsTextSelectable() async throws {
        let small = dir.appendingPathComponent("small.pdf")
        try Fixtures.pdf([.text(["Already tiny"])], at: small)
        let first = try await runTool(.compress, [small])
        var optimized = small
        if let file = first.files.first {
            XCTAssertLessThan(file.fileSize, small.fileSize)
            optimized = file
        } else {
            XCTAssertEqual(first.note, "Already optimized")
        }
        // A file PDFKit just wrote can't shrink again: the larger attempt is deleted, not returned.
        let before = Fixtures.listing(dir)
        let again = try await runTool(.compress, [optimized])
        XCTAssertTrue(again.files.isEmpty, "\(again.files)")
        XCTAssertEqual(again.note, "Already optimized")
        XCTAssertEqual(Fixtures.listing(dir), before, "no larger copy left behind")

        let mixed = dir.appendingPathComponent("mixed.pdf")
        try Fixtures.pdf([.text(["Selectable heading"]), .noisyImage], at: mixed)
        let compression = try await runTool(.compress, [mixed])
        let compressed = try XCTUnwrap(compression.files.first)
        XCTAssertLessThan(compressed.fileSize, mixed.fileSize)
        let document = try XCTUnwrap(PDFDocument(url: compressed))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.string?.contains("Selectable heading"), true)
    }

    // MARK: - Output handling

    func testCancellingLeavesNoPartialPageFolder() async throws {
        let pdf = dir.appendingPathComponent("long.pdf")
        try Fixtures.pdf((1...150).map { .caption("\($0)") }, at: pdf, sizes: Array(repeating: CGSize(width: 144, height: 144), count: 150))
        let handle = TaskHandle()
        let backend = DocumentsEngine.conversionBackends[0]
        let task = Task {
            try await backend.convert(pdf, from: .pdf, to: .png, output: OutputPlan(for: pdf),
                                      context: ConversionContext { if $0 > 0.1 { handle.cancel() } })
        }
        handle.task = task

        let result = await task.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(Fixtures.listing(dir), ["long.pdf"])
    }

    func testPageFoldersNeverReplaceExistingItems() async throws {
        let pdf = dir.appendingPathComponent("deck.pdf")
        try Fixtures.pdf([.caption("a"), .caption("b")], at: pdf)
        try Data("not a folder".utf8).write(to: dir.appendingPathComponent("deck"))
        var options = ConversionOptions()
        options.pdfDPI = 36

        let first = try await convert(pdf, to: .png, options: options)
        let second = try await convert(pdf, to: .png, options: options)

        XCTAssertEqual(first.lastPathComponent, "deck 2")
        XCTAssertEqual(second.lastPathComponent, "deck 3")
        XCTAssertEqual(try read(dir.appendingPathComponent("deck")), "not a folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.path).sorted(), ["deck 1.png", "deck 2.png"])
    }
}

/// Collects progress values reported from any thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        log.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }
}

/// Lets a progress callback cancel the task it runs in.
final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<[URL], Error>?
    private var cancelRequested = false

    var task: Task<[URL], Error>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set {
            lock.lock()
            stored = newValue
            let cancelNow = cancelRequested
            lock.unlock()
            if cancelNow { newValue?.cancel() }
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let task = stored
        lock.unlock()
        task?.cancel()
    }
}
