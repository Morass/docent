import Foundation

/// A source file as a page to read: its declarations in order, each with the documentation
/// comment written above it and the line it is on.
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

    public static func render(
        symbols: [SourceSymbols.Symbol],
        path: String,
        language: SourceSymbols.Language
    ) -> Rendered {
        let title = path
        var body = "<h1 id=\"top\">\(Markdown.escape(path))</h1>\n"
        body += "<p class=\"docent-source\">\(Markdown.escape(language.name)) · "
        body += "\(symbols.count) declaration\(symbols.count == 1 ? "" : "s")</p>\n"

        var entries: [Entry] = []
        var used = Set<String>()
        for symbol in symbols {
            var anchor = Markdown.slug(symbol.name).nonEmpty ?? "symbol"
            var suffix = 2
            while !used.insert(anchor).inserted {
                anchor = "\(Markdown.slug(symbol.name))-\(suffix)"
                suffix += 1
            }
            entries.append(Entry(name: symbol.name, kind: symbol.kind, anchor: anchor))

            body += "<h2 id=\"\(Markdown.escape(anchor))\">\(Markdown.escape(symbol.name))</h2>\n"
            body += "<p class=\"docent-source\">\(Markdown.escape(symbol.kind)) · line \(symbol.line)</p>\n"
            body += "<pre><code>\(Markdown.escape(symbol.declaration))</code></pre>\n"
            if !symbol.doc.isEmpty {
                // A doc comment is prose, and people write Markdown in them.
                body += Markdown.render(symbol.doc, fallbackTitle: symbol.name).html
            }
        }
        if symbols.isEmpty {
            body += "<p>No declarations were recognised in this file. Its text is still searchable.</p>\n"
        }

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(Markdown.escape(title))</title>
        <style>\(Markdown.typography)</style></head>
        <body>
        \(body)</body></html>
        """
        return Rendered(title: title, html: html, entries: entries)
    }
}
