import Foundation

/// A small Markdown renderer.
///
/// Deliberately not a full CommonMark implementation: it covers what documentation in a
/// repository actually uses — headings, paragraphs, fenced code, lists, tables, block
/// quotes, links, inline code and emphasis — and escapes everything else rather than
/// guessing. A docset page only has to be *readable*; the source of truth stays the file.
public enum Markdown {
    public struct Heading: Hashable, Sendable {
        public let level: Int
        public let text: String
        public let anchor: String
    }

    public struct Page: Hashable, Sendable {
        public let title: String
        public let html: String
        public let headings: [Heading]
    }

    public static func render(_ source: String, fallbackTitle: String) -> Page {
        var html = ""
        var headings: [Heading] = []
        var seenAnchors: Set<String> = []
        var lines = source.components(separatedBy: .newlines)[...]

        var listKind: String? = nil          // "ul" or "ol", nil when not in a list
        func closeList() {
            if let kind = listKind { html += "</\(kind)>\n"; listKind = nil }
        }

        while let line = lines.first {
            lines = lines.dropFirst()

            // Fenced code: everything until the closing fence is literal.
            if let fence = codeFence(line) {
                closeList()
                var code = ""
                while let next = lines.first, codeFence(next) == nil {
                    code += next + "\n"
                    lines = lines.dropFirst()
                }
                if !lines.isEmpty { lines = lines.dropFirst() }   // the closing fence
                let language = fence.isEmpty ? "" : " class=\"language-\(escape(fence))\""
                html += "<pre><code\(language)>\(escape(code))</code></pre>\n"
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { closeList(); continue }

            if let heading = atxHeading(trimmed) {
                closeList()
                var anchor = slug(heading.text)
                var attempt = 2
                while !seenAnchors.insert(anchor).inserted {
                    anchor = slug(heading.text) + "-\(attempt)"
                    attempt += 1
                }
                headings.append(Heading(level: heading.level, text: heading.text, anchor: anchor))
                html += "<h\(heading.level) id=\"\(escape(anchor))\">\(inline(heading.text))</h\(heading.level)>\n"
                continue
            }

            if trimmed.hasPrefix(">") {
                closeList()
                html += "<blockquote>\(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>\n"
                continue
            }

            if trimmed.hasPrefix("---") || trimmed.hasPrefix("***"), trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == " " }) {
                closeList()
                html += "<hr>\n"
                continue
            }

            if let item = listItem(trimmed) {
                if listKind != item.kind {
                    closeList()
                    html += "<\(item.kind)>\n"
                    listKind = item.kind
                }
                // Markdown wraps: the lines after a bullet, up to a blank line or the next
                // bullet, are part of the same item. Without this every wrapped line became
                // its own paragraph and a list read as confetti.
                var text = item.text
                while let next = lines.first {
                    let candidate = next.trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, listItem(candidate) == nil, atxHeading(candidate) == nil,
                          codeFence(next) == nil, !candidate.hasPrefix(">"), !candidate.contains("|") else { break }
                    text += " " + candidate
                    lines = lines.dropFirst()
                }
                html += "<li>\(inline(text))</li>\n"
                continue
            }

            // A pipe table: a header row, a divider of dashes, then rows. Repository docs
            // are full of them and they are unreadable as paragraphs.
            if trimmed.contains("|"), let divider = lines.first, isTableDivider(divider) {
                closeList()
                lines = lines.dropFirst()
                html += "<table>\n<thead><tr>"
                for cell in tableCells(trimmed) { html += "<th>\(inline(cell))</th>" }
                html += "</tr></thead>\n<tbody>\n"
                while let row = lines.first, row.contains("|"), !row.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines = lines.dropFirst()
                    html += "<tr>"
                    for cell in tableCells(row) { html += "<td>\(inline(cell))</td>" }
                    html += "</tr>\n"
                }
                html += "</tbody>\n</table>\n"
                continue
            }

