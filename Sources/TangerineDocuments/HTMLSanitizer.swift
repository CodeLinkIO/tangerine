import Foundation
import TangerineCore

/// Rewrites HTML so AppKit's WebKit-backed importer can't reach the network or read files outside the
/// document's folder. Depending on the macOS version the importer can fetch remote images, stylesheets and
/// frames (blocking up to its timeout), it embeds any `file:` image, and it ignores Content-Security-Policy,
/// so references are neutralized before import:
/// - `<script>`, `<iframe>`, `<frame>`, `<object>`, `<embed>`, `<applet>`, `<link>`, `<base>` and
///   `<meta http-equiv>` are removed, as are comments, event handlers, `srcset` and CSS `@import`.
/// - Fetching attributes (`src`, `background`, `poster`, `href` outside links…) and CSS `url()` keep only
///   references `resolve` returns; a rejected image becomes its alt text.
/// - Link targets keep only http(s), mailto, relative paths and #anchors (see `URLSafety`).
enum HTMLSanitizer {
    /// Sanitizes `html`. `resolve` receives each fetchable reference as written (character references may
    /// still be encoded) and returns the reference to load instead, or nil to drop it.
    static func sanitize(_ html: String, resolve: (String) -> String?) -> String {
        let b = Array(html.utf8)
        let n = b.count
        var out: [UInt8] = []
        out.reserveCapacity(n + 128)
        // WebKit prefetches DNS for link hosts unless told not to. The tag goes after any doctype, which
        // must come first to keep the document out of quirks mode.
        var pendingMeta = true
        func emit<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            if pendingMeta {
                out += Array(#"<meta http-equiv="x-dns-prefetch-control" content="off">"#.utf8)
                pendingMeta = false
            }
            out += bytes
        }
        var i = 0
        while i < n {
            guard b[i] == UInt8(ascii: "<"), i + 1 < n else {
                // Text runs up to the next "<" are copied as they are.
                var end = i + 1
                while end < n, b[end] != UInt8(ascii: "<") { end += 1 }
                if pendingMeta, b[i..<end].allSatisfy(isSpace) { out += b[i..<end] } else { emit(b[i..<end]) }
                i = end
                continue
            }
            let next = b[i + 1]
            if next == UInt8(ascii: "!") {
                if starts(b, "<!--", at: i) {
                    i = commentEnd(b, from: i + 4)
                } else {
                    // Doctype or bogus comment: never markup, ends at the first ">".
                    let end = (index(of: UInt8(ascii: ">"), in: b, from: i) ?? n - 1) + 1
                    if starts(b, "<!doctype", at: i) { out += b[i..<end] }
                    i = end
                    if pendingMeta { emit([]) }
                }
                continue
            }
            if next == UInt8(ascii: "?") {
                i = (index(of: UInt8(ascii: ">"), in: b, from: i) ?? n - 1) + 1
                continue
            }
            let isEndTag = next == UInt8(ascii: "/")
            let nameStart = isEndTag ? i + 2 : i + 1
            guard nameStart < n, isLetter(b[nameStart]) else {
                if isEndTag {
                    // "</>" is ignored and "</ junk>" is a bogus comment.
                    i = (index(of: UInt8(ascii: ">"), in: b, from: i) ?? n - 1) + 1
                } else {
                    emit(CollectionOfOne(b[i])) // a literal "<"
                    i += 1
                }
                continue
            }
            // A tag cut off by the end of the file is dropped, as browsers do.
            guard let tag = parseTag(b, nameStart: nameStart) else { break }
            i = tag.end
            let name = tag.name.lowercased()
            if Self.removedElements.contains(name) || (name == "meta" && tag.has("http-equiv")) { continue }
            if isEndTag {
                emit("</\(tag.name)>".utf8)
                continue
            }
            if name == "script" {
                i = rawTextEnd(b, from: i, tag: "script").after
                continue
            }
            if name == "img", let src = tag.value("src"), resolve(src) == nil {
                let alt = tag.value("alt") ?? ""
                emit(alt.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").utf8)
                continue
            }
            emit(rebuild(tag, resolve: resolve).utf8)
            if name == "style" {
                let end = rawTextEnd(b, from: i, tag: "style")
                out += Array(sanitizeCSS(String(decoding: b[i..<end.contentEnd], as: UTF8.self), resolve: resolve).utf8)
                out += Array("</style>".utf8)
                i = end.after
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The policy for documents on disk: `data:` URLs, #anchors and, when there's a base folder, relative
    /// paths that stay inside it. Remote, protocol-relative, absolute-path and `file:` references are rejected.
    static func localReference(_ reference: String, allowRelative: Bool) -> String? {
        guard let value = decodeEntities(reference).map(URLSafety.compact), !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("data:") || value.hasPrefix("#") { return value }
        guard allowRelative, !value.hasPrefix("/"), !value.hasPrefix("\\") else { return nil }
        let path = value.prefix { $0 != "?" && $0 != "#" }
        guard !path.contains(":") else { return nil }
        // WebKit decodes %2e and treats "\" as "/", so check the path the way it will be resolved.
        let decoded = (String(path).removingPercentEncoding ?? String(path)).replacingOccurrences(of: "\\", with: "/")
        var depth = 0
        for segment in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            if segment == ".." {
                depth -= 1
                if depth < 0 { return nil }
            } else if segment != ".", !segment.isEmpty {
                depth += 1
            }
        }
        return value
    }

    // MARK: - Tags

    private static let removedElements: Set<String> = [
        "iframe", "frame", "frameset", "object", "embed", "applet", "param", "link", "base", "portal",
    ]
    /// Attributes that make the importer fetch something.
    private static let fetchingAttributes: Set<String> = [
        "src", "background", "poster", "data", "lowsrc", "dynsrc", "manifest", "codebase", "archive",
        "classid", "profile", "icon",
    ]
    private static let droppedAttributes: Set<String> = ["srcset", "imagesrcset", "ping", "attributionsrc"]

    struct Tag {
        var name: String
        /// Names as written (they're matched case-insensitively) and raw, still entity-encoded values.
        var attributes: [(name: String, value: String)]
        var selfClosing: Bool
        var end: Int

        func has(_ attribute: String) -> Bool {
            attributes.contains { $0.name.lowercased() == attribute }
        }

        func value(_ attribute: String) -> String? {
            attributes.first { $0.name.lowercased() == attribute }?.value
        }
    }

    /// Tokenizes a tag following the HTML spec's tag states (quotes may hide ">", "/" separates attributes).
    /// Returns nil when the input ends inside the tag.
    static func parseTag(_ b: [UInt8], nameStart: Int) -> Tag? {
        let n = b.count
        var i = nameStart
        while i < n, !isSpace(b[i]), b[i] != UInt8(ascii: "/"), b[i] != UInt8(ascii: ">") { i += 1 }
        var tag = Tag(name: String(decoding: b[nameStart..<i], as: UTF8.self), attributes: [], selfClosing: false, end: n)
        while true {
            while i < n, isSpace(b[i]) { i += 1 }
            guard i < n else { return nil }
            if b[i] == UInt8(ascii: ">") {
                tag.end = i + 1
                return tag
            }
            if b[i] == UInt8(ascii: "/") {
                i += 1
                if i < n, b[i] == UInt8(ascii: ">") {
                    tag.selfClosing = true
                    tag.end = i + 1
                    return tag
                }
                continue
            }
            let nameStart = i
            i += 1 // the first character can be "=" (a parse error that browsers keep in the name)
            while i < n, !isSpace(b[i]), b[i] != UInt8(ascii: "/"), b[i] != UInt8(ascii: ">"), b[i] != UInt8(ascii: "=") { i += 1 }
            let name = String(decoding: b[nameStart..<i], as: UTF8.self)
            while i < n, isSpace(b[i]) { i += 1 }
            guard i < n else { return nil }
            var value = ""
            if b[i] == UInt8(ascii: "=") {
                i += 1
                while i < n, isSpace(b[i]) { i += 1 }
                guard i < n else { return nil }
                if b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'") {
                    guard let close = index(of: b[i], in: b, from: i + 1) else { return nil }
                    value = String(decoding: b[(i + 1)..<close], as: UTF8.self)
                    i = close + 1
                } else {
                    let start = i
                    while i < n, !isSpace(b[i]), b[i] != UInt8(ascii: ">") { i += 1 }
                    value = String(decoding: b[start..<i], as: UTF8.self)
                }
            }
            tag.attributes.append((name, value))
        }
    }

    private static func rebuild(_ tag: Tag, resolve: (String) -> String?) -> String {
        let name = tag.name.lowercased()
        let isLink = name == "a" || name == "area"
        var out = "<" + tag.name
        for (attribute, value) in tag.attributes {
            let key = attribute.lowercased()
            var kept: String?
            if key.hasPrefix("on") || droppedAttributes.contains(key) {
                kept = nil
            } else if key == "href" || key == "xlink:href" {
                if isLink {
                    kept = decodeEntities(value).flatMap { URLSafety.isSafeLink($0) ? $0 : nil }.map(escapeAttribute)
                } else {
                    kept = resolve(value).map(escapeAttribute)
                }
            } else if fetchingAttributes.contains(key) {
                kept = resolve(value).map(escapeAttribute)
            } else if key == "style" {
                // Browsers decode character references before parsing the CSS ("u&#114;l(" is "url(").
                let css = decodeEntities(value).map { sanitizeCSS($0, resolve: resolve) } ?? ""
                kept = css.isEmpty ? nil : escapeAttribute(css)
            } else {
                kept = value.replacingOccurrences(of: "\"", with: "&quot;")
            }
            if let kept { out += " \(attribute)=\"\(kept)\"" }
        }
        return out + (tag.selfClosing ? "/>" : ">")
    }

    // MARK: - CSS

    /// Drops `@import` and `image-set()`, and keeps `url()` only for references `resolve` accepts.
    static func sanitizeCSS(_ css: String, resolve: (String) -> String?) -> String {
        // "<!--" and "-->" are ignorable CSS tokens; any other "<" (markup inside SVG styles) or escape
        // sequence could hide something from this scan, so such styles are dropped whole.
        let text = css.replacingOccurrences(of: "<!--", with: " ").replacingOccurrences(of: "-->", with: " ")
        let lower = text.lowercased()
        guard !text.contains("<"), !text.contains("\\"), !lower.contains("image-set("), !lower.contains("image(") else {
            return ""
        }
        var out = ""
        var rest = Substring(text)
        while let match = rest.range(of: #"@import|url\("#, options: [.regularExpression, .caseInsensitive]) {
            out += rest[..<match.lowerBound]
            if rest[match].lowercased() == "@import" {
                rest = rest[match.upperBound...].drop { $0 != ";" }.dropFirst()
                continue
            }
            var argument = rest[match.upperBound...].drop { $0 == " " }
            var reference: Substring
            if let quote = argument.first, quote == "\"" || quote == "'" {
                argument = argument.dropFirst()
                reference = argument.prefix { $0 != quote }
                argument = argument.dropFirst(reference.count + 1)
            } else {
                reference = argument.prefix { $0 != ")" }
                argument = argument.dropFirst(reference.count)
            }
            rest = argument.drop { $0 != ")" }.dropFirst()
            reference = reference.trimmingCharacters(in: .whitespaces)[...]
            if let kept = resolve(String(reference)) {
                out += "url(\"\(kept.replacingOccurrences(of: "\"", with: "%22"))\")"
            } else {
                out += "none"
            }
        }
        return out + rest
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "colon": ":", "sol": "/", "bsol": "\\",
        "period": ".", "percnt": "%", "num": "#", "quest": "?", "excl": "!", "commat": "@", "lpar": "(",
        "rpar": ")", "equals": "=", "plus": "+", "comma": ",", "semi": ";", "lowbar": "_", "hyphen": "-",
        "dash": "-", "Tab": "\t", "NewLine": "\n", "nbsp": "\u{A0}",
    ]

