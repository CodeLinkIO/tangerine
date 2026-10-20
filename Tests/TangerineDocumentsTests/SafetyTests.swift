import AppKit
import TangerineCore
import XCTest
@testable import TangerineDocuments

/// Script-free output, offline HTML import, and Markdown that can't hang or crash the converter.
final class SafetyTests: XCTestCase {
    private func local(_ html: String) -> String {
        HTMLSanitizer.sanitize(html) { HTMLSanitizer.localReference($0, allowRelative: true) }
    }

    // MARK: - Markdown links

    func testMarkdownRendersScriptURLsAsPlainText() {
        let unsafe = [
            "[x](javascript:alert(1))", "[x](JaVaScRiPt:alert(1))", "[x]( javascript:alert(1))",
            "[x](java\tscript:alert(1))", "[x](<javascript:alert(1)>)", "[x](vbscript:msgbox)",
            "[x](data:text/html;base64,PHNjcmlwdD4=)", "[x](file:///etc/passwd)",
        ]
        for markdown in unsafe {
            XCTAssertEqual(MarkdownInline.xhtml(markdown), "x", markdown)
        }
        XCTAssertEqual(MarkdownInline.xhtml("[**bold** x](javascript:alert(1))"), "<strong>bold</strong> x")
        XCTAssertEqual(MarkdownInline.xhtml("![alt text](javascript:alert(1))"), "alt text")
        XCTAssertEqual(MarkdownInline.xhtml("![svg](data:image/svg+xml;base64,PHN2Zz4=)"), "svg")
        XCTAssertEqual(MarkdownInline.xhtml("<javascript:alert(1)>"), "&lt;javascript:alert(1)&gt;")

        let safe: [(String, String)] = [
            ("[web](https://example.invalid/a?b=1&c=2)", #"<a href="https://example.invalid/a?b=1&amp;c=2">web</a>"#),
            ("[plain](http://example.invalid)", #"<a href="http://example.invalid">plain</a>"#),
            ("[mail](mailto:someone@example.invalid)", #"<a href="mailto:someone@example.invalid">mail</a>"#),
            ("[doc](docs/guide.md#setup)", #"<a href="docs/guide.md#setup">doc</a>"#),
            ("[top](#top)", ##"<a href="#top">top</a>"##),
            ("[colon](notes/a:b.md)", #"<a href="notes/a:b.md">colon</a>"#),
            ("![pixel](data:image/png;base64,iVBORw0KGgo=)", #"<img src="data:image/png;base64,iVBORw0KGgo=" alt="pixel"/>"#),
        ]
        for (markdown, html) in safe {
            XCTAssertEqual(MarkdownInline.xhtml(markdown), html, markdown)
        }
    }

    func testRawHTMLInMarkdownIsEscaped() {
        XCTAssertEqual(MarkdownRenderer.body(markdown: "<script>alert(1)</script>"), "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
        XCTAssertEqual(MarkdownRenderer.body(markdown: #"<img src=x onerror="alert(1)">"#),
                       "<p>&lt;img src=x onerror=&quot;alert(1)&quot;&gt;</p>")
        XCTAssertEqual(MarkdownInline.xhtml(#"[a](https://x.invalid "t\" onmouseover=\"alert(1)")"#).contains("onmouseover=\""), false)
    }

    func testHTMLToMarkdownDropsScriptLinks() async throws {
        let dir = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("links.html")
        try Data(#"<p><a href="javascript:alert(1)">click me</a> and <a href="https://ok.example.invalid/">fine</a></p>"#.utf8).write(to: html)

        let md = try read(try await convert(html, to: .md))

        XCTAssertTrue(md.contains("click me and [fine](https://ok.example.invalid/)"), md)
        XCTAssertFalse(md.contains("javascript"), md)
    }

    // MARK: - HTML sanitizer

    func testSanitizerRemovesEveryRemoteReference() {
        let hostile = [
            #"<img src="https://evil.example.invalid/p.gif">"#,
            #"<IMG SRC=HTTP://evil.example.invalid/p.gif>"#,
            #"<img src="//evil.example.invalid/p.gif">"#,
            #"<img src=" https://evil.example.invalid/p.gif ">"#,
            #"<img src="ht&#x74;ps://evil.example.invalid/p.gif">"#,
            #"<img src="https&colon;//evil.example.invalid/p.gif">"#,
            #"<img src="h&#116;tps&#58;//evil.example.invalid">"#,
            #"<img alt="a > b" src="https://evil.example.invalid/p.gif">"#,
            #"<img/src="https://evil.example.invalid/p.gif">"#,
            #"<img src="local.png" srcset="https://evil.example.invalid/2x.png 2x">"#,
            #"<picture><source srcset="https://evil.example.invalid/a.webp"><img src="local.png"></picture>"#,
            #"<link rel="stylesheet" href="https://evil.example.invalid/a.css">"#,
            #"<link rel=preconnect href=https://evil.example.invalid>"#,
            #"<style>@import "https://evil.example.invalid/a.css";</style>"#,
            #"<style>@IMPORT url(https://evil.example.invalid/a.css);</style>"#,
            #"<style>p { background: URL( 'https://evil.example.invalid/bg.png' ) }</style>"#,
            #"<style>p { background-image: image-set("https://evil.example.invalid/a.png" 1x) }</style>"#,
            #"<style>p { background: u\72l(https://evil.example.invalid/bg.png) }</style>"#,
            #"<style>@font-face { src: url(https://evil.example.invalid/f.woff) }</style>"#,
            #"<svg><style><img src="https://evil.example.invalid/p.gif"></style></svg>"#,
            #"<svg><script><img src="https://evil.example.invalid/p.gif"></script></svg>"#,
            #"<p style="background: url(https://evil.example.invalid/bg.png)">x</p>"#,
            #"<p style="background: u&#114;l(https://evil.example.invalid/bg.png)">x</p>"#,
            #"<body background="https://evil.example.invalid/bg.png">"#,
            #"<table background="https://evil.example.invalid/bg.png"><tr><td>x</td></tr></table>"#,
            #"<video poster="https://evil.example.invalid/p.jpg" src="https://evil.example.invalid/v.mp4"></video>"#,
            #"<audio src="https://evil.example.invalid/a.mp3"></audio>"#,
            #"<input type="image" src="https://evil.example.invalid/b.png">"#,
            #"<iframe src="https://evil.example.invalid/"></iframe>"#,
            #"<frameset><frame src="https://evil.example.invalid/"></frameset>"#,
            #"<object data="https://evil.example.invalid/x.swf"></object>"#,
            #"<embed src="https://evil.example.invalid/x.swf">"#,
            #"<script src="https://evil.example.invalid/a.js"></script>"#,
            #"<base href="https://evil.example.invalid/"><img src="p.gif">"#,
            #"<meta http-equiv="refresh" content="0;url=https://evil.example.invalid/">"#,
            #"<svg><image href="https://evil.example.invalid/i.png"/><use xlink:href="https://evil.example.invalid/s.svg#a"/></svg>"#,
            #"<html manifest="https://evil.example.invalid/m.appcache">"#,
            #"<a href="https://ok.invalid/" ping="https://evil.example.invalid/ping">ok</a>"#,
            #"<!-- <img src="https://evil.example.invalid/c.gif"> -->"#,
            #"<p>text</p><img src="https://evil.example.invalid/eof.gif""#,
        ]
        for html in hostile {
            XCTAssertFalse(local(html).lowercased().contains("evil"), "\(html) → \(local(html))")
        }
    }

    func testSanitizerRejectsLocalFilesOutsideTheFolder() {
        for reference in ["file:///Users/someone/secret.png", "/etc/hosts", "../secret.png", "a/../../secret.png",
                          "%2e%2e/secret.png", ".%2E/secret.png", "..\\secret.png", "C:\\secret.png", "img&period;png&sol;..&sol;..&sol;x"] {
            XCTAssertNil(HTMLSanitizer.localReference(reference, allowRelative: true), reference)
        }
        for reference in ["pic.png", "img/pic%20one.png", "a/../pic.png", "./pic.png", "#section", "pic.png?v=2",
                          "data:image/png;base64,AAAA"] {
            XCTAssertNotNil(HTMLSanitizer.localReference(reference, allowRelative: true), reference)
        }
        XCTAssertNil(HTMLSanitizer.localReference("pic.png", allowRelative: false), "no base folder, no relative files")
    }

    func testSanitizerKeepsOrdinaryMarkup() {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>T &amp; U</title>
        <style>p.note { color: #333; font: 12px Helvetica }</style></head>
        <body class='main'><h1 id=top>Title</h1>
        <p class="note" style="font-weight: bold">Hello <a href="https://example.invalid/x?a=1&amp;b=2" title="go">link</a>
        <a href="javascript:alert(1)">bad</a> <img src="pic.png" alt="A &quot;pic&quot;" width=10><br/>
        <a href="#top">top</a></p><p>2 &lt; 3 and a lone < sign</p></body></html>
        """

        let clean = local(html)

        XCTAssertTrue(clean.hasPrefix(#"<!doctype html><meta http-equiv="x-dns-prefetch-control" content="off"><html>"#), clean)
        for kept in [#"<meta charset="utf-8">"#, "<title>T &amp; U</title>", "p.note { color: #333; font: 12px Helvetica }",
                     #"<body class="main">"#, #"<h1 id="top">"#, #"style="font-weight: bold""#,
                     #"<a href="https://example.invalid/x?a=1&amp;b=2" title="go">link</a>"#,
                     #"<img src="pic.png" alt="A &quot;pic&quot;" width="10">"#, ##"<a href="#top">top</a>"##,
                     "2 &lt; 3 and a lone < sign"] {
            XCTAssertTrue(clean.contains(kept), "lost \(kept): \(clean)")
        }
        XCTAssertTrue(clean.contains("<a>bad</a>"), clean)
        XCTAssertEqual(local("<p>plain</p>"), #"<meta http-equiv="x-dns-prefetch-control" content="off"><p>plain</p>"#)

        let big = String(repeating: "<p class=x>Hello <b>world</b> &amp; <a href='https://example.invalid/'>more</a></p>\n", count: 25_000)
        let start = Date()
        XCTAssertEqual(local(big).components(separatedBy: "<b>world</b>").count - 1, 25_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "2 MB of HTML")
    }

    func testHTMLImportEmbedsOnlyImagesInsideTheFolder() async throws {
        let root = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("img/in.png")
        try Fixtures.png(at: inside, width: 11, height: 11)
        let outside = root.appendingPathComponent("secret.png")
        try Fixtures.png(at: outside, width: 13, height: 13)
        let pixel = try Data(contentsOf: inside)
        let html = """
        <p>a <img src="img/in.png" alt="inside"> b <img src="../secret.png" alt="parent">
        c <img src="\(outside.absoluteString)" alt="absolute"> d <img src="\(outside.path)" alt="path">
        e <img src="data:image/png;base64,\(pixel.base64EncodedString())" alt="inline"></p>
        """

        let rich = try await DocumentSource.html(html, baseURL: folder).attributedString

        XCTAssertEqual(Fixtures.attachmentData(in: rich), [pixel, pixel], "only the in-folder and inline images load")
        for alt in ["parent", "absolute", "path"] {
            XCTAssertTrue(rich.string.contains(alt), "\(alt) should become alt text: \(rich.string)")
        }
    }

    // MARK: - Pathological Markdown

    func testPathologicalMarkdownStaysFast() {
        let inputs: [(String, String)] = [
            ("unclosed brackets", String(repeating: "[a ", count: 20_000)),
            ("unclosed images", String(repeating: "![a ", count: 20_000)),
            ("unmatched closers", String(repeating: "a* ", count: 20_000)),
            ("nested emphasis", String(repeating: "*a ", count: 3_000) + String(repeating: "a* ", count: 3_000)),
            ("bare URL with parens", "see https://example.invalid/" + String(repeating: ")", count: 20_000)),
            ("link brackets in one word", String(repeating: "[a](", count: 5_000)),
        ]
        for (name, markdown) in inputs {
            let start = Date()
            let html = MarkdownRenderer.body(markdown: markdown)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 3, "\(name) took \(elapsed) s")
            Fixtures.assertWellFormedXML(Data("<root>\(html)</root>".utf8), name)
        }
        // Brackets and emphasis pair up exactly as before the speed-ups (also checked by differential fuzzing).
        XCTAssertEqual(MarkdownInline.xhtml("[a [b](u) c"), #"[a <a href="u">b</a> c"#)
        XCTAssertEqual(MarkdownInline.xhtml("[[x]](y) [z](w)"), #"<a href="y">[x]</a> <a href="w">z</a>"#)
        XCTAssertEqual(MarkdownInline.xhtml("![a [b](u)"), #"![a <a href="u">b</a>"#)
        XCTAssertEqual(MarkdownInline.xhtml("*a **b* c**"), "<em>a <em><em>b</em> c</em></em>")
        XCTAssertEqual(MarkdownInline.xhtml("~~~a~~ b~~"), "~<del>a</del> b~~")
    }

    func testDeepNestingIsCappedInsteadOfCrashing() {
        let depth = MarkdownParser.maxNesting
        let quotes = MarkdownRenderer.body(markdown: String(repeating: ">", count: 5_000) + " deep")
        XCTAssertEqual(quotes.components(separatedBy: "<blockquote>").count - 1, depth)
        XCTAssertTrue(quotes.contains("deep"))

        let list = (0..<200).map { String(repeating: "  ", count: $0) + "- item \($0)" }.joined(separator: "\n")
        let renderedList = MarkdownRenderer.body(markdown: list)
        XCTAssertEqual(renderedList.components(separatedBy: "<ul>").count - 1, depth)
        XCTAssertTrue(renderedList.contains("item 199"))
        Fixtures.assertWellFormedXML(Data("<root>\(renderedList)</root>".utf8), "list")

        let emphasis = MarkdownInline.xhtml(String(repeating: "*", count: 5_000) + "x" + String(repeating: "*", count: 5_000))
        XCTAssertLessThanOrEqual(emphasis.components(separatedBy: "<strong>").count - 1, MarkdownInline.maxNesting)
        Fixtures.assertWellFormedXML(Data("<root>\(emphasis)</root>".utf8), "emphasis")
    }
}
