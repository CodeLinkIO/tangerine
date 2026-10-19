import AppKit
import PDFKit
import TangerineCore
import XCTest
@testable import TangerineDocuments

final class DocumentConversionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try Fixtures.directory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private static let sampleMarkdown = """
    # Orange Report

    Some **bold** text, some *italic* words and a [link](https://example.com).

    ## Shopping List

    - apples
    - tangerines
        - mandarins

    1. peel
    2. eat

    | Fruit | Count |
    | --- | ---: |
    | Orange | 3 |

    ```swift
    let juice = "fresh"
    ```

    > Quoted line
    """

    func testSupportMatrix() {
        let backends = DocumentsEngine.conversionBackends
        func supported(_ from: FileFormat, _ to: FileFormat) -> Bool {
            backends.contains { $0.supports(from: from, to: to) }
        }
        for target: FileFormat in [.png, .jpg, .tiff, .heic, .txt, .md, .docx, .rtf, .odt, .html, .epub] {
            XCTAssertTrue(supported(.pdf, target), "pdf → \(target)")
        }
        for source: FileFormat in [.docx, .doc, .rtf, .rtfd, .odt, .html, .txt, .md, .webarchive] {
            for target: FileFormat in [.pdf, .docx, .rtf, .odt, .html, .txt, .md, .epub] where target != source {
                XCTAssertTrue(supported(source, target), "\(source) → \(target)")
            }
        }
        XCTAssertFalse(supported(.md, .md))
        XCTAssertFalse(supported(.pdf, .pdf))
        XCTAssertFalse(supported(.png, .pdf), "image → PDF belongs to the image engine")
        XCTAssertFalse(supported(.docx, .png))
    }

    func testMarkdownToHTMLDocument() async throws {
        let md = try write(Self.sampleMarkdown, "report.md")

        let html = try read(try await convert(md, to: .html))

        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<title>report</title>"))
        XCTAssertTrue(html.contains("<h1>Orange Report</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"))
        XCTAssertTrue(html.contains("<li>tangerines\n<ul>\n<li>mandarins</li>"))
        XCTAssertTrue(html.contains("<ol>\n<li>peel</li>"))
        XCTAssertTrue(html.contains("<td style=\"text-align: right\">3</td>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let juice = &quot;fresh&quot;</code></pre>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        Fixtures.assertWellFormedXML(Data(html.utf8), "report.html")
    }

    func testMarkdownToDocxAndBackKeepsStructure() async throws {
        let md = try write(Self.sampleMarkdown, "report.md")

        let docx = try await convert(md, to: .docx)
        let roundTrip = try read(try await convert(docx, to: .md))

        XCTAssertEqual(roundTrip.split(separator: "\n").first, "# Orange Report", roundTrip)
        XCTAssertTrue(roundTrip.contains("## Shopping List"), roundTrip)
        XCTAssertTrue(roundTrip.contains("**bold**"), roundTrip)
        XCTAssertTrue(roundTrip.contains("*italic*"), roundTrip)
        // AppKit's DOCX writer drops hyperlinks and tables, so only the link text survives.
        XCTAssertTrue(roundTrip.contains("and a link."), roundTrip)
        XCTAssertTrue(roundTrip.contains("- apples\n- tangerines\n    - mandarins"), roundTrip)
        XCTAssertTrue(roundTrip.contains("1. peel") && roundTrip.contains("2. eat"), roundTrip)
        XCTAssertTrue(roundTrip.contains("let juice = \"fresh\""), roundTrip)
    }

    func testHTMLToMarkdown() async throws {
        let html = try write("""
        <html><body>
        <h1>Title</h1>
        <p>Hello <b>bold</b>, <i>italic</i> and <a href="https://example.com/x">a link</a>.</p>
        <ul><li>one</li><li>two<ul><li>deep</li></ul></li></ul>
        <ol><li>first</li><li>second</li></ol>
        <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
        <pre><code>let x = 1
        let y = 2</code></pre>
        </body></html>
        """, "page.html")

        let md = try read(try await convert(html, to: .md))

        XCTAssertTrue(md.hasPrefix("# Title\n"), md)
        XCTAssertTrue(md.contains("Hello **bold**, *italic* and [a link](https://example.com/x)."), md)
        XCTAssertTrue(md.contains("- one\n- two\n    - deep\n\n1. first"), md)
        XCTAssertTrue(md.contains("1. first\n2. second"), md)
        XCTAssertTrue(md.contains("| A | B |\n| --- | --- |\n| 1 | 2 |"), md)
        XCTAssertTrue(md.contains("```\nlet x = 1\nlet y = 2\n```"), md)
    }

    func testDocxToPDFPaginates() async throws {
        let paragraphs = (1...160).map { "Paragraph \($0): oranges are rich in vitamin C and taste great." }
        let text = NSAttributedString(string: paragraphs.joined(separator: "\n"),
                                      attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
        let docx = dir.appendingPathComponent("long.docx")
        try text.data(from: NSRange(location: 0, length: text.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)

        let pdf = try await convert(docx, to: .pdf)

        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThanOrEqual(document.pageCount, 3)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Paragraph 1:") ?? false)
        XCTAssertTrue(document.string?.contains("Paragraph 160:") ?? false, "last paragraph missing")
    }

    func testMarkdownToPDFRendersTextNotMarkup() async throws {
        let md = try write(Self.sampleMarkdown, "report.md")

        let pdf = try await convert(md, to: .pdf)
        let document = try XCTUnwrap(PDFDocument(url: pdf))

        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains("Orange Report"))
        XCTAssertTrue(text.contains("bold"))
        XCTAssertFalse(text.contains("**"), "markdown syntax leaked into the PDF")
    }

    func testTextToEPUBIsValidPackage() async throws {
        let txt = try write("Chapter text with <angle> & ampersand.\nSecond line.\n\nNew paragraph.", "story.txt")

        let epub = try await convert(txt, to: .epub)

        let data = try Data(contentsOf: epub)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(data[8], 0, "mimetype must be stored")
        XCTAssertEqual(String(decoding: data[30..<38], as: UTF8.self), "mimetype")
        XCTAssertEqual(String(decoding: data[38..<58], as: UTF8.self), "application/epub+zip")

        let (status, log) = try Fixtures.run("/usr/bin/unzip", ["-t", epub.path])
        XCTAssertEqual(status, 0, log)

        let extracted = dir.appendingPathComponent("story-extracted")
        let (dittoStatus, dittoLog) = try Fixtures.run("/usr/bin/ditto", ["-x", "-k", epub.path, extracted.path])
        XCTAssertEqual(dittoStatus, 0, dittoLog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("META-INF/container.xml").path))
        for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/chapter1.xhtml"] {
            Fixtures.assertWellFormedXML(try Data(contentsOf: extracted.appendingPathComponent(name)), name)
        }
        let chapter = try read(extracted.appendingPathComponent("OEBPS/chapter1.xhtml"))
        XCTAssertTrue(chapter.contains("<p>Chapter text with &lt;angle&gt; &amp; ampersand.<br/>\nSecond line.</p>"), chapter)
        XCTAssertTrue(chapter.contains("<p>New paragraph.</p>"))
        let opf = try read(extracted.appendingPathComponent("OEBPS/content.opf"))
        XCTAssertTrue(opf.contains("<dc:title>story</dc:title>"))
        XCTAssertTrue(opf.contains("properties=\"nav\""))
    }

    func testMarkdownToEPUBSplitsChaptersAtTopHeadings() async throws {
        let md = try write("# One\n\nFirst ![pic](pic.png)\n\n# Two\n\nSecond *part*", "book.md")

        let epub = try await convert(md, to: .epub)

        let extracted = dir.appendingPathComponent("book-extracted")
        _ = try Fixtures.run("/usr/bin/ditto", ["-x", "-k", epub.path, extracted.path])
        let nav = try read(extracted.appendingPathComponent("OEBPS/nav.xhtml"))
        XCTAssertTrue(nav.contains("<a href=\"chapter1.xhtml\">One</a>"), nav)
        XCTAssertTrue(nav.contains("<a href=\"chapter2.xhtml\">Two</a>"), nav)
        let second = try read(extracted.appendingPathComponent("OEBPS/chapter2.xhtml"))
        XCTAssertTrue(second.contains("<p>Second <em>part</em></p>"), second)
        let first = try read(extracted.appendingPathComponent("OEBPS/chapter1.xhtml"))
        XCTAssertFalse(first.contains("<img"), "unpackaged images become alt text")
        XCTAssertTrue(first.contains("[pic]"))
        XCTAssertTrue(try read(extracted.appendingPathComponent("OEBPS/content.opf")).contains("<dc:title>One</dc:title>"))
    }

    func testRichFormatsConvertToEachOther() async throws {
        let md = try write("# Title\n\nBody with **bold**.", "doc.md")
        let rtf = try await convert(md, to: .rtf)
        let odt = try await convert(rtf, to: .odt)
        let txt = try await convert(odt, to: .txt)

        XCTAssertEqual(rtf.pathExtension, "rtf")
        XCTAssertTrue(try read(rtf).hasPrefix("{\\rtf1"))
        let text = try read(txt)
        XCTAssertTrue(text.contains("Title"), text)
        XCTAssertTrue(text.contains("Body with bold."), text)
    }

    func testWebArchiveToMarkdown() async throws {
        let rich = NSMutableAttributedString(string: "Archived ", attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
        rich.append(NSAttributedString(string: "page", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 12)!]))
        let archive = dir.appendingPathComponent("saved.webarchive")
        let box = Unchecked(rich)
        let data = try await MainActor.run {
            try box.value.data(from: NSRange(location: 0, length: box.value.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.webArchive])
        }
        try data.write(to: archive)

        let md = try read(try await convert(archive, to: .md))

        XCTAssertTrue(md.contains("Archived **page**"), md)
    }

    func testOutputsNeverOverwrite() async throws {
        let md = try write("Hello", "note.md")
        let first = try await convert(md, to: .txt)
        let second = try await convert(md, to: .txt)
        XCTAssertEqual(first.lastPathComponent, "note.txt")
        XCTAssertEqual(second.lastPathComponent, "note 2.txt")
        XCTAssertEqual(try read(second).trimmingCharacters(in: .whitespacesAndNewlines), "Hello")
    }

    func testLegacyEncodedTextIsReadable() async throws {
        let url = dir.appendingPathComponent("latin.txt")
        try XCTUnwrap("Café crème".data(using: .isoLatin1)).write(to: url)

        let html = try read(try await convert(url, to: .html))

        XCTAssertTrue(html.contains("Café crème"), html)
    }
}