    /// Decodes character references in an attribute value. Returns nil for named references this table
    /// doesn't know, so callers treat them as unsafe rather than guessing what a browser would see.
    static func decodeEntities(_ value: String) -> String? {
        guard value.contains("&") else { return value }
        var out = ""
        var rest = Substring(value)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if after.first == "#" {
                let body = after.dropFirst()
                let hex = body.first == "x" || body.first == "X"
                let digits = (hex ? body.dropFirst() : body).prefix { hex ? $0.isHexDigit : $0.isASCII && $0.isNumber }
                if !digits.isEmpty {
                    let value = UInt32(digits.prefix(8), radix: hex ? 16 : 10) ?? 0xFFFD
                    out.unicodeScalars.append(Unicode.Scalar(value).flatMap { $0.value == 0 ? nil : $0 } ?? "\u{FFFD}")
                    var tail = (hex ? body.dropFirst() : body).dropFirst(digits.count)
                    if tail.first == ";" { tail = tail.dropFirst() }
                    rest = tail
                    continue
                }
            } else {
                let name = after.prefix { $0.isLetter || $0.isNumber }
                if !name.isEmpty, after.dropFirst(name.count).first == ";" {
                    guard let decoded = namedEntities[String(name)] else { return nil }
                    out += decoded
                    rest = after.dropFirst(name.count + 1)
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: - Scanning helpers

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D
    }

    private static func isLetter(_ c: UInt8) -> Bool {
        (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
    }

    private static func index(of byte: UInt8, in b: [UInt8], from start: Int) -> Int? {
        var i = start
        while i < b.count {
            if b[i] == byte { return i }
            i += 1
        }
        return nil
    }

    /// Case-insensitive ASCII prefix match.
    private static func starts(_ b: [UInt8], _ prefix: String, at start: Int) -> Bool {
        let p = Array(prefix.utf8)
        guard start + p.count <= b.count else { return false }
        for k in 0..<p.count where b[start + k] | 0x20 != p[k] | 0x20 { return false }
        return true
    }

    /// End of a comment whose body starts at `start`: after "-->" or "--!>" (or "<!-->" / "<!--->").
    private static func commentEnd(_ b: [UInt8], from start: Int) -> Int {
        if starts(b, ">", at: start) { return start + 1 }
        if starts(b, "->", at: start) { return start + 2 }
        var i = start
        while i < b.count {
            if starts(b, "-->", at: i) { return i + 3 }
            if starts(b, "--!>", at: i) { return i + 4 }
            i += 1
        }
        return b.count
    }

    /// Where the raw text of a `<script>` or `<style>` element ends: the first "</tag" followed by a
    /// space, "/" or ">", and the index after that end tag.
    private static func rawTextEnd(_ b: [UInt8], from start: Int, tag: String) -> (contentEnd: Int, after: Int) {
        let closer = "</" + tag
        var i = start
        while i < b.count {
            if b[i] == UInt8(ascii: "<"), starts(b, closer, at: i) {
                let k = i + closer.utf8.count
                if k >= b.count || isSpace(b[k]) || b[k] == UInt8(ascii: "/") || b[k] == UInt8(ascii: ">") {
                    return (i, parseTag(b, nameStart: i + 2)?.end ?? b.count)
                }
            }
            i += 1
        }
        return (b.count, b.count)
    }
}

/// Which link and image targets are safe to emit in generated HTML and EPUB.
enum URLSafety {
    /// The URL as browsers read it: ASCII tabs and newlines removed, leading and trailing controls and
    /// spaces trimmed.
    static func compact(_ url: String) -> String {
        let scalars = url.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"..."\u{20}"))
    }

    /// The lowercased scheme, or nil for relative references (a ":" after "/", "?" or "#" isn't a scheme).
    static func scheme(of url: String) -> String? {
        let value = compact(url)
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let candidate = value[..<colon]
        guard !candidate.contains(where: { "/?#".contains($0) }) else { return nil }
        return candidate.lowercased()
    }

    /// http(s), mailto, relative paths and #anchors. Everything else (javascript:, vbscript:, data:,
    /// file:…) is rendered as plain text.
    static func isSafeLink(_ url: String) -> Bool {
        guard let scheme = scheme(of: url) else { return true }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    /// Like links (without mailto), plus inline PNG, JPEG, GIF and WebP `data:` images, which can't run script.
    static func isSafeImage(_ url: String) -> Bool {
        guard let scheme = scheme(of: url) else { return true }
        if scheme == "data" {
            let value = compact(url).lowercased()
            return ["data:image/png", "data:image/jpeg", "data:image/gif", "data:image/webp"].contains { value.hasPrefix($0) }
        }
        return scheme == "http" || scheme == "https"
    }
}

/// Reads Safari web archives without WebKit fetching anything: archived images are inlined as `data:` URLs
/// and every other reference is removed.
enum WebArchive {
    static func html(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any],
              let body = main["WebResourceData"] as? Data
        else { throw ConversionError.unreadable(url) }
        var encoding = String.Encoding.utf8
        if let name = main["WebResourceTextEncodingName"] as? String {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        let text = String(data: body, encoding: encoding) ?? String(decoding: body, as: UTF8.self)
        switch (main["WebResourceMIMEType"] as? String)?.lowercased() {
        case "text/plain"?: return "<pre>\(XML.escape(text))</pre>"
        case nil, "text/html"?, "application/xhtml+xml"?: break
        default: throw ConversionError.unreadable(url) // an archived image or PDF, not a page
        }
        let page = (main["WebResourceURL"] as? String).flatMap(URL.init(string:))
        var images: [String: String] = [:]
        for resource in plist["WebSubresources"] as? [[String: Any]] ?? [] {
            guard let address = resource["WebResourceURL"] as? String,
                  let type = resource["WebResourceMIMEType"] as? String, type.lowercased().hasPrefix("image/"),
                  let bytes = resource["WebResourceData"] as? Data
            else { continue }
            images[address] = "data:\(type);base64,\(bytes.base64EncodedString())"
        }
        return HTMLSanitizer.sanitize(text) { reference in
            if let inline = HTMLSanitizer.localReference(reference, allowRelative: false) { return inline }
            guard let decoded = HTMLSanitizer.decodeEntities(reference).map(URLSafety.compact),
                  let absolute = URL(string: decoded, relativeTo: page)?.absoluteString
            else { return nil }
            return images[absolute]
        }
    }
}
