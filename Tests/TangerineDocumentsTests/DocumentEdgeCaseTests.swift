import AppKit
import PDFKit
import TangerineCore
import XCTest
@testable import TangerineDocuments

/// Encodings, unicode, damaged files, awkward file names and output-folder problems for text documents.
final class DocumentEdgeCaseTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try Fixtures.directory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        try write(Data(text.utf8), name)
    }

    private func richText(_ url: URL, _ type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }

    private func pdfText(_ url: URL) throws -> String {
        try XCTUnwrap(PDFDocument(url: url)?.string)
    }

    // MARK: - Text encodings

    func testTextEncodingsAreDetected() async throws {
        let cases: [(String, Data, String)] = [
            ("utf8-bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("Héllo wörld".utf8), "Héllo wörld"),
            ("utf16le.txt", Data([0xFF, 0xFE]) + "Héllo 日本 🍊".data(using: .utf16LittleEndian)!, "Héllo 日本 🍊"),
            ("utf16be.txt", Data([0xFE, 0xFF]) + "Héllo 日本 🍊".data(using: .utf16BigEndian)!, "Héllo 日本 🍊"),
            ("latin1.txt", "Café crème, garçon".data(using: .isoLatin1)!, "Café crème, garçon"),
            ("cp1252.txt", "“Smart” quotes cost 5 € – naïve…".data(using: .windowsCP1252)!, "“Smart” quotes cost 5 € – naïve…"),
            ("sjis.txt", "こんにちは世界、日本語のテキストです。".data(using: .shiftJIS)!, "こんにちは世界、日本語のテキストです。"),
            ("sjis-short.txt", "日本語".data(using: .shiftJIS)!, "日本語"),
        ]
        for (name, data, expected) in cases {
            let url = try write(data, name)
            let html = try read(try await convert(url, to: .html))
            XCTAssertTrue(html.contains("<p>\(expected)</p>"), "\(name): \(html)")
            XCTAssertFalse(html.contains("\u{FEFF}"), "\(name) kept its BOM")
            let md = try read(try await convert(url, to: .md))
            XCTAssertEqual(md, expected, name)
        }
    }

    func testCRLFAndEmptyTextFiles() async throws {
        let crlf = try write("Line one\r\nLine two\r\n\r\nSecond paragraph\r\n", "windows.txt")
        let html = try read(try await convert(crlf, to: .html))
        XCTAssertTrue(html.contains("<p>Line one<br/>\nLine two</p>\n<p>Second paragraph</p>"), html)
        let docText = try richText(try await convert(crlf, to: .docx), .officeOpenXML).string
        XCTAssertTrue(docText.contains("Line one") && docText.contains("Second paragraph"), docText)
        let crlfPDF = try await convert(crlf, to: .pdf)
        XCTAssertTrue(try pdfText(crlfPDF).contains("Second paragraph"))

        let empty = try write(Data(), "empty.txt")
        for target: FileFormat in [.pdf, .docx, .rtf, .odt, .html, .md, .epub] {
            let output = try await convert(empty, to: target)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "\(target)")
        }
        XCTAssertEqual(PDFDocument(url: dir.appendingPathComponent("empty.pdf"))?.pageCount, 1)
        XCTAssertEqual(try read(dir.appendingPathComponent("empty.md")), "")
        let (status, log) = try Fixtures.run("/usr/bin/unzip", ["-t", dir.appendingPathComponent("empty.epub").path])
        XCTAssertEqual(status, 0, log)
    }

    // MARK: - Markdown content

    func testEmptyAndWhitespaceMarkdownConvertsToEveryFormat() async throws {
        for (name, text) in [("blank.md", ""), ("spaces.md", "   \n\t\n  \n")] {
            let md = try write(text, name)
            for target: FileFormat in [.pdf, .docx, .rtf, .odt, .html, .txt, .epub] {
                let output = try await convert(md, to: target)
                XCTAssertTrue(target == .txt || output.fileSize > 0, "\(name) → \(target)")
            }
        }
        let html = try read(dir.appendingPathComponent("blank.html"))
        Fixtures.assertWellFormedXML(Data(html.utf8), "blank.html")
        XCTAssertEqual(try read(dir.appendingPathComponent("spaces.txt")).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    private static let unicodeMarkdown = """
    # Tiếng Việt có dấu

    Xin chào thế giới — **đậm** và *nghiêng*.

    日本語のテキスト、中文测试，한국어.

    Emoji 🍊🎉👩🏽‍💻 and Arabic مرحبا بالعالم and Hebrew שלום.
    """

    private static let unicodeSnippets = ["Tiếng Việt có dấu", "Xin chào thế giới", "đậm", "nghiêng",
                                          "日本語のテキスト、中文测试，한국어", "🍊🎉👩🏽‍💻", "مرحبا بالعالم", "שלום"]

    func testUnicodeSurvivesEveryFormatAndBack() async throws {
        let md = try write(Self.unicodeMarkdown, "unicode.md")
        // NFKC: PDF text extraction may return compatibility forms (e.g. the Kangxi radical ⽇ for 日).
        func assertAll(_ text: String, _ label: String, _ snippets: [String] = DocumentEdgeCaseTests.unicodeSnippets) {
            let normalized = text.precomposedStringWithCompatibilityMapping
            for snippet in snippets {
                XCTAssertTrue(normalized.contains(snippet.precomposedStringWithCompatibilityMapping), "\(label) lost “\(snippet)”: \(text)")
            }
        }

        for target: FileFormat in [.docx, .rtf, .odt] {
            let roundTrip = try read(try await convert(try await convert(md, to: target), to: .md))
            assertAll(roundTrip, "\(target) → md")
            XCTAssertTrue(roundTrip.contains("**đậm**") && roundTrip.contains("*nghiêng*"), "\(target): \(roundTrip)")
        }
        assertAll(try read(try await convert(md, to: .html)), "html")
        assertAll(try read(try await convert(md, to: .txt)), "txt")
        let book = try Fixtures.extract(try await convert(md, to: .epub), in: dir)
        assertAll(try read(book.appendingPathComponent("OEBPS/chapter1.xhtml")), "epub")
        XCTAssertTrue(try read(book.appendingPathComponent("OEBPS/content.opf")).contains("<dc:title>Tiếng Việt có dấu</dc:title>"))
        // PDF text extraction can't be relied on for emoji or right-to-left order; check the rest.
        assertAll(try pdfText(try await convert(md, to: .pdf)), "pdf", Array(Self.unicodeSnippets.prefix(5)))
    }

    func testRichFormatRoundTripsKeepParagraphsListsAndEmphasis() async throws {
        let md = try write("""
        First paragraph with **bold** and *italic*.

        Second paragraph.

        - apples
        - pears
            - nashi

        1. one
        2. two
        """, "structure.md")
        for target: FileFormat in [.docx, .odt, .rtf] {
            let roundTrip = try read(try await convert(try await convert(md, to: target), to: .md))
            XCTAssertTrue(roundTrip.contains("First paragraph with **bold** and *italic*."), "\(target): \(roundTrip)")
            XCTAssertTrue(roundTrip.contains("\n\nSecond paragraph.\n\n"), "\(target): \(roundTrip)")
            XCTAssertTrue(roundTrip.contains("- apples\n- pears\n    - nashi"), "\(target): \(roundTrip)")
            XCTAssertTrue(roundTrip.contains("1. one\n2. two"), "\(target): \(roundTrip)")
        }
    }

    // MARK: - Legacy and damaged inputs

    func testLegacyDocAndRTFNamedDocAreReadable() async throws {
        let rich = NSMutableAttributedString(string: "Legacy ", attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
        rich.append(NSAttributedString(string: "bold", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 12)!]))
        let range = NSRange(location: 0, length: rich.length)
        let doc = try write(try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat]), "word97.doc")
        let docMarkdown = try await convert(doc, to: .md)
        XCTAssertTrue(try read(docMarkdown).contains("Legacy **bold**"))

        // Word and many exporters save RTF with a .doc extension.
        let disguised = try write(try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), "really-rtf.doc")
        let disguisedMarkdown = try await convert(disguised, to: .md)
        XCTAssertTrue(try read(disguisedMarkdown).contains("Legacy **bold**"))
    }

    func testDamagedDocumentsFailCleanly() async throws {
        var zip = ZipWriter()
        try zip.add("hello.txt", Data("not a word document".utf8))
        let noise = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 3) })
        let cases: [(String, Data)] = [
            ("noise.docx", noise), ("plain-zip.docx", try zip.finalize()), ("empty.docx", Data()),
            ("text.docx", Data("just text".utf8)), ("noise.odt", noise), ("noise.rtf", noise), ("noise.doc", noise),
            ("noise.webarchive", noise),
        ]
        for (name, data) in cases {
            let url = try write(data, name)
            let before = Fixtures.listing(dir)
            for target: FileFormat in [.md, .pdf] {
                do {
                    _ = try await convert(url, to: target)
                    XCTFail("\(name) → \(target) should fail")
                } catch let ConversionError.unreadable(failed) {
                    XCTAssertEqual(failed.lastPathComponent, name)
                } catch {
                    XCTFail("\(name) → \(target): unexpected \(error)")
                }
            }
            XCTAssertEqual(Fixtures.listing(dir), before, "\(name) left files behind")
        }
    }

    func testRTFDWithImageConvertsToPDFAndMarkdown() async throws {
        let png = dir.appendingPathComponent("dot.png")
        try Fixtures.png(at: png, width: 40, height: 40)
        let wrapper = FileWrapper(regularFileWithContents: try Data(contentsOf: png))
        wrapper.preferredFilename = "dot.png"
        let rich = NSMutableAttributedString(string: "Bundle with an image: ")
        rich.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        rich.append(NSAttributedString(string: " and text after."))
        let rtfd = dir.appendingPathComponent("bundle.rtfd")
        try XCTUnwrap(rich.rtfdFileWrapper(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
            .write(to: rtfd, options: .atomic, originalContentsURL: nil)

        let md = try read(try await convert(rtfd, to: .md))
        XCTAssertTrue(md.contains("Bundle with an image:") && md.contains("and text after."), md)
        XCTAssertFalse(md.contains("\u{FFFC}"))
        let pdf = try await convert(rtfd, to: .pdf)
        XCTAssertTrue(try pdfText(pdf).contains("and text after."))
    }

    // MARK: - Privacy: remote references

    private static let trackingHTML = """
    <!DOCTYPE html>
    <html><head>
    <link rel="stylesheet" href="https://cdn.example.invalid/site.css">
    <style>@import url("https://cdn.example.invalid/more.css"); body { background: url(https://cdn.example.invalid/bg.png) }</style>
    <script src="https://cdn.example.invalid/app.js"></script>
    <meta http-equiv="refresh" content="0; url=https://redirect.example.invalid/">
    <base href="https://base.example.invalid/">
    </head><body>
    <h1>News</h1>
    <p>Read <a href="https://news.example.invalid/story">the story</a>.
    <img src="https://tracker.example.invalid/pixel.gif" alt="pixel"> <img src="//cdn.example.invalid/x.png">
    <img src="photo.png" alt="local photo"></p>
    <iframe src="https://ads.example.invalid/frame"></iframe>
    <object data="https://ads.example.invalid/movie.swf"></object>
    <video poster="https://cdn.example.invalid/poster.jpg"></video>
    </body></html>
    """

    func testHTMLWithRemoteResourcesConvertsOfflineKeepingLinks() async throws {
        try Fixtures.png(at: dir.appendingPathComponent("photo.png"), width: 30, height: 20)
        let html = try write(Self.trackingHTML, "news.html")

        let sanitized = HTMLSanitizer.sanitize(Self.trackingHTML) { HTMLSanitizer.localReference($0, allowRelative: true) }
        for host in ["cdn.", "tracker.", "ads.", "redirect.", "base."] {
            XCTAssertFalse(sanitized.contains(host + "example.invalid"), "\(host) survived: \(sanitized)")
        }
        XCTAssertTrue(sanitized.hasPrefix("<!DOCTYPE html>"), "doctype must stay first")

        let start = Date()
        let md = try read(try await convert(html, to: .md))
        let source = try await DocumentSource.load(html, format: .html, context: ConversionContext())
        let rich = try await source.attributedString
        _ = try await convert(html, to: .pdf)
        _ = try await convert(html, to: .docx)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "conversion waited on the network")

        XCTAssertTrue(md.hasPrefix("# News"), md)
        XCTAssertTrue(md.contains("[the story](https://news.example.invalid/story)"), "links are kept: \(md)")
        XCTAssertTrue(rich.string.contains("pixel"), "rejected images become alt text")
        XCTAssertEqual(Fixtures.attachmentData(in: rich), [try Data(contentsOf: dir.appendingPathComponent("photo.png"))])
    }

    func testWebArchiveUsesArchivedImagesAndDropsEverythingElse() async throws {
        let pngURL = dir.appendingPathComponent("pic.png")
        try Fixtures.png(at: pngURL, width: 24, height: 24)
        let png = try Data(contentsOf: pngURL)
        let page = """
        <html><head><link rel="stylesheet" href="https://site.example.invalid/archived.css"></head><body>
        <p>Archived <b>page</b> <img src="img/pic.png" alt="archived"> <img src="https://tracker.example.invalid/p.gif" alt="beacon"></p>
        <iframe src="https://ads.example.invalid/"></iframe></body></html>
        """
        let plist: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(page.utf8), "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8", "WebResourceURL": "https://site.example.invalid/news/page.html",
                "WebResourceFrameName": "",
            ],
            "WebSubresources": [
                ["WebResourceData": png, "WebResourceMIMEType": "image/png",
                 "WebResourceURL": "https://site.example.invalid/news/img/pic.png"],
                ["WebResourceData": Data("p { color: red }".utf8), "WebResourceMIMEType": "text/css",
                 "WebResourceURL": "https://site.example.invalid/archived.css"],
            ],
        ]
        let archive = try write(try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0), "saved.webarchive")

        let html = try WebArchive.html(archive)
        XCTAssertFalse(html.contains("example.invalid"), html)
        let source = try await DocumentSource.load(archive, format: .webarchive, context: ConversionContext())
        let rich = try await source.attributedString
        XCTAssertEqual(Fixtures.attachmentData(in: rich), [png])
        XCTAssertTrue(rich.string.contains("beacon"))
        let markdown = try await convert(archive, to: .md)
        XCTAssertTrue(try read(markdown).contains("Archived **page**"))

        // A saved plain-text page is text, not markup.
        let plain: [String: Any] = ["WebMainResource": [
            "WebResourceData": Data("<b>not bold</b> & co".utf8), "WebResourceMIMEType": "text/plain",
            "WebResourceTextEncodingName": "UTF-8", "WebResourceURL": "https://site.example.invalid/notes.txt",
        ]]
        let notes = try write(try PropertyListSerialization.data(fromPropertyList: plain, format: .binary, options: 0), "notes.webarchive")
        let notesText = try await convert(notes, to: .txt)
        XCTAssertEqual(try read(notesText).trimmingCharacters(in: .whitespacesAndNewlines), "<b>not bold</b> & co")
    }

    // MARK: - File names and output folders

    func testAwkwardFileNamesWork() async throws {
        let name = #"-rf "Tom's" & <Jerry> Tiếng Việt 日本 🍊"#
        let md = try write("Body text", name + ".md")
        for target: FileFormat in [.pdf, .html, .epub, .docx, .txt, .rtf] {
            let output = try await convert(md, to: target)
            XCTAssertEqual(output.lastPathComponent, "\(name).\(target.fileExtension)")
        }
        let html = try read(dir.appendingPathComponent(name + ".html"))
        XCTAssertTrue(html.contains("<title>-rf &quot;Tom's&quot; &amp; &lt;Jerry&gt; Tiếng Việt 日本 🍊</title>"), html)
        let book = try Fixtures.extract(dir.appendingPathComponent(name + ".epub"), in: dir)
        let opf = try XMLDocument(data: try Data(contentsOf: book.appendingPathComponent("OEBPS/content.opf")))
        XCTAssertEqual(try opf.nodes(forXPath: "//*[local-name()='title']").first?.stringValue, name)
    }

    func testReadOnlyOutputFolderFailsWithoutPartialFiles() async throws {
        let md = try write("# Title\n\nBody", "note.md")
        let deck = dir.appendingPathComponent("deck.pdf")
        try Fixtures.pdf([.text(["One"]), .text(["Two"])], at: deck)
        let single = dir.appendingPathComponent("single.pdf")
        try Fixtures.pdf([.text(["Only"])], at: single)
        let before = Fixtures.listing(dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let jobs: [(String, () async throws -> Void)] = [
            ("md → html", { _ = try await convert(md, to: .html) }),
            ("md → pdf", { _ = try await convert(md, to: .pdf) }),
            ("md → docx", { _ = try await convert(md, to: .docx) }),
            ("md → epub", { _ = try await convert(md, to: .epub) }),
            ("pdf → png folder", { _ = try await convert(deck, to: .png) }),
            ("pdf → jpg", { _ = try await convert(single, to: .jpg) }),
            ("pdf → txt", { _ = try await convert(deck, to: .txt) }),
            ("split", { _ = try await runTool(.splitPDF, [deck]) }),
            ("merge", { _ = try await runTool(.mergePDF, [deck, single]) }),
            ("compress", { _ = try await runTool(.compress, [deck]) }),
        ]
        for (label, job) in jobs {
            do {
                try await job()
                XCTFail("\(label) should fail in a read-only folder")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty, label)
            }
        }
        XCTAssertEqual(Fixtures.listing(dir), before)
    }

    // MARK: - Paginated PDF output

    func testPaginatedPDFKeepsLongDocumentsLongWordsAndHugeText() async throws {
        let long = try write((1...3000).map { "Paragraph \($0) about oranges." }.joined(separator: "\n"), "long.txt")
        let longURL = try await convert(long, to: .pdf)
        let longPDF = try XCTUnwrap(PDFDocument(url: longURL))
        XCTAssertGreaterThan(longPDF.pageCount, 40)
        XCTAssertTrue(longPDF.page(at: longPDF.pageCount - 1)?.string?.contains("Paragraph 3000 about oranges.") ?? false)
        XCTAssertEqual(longPDF.page(at: longPDF.pageCount - 1)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))

        let word = "https://example.invalid/" + String(repeating: "a", count: 20_000)
        let wordPDF = try pdfText(try await convert(try write(word, "word.txt"), to: .pdf))
        XCTAssertEqual(wordPDF.filter { $0 == "a" }.count, 20_000 + word.prefix(24).filter { $0 == "a" }.count,
                       "a single long word must wrap, not be cut")

        let huge = try write(#"<p><span style="font-size: 900px">Huge</span></p><p>after the huge text</p>"#, "huge.html")
        let hugeText = try pdfText(try await convert(huge, to: .pdf))
        XCTAssertTrue(hugeText.contains("after the huge text"), hugeText)
    }

    func testOversizedImagesAreShrunkToFitThePage() async throws {
        try Fixtures.png(at: dir.appendingPathComponent("tall.png"), width: 300, height: 3000)
        try Fixtures.png(at: dir.appendingPathComponent("wide.png"), width: 2000, height: 100)
        let md = try write("Before the images\n\n![tall](tall.png)\n\nBetween\n\n![wide](wide.png)\n\nAfter the images", "pictures.md")

        let pdf = try await convert(md, to: .pdf)

        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertTrue(document.string?.contains("After the images") ?? false)
        var sawImage = false
        for index in 0..<document.pageCount {
            let png = dir.appendingPathComponent("page\(index).png")
            try PDFRasterizer.write(PDFRasterizer.render(try XCTUnwrap(document.page(at: index)), dpi: 36), to: png,
                                    typeIdentifier: "public.png", dpi: 36, quality: 1)
            // At 36 DPI the 1 in margins are 36 px: nothing may spill into the bottom or right margin.
            XCTAssertGreaterThan(try XCTUnwrap(Fixtures.minBrightness(of: png, in: CGRect(x: 0, y: 361, width: 306, height: 35))), 225, "page \(index + 1) bottom margin")
            XCTAssertGreaterThan(try XCTUnwrap(Fixtures.minBrightness(of: png, in: CGRect(x: 271, y: 0, width: 35, height: 396))), 225, "page \(index + 1) right margin")
            if try XCTUnwrap(Fixtures.minBrightness(of: png, in: CGRect(x: 36, y: 36, width: 234, height: 324))) < 160 { sawImage = true }
        }
        XCTAssertTrue(sawImage, "images should still be drawn")
    }

    // MARK: - EPUB

    func testEPUBEscapesMetadataAndIsWellFormed() async throws {
        let md = try write("""
        # Rock & Roll <Live> "Quoted" 'single'

        Body & more <tags> and a [link](https://example.invalid/?a=1&b=2).

        ## Sub & section

        ```html
        <script>alert("x")</script>
        ```

        # Second & last
        """, #"Tom & Jerry <"Best"> 'Hits'.md"#)

        let epub = try await convert(md, to: .epub)

        let data = try Data(contentsOf: epub)
        XCTAssertEqual(String(decoding: data[30..<38], as: UTF8.self), "mimetype", "mimetype must be the first entry")
        XCTAssertEqual(data[8], 0, "mimetype must be stored")
        let (status, log) = try Fixtures.run("/usr/bin/unzip", ["-t", epub.path])
        XCTAssertEqual(status, 0, log)
        let book = try Fixtures.extract(epub, in: dir)
        for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter1.xhtml", "OEBPS/chapter2.xhtml"] {
            XCTAssertNoThrow(try XMLDocument(data: try Data(contentsOf: book.appendingPathComponent(name))), name)
        }
        let opf = try XMLDocument(data: try Data(contentsOf: book.appendingPathComponent("OEBPS/content.opf")))
        XCTAssertEqual(try opf.nodes(forXPath: "//*[local-name()='title']").first?.stringValue, #"Rock & Roll <Live> "Quoted" 'single'"#)
        let nav = try XMLDocument(data: try Data(contentsOf: book.appendingPathComponent("OEBPS/nav.xhtml")))
        XCTAssertEqual(try nav.nodes(forXPath: "//*[local-name()='li']").map { $0.stringValue ?? "" },
                       [#"Rock & Roll <Live> "Quoted" 'single'"#, "Second & last"])
        let chapter = try read(book.appendingPathComponent("OEBPS/chapter1.xhtml"))
        XCTAssertFalse(chapter.contains("<script"), chapter)
        XCTAssertTrue(chapter.contains("href=\"https://example.invalid/?a=1&amp;b=2\""), chapter)
    }

    func testEPUBWithBlankHeadingFallsBackToFileName() async throws {
        let md = try write("#\n\nText under an empty heading.", "untitled notes.md")
        let book = try Fixtures.extract(try await convert(md, to: .epub), in: dir)
        let opf = try XMLDocument(data: try Data(contentsOf: book.appendingPathComponent("OEBPS/content.opf")))
        XCTAssertEqual(try opf.nodes(forXPath: "//*[local-name()='title']").first?.stringValue, "untitled notes")
    }

    func testEPUBWithHugeNumberOfHeadingsIsCappedNotCrashed() async throws {
        let md = try write((1...66_000).map { "# Heading \($0)\n\nText \($0)." }.joined(separator: "\n\n"), "many.md")

        let epub = try await convert(md, to: .epub)

        let (status, log) = try Fixtures.run("/usr/bin/unzip", ["-t", epub.path])
        XCTAssertEqual(status, 0, String(log.suffix(300)))
        let book = try Fixtures.extract(epub, in: dir)
        let chapters = try FileManager.default.contentsOfDirectory(atPath: book.appendingPathComponent("OEBPS").path)
            .filter { $0.hasPrefix("chapter") }
        XCTAssertEqual(chapters.count, EPUBWriter.maxChapters)
        let last = try read(book.appendingPathComponent("OEBPS/chapter\(EPUBWriter.maxChapters).xhtml"))
        XCTAssertTrue(last.contains("Heading 66000") && last.contains("Text 66000."), "overflow lands in the last chapter")

        // The writer itself refuses (instead of trapping) once the classic ZIP entry count runs out.
        var zip = ZipWriter()
        for index in 0..<Int(UInt16.max) { try zip.add("f\(index)", Data(), compress: false) }
        XCTAssertThrowsError(try zip.add("one-too-many", Data()))
    }

    func testComplexMarkdownGivesWellFormedHTMLAndEPUB() async throws {
        let md = try write("""
        # H1
        ## H2
        ### H3
        #### H4
        ##### H5
        ###### H6
        ####### not a heading

        - level 1
            - level 2
                - level 3
                    - level 4 with `code <b>` and **bold**

        ```html
        <div onclick="steal()">&nbsp;<script>alert(1)</script></div>
        ```

        | Left | Center | Right |
        | :--- | :---: | ---: |
        | a \\| b | `x|y` | <i>raw</i> |

        <div onclick="steal()">raw block html</div>
        <script>alert("raw")</script>

        ![relative](images/pic one.png) ![spaced](<images/pic two.png>) [js](javascript:alert(1)) &copy; &#x41; \u{0C}\u{0}

        Emoji 🍊 RTL مرحبا
        """, "complex.md")

        let html = try read(try await convert(md, to: .html))
        XCTAssertNoThrow(try XMLDocument(xmlString: html, options: []), "complex.html")
        for forbidden in ["<script", "<div", "javascript:", "onclick=\""] {
            XCTAssertFalse(html.contains(forbidden), "\(forbidden) leaked: \(html)")
        }
        XCTAssertTrue(html.contains("<h6>H6</h6>") && html.contains("####### not a heading"))
        XCTAssertTrue(html.contains("<img src=\"images/pic two.png\" alt=\"spaced\"/>"), html)

        let book = try Fixtures.extract(try await convert(md, to: .epub), in: dir)
        for name in ["OEBPS/nav.xhtml", "OEBPS/chapter1.xhtml", "OEBPS/content.opf"] {
            XCTAssertNoThrow(try XMLDocument(data: try Data(contentsOf: book.appendingPathComponent(name))), name)
        }
        let chapter = try read(book.appendingPathComponent("OEBPS/chapter1.xhtml"))
        XCTAssertFalse(chapter.contains("<script") || chapter.contains("javascript:"), chapter)
    }
}
