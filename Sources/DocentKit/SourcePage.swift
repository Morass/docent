import Foundation

/// A source file as a page to read: what it declares, in the order it declares it, with
/// each member under the type it belongs to and the documentation comment written above it.
public enum SourcePage {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let kind: String
        public let anchor: String
    }

    public struct Rendered: Sendable {
        public let title: String
        public let html: String
        public let entries: [Entry]
    }

    static let typeKinds: Set<String> = ["Class", "Struct", "Enum", "Protocol", "Interface",
                                         "Trait", "Category", "Module"]

    /// Anchors first, so the whole docset can be linked before any page is written.
    public static func entries(for symbols: [SourceSymbols.Symbol]) -> [Entry] {
        var entries: [Entry] = []
        var used = Set<String>()
        // The next free suffix per name, so a file full of identical names does not turn
        // anchor-making into quadratic work.
        var counts: [String: Int] = [:]
        for symbol in symbols {
            let base = Markdown.slug(symbol.name).nonEmpty ?? "symbol"
            var anchor = base
            var suffix = counts[base] ?? 2
            while !used.insert(anchor).inserted {
                anchor = "\(base)-\(suffix)"
                suffix += 1
            }
            counts[base] = suffix
            entries.append(Entry(name: symbol.name, kind: symbol.kind, anchor: anchor))
        }
        return entries
    }

    public static func render(
        symbols: [SourceSymbols.Symbol],
        path: String,
        language: SourceSymbols.Language,
        breadcrumb: String = "",
        link: (String) -> String = { $0 }
    ) -> Rendered {
        let entries = entries(for: symbols)
        var body = breadcrumb
        body += "<h1 id=\"top\">\(Markdown.escape((path as NSString).lastPathComponent))</h1>\n"
        body += "<p class=\"docent-source\">\(Markdown.escape(path)) · \(Markdown.escape(language.name))"
        body += " · \(symbols.count) declaration\(symbols.count == 1 ? "" : "s")</p>\n"

        // What is in this file, before the detail of it: a page of forty declarations is
        // unreadable without a way in.
        let topLevel = zip(symbols, entries).filter { !$0.0.name.contains(".") }
        if topLevel.count > 1 {
            body += "<h2 id=\"contents\">Contents</h2>\n<ul>\n"
            for (symbol, entry) in topLevel {
                body += "<li><a href=\"#\(Markdown.escape(entry.anchor))\">\(Markdown.escape(symbol.name))</a>"
                body += " <span class=\"docent-source\">\(Markdown.escape(symbol.kind))</span></li>\n"
            }
            body += "</ul>\n"
        }

        for (offset, symbol) in symbols.enumerated() {
            let entry = entries[offset]
            let depth = symbol.name.split(separator: ".").count
            let heading = min(2 + max(0, depth - 1), 4)
            body += "<h\(heading) id=\"\(Markdown.escape(entry.anchor))\">\(Markdown.escape(symbol.name))</h\(heading)>\n"
            body += "<p class=\"docent-source\">\(Markdown.escape(symbol.kind)) · line \(symbol.line)</p>\n"
            body += "<pre><code>\(link(Markdown.escape(symbol.declaration)))</code></pre>\n"
            if !symbol.doc.isEmpty {
                // A doc comment is prose, and people write Markdown in them.
                body += link(Markdown.render(symbol.doc, fallbackTitle: symbol.name).html)
            }

            // Everything declared inside this type, so a type reads as a type rather than
            // as the first of forty equal headings.
            if typeKinds.contains(symbol.kind) {
                let prefix = symbol.name + "."
                let members = zip(symbols, entries).filter { pair in
                    pair.0.name.hasPrefix(prefix)
                        && !pair.0.name.dropFirst(prefix.count).contains(".")
                }
                if !members.isEmpty {
                    body += "<p class=\"docent-source\">Members</p>\n<ul>\n"
                    for (member, memberEntry) in members {
                        let short = String(member.name.dropFirst(prefix.count))
                        body += "<li><a href=\"#\(Markdown.escape(memberEntry.anchor))\">\(Markdown.escape(short))</a>"
                        body += " <span class=\"docent-source\">\(Markdown.escape(member.kind))</span></li>\n"
                    }
                    body += "</ul>\n"
                }
            }
        }
        if symbols.isEmpty {
            body += "<p>No declarations were recognised in this file. Its text is still searchable.</p>\n"
        }

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(Markdown.escape(path))</title>
        <style>\(Markdown.typography)</style></head>
        <body>
        \(body)</body></html>
        """
        return Rendered(title: path, html: html, entries: entries)
    }
}
