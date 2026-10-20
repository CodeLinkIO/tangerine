import Foundation

/// Block-level Markdown tree for the GitHub-flavored subset we support.
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]], tight: Bool)
    case rule
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    /// Pre-rendered, already-escaped XHTML (used for plain text sources).
    case rawXHTML(String)
}

enum TableAlignment: Equatable {
    case none, left, center, right
}

/// Parses Markdown source into blocks. Inline syntax is handled later by `MarkdownInline`.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map(expandLeadingTabs)
        return parseBlocks(lines[...])
    }

    // MARK: - Blocks

    /// Quotes and lists nested deeper than this read as paragraphs, so hostile input can't exhaust the stack.
    static let maxNesting = 32

    static func parseBlocks(_ lines: ArraySlice<String>, depth: Int = 0) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var i = lines.startIndex
        let end = lines.endIndex

        while i < end {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }

            // Indented code block.
            if indentation(line) >= 4 {
                var code: [String] = []
                while i < end, isBlank(lines[i]) || indentation(lines[i]) >= 4 {
                    code.append(isBlank(lines[i]) ? "" : String(lines[i].dropFirst(4)))
                    i += 1
                }
                while code.last == "" { code.removeLast() }
                blocks.append(.code(language: nil, text: code.joined(separator: "\n")))
                continue
            }

            if let fence = openingFence(line) {
                i += 1
                var code: [String] = []
                while i < end {
                    if isClosingFence(lines[i], for: fence) { i += 1; break }
                    code.append(removeIndentation(lines[i], upTo: fence.indent))
                    i += 1
                }
                blocks.append(.code(language: fence.info.isEmpty ? nil : fence.info, text: code.joined(separator: "\n")))
                continue
            }

            if let heading = atxHeading(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            if isRule(line) {
                blocks.append(.rule)
                i += 1
                continue
            }

            if depth < maxNesting, isQuote(line) {
                var inner: [String] = []
                while i < end, !isBlank(lines[i]) {
                    if isQuote(lines[i]) {
                        inner.append(stripQuoteMarker(lines[i]))
                    } else if !inner.isEmpty, !startsBlock(lines[i], interruptingParagraph: true) {
                        inner.append(lines[i]) // lazy continuation
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.quote(parseBlocks(inner[...], depth: depth + 1)))
                continue
            }

            if depth < maxNesting, let marker = listMarker(line) {
                let (list, next) = parseList(lines, from: i, first: marker, depth: depth)
                blocks.append(list)
                i = next
                continue
            }

            if i + 1 < end, line.contains("|"), let alignments = tableDelimiter(lines[i + 1]) {
                let header = splitTableRow(line)
                if header.count == alignments.count {
                    i += 2
                    var rows: [[String]] = []
                    while i < end, !isBlank(lines[i]), lines[i].contains("|") {
                        var cells = splitTableRow(lines[i])
                        if cells.count < header.count {
                            cells += Array(repeating: "", count: header.count - cells.count)
                        }
                        rows.append(Array(cells.prefix(header.count)))
                        i += 1
                    }
                    blocks.append(.table(header: header, alignments: alignments, rows: rows))
                    continue
                }
            }

            // Paragraph, possibly turned into a setext heading.
            var paragraph = [trimLeading(line)]
            i += 1
            var setextLevel: Int?
            while i < end {
                let next = lines[i]
                if isBlank(next) { break }
                if let level = setextUnderline(next) {
                    setextLevel = level
                    i += 1
                    break
                }
                if startsBlock(next, interruptingParagraph: true) { break }
                paragraph.append(trimLeading(next))
                i += 1
            }
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            if let setextLevel {
                blocks.append(.heading(level: setextLevel, text: text))
            } else {
                blocks.append(.paragraph(text))
            }
        }
        return blocks
    }

    // MARK: - Lists

    struct ListMarker {
        var indent: Int
        var ordered: Bool
        /// Bullet character or ordered delimiter ("." or ")").
        var symbol: Character
        var start: Int
        var contentIndent: Int
        var content: String
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let chars = Array(line)
        var j = indent
        guard j < chars.count else { return nil }
        var ordered = false
        var symbol: Character
        var start = 1
        if "-+*".contains(chars[j]) {
            symbol = chars[j]
            j += 1
        } else {
            var digits = ""
            while j < chars.count, chars[j].isASCII, chars[j].isNumber, digits.count < 9 {
                digits.append(chars[j])
                j += 1
            }
            guard !digits.isEmpty, j < chars.count, chars[j] == "." || chars[j] == ")" else { return nil }
            symbol = chars[j]
            ordered = true
            start = Int(digits) ?? 1
            j += 1
        }
        let markerEnd = j
        if j == chars.count {
            return ListMarker(indent: indent, ordered: ordered, symbol: symbol, start: start,
                              contentIndent: markerEnd + 1, content: "")
        }
        guard chars[j] == " " else { return nil }
        var spaces = 0
        while j < chars.count, chars[j] == " " { spaces += 1; j += 1 }
        if j == chars.count || spaces > 4 { spaces = 1 }
        let content = String(chars[min(markerEnd + spaces, chars.count)...])
        return ListMarker(indent: indent, ordered: ordered, symbol: symbol, start: start,
                          contentIndent: markerEnd + spaces, content: content)
    }

    private static func parseList(_ lines: ArraySlice<String>, from start: Int, first: ListMarker, depth: Int) -> (MarkdownBlock, Int) {
        var items: [[MarkdownBlock]] = []
        var tight = true
        var i = start
        var current = first

        while true {
            var itemLines = [current.content]
            var previousBlank = current.content.isEmpty
            i += 1
            while i < lines.endIndex {
                let line = lines[i]
                if isBlank(line) {
                    itemLines.append("")
                    previousBlank = true
                    i += 1
                    continue
                }
                let indent = indentation(line)
                if indent >= current.contentIndent {
                    itemLines.append(String(line.dropFirst(current.contentIndent)))
                } else if listMarker(line) != nil, indent > current.indent {
                    // Sloppy nesting (e.g. two spaces under "1."): still a child of this item.
                    itemLines.append(String(line.dropFirst(indent)))
                } else if !previousBlank, listMarker(line) == nil, !startsBlock(line, interruptingParagraph: true) {
                    itemLines.append(trimLeading(line)) // lazy continuation
                } else {
                    break
                }
                previousBlank = false
                i += 1
            }
            var trailingBlanks = 0
            while itemLines.count > 1, itemLines.last == "" {
                itemLines.removeLast()
                trailingBlanks += 1
            }
            if itemLines.dropFirst().contains(""), containsBlankBetweenBlocks(itemLines) { tight = false }
            items.append(parseBlocks(itemLines[...], depth: depth + 1))

            guard i < lines.endIndex, let next = listMarker(lines[i]),
                  next.ordered == first.ordered, next.symbol == first.symbol,
                  next.indent < current.contentIndent
            else { break }
            if trailingBlanks > 0 { tight = false }
            current = next
        }
        return (.list(ordered: first.ordered, start: first.start, items: items, tight: tight), i)
    }

    /// Blank lines inside fenced code don't make a list loose.
    private static func containsBlankBetweenBlocks(_ lines: [String]) -> Bool {
        var inFence: Fence?
        for line in lines {
            if let fence = inFence {
                if isClosingFence(line, for: fence) { inFence = nil }
                continue
            }
            if let fence = openingFence(line) { inFence = fence; continue }
            if isBlank(line) { return true }
        }
        return false
    }

    // MARK: - Line classification

    static func startsBlock(_ line: String, interruptingParagraph: Bool) -> Bool {
        if openingFence(line) != nil || atxHeading(line) != nil || isRule(line) || isQuote(line) { return true }
        if let marker = listMarker(line) {
            if !interruptingParagraph { return true }
            return !marker.content.trimmingCharacters(in: .whitespaces).isEmpty && (!marker.ordered || marker.start == 1)
        }
        return false
    }

    struct Fence {
        var character: Character
        var length: Int
        var indent: Int
        var info: String
    }

    static func openingFence(_ line: String) -> Fence? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix { $0 == first }.count
        guard run >= 3 else { return nil }
        let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init) ?? ""
        return Fence(character: first, length: run, indent: indent, info: language)
    }

    static func isClosingFence(_ line: String, for fence: Fence) -> Bool {
        let indent = indentation(line)
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let run = rest.prefix { $0 == fence.character }.count
        return run >= fence.length && rest.dropFirst(run).allSatisfy { $0 == " " }
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: "## Title ##".
        if let range = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    static func isRule(_ line: String) -> Bool {
        let indent = indentation(line)
        guard indent <= 3 else { return false }
        let compact = line.filter { $0 != " " }
        guard let first = compact.first, "-*_".contains(first), compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func setextUnderline(_ line: String) -> Int? {
        guard indentation(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "=" || first == "-" else { return nil }
        guard trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    static func isQuote(_ line: String) -> Bool {
        indentation(line) <= 3 && line.drop(while: { $0 == " " }).first == ">"
    }

    static func stripQuoteMarker(_ line: String) -> String {
        var rest = line.drop(while: { $0 == " " }).dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    // MARK: - Tables

    static func tableDelimiter(_ line: String) -> [TableAlignment]? {
        let cells = splitTableRow(line)
        guard !cells.isEmpty, line.contains("-") else { return nil }
        var alignments: [TableAlignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            alignments.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return alignments
    }

    /// Splits "| a | b |" into ["a", "b"], honoring backslash-escaped pipes and code spans.
    static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for ch in trimmed {
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode, previous != "\\" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if ch == "|", previous == "\\" {
                current.removeLast()
                current.append(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Helpers

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    static func trimLeading(_ line: String) -> String {
        String(line.drop(while: { $0 == " " }))
    }

    static func removeIndentation(_ line: String, upTo count: Int) -> String {
        String(line.dropFirst(min(count, indentation(line))))
    }

    /// Expands tabs in leading whitespace to 4-column tab stops.
    static func expandLeadingTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var result = ""
        var column = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            if line[index] == "\t" {
                let spaces = 4 - column % 4
                result += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                result.append(" ")
                column += 1
            }
            index = line.index(after: index)
        }
        return result + line[index...]
    }
}
