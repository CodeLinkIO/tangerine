import Foundation

/// Inline Markdown: emphasis, code spans, links, images, autolinks, strikethrough and line breaks.
/// Emphasis uses a delimiter stack so the output is always properly nested (well-formed XHTML).
enum MarkdownInline {
    indirect enum Node: Equatable {
        case text(String)
        case element(String, attributes: [Attribute], children: [Node])
        case void(String, attributes: [Attribute])
        case lineBreak
    }

    struct Attribute: Equatable {
        var name: String
        var value: String
    }

    struct Options {
        /// Replace images with their alt text (used for EPUB, where external images aren't packaged).
        var imagesAsText = false
    }

    static func xhtml(_ text: String, options: Options = Options()) -> String {
        render(parse(text), options: options)
    }

    /// Text content with all markup removed.
    static func plainText(_ text: String) -> String {
        plainText(parse(text))
    }

    static func plainText(_ nodes: [Node]) -> String {
        nodes.map { node in
            switch node {
            case let .text(s): s
            case let .element(_, _, children): plainText(children)
            case let .void(_, attributes): attributes.first { $0.name == "alt" }?.value ?? ""
            case .lineBreak: "\n"
            }
        }.joined()
    }

    // MARK: - Rendering

    static func render(_ nodes: [Node], options: Options = Options()) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case let .text(s):
                out += XML.escape(s)
            case let .element(tag, attributes, children):
                out += "<\(tag)\(renderAttributes(attributes))>\(render(children, options: options))</\(tag)>"
            case let .void(tag, attributes):
                if tag == "img", options.imagesAsText {
                    let alt = attributes.first { $0.name == "alt" }?.value ?? ""
                    if !alt.isEmpty { out += "<span class=\"image\">[\(XML.escape(alt))]</span>" }
                } else {
                    out += "<\(tag)\(renderAttributes(attributes))/>"
                }
            case .lineBreak:
                out += "<br/>"
            }
        }
        return out
    }

    private static func renderAttributes(_ attributes: [Attribute]) -> String {
        attributes.map { " \($0.name)=\"\(XML.escape($0.value))\"" }.joined()
    }

    // MARK: - Parsing

    private struct Delimiter {
        var character: Character
        var count: Int
        var canOpen: Bool
        var canClose: Bool
    }

    private enum Token {
        case node(Node)
        case delimiter(Delimiter)
    }

    static func parse(_ text: String, allowLinks: Bool = true) -> [Node] {
        let chars = Array(text)
        var tokens: [Token] = []
        var buffer = ""
        var i = 0
        var links = LinkScan(budget: chars.count * 4 + 1_024)

        func flush() {
            if !buffer.isEmpty {
                tokens.append(.node(.text(buffer)))
                buffer = ""
            }
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count, chars[i + 1] == "\n" {
                    flush()
                    tokens.append(.node(.lineBreak))
                    i += 2
                } else if i + 1 < chars.count, isASCIIPunctuation(chars[i + 1]) {
                    buffer.append(chars[i + 1])
                    i += 2
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "`":
                let run = runLength(chars, at: i, of: "`")
                if let close = findBacktickRun(chars, from: i + run, length: run) {
                    var content = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                       !content.allSatisfy({ $0 == " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    flush()
                    tokens.append(.node(.element("code", attributes: [], children: [.text(content)])))
                    i = close + run
                } else {
                    buffer += String(repeating: "`", count: run)
                    i += run
                }

            case "!" where allowLinks && i + 1 < chars.count && chars[i + 1] == "[":
                if let link = parseLink(chars, at: i + 1, scan: &links) {
                    flush()
                    let alt = plainText(parse(link.label, allowLinks: false))
                    if URLSafety.isSafeImage(link.destination) {
                        var attributes = [Attribute(name: "src", value: link.destination), Attribute(name: "alt", value: alt)]
                        if let title = link.title { attributes.append(Attribute(name: "title", value: title)) }
                        tokens.append(.node(.void("img", attributes: attributes)))
                    } else {
                        tokens.append(.node(.text(alt)))
                    }
                    i = link.end
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "[" where allowLinks:
                if let link = parseLink(chars, at: i, scan: &links) {
                    flush()
                    let label = parse(link.label, allowLinks: false)
                    if URLSafety.isSafeLink(link.destination) {
                        var attributes = [Attribute(name: "href", value: link.destination)]
                        if let title = link.title { attributes.append(Attribute(name: "title", value: title)) }
                        tokens.append(.node(.element("a", attributes: attributes, children: label)))
                    } else {
                        // javascript:, data: and other schemes stay as plain text.
                        tokens.append(contentsOf: label.map(Token.node))
                    }
                    i = link.end
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "<":
                if allowLinks, let (url, end) = parseAutolink(chars, at: i) {
                    flush()
                    let display = url.hasPrefix("mailto:") ? String(url.dropFirst(7)) : url
                    tokens.append(.node(.element("a", attributes: [Attribute(name: "href", value: url)], children: [.text(display)])))
                    i = end
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "h" where allowLinks && (i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)):
                if let (url, end) = parseBareURL(chars, at: i) {
                    flush()
                    tokens.append(.node(.element("a", attributes: [Attribute(name: "href", value: url)], children: [.text(url)])))
                    i = end
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "*", "_", "~":
                let run = runLength(chars, at: i, of: c)
                let before: Character? = i > 0 ? chars[i - 1] : nil
                let after: Character? = i + run < chars.count ? chars[i + run] : nil
                let beforeSpace = before.map(isWhitespace) ?? true
                let afterSpace = after.map(isWhitespace) ?? true
                let beforePunct = before.map(isPunctuation) ?? false
                let afterPunct = after.map(isPunctuation) ?? false
                let leftFlanking = !afterSpace && (!afterPunct || beforeSpace || beforePunct)
                let rightFlanking = !beforeSpace && (!beforePunct || afterSpace || afterPunct)
                var canOpen = leftFlanking
                var canClose = rightFlanking
                if c == "_" {
                    canOpen = leftFlanking && (!rightFlanking || beforePunct)
                    canClose = rightFlanking && (!leftFlanking || afterPunct)
                }
                if c == "~", run < 2 {
                    buffer.append(c)
                    i += 1
                    continue
                }
                flush()
                tokens.append(.delimiter(Delimiter(character: c, count: run, canOpen: canOpen, canClose: canClose)))
                i += run

            case "\n":
                if buffer.hasSuffix("  ") {
                    while buffer.hasSuffix(" ") { buffer.removeLast() }
                    flush()
                    tokens.append(.node(.lineBreak))
                } else {
                    while buffer.hasSuffix(" ") { buffer.removeLast() }
                    buffer.append("\n")
                }
                i += 1
                while i < chars.count, chars[i] == " " { i += 1 }

            default:
                buffer.append(c)
                i += 1
            }
        }
        flush()
        return resolveEmphasis(tokens)
    }

    /// Deeper emphasis is left as literal text so rendering can't exhaust the stack.
    static let maxNesting = 32

    /// Pairs delimiter runs into <em>, <strong> and <del>, innermost first.
    private static func resolveEmphasis(_ input: [Token]) -> [Node] {
        var tokens = input
        var closerIndex = 0
        // Per delimiter character, no usable opener lies below this index (so unmatched closers stay linear).
        var openersBottom: [Character: Int] = [:]
        while closerIndex < tokens.count {
            guard case let .delimiter(closer) = tokens[closerIndex], closer.canClose, closer.count > 0 else {
                closerIndex += 1
                continue
            }
            var openerIndex: Int?
            var j = closerIndex - 1
            while j >= openersBottom[closer.character, default: 0] {
                if case let .delimiter(opener) = tokens[j], opener.character == closer.character,
                   opener.canOpen, opener.count > 0 {
                    if closer.character != "~" || (opener.count >= 2 && closer.count >= 2) {
                        openerIndex = j
                        break
                    }
                }
                j -= 1
            }
            guard let openerIndex, case var .delimiter(opener) = tokens[openerIndex] else {
                // A "~" closer with one tilde left can't match, but a later "~~" still might.
                if closer.character != "~" || closer.count >= 2 { openersBottom[closer.character] = closerIndex }
                closerIndex += 1
                continue
            }
            let children = flatten(Array(tokens[(openerIndex + 1)..<closerIndex]))
            guard nestingDepth(children, limit: maxNesting) < maxNesting else {
                // Openers further down would wrap these same children, so they're too deep as well.
                openersBottom[closer.character] = closerIndex
                closerIndex += 1
                continue
            }
            var closerCopy = closer
            let use: Int
            let tag: String
            if closer.character == "~" {
                use = 2
                tag = "del"
            } else {
                use = opener.count >= 2 && closerCopy.count >= 2 ? 2 : 1
                tag = use == 2 ? "strong" : "em"
            }
            opener.count -= use
            closerCopy.count -= use
            tokens.replaceSubrange((openerIndex + 1)..<closerIndex,
                                   with: [.node(.element(tag, attributes: [], children: children))])
            tokens[openerIndex] = .delimiter(opener)
            // Keep the bottoms pointing at the same tokens after the collapse.
            let shift = closerIndex - (openerIndex + 2)
            for (character, bottom) in openersBottom where bottom > openerIndex {
                openersBottom[character] = bottom >= closerIndex ? bottom - shift : openerIndex + 1
            }
            closerIndex = openerIndex + 2
            tokens[closerIndex] = .delimiter(closerCopy)
            // Re-examine the same closer if it still has delimiters left.
        }
        return mergeText(flatten(tokens))
    }

    /// How deeply elements nest in `nodes`, counting at most `limit` levels.
    private static func nestingDepth(_ nodes: [Node], limit: Int) -> Int {
        var deepest = 0
        for case let .element(_, _, children) in nodes {
            deepest = max(deepest, 1 + (limit > 1 ? nestingDepth(children, limit: limit - 1) : 0))
            if deepest >= limit { break }
        }
        return deepest
    }

    private static func flatten(_ tokens: [Token]) -> [Node] {
        tokens.compactMap { token in
            switch token {
            case let .node(node): node
            case let .delimiter(d): d.count > 0 ? .text(String(repeating: d.character, count: d.count)) : nil
            }
        }
    }

    private static func mergeText(_ nodes: [Node]) -> [Node] {
        var result: [Node] = []
        for node in nodes {
            if case let .text(s) = node, case let .text(previous)? = result.last {
                result[result.count - 1] = .text(previous + s)
            } else {
                result.append(node)
            }
        }
        return result
    }

    // MARK: - Links

    private struct ParsedLink {
        var label: String
        var destination: String
        var title: String?
        var end: Int
    }

    /// Link-parsing state shared by every `[` in one run of text.
    private struct LinkScan {
        /// Memoized bracket matches (see `closingBracket`).
        var brackets: [Int: Int] = [:]
        /// Characters left for scanning destinations and titles. Successful links consume what they scan, so
        /// only text crafted to fail over and over (e.g. "[a](" repeated in one long word) runs out; its
        /// remaining brackets then stay literal instead of taking quadratic time.
        var budget: Int
    }

    /// Parses `[label](destination "title")` starting at the opening bracket.
    private static func parseLink(_ chars: [Character], at start: Int, scan: inout LinkScan) -> ParsedLink? {
        guard scan.budget > 0, chars[start] == "[", let close = closingBracket(chars, from: start, memo: &scan.brackets),
              close + 1 < chars.count, chars[close + 1] == "(" else { return nil }
        var j = close + 2
        defer { scan.budget -= j - close }
        while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
        var destination = ""
        if j < chars.count, chars[j] == "<" {
            j += 1
            while j < chars.count, chars[j] != ">" {
                if chars[j] == "\n" { return nil }
                destination.append(chars[j])
                j += 1
            }
            guard j < chars.count else { return nil }
            j += 1
        } else {
            var parens = 0
            while j < chars.count {
                let c = chars[j]
                if c == " " || c == "\n" { break }
                if c == "(" { parens += 1 }
                if c == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                if c == "\\", j + 1 < chars.count, isASCIIPunctuation(chars[j + 1]) {
                    destination.append(chars[j + 1])
                    j += 2
                    continue
                }
                destination.append(c)
                j += 1
            }
        }
        while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
        var title: String?
        if j < chars.count, chars[j] == "\"" || chars[j] == "'" || chars[j] == "(" {
            let closing: Character = chars[j] == "(" ? ")" : chars[j]
            j += 1
            var t = ""
            while j < chars.count, chars[j] != closing {
                t.append(chars[j])
                j += 1
            }
            guard j < chars.count else { return nil }
            title = t
            j += 1
            while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        return ParsedLink(label: String(chars[(start + 1)..<close]), destination: destination, title: title, end: j + 1)
    }

    /// The "]" matching the "[" at `start`, skipping escapes and code spans. Every bracket the scan passes is
    /// matched too and memoized (-1 when unmatched), so a paragraph full of unclosed brackets is scanned once
    /// instead of once per bracket. A later scan from a memoized "[" would see exactly the same characters.
    private static func closingBracket(_ chars: [Character], from start: Int, memo: inout [Int: Int]) -> Int? {
        if let known = memo[start] { return known < 0 ? nil : known }
        var open: [Int] = []
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "`" {
                let run = runLength(chars, at: i, of: "`")
                if let end = findBacktickRun(chars, from: i + run, length: run) { i = end + run; continue }
                i += run
                continue
            }
            if c == "[" { open.append(i) }
            if c == "]", let opener = open.popLast() {
                memo[opener] = i
                if open.isEmpty { return i }
            }
            i += 1
        }
        for opener in open { memo[opener] = -1 }
        return nil
    }

    private static func parseAutolink(_ chars: [Character], at start: Int) -> (String, Int)? {
        var j = start + 1
        var url = ""
        while j < chars.count, chars[j] != ">" {
            if chars[j] == " " || chars[j] == "<" || chars[j] == "\n" { return nil }
            url.append(chars[j])
            j += 1
        }
        guard j < chars.count else { return nil }
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            return (url, j + 1)
        }
        if url.contains("@"), !url.contains(":"), url.split(separator: "@").count == 2 {
            return ("mailto:" + url, j + 1)
        }
        return nil
    }

    private static func parseBareURL(_ chars: [Character], at start: Int) -> (String, Int)? {
        let prefix = String(chars[start..<min(chars.count, start + 8)]).lowercased()
        guard prefix.hasPrefix("http://") || prefix.hasPrefix("https://") else { return nil }
        var j = start
        while j < chars.count, !isWhitespace(chars[j]), chars[j] != "<" { j += 1 }
        // Trailing punctuation belongs to the sentence, not the URL.
        var unmatchedClosers = chars[start..<j].reduce(0) { $0 + ($1 == ")" ? 1 : $1 == "(" ? -1 : 0) }
        while j > start, ".,;:!?'\")]*_~".contains(chars[j - 1]) {
            if chars[j - 1] == ")" {
                if unmatchedClosers <= 0 { break }
                unmatchedClosers -= 1
            }
            j -= 1
        }
        let url = String(chars[start..<j])
        guard url.count > prefix.prefix(while: { $0 != "/" }).count + 3 else { return nil }
        return (url, j)
    }

    // MARK: - Character helpers

    private static func runLength(_ chars: [Character], at start: Int, of c: Character) -> Int {
        var n = 0
        while start + n < chars.count, chars[start + n] == c { n += 1 }
        return n
    }

    private static func findBacktickRun(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                let run = runLength(chars, at: i, of: "`")
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func isWhitespace(_ c: Character) -> Bool {
        c.isWhitespace
    }

    private static func isPunctuation(_ c: Character) -> Bool {
        c.isPunctuation || c.isSymbol
    }

    static func isASCIIPunctuation(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        return (33...47).contains(ascii) || (58...64).contains(ascii) || (91...96).contains(ascii) || (123...126).contains(ascii)
    }
}

/// XML escaping that also drops characters XML 1.0 forbids (form feeds from PDFs, NULs…).
enum XML {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                let v = scalar.value
                let allowed = v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v)
                    || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
                if allowed { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
