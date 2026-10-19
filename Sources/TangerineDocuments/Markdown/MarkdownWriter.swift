import AppKit

/// Converts rich text (from DOCX, RTF, HTML…) to Markdown.
/// Headings are inferred from font size relative to the body text; lists, tables, code,
/// bold, italic, strikethrough and links are preserved.
enum MarkdownWriter {
    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        let bodySize = dominantFontSize(in: text)
        // `list` is "-" or "1." for list items (top-level marker kind), nil for other blocks.
        var blocks: [(text: String, list: String?)] = []
        var codeLines: [String]?
        var table: (id: ObjectIdentifier, cells: [Int: [Int: String]])?
        var orderedCounters: [Int: Int] = [:]
        // Indents of open marker-text list levels (DOCX import keeps markers as text, without NSTextList).
        var markerIndents: [CGFloat] = []

        func flushCode() {
            guard var lines = codeLines else { return }
            while lines.last?.isEmpty == true { lines.removeLast() }
            let body = lines.joined(separator: "\n")
            let fence = body.contains("```") ? "~~~" : "```"
            blocks.append(("\(fence)\n\(body)\n\(fence)", nil))
            codeLines = nil
        }

        func flushTable() {
            guard let current = table else { return }
            table = nil
            let rows = current.cells.keys.sorted()
            let columnCount = current.cells.values.map { ($0.keys.max() ?? 0) + 1 }.max() ?? 0
            guard columnCount > 0 else { return }
            func row(_ r: Int) -> String {
                let cells = (0..<columnCount).map { current.cells[r]?[$0] ?? "" }
                return "| " + cells.joined(separator: " | ") + " |"
            }
            var lines = [row(rows[0]), "|" + String(repeating: " --- |", count: columnCount)]
            lines += rows.dropFirst().map(row)
            blocks.append((lines.joined(separator: "\n"), nil))
        }

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let paragraph = string.substring(with: range)
            let style = range.length > 0
                ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : nil