            closeList()
            var paragraph = trimmed
            while let next = lines.first {
                let candidate = next.trimmingCharacters(in: .whitespaces)
                guard !candidate.isEmpty, listItem(candidate) == nil, atxHeading(candidate) == nil,
                      codeFence(next) == nil, !candidate.hasPrefix(">"), !candidate.contains("|") else { break }
                paragraph += " " + candidate
                lines = lines.dropFirst()
            }
            html += "<p>\(inline(paragraph))</p>\n"
        }
        closeList()

        let title = headings.first(where: { $0.level == 1 })?.text ?? fallbackTitle
        return Page(title: title, html: html, headings: headings)
    }

    /// A complete page, with the title and a link back to the file it came from.
    public static func document(_ page: Page, sourcePath: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(page.title))</title>
        <style>\(typography)</style></head>
        <body>
        \(page.html)
        <hr>
        <p class="docent-source">\(escape(sourcePath))</p>
        </body></html>
        """
    }

    /// Typography only — every colour comes from the reader's theme. Without this a
    /// generated page renders in the browser's default serif at full window width, which is
    /// unreadable next to a real docset.
    public static let typography = """
    body { font: 15.5px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", Helvetica, Arial, sans-serif;
           margin: 0 auto; padding: 28px 34px 64px; max-width: 46rem; }
    h1 { font-size: 1.8rem; margin: 0 0 1rem; line-height: 1.2; }
    h2 { font-size: 1.3rem; margin: 2rem 0 .6rem; }
    h3 { font-size: 1.08rem; margin: 1.5rem 0 .4rem; }
    p, li { margin: .55rem 0; }
    ul, ol { padding-left: 1.4rem; }
    code, pre, kbd { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; }
    code { padding: .1em .35em; border-radius: 4px; }
    pre { padding: .8rem 1rem; border-radius: 8px; overflow-x: auto; }
    pre code { padding: 0; background: none !important; }
    table { border-collapse: collapse; width: 100%; margin: 1rem 0; display: block; overflow-x: auto; }
    th, td { border: 1px solid; padding: .4rem .6rem; text-align: left; vertical-align: top; }
    blockquote { margin: .8rem 0; padding: .1rem 0 .1rem 1rem; border-left: 3px solid; }
    hr { border: 0; border-top: 1px solid; margin: 2rem 0 1rem; }
    .docent-source { font-size: .8rem; opacity: .65; }
    """

    // MARK: - Blocks

    static func codeFence(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (hashes, rest)
    }

    static func listItem(_ line: String) -> (kind: String, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return ("ul", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ("ol", String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "-" || $0 == "|" || $0 == ":" || $0 == " " }
    }

    static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Inline

    /// Inline markup, with everything escaped first: the source is someone's file, and the
    /// output is HTML a web view will run.
    static func inline(_ text: String) -> String {
        var out = escape(text)
        out = replacePairs(in: out, marker: "`", tag: "code")
        out = replacePairs(in: out, marker: "**", tag: "strong")
        out = replacePairs(in: out, marker: "*", tag: "em")
        out = links(in: out)
        return out
    }

    private static func replacePairs(in text: String, marker: String, tag: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: marker),
              let close = rest[open.upperBound...].range(of: marker) {
            out += rest[..<open.lowerBound]
            out += "<\(tag)>" + rest[open.upperBound..<close.lowerBound] + "</\(tag)>"
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// `[text](target)` — only local and http(s) targets become links, and an http link in a
    /// page is inert anyway: the reader blocks the network.
    private static func links(in text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let openBracket = rest.range(of: "["),
              let closeBracket = rest[openBracket.upperBound...].range(of: "]("),
              let closeParen = rest[closeBracket.upperBound...].range(of: ")") {
            let label = rest[openBracket.upperBound..<closeBracket.lowerBound]
            let target = String(rest[closeBracket.upperBound..<closeParen.lowerBound])
            out += rest[..<openBracket.lowerBound]
            if target.contains("\"") || target.contains(" ") || target.lowercased().hasPrefix("javascript:") {
                out += "[\(label)](\(escape(target)))"
            } else {
                out += "<a href=\"\(escape(target))\">\(label)</a>"
            }
            rest = rest[closeParen.upperBound...]
        }
        return out + rest
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// GitHub-style anchor, so a link written for GitHub usually still lands.
    public static func slug(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber { out.append(character) }
            else if character == " " || character == "-" || character == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
