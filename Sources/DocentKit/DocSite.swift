import Foundation

/// What turns a pile of indexed pages into documentation you can read: one overview to
/// start from, links between the pages, and a name in a doc comment that takes you to the
/// thing it names.
public enum DocSite {
    /// One page of the docset, as the overview and the cross-linker need to know it.
    public struct Page: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case document            // Markdown or HTML the author wrote
            case code(String)        // a source file; the string is the language's name
        }
        public let relative: String      // path inside the indexed folder
        public let pagePath: String      // path inside the docset's Documents
        public let title: String
        public let kind: Kind
        /// Symbol name → anchor on this page, in the order they appear.
        public let anchors: [(name: String, kind: String, anchor: String)]

        public init(relative: String, pagePath: String, title: String, kind: Kind,
                    anchors: [(name: String, kind: String, anchor: String)]) {
            self.relative = relative
            self.pagePath = pagePath
            self.title = title
            self.kind = kind
            self.anchors = anchors
        }

        public static func == (a: Page, b: Page) -> Bool {
            a.relative == b.relative && a.pagePath == b.pagePath && a.title == b.title && a.kind == b.kind
        }
    }

    // MARK: - Links between pages

    /// Symbol name → where it is documented, for names that mean exactly one thing.
    ///
    /// A name defined in two places is left out rather than guessed at: a link that lands
    /// on the wrong `draw` is worse than no link, because the reader believes it.
    public static func linkTable(for pages: [Page]) -> [String: String] {
        var table: [String: String] = [:]
        var ambiguous = Set<String>()
        for page in pages {
            for anchor in page.anchors {
                let target = "\(page.pagePath)#\(anchor.anchor)"
                if let existing = table[anchor.name], existing != target {
                    ambiguous.insert(anchor.name)
                } else {
                    table[anchor.name] = target
                }
            }
        }
        for name in ambiguous { table.removeValue(forKey: name) }
        return table
    }

    /// How a page at `pagePath` reaches `target`, which is written from the docset root.
    public static func relativeTarget(_ target: String, from pagePath: String) -> String {
        let depth = max(0, pagePath.split(separator: "/").count - 1)
        return String(repeating: "../", count: depth) + target
    }

    /// Turns every name the docset documents into a link to it, in the text of a page.
    ///
    /// Only names that read as names: something capitalised, or something qualified with a
    /// dot. A bare `draw` in a sentence is a verb as often as it is a method.
    public static func crossLink(
        _ html: String,
        from pagePath: String,
        table: [String: String],
        skipping own: Set<String> = []
    ) -> String {
        guard !table.isEmpty else { return html }
        var out = ""
        var rest = Substring(html)
        var insideLink = false

        func isIdentifier(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_" || character == "."
        }

        while let openTag = rest.firstIndex(of: "<") {
            let text = rest[..<openTag]
            out += insideLink ? String(text) : link(String(text))
            // Copy the tag through untouched, and notice whether it opens or closes a link.
            guard let closeTag = rest[openTag...].firstIndex(of: ">") else {
                out += rest[openTag...]
                return out
            }
            let tag = rest[openTag...closeTag]
            if tag.hasPrefix("<a ") || tag.hasPrefix("<a>") { insideLink = true }
            if tag.hasPrefix("</a") { insideLink = false }
            out += tag
            rest = rest[rest.index(after: closeTag)...]
        }
        out += insideLink ? String(rest) : link(String(rest))
        return out

        func link(_ text: String) -> String {
            var result = ""
            var cursor = text.startIndex
            while cursor < text.endIndex {
                guard isIdentifier(text[cursor]) else {
                    result.append(text[cursor])
                    cursor = text.index(after: cursor)
                    continue
                }
                var end = cursor
                while end < text.endIndex, isIdentifier(text[end]) { end = text.index(after: end) }
                var token = String(text[cursor..<end])
                // `Canvas.draw(` arrives as `Canvas.draw`; a trailing dot is punctuation.
                while token.hasSuffix(".") { token.removeLast() }

                var matched: String? = nil
                var candidate = token
                while !candidate.isEmpty {
                    if candidate.count >= 3, !own.contains(candidate),
                       candidate.first?.isUppercase == true || candidate.contains("."),
                       let target = table[candidate] {
                        matched = candidate
                        break
                    }
                    guard let dot = candidate.lastIndex(of: ".") else { break }
                    candidate = String(candidate[..<dot])
                }

                if let matched, let target = table[matched] {
                    let href = Markdown.escape(relativeTarget(target, from: pagePath))
                    result += "<a href=\"\(href)\">\(matched)</a>"
                    result += String(text[cursor..<end]).dropFirst(matched.count)
                } else {
                    result += text[cursor..<end]
                }
                cursor = end
            }
            return result
        }
    }

    /// Rewrites a link to another file in the folder — `docs/DESIGN.md` — to the page that
    /// file became. Without this, every link between a project's own documents is dead the
    /// moment it is indexed.
    public static func rewriteDocumentLinks(
        _ html: String,
        pagePath: String,
        sourceRelative: String,
        pages: [String: String]        // path inside the folder → page path in the docset
    ) -> String {
        var out = ""
        var rest = Substring(html)
        let directory = (sourceRelative as NSString).deletingLastPathComponent

        while let marker = rest.range(of: "href=\"") {
            guard let close = rest[marker.upperBound...].range(of: "\"") else { break }
            let reference = String(rest[marker.upperBound..<close.lowerBound])
            out += rest[..<marker.upperBound]

            var rewritten = reference
            let lower = reference.lowercased()
            let isLocal = !reference.isEmpty && !reference.hasPrefix("#") && !reference.hasPrefix("/")
                && !["http:", "https:", "mailto:", "data:", "file:", "//"].contains(where: { lower.hasPrefix($0) })
            if isLocal {
                var path = reference
                var fragment = ""
                if let hash = path.firstIndex(of: "#") {
                    fragment = String(path[hash...])
                    path = String(path[..<hash])
                }
                let decoded = path.removingPercentEncoding ?? path
                let resolved = normalise(directory.isEmpty ? decoded : directory + "/" + decoded)
                if let page = pages[resolved] {
                    rewritten = relativeTarget(page, from: pagePath) + fragment
                }
            }
            out += Markdown.escape(rewritten)
            out += rest[close.lowerBound..<close.upperBound]
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// `docs/../README.md` → `README.md`, without touching the disk.
    static func normalise(_ path: String) -> String {
        var parts: [String] = []
        for piece in path.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(piece))
            }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - The page you land on

extension DocSite {
    /// The docset's front page: the project's own README, then everything it holds —
    /// documents, source files grouped by folder, and every type it declares.
    ///
    /// Landing on a list of file names is what a file browser does. Landing on the README
    /// with the rest of the project underneath it is what documentation does.
    public static func overview(name: String, pages: [Page], readme: String?) -> String {
        var body = ""
        if let readme {
            // The README almost always opens with the project's name as a heading; adding
            // ours above it gives the page two titles.
            if !readme.contains("<h1") { body += "<h1>\(Markdown.escape(name))</h1>\n" }
            body += readme
            body += "<hr>\n"
        } else {
            body += "<h1>\(Markdown.escape(name))</h1>\n"
        }

        let documents = pages.filter { $0.kind == .document }
        let code = pages.filter { if case .code = $0.kind { return true } else { return false } }

        if !documents.isEmpty {
            body += "<h2 id=\"documents\">Documents</h2>\n<ul>\n"
            for page in documents.sorted(by: { $0.relative < $1.relative }) {
                body += "<li><a href=\"\(Markdown.escape(page.pagePath))\">\(Markdown.escape(page.title))</a>"
                if page.title != page.relative {
                    body += " <span class=\"docent-source\">\(Markdown.escape(page.relative))</span>"
                }
                body += "</li>\n"
            }
            body += "</ul>\n"
        }

        if !code.isEmpty {
            body += "<h2 id=\"code\">Code</h2>\n"
            let byFolder = Dictionary(grouping: code) { page -> String in
                let folder = (page.relative as NSString).deletingLastPathComponent
                return folder.isEmpty ? "." : folder
            }
            for folder in byFolder.keys.sorted() {
                body += "<h3>\(Markdown.escape(folder == "." ? "(top level)" : folder))</h3>\n<ul>\n"
                for page in (byFolder[folder] ?? []).sorted(by: { $0.relative < $1.relative }) {
                    let file = (page.relative as NSString).lastPathComponent
                    let count = page.anchors.count
                    body += "<li><a href=\"\(Markdown.escape(page.pagePath))\">\(Markdown.escape(file))</a>"
                    body += " <span class=\"docent-source\">\(count) declaration\(count == 1 ? "" : "s")</span></li>\n"
                }
                body += "</ul>\n"
            }
        }

        let typeKinds: Set<String> = ["Class", "Struct", "Enum", "Protocol", "Interface", "Trait", "Type"]
        var types: [(name: String, kind: String, target: String)] = []
        for page in pages {
            for anchor in page.anchors where typeKinds.contains(anchor.kind) {
                types.append((anchor.name, anchor.kind, "\(page.pagePath)#\(anchor.anchor)"))
            }
        }
        if !types.isEmpty {
            body += "<h2 id=\"types\">Types</h2>\n<ul>\n"
            for type in types.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                body += "<li><a href=\"\(Markdown.escape(type.target))\">\(Markdown.escape(type.name))</a>"
                body += " <span class=\"docent-source\">\(Markdown.escape(type.kind))</span></li>\n"
            }
            body += "</ul>\n"
        }

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(Markdown.escape(name))</title>
        <style>\(Markdown.typography)</style></head>
        <body>
        \(body)</body></html>
        """
    }

    /// The strip at the top of every page: back to the overview, and where this page sits.
    public static func breadcrumb(for relative: String, pagePath: String) -> String {
        let home = relativeTarget("index.html", from: pagePath)
        let folder = (relative as NSString).deletingLastPathComponent
        var line = "<p class=\"docent-source\"><a href=\"\(Markdown.escape(home))\">Overview</a>"
        if !folder.isEmpty { line += " · " + Markdown.escape(folder) }
        return line + "</p>\n"
    }
}