            // Table cells arrive as one paragraph per cell.
            if let cellBlock = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                flushCode()
                let id = ObjectIdentifier(cellBlock.table)
                if table?.id != id {
                    flushTable()
                    table = (id, [:])
                }
                // Header cells are bold by convention; don't wrap them in ** markers.
                let cell = inline(text, range: range, ignoreBold: cellBlock.startingRow == 0)
                    .replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: " ")
                let existing = table?.cells[cellBlock.startingRow]?[cellBlock.startingColumn]
                let merged = existing.map { $0.isEmpty ? cell : "\($0) \(cell)" } ?? cell
                table?.cells[cellBlock.startingRow, default: [:]][cellBlock.startingColumn] = merged
                return
            }
            flushTable()

            if paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                if codeLines != nil { codeLines?.append("") }
                return
            }

            let lists = style?.textLists ?? []
            if lists.isEmpty, isMonospaced(text, range: range) {
                if codeLines == nil { codeLines = [] }
                codeLines?.append(paragraph.replacingOccurrences(of: "\u{2028}", with: "\n"))
                return
            }
            flushCode()

            if lists.isEmpty, let marker = textMarker(paragraph) {
                let indent = style?.headIndent ?? 0
                while let last = markerIndents.last, last > indent + 1 { markerIndents.removeLast() }
                if markerIndents.last.map({ indent > $0 + 1 }) ?? true { markerIndents.append(indent) }
                let level = markerIndents.count - 1
                let contentRange = NSRange(location: range.location + marker.length, length: range.length - marker.length)
                let content = inline(text, range: contentRange).trimmingCharacters(in: .whitespaces)
                for deeper in orderedCounters.keys where deeper > level { orderedCounters[deeper] = nil }
                var bullet = "-"
                if marker.ordered {
                    let n = marker.number ?? ((orderedCounters[level] ?? 0) + 1)
                    orderedCounters[level] = n
                    bullet = "\(n)."
                }
                blocks.append((String(repeating: "    ", count: level) + "\(bullet) \(content)",
                               level == 0 ? (marker.ordered ? "1." : "-") : blocks.last?.list ?? "-"))
                return
            }
            markerIndents.removeAll()

            if let list = lists.last {
                let level = lists.count - 1
                let markerLength = listMarkerLength(paragraph)
                let contentRange = NSRange(location: range.location + markerLength, length: range.length - markerLength)
                let content = inline(text, range: contentRange).trimmingCharacters(in: .whitespaces)
                for deeper in orderedCounters.keys where deeper > level { orderedCounters[deeper] = nil }
                let marker: String
                if isOrdered(list) {
                    let n = (orderedCounters[level] ?? (list.startingItemNumber - 1)) + 1
                    orderedCounters[level] = n
                    marker = "\(n)."
                } else {
                    orderedCounters[level] = nil
                    marker = "-"
                }
                blocks.append((String(repeating: "    ", count: level) + "\(marker) \(content)",
                               level == 0 ? (isOrdered(list) ? "1." : "-") : blocks.last?.list ?? "-"))
                return
            }
            orderedCounters.removeAll()

            if let level = headingLevel(text, range: range, bodySize: bodySize) {
                let content = inline(text, range: range, ignoreBold: true).trimmingCharacters(in: .whitespaces)
                blocks.append((String(repeating: "#", count: level) + " " + content, nil))
                return
            }

            let content = inline(text, range: range).trimmingCharacters(in: .whitespaces)
            blocks.append((escapeBlockStart(content), nil))
        }
        flushCode()
        flushTable()

        var out = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                // Items of the same list stay together; a different list kind needs a blank line.
                let previous = blocks[index - 1].list
                out += block.list != nil && block.list == previous ? "\n" : "\n\n"
            }
            out += block.text
        }
        return out.isEmpty ? "" : out + "\n"
    }

    // MARK: - Inline

    private struct Style: Equatable {
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: String?
    }

    private static func inline(_ text: NSAttributedString, range: NSRange, ignoreBold: Bool = false) -> String {
        guard range.length > 0 else { return "" }
        var segments: [(String, Style)] = []
        text.enumerateAttributes(in: range) { attributes, subrange, _ in
            var style = Style()
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                style.bold = traits.contains(.bold) && !ignoreBold
                style.italic = traits.contains(.italic)
                style.code = traits.contains(.monoSpace)
            }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { style.strike = true }
            if let url = attributes[.link] as? URL {
                style.link = url.absoluteString
            } else if let url = attributes[.link] as? String {
                style.link = url
            }
            let piece = (text.string as NSString).substring(with: subrange)
                .replacingOccurrences(of: "\u{FFFC}", with: "") // attachments
            if let last = segments.last, last.1 == style {
                segments[segments.count - 1].0 += piece
            } else {
                segments.append((piece, style))
            }
        }

        var out = ""
        var index = 0
        while index < segments.count {
            // Group consecutive segments that share a link so formatting stays inside the brackets.
            let link = segments[index].1.link
            var group: [(String, Style)] = []
            while index < segments.count, segments[index].1.link == link {
                group.append(segments[index])
                index += 1
            }
            let rendered = group.map { format($0.0, $0.1) }.joined()
            if let link, !rendered.trimmingCharacters(in: .whitespaces).isEmpty {
                out += "[\(rendered)](\(link.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29")))"
            } else {
                out += rendered
            }
        }
        return out.replacingOccurrences(of: "\u{2028}", with: "\\\n")
    }

    private static func format(_ raw: String, _ style: Style) -> String {
        if style.code {
            let ticks = raw.contains("`") ? "``" : "`"
            let padded = raw.hasPrefix("`") || raw.hasSuffix("`") ? " \(raw) " : raw
            return raw.trimmingCharacters(in: .whitespaces).isEmpty ? raw : "\(ticks)\(padded)\(ticks)"
        }
        // Emphasis markers must hug non-space text, so keep surrounding whitespace outside.
        let leading = String(raw.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(raw.reversed().prefix { $0 == " " || $0 == "\t" })
        let core = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !core.isEmpty else { return raw }
        var result = escapeInline(core)
        if style.strike { result = "~~\(result)~~" }
        if style.italic { result = "*\(result)*" }
        if style.bold { result = "**\(result)**" }
        return leading + result + trailing
    }

    // MARK: - Escaping

    /// Escapes characters that would otherwise start inline Markdown syntax.
    static func escapeInline(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]<~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Escapes a line so it can't be read as a heading, quote, list item or rule.
    static func escapeBlockStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        if first == "#" || first == ">" || first == "|" { return "\\" + line }
        if "-+*".contains(first), line.dropFirst().first == " " || line.count == 1 { return "\\" + line }
        if line.allSatisfy({ $0 == "=" || $0 == "-" }) { return "\\" + line }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if let marker = rest.first, marker == "." || marker == ")", rest.dropFirst().first == " " || rest.count == 1 {
                return digits + "\\" + rest
            }
        }
        return line
    }

    /// Markdown for plain text: every line escaped, blank lines kept as paragraph breaks.
    static func escapePlainText(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "" : escapeBlockStart(escapeInline(trimmed))
        }.joined(separator: "\n")
    }

    // MARK: - Analysis

    private static func dominantFontSize(in text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont, !font.fontDescriptor.symbolicTraits.contains(.monoSpace) else { return }
            counts[font.pointSize.rounded(), default: 0] += range.length
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    private static func headingLevel(_ text: NSAttributedString, range: NSRange, bodySize: CGFloat) -> Int? {
        guard range.length > 0, range.length <= 200 else { return nil }
        var minSize = CGFloat.greatestFiniteMagnitude
        var allBold = true
        let string = text.string as NSString
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard !string.substring(with: subrange).trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let font = value as? NSFont
            minSize = min(minSize, font?.pointSize ?? bodySize)
            if !(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false) { allBold = false }
        }
        guard minSize != .greatestFiniteMagnitude, bodySize > 0 else { return nil }
        let ratio = minSize / bodySize
        if ratio >= 1.75 { return 1 }
        if ratio >= 1.4 { return 2 }
        if ratio >= 1.18 { return 3 }
        if ratio >= 1.05, allBold { return 4 }
        return nil
    }

    private static func isMonospaced(_ text: NSAttributedString, range: NSRange) -> Bool {
        var mono = true
        let string = text.string as NSString
        text.enumerateAttribute(.font, in: range) { value, subrange, stop in
            guard !string.substring(with: subrange).trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if !((value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false) {
                mono = false
                stop.pointee = true
            }
        }
        return mono
    }

    /// Length of a leading "\t•\t" / "\t1.\t" marker that AppKit inserts as text for list items.
    private static func listMarkerLength(_ paragraph: String) -> Int {
        let ns = paragraph as NSString
        let regex = try? NSRegularExpression(pattern: #"^\t?[^\t\n]{0,12}\t"#)
        let match = regex?.firstMatch(in: paragraph, range: NSRange(location: 0, length: ns.length))
        return match?.range.length ?? 0
    }

    /// A list marker kept as literal text, e.g. "\t•\titem" or "\t2.\titem".
    private static func textMarker(_ paragraph: String) -> (length: Int, ordered: Bool, number: Int?)? {
        let ns = paragraph as NSString
        let pattern = #"^\t?([•◦▪▫‣⁃●○■□∙·\-–—*]|(\d{1,3})[.)]?|[A-Za-z][.)]|[ivxlcdmIVXLCDM]{1,6}[.)])\t"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: paragraph, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let token = ns.substring(with: match.range(at: 1))
        let ordered = token.first.map { $0.isLetter || $0.isNumber } ?? false
        let digits = match.range(at: 2).location != NSNotFound ? Int(ns.substring(with: match.range(at: 2))) : nil
        return (match.range.length, ordered, digits)
    }

    private static func isOrdered(_ list: NSTextList) -> Bool {
        let format = list.markerFormat.rawValue.lowercased()
        return ["decimal", "alpha", "roman", "latin"].contains { format.contains($0) }
    }
}
