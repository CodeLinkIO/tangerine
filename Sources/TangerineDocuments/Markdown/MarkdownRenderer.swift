import Foundation

/// Renders Markdown blocks to well-formed XHTML fragments and complete documents.
enum MarkdownRenderer {
    struct Options {
        var inline = MarkdownInline.Options()
    }

    static func body(markdown: String, options: Options = Options()) -> String {
        body(MarkdownParser.parse(markdown), options: options)
    }

    static func body(_ blocks: [MarkdownBlock], options: Options = Options()) -> String {
        blocks.map { render($0, tight: false, options: options) }.joined(separator: "\n")
    }

    /// Escaped paragraphs for plain text, keeping single line breaks.
    static func plainTextBlocks(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { paragraph in
                let lines = paragraph.components(separatedBy: "\n").map(XML.escape)
                return .rawXHTML("<p>\(lines.joined(separator: "<br/>\n"))</p>")
            }
    }

    private static func render(_ block: MarkdownBlock, tight: Bool, options: Options) -> String {
        switch block {
        case let .heading(level, text):
            return "<h\(level)>\(MarkdownInline.xhtml(text, options: options.inline))</h\(level)>"
        case let .paragraph(text):
            let content = MarkdownInline.xhtml(text, options: options.inline)
            return tight ? content : "<p>\(content)</p>"
        case let .code(language, text):
            let cls = language.map { " class=\"language-\(XML.escape($0))\"" } ?? ""
            return "<pre><code\(cls)>\(XML.escape(text))</code></pre>"
        case let .quote(blocks):
            return "<blockquote>\n\(blocks.map { render($0, tight: false, options: options) }.joined(separator: "\n"))\n</blockquote>"
        case let .list(ordered, start, items, isTight):
            let tag = ordered ? "ol" : "ul"
            let startAttribute = ordered && start != 1 ? " start=\"\(start)\"" : ""
            let renderedItems = items.map { item in
                "<li>" + item.map { render($0, tight: isTight, options: options) }.joined(separator: "\n") + "</li>"
            }
            return "<\(tag)\(startAttribute)>\n\(renderedItems.joined(separator: "\n"))\n</\(tag)>"
        case .rule:
            return "<hr/>"
        case let .table(header, alignments, rows):
            func cell(_ tag: String, _ text: String, _ index: Int) -> String {
                let alignment = index < alignments.count ? alignments[index] : .none
                let style: String
                switch alignment {
                case .none: style = ""
                case .left: style = " style=\"text-align: left\""
                case .center: style = " style=\"text-align: center\""
                case .right: style = " style=\"text-align: right\""
                }
                return "<\(tag)\(style)>\(MarkdownInline.xhtml(text, options: options.inline))</\(tag)>"
            }
            let head = "<tr>" + header.enumerated().map { cell("th", $1, $0) }.joined() + "</tr>"
            let body = rows.map { row in "<tr>" + row.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>" }
            var html = "<table>\n<thead>\n\(head)\n</thead>"
            if !body.isEmpty { html += "\n<tbody>\n\(body.joined(separator: "\n"))\n</tbody>" }
            return html + "\n</table>"
        case let .rawXHTML(html):
            return html
        }
    }

    // MARK: - Documents

    /// A standalone HTML5 document (XHTML-compatible) with the default stylesheet.
    static func htmlDocument(title: String, body: String, stylesheet: String = Stylesheet.screen) -> String {
        """
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>\(XML.escape(title))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
    }

    enum Stylesheet {
        /// Typography shared by HTML export, rich-text import (DOCX/RTF/PDF) and EPUB.
        static let base = """
        body { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 12pt; line-height: 1.45; color: #1d1d1f; }
        h1, h2, h3, h4, h5, h6 { font-weight: bold; line-height: 1.2; margin: 1.1em 0 0.45em; }
        h1 { font-size: 1.9em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1.1em; }
        h5 { font-size: 1em; }
        h6 { font-size: 0.9em; color: #555555; }
        p { margin: 0 0 0.8em; }
        code, pre { font-family: Menlo, Monaco, "Courier New", monospace; font-size: 0.9em; }
        pre { background: #f5f5f7; padding: 0.7em 0.9em; border-radius: 6px; white-space: pre-wrap; }
        blockquote { margin: 0 0 0.8em; padding-left: 1em; border-left: 3px solid #d2d2d7; color: #555555; }
        table { border-collapse: collapse; margin: 0 0 0.8em; }
        th, td { border: 1px solid #d2d2d7; padding: 0.3em 0.6em; vertical-align: top; }
        th { background: #f5f5f7; }
        hr { border: none; border-top: 1px solid #d2d2d7; margin: 1.2em 0; }
        a { color: #0066cc; }
        img { max-width: 100%; }
        """

        /// Adds a readable column for viewing in a browser.
        static let screen = base + "\nbody { max-width: 46em; margin: 2em auto; padding: 0 1em; }"
    }
}
