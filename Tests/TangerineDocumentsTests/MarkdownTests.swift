import XCTest
@testable import TangerineDocuments

final class MarkdownTests: XCTestCase {
    private func html(_ markdown: String) -> String {
        MarkdownRenderer.body(markdown: markdown)
    }

    func testHeadingsParagraphsAndRules() {
        XCTAssertEqual(html("# Title"), "<h1>Title</h1>")
        XCTAssertEqual(html("### Closed ###"), "<h3>Closed</h3>")
        XCTAssertEqual(html("Setext\n======"), "<h1>Setext</h1>")
        XCTAssertEqual(html("Sub\n---"), "<h2>Sub</h2>")
        XCTAssertEqual(html("one\ntwo\n\nthree"), "<p>one\ntwo</p>\n<p>three</p>")
        XCTAssertEqual(html("a\n\n***\n\nb"), "<p>a</p>\n<hr/>\n<p>b</p>")
        XCTAssertEqual(html("#hashtag"), "<p>#hashtag</p>")
    }

    func testInlineFormatting() {
        XCTAssertEqual(MarkdownInline.xhtml("**bold** and *it* and ~~gone~~"),
                       "<strong>bold</strong> and <em>it</em> and <del>gone</del>")
        XCTAssertEqual(MarkdownInline.xhtml("***both***"), "<em><strong>both</strong></em>")
        XCTAssertEqual(MarkdownInline.xhtml("snake_case_name stays"), "snake_case_name stays")
        XCTAssertEqual(MarkdownInline.xhtml("`a *b* <c>`"), "<code>a *b* &lt;c&gt;</code>")
        XCTAssertEqual(MarkdownInline.xhtml(#"\*literal\* & <tag>"#), "*literal* &amp; &lt;tag&gt;")
        XCTAssertEqual(MarkdownInline.xhtml("2 * 3 * 4"), "2 * 3 * 4")
        XCTAssertEqual(MarkdownInline.xhtml("line  \nbreak"), "line<br/>break")
    }

    func testLinksAndImages() {
        XCTAssertEqual(MarkdownInline.xhtml("[**Docs**](https://example.com/a_b \"Title\")"),
                       "<a href=\"https://example.com/a_b\" title=\"Title\"><strong>Docs</strong></a>")
        XCTAssertEqual(MarkdownInline.xhtml("![A cat](cat.png)"), "<img src=\"cat.png\" alt=\"A cat\"/>")
        XCTAssertEqual(MarkdownInline.xhtml("<https://x.org>"), "<a href=\"https://x.org\">https://x.org</a>")
        XCTAssertEqual(MarkdownInline.xhtml("see https://x.org/p."), "see <a href=\"https://x.org/p\">https://x.org/p</a>.")
        XCTAssertEqual(MarkdownInline.xhtml("[not a link]"), "[not a link]")
    }

    func testListsNestAndTrackTightness() {
        XCTAssertEqual(html("- one\n- two\n  - nested\n- three"), """
        <ul>
        <li>one</li>
        <li>two
        <ul>
        <li>nested</li>
        </ul></li>
        <li>three</li>
        </ul>
        """)
        XCTAssertEqual(html("3. c\n4. d"), "<ol start=\"3\">\n<li>c</li>\n<li>d</li>\n</ol>")
        XCTAssertEqual(html("- a\n\n- b"), "<ul>\n<li><p>a</p></li>\n<li><p>b</p></li>\n</ul>")
        // Two-space nesting under an ordered item still nests.
        XCTAssertTrue(html("1. top\n  - child").contains("<li>top\n<ul>\n<li>child</li>"))
    }

    func testCodeQuotesAndTables() {
        XCTAssertEqual(html("```swift\nlet a = \"<b>\"\n\nprint(a)\n```"),
                       "<pre><code class=\"language-swift\">let a = &quot;&lt;b&gt;&quot;\n\nprint(a)</code></pre>")
        XCTAssertEqual(html("    indented\n    code"), "<pre><code>indented\ncode</code></pre>")
        XCTAssertEqual(html("> quoted *text*\n> more"), "<blockquote>\n<p>quoted <em>text</em>\nmore</p>\n</blockquote>")
        let table = html("| Name | Qty |\n| :--- | ---: |\n| Apple | 3 |\n| Pear \\| Fig | `1|2` |")
        XCTAssertTrue(table.contains("<th style=\"text-align: left\">Name</th><th style=\"text-align: right\">Qty</th>"))
        XCTAssertTrue(table.contains("<td style=\"text-align: left\">Pear | Fig</td>"))
        XCTAssertTrue(table.contains("<code>1|2</code>"))
    }

    func testOutputIsAlwaysWellFormed() {
        let nasty = """
        # Odd **nesting *here** done*
        Text with ** unmatched and _under*mixed_ & "quotes" \u{0C} form feed
        - [link **bold](https://a.b) after**
        > ~~strike *em~~ end*
        | a | b |
        |---|---|
        | <x> | & |
        """
        let document = "<root>\(MarkdownRenderer.body(markdown: nasty))</root>"
        Fixtures.assertWellFormedXML(Data(document.utf8), "rendered markdown")
    }

    func testRichTextEscaping() {
        XCTAssertEqual(MarkdownWriter.escapeBlockStart("# not heading"), "\\# not heading")
        XCTAssertEqual(MarkdownWriter.escapeBlockStart("1. not list"), "1\\. not list")
        XCTAssertEqual(MarkdownWriter.escapeInline("a*b_c`d"), "a\\*b\\_c\\`d")
        // Escaped text renders back to the original characters.
        XCTAssertEqual(MarkdownInline.xhtml(MarkdownWriter.escapeInline("x*y*z_w_")), "x*y*z_w_")
    }
}
