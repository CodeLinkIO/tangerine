import Foundation

/// Writes an EPUB 3 book. Chapters are split at top-level headings.
enum EPUBWriter {
    struct Chapter {
        var title: String
        var blocks: [MarkdownBlock]
    }

    static func write(blocks: [MarkdownBlock], fallbackTitle: String, language: String = "en", to url: URL) throws {
        let chapters = split(blocks, fallbackTitle: fallbackTitle)
        let bookTitle = blocks.lazy.compactMap { block -> String? in
            if case let .heading(1, text) = block { return MarkdownInline.plainText(text) }
            return nil
        }.first ?? fallbackTitle

        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        zip.add("META-INF/container.xml", Data(container.utf8))
        zip.add("OEBPS/content.opf", Data(packageDocument(title: bookTitle, language: language, chapterCount: chapters.count).utf8))
        zip.add("OEBPS/nav.xhtml", Data(navigation(title: bookTitle, chapters: chapters, language: language).utf8))
        zip.add("OEBPS/style.css", Data(MarkdownRenderer.Stylesheet.base.utf8))
        var options = MarkdownRenderer.Options()
        options.inline.imagesAsText = true
        for (index, chapter) in chapters.enumerated() {
            let body = MarkdownRenderer.body(chapter.blocks, options: options)
            zip.add("OEBPS/chapter\(index + 1).xhtml", Data(xhtml(title: chapter.title, body: body, language: language).utf8))
        }
        try zip.finalize().write(to: url, options: .atomic)
    }

    static func split(_ blocks: [MarkdownBlock], fallbackTitle: String) -> [Chapter] {
        var chapters: [Chapter] = []
        var current: [MarkdownBlock] = []
        var currentTitle: String?
        for block in blocks {
            if case let .heading(1, text) = block {
                if !current.isEmpty {
                    chapters.append(Chapter(title: currentTitle ?? fallbackTitle, blocks: current))
                }
                current = [block]
                currentTitle = MarkdownInline.plainText(text)
            } else {
                current.append(block)
            }
        }
        if !current.isEmpty || chapters.isEmpty {
            chapters.append(Chapter(title: currentTitle ?? fallbackTitle, blocks: current))
        }
        for index in chapters.indices where chapters[index].title.trimmingCharacters(in: .whitespaces).isEmpty {
            chapters[index].title = "Chapter \(index + 1)"
        }
        return chapters
    }

    private static let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>

    """

    private static func packageDocument(title: String, language: String, chapterCount: Int) -> String {
        let modified = ISO8601DateFormatter().string(from: Date())
        let items = (1...chapterCount).map {
            "    <item id=\"chapter\($0)\" href=\"chapter\($0).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = (1...chapterCount).map { "    <itemref idref=\"chapter\($0)\"/>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="\(language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(XML.escape(title))</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>
        \(items)
          </manifest>
          <spine>
        \(spine)
          </spine>
        </package>

        """
    }

    private static func navigation(title: String, chapters: [Chapter], language: String) -> String {
        let entries = chapters.enumerated().map {
            "      <li><a href=\"chapter\($0.offset + 1).xhtml\">\(XML.escape($0.element.title))</a></li>"
        }.joined(separator: "\n")
        return xhtml(title: title, body: """
        <nav epub:type="toc" id="toc">
          <h1>Contents</h1>
          <ol>
        \(entries)
          </ol>
        </nav>
        """, language: language)
    }

    private static func xhtml(title: String, body: String, language: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head>
        <meta charset="UTF-8"/>
        <title>\(XML.escape(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
    }
}
