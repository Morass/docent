import Foundation

/// A documentation page as text: what `docent show` prints, and what any other program
/// gets when it asks Docent a question from a script.
public struct RenderedPage: Hashable, Sendable {
    public let title: String?
    public let text: String

    public init(title: String?, text: String) {
        self.title = title
        self.text = text
    }
}

/// Turns a docset's HTML into readable plain text.
///
/// Deliberately not a browser: no CSS, no JavaScript, no network. A docset page is a local
/// file, and this reads it the way `man` reads a man page — which is also why it is a pure
/// function over a string, and every awkward case below is a unit test.
public enum HTMLText {
    /// Tags whose *contents* are not text at all.
    private static let ignoredContainers: Set<String> = ["script", "style", "head", "svg", "noscript", "template"]
    /// Tags that end the current line.
    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "nav", "aside", "main",
        "ul", "ol", "dl", "dt", "dd", "table", "tbody", "thead", "tfoot", "tr",
        "blockquote", "figure", "figcaption", "form", "address", "details", "summary",
    ]

    public static func render(_ html: String, anchor: String? = nil) -> RenderedPage {
        let title = extractTitle(html)
        let body = anchor.flatMap { section(of: html, anchor: $0) } ?? html
        return RenderedPage(title: title, text: text(from: body))
    }

    // MARK: - Title

    static func extractTitle(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: openEnd.upperBound..<html.endIndex)
        else { return nil }
        let raw = String(html[openEnd.upperBound..<close.lowerBound])
        return decodeEntities(raw).replacingOccurrences(of: "\n", with: " ").squeezed.trimmed.nonEmpty
    }

    // MARK: - Anchors

    /// The slice of the page an `#anchor` points at: from the anchor to whatever starts the
    /// next section. A docset path usually points into the middle of a big page, and
    /// printing the whole page instead of the one symbol asked for is the difference
    /// between an answer and a dump.
    static func section(of html: String, anchor: String) -> String? {
        guard let anchorTag = anchorRange(in: html, anchor: anchor) else { return nil }
        let start = anchorTag.lowerBound

        // The heading this section owns — either the anchor sits *on* the heading
        // (`<h2 id="alpha">`), or the heading follows it (`<a name="spin"></a><h2>spin()`).
        // Either way it belongs to this section and must not be read as the next one.
        var ownLevel = 3
        var cursor = anchorTag.upperBound
        if let level = headingLevel(of: html, at: start) {
            ownLevel = level
            cursor = endOfTag(html, from: start) ?? anchorTag.upperBound
        } else {
            let lookahead = html[anchorTag.upperBound...].prefix(400)
            if let level = firstHeading(in: String(lookahead)),
               let heading = html.range(of: "<h\(level)", options: .caseInsensitive, range: anchorTag.upperBound..<html.endIndex) {
                ownLevel = level
                cursor = endOfTag(html, from: heading.lowerBound) ?? heading.upperBound
            }
        }

        if let next = nextSectionBreak(in: html, from: cursor, maxLevel: ownLevel) {
            return String(html[start..<next.range.lowerBound])
        }
        return String(html[start...])
    }

    /// The level of the heading tag that starts at `index`, if that is what starts there.
    private static func headingLevel(of html: String, at index: String.Index) -> Int? {
        guard html[index] == "<" else { return nil }
        var cursor = html.index(after: index)
        guard cursor < html.endIndex, html[cursor] == "h" || html[cursor] == "H" else { return nil }
        cursor = html.index(after: cursor)
        guard cursor < html.endIndex, let level = html[cursor].wholeNumberValue, (1...6).contains(level) else { return nil }
        return level
    }

    private static func endOfTag(_ html: String, from index: String.Index) -> String.Index? {
        html.range(of: ">", range: index..<html.endIndex)?.upperBound
    }

    private static func anchorRange(in html: String, anchor: String) -> Range<String.Index>? {
        // Try the anchor exactly as the index spells it, then percent-decoded: docsets are
        // inconsistent about which form ends up in the page.
        var spellings = [anchor]
        if let decoded = anchor.removingPercentEncoding, decoded != anchor { spellings.append(decoded) }
        // `//dash_ref_example-Println/Sample/Println/0` also appears as a plain `id`.
        for spelling in spellings {
            if spelling.hasPrefix("//"), let bare = spelling.split(separator: "/").dropFirst(2).first {
                let trimmed = bare.replacingOccurrences(of: "dash_ref_", with: "")
                    .replacingOccurrences(of: "apple_ref_", with: "")
                if !trimmed.isEmpty { spellings.append(trimmed) }
            }
        }
        for escaped in spellings {
        for attribute in ["name", "id"] {
            for quote in ["\"", "'"] {
                let needle = "\(attribute)=\(quote)\(escaped)\(quote)"
                if let found = html.range(of: needle, options: .caseInsensitive) {
                    // Back up to the start of the tag that carries the attribute.
                    if let tagStart = html.range(of: "<", options: .backwards, range: html.startIndex..<found.lowerBound) {
                        return tagStart.lowerBound..<found.upperBound
                    }
                    return found
                }
            }
        }
        }
        return nil
    }

    private static func firstHeading(in fragment: String) -> Int? {
        for level in 1...6 where fragment.range(of: "<h\(level)", options: .caseInsensitive) != nil {
            return level
        }
        return nil
    }

    private struct SectionBreak {
        let range: Range<String.Index>
        let isHeading: Bool
        let level: Int
    }

    private static func nextSectionBreak(in html: String, from index: String.Index, maxLevel: Int) -> SectionBreak? {
        var best: SectionBreak?
        func consider(_ range: Range<String.Index>?, isHeading: Bool, level: Int) {
            guard let range else { return }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = SectionBreak(range: range, isHeading: isHeading, level: level)
            }
        }
        let tail = index..<html.endIndex
        for level in 1...max(1, maxLevel) {
            consider(html.range(of: "<h\(level)", options: .caseInsensitive, range: tail), isHeading: true, level: level)
        }
        for marker in ["<a name=\"//apple_ref", "<a name=\"//dash_ref"] {
            consider(html.range(of: marker, options: .caseInsensitive, range: tail), isHeading: false, level: 0)
        }
        return best
    }

    // MARK: - Text

    static func text(from html: String) -> String {
        var out = ""
        var index = html.startIndex
        var verbatimDepth = 0
        var skipUntil: String? = nil
        var pendingText = ""

        func flushText() {
            guard !pendingText.isEmpty else { return }
            let decoded = decodeEntities(pendingText)
            out += verbatimDepth > 0 ? decoded : decoded.squeezed
            pendingText = ""
        }
        func newline(_ count: Int) {
            flushText()
            guard !out.isEmpty else { return }
            let existing = out.reversed().prefix(while: { $0 == "\n" }).count
            out += String(repeating: "\n", count: max(0, count - existing))
        }

        while index < html.endIndex {
            let character = html[index]
            guard character == "<" else {
                pendingText.append(character)
                index = html.index(after: index)
                continue
            }
            guard let tag = readTag(html, from: index) else {
                pendingText.append(character)
                index = html.index(after: index)
                continue
            }
            index = tag.end

            if let waiting = skipUntil {
                if tag.isClosing, tag.name == waiting { skipUntil = nil }
                pendingText = ""
                continue
            }
            if !tag.isClosing, ignoredContainers.contains(tag.name), !tag.isSelfClosing {
                flushText()
                skipUntil = tag.name
                continue
            }

            switch tag.name {
            case "br":
                newline(1)
            case "hr":
                newline(2)
            case "pre":
                if tag.isClosing {
                    flushText()
                    verbatimDepth = max(0, verbatimDepth - 1)
                    newline(2)
                } else {
                    newline(2)
                    verbatimDepth += 1
                }
            case "li":
                if tag.isClosing { newline(1) } else { newline(1); out += "  • " }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(tag.name.dropFirst())) ?? 1
                if tag.isClosing {
                    newline(2)
                } else {
                    newline(2)
                    out += String(repeating: "#", count: level) + " "
                }
            case "td", "th":
                if tag.isClosing { flushText(); out += " | " }
            case "code", "tt":
                if verbatimDepth == 0 {
                    flushText()
                    out += "`"
                }
            default:
                if blockTags.contains(tag.name) { newline(tag.name == "p" ? 2 : 1) }
            }
            if tag.name == "img", !tag.isClosing { flushText() }
        }
        flushText()

        return out
            // Permalink glyphs: every page generator leaves one beside each heading, and
            // they are navigation, not text.
            .replacingOccurrences(of: "¶", with: "")
            .replacingOccurrences(of: "🔗", with: "")
            .replacingOccurrences(of: " | \n", with: "\n")
            .replacingOccurrences(of: "``", with: "")
            .collapsingBlankLines
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Tag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let end: String.Index
    }

    /// Reads `<tag …>` starting at `index`, respecting quoted attribute values so that a
    /// `>` inside an attribute does not end the tag early.
    private static func readTag(_ html: String, from index: String.Index) -> Tag? {
        var cursor = html.index(after: index)
        guard cursor < html.endIndex else { return nil }
        var isClosing = false
        if html[cursor] == "/" {
            isClosing = true
            cursor = html.index(after: cursor)
            // A page ending in `</` is two bytes of malformed HTML, and reading one
            // character further is a crash in a tool people point at files they downloaded.
            guard cursor < html.endIndex else { return nil }
        }
        if html[cursor] == "!" {  // comment or doctype
            if let close = html.range(of: ">", range: cursor..<html.endIndex) {
                if html[cursor...].hasPrefix("!--"), let commentEnd = html.range(of: "-->", range: cursor..<html.endIndex) {
                    return Tag(name: "!--", isClosing: false, isSelfClosing: true, end: commentEnd.upperBound)
                }
                return Tag(name: "!", isClosing: false, isSelfClosing: true, end: close.upperBound)
            }
            return nil
        }

        var name = ""
        while cursor < html.endIndex, html[cursor].isLetter || html[cursor].isNumber {
            name.append(html[cursor])
            cursor = html.index(after: cursor)
        }
        guard !name.isEmpty else { return nil }

        var quote: Character? = nil
        var selfClosing = false
        while cursor < html.endIndex {
            let character = html[cursor]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                cursor = html.index(after: cursor)
                return Tag(name: name.lowercased(), isClosing: isClosing, isSelfClosing: selfClosing, end: cursor)
            } else if character == "/" {
                selfClosing = true
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "times": "×", "middot": "·", "bull": "•",
        "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "trade": "™",
        "larr": "←", "rarr": "→", "harr": "↔", "deg": "°", "plusmn": "±",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            // Bounded lookahead: searching the whole remaining page for `;` at every `&`
            // turns a page full of ampersands into quadratic work.
            let horizon = text.index(index, offsetBy: 11, limitedBy: text.endIndex) ?? text.endIndex
            guard text[index] == "&",
                  let semicolon = text.range(of: ";", range: index..<horizon)
            else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            let body = String(text[text.index(after: index)..<semicolon.lowerBound])
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value: UInt32?
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                    index = semicolon.upperBound
                    continue
                }
            } else if let replacement = namedEntities[body.lowercased()] {
                out += replacement
                index = semicolon.upperBound
                continue
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }
}

extension String {
    /// Runs of whitespace become one space, the way HTML itself treats them.
    var squeezed: String {
        var out = ""
        var lastWasSpace = false
        for character in self {
            if character.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(character)
                lastWasSpace = false
            }
        }
        return out
    }

    /// Whitespace-only lines become empty, and a run of empty lines becomes one. Trimming
    /// has to happen *first*: a line holding a single space is a blank line to a reader but
    /// not to a newline count, which is how three blank lines survive a naive collapse.
    var collapsingBlankLines: String {
        var lines: [String] = []
        var blanks = 0
        for raw in split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
            if line.isEmpty {
                blanks += 1
                if blanks <= 1 { lines.append(line) }
            } else {
                blanks = 0
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
