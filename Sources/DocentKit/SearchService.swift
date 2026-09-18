import Foundation

/// The library, the indexes and the ranking joined up: ask a question, get an ordered
/// answer, read a page. Both the command and the app go through exactly this.
public struct SearchService: Sendable {
    public let library: DocsetLibrary

    public init(library: DocsetLibrary = .standard()) {
        self.library = library
    }

    public func docsets() -> [Docset] { library.docsets() }

    /// A query may name a docset the way Dash and Zeal spell it — `go:Println`, `swift:Array`
    /// — matching the docset's keyword, its name, or the start of either.
    public struct Query: Hashable, Sendable {
        public let text: String
        public let docsetHint: String?

        public init(_ raw: String) {
            let trimmed = raw.trimmed
            guard let colon = trimmed.firstIndex(of: ":"), colon != trimmed.startIndex else {
                text = trimmed
                docsetHint = nil
                return
            }
            let hint = String(trimmed[trimmed.startIndex..<colon]).trimmed
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmed
            // `NSString::length` is a symbol, not a docset hint: only treat the prefix as a
            // hint when it is a single plain word and a single colon follows it.
            let doubled = trimmed[trimmed.index(after: colon)...].hasPrefix(":")
            if !doubled, !hint.isEmpty, !rest.isEmpty,
               hint.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) {
                text = rest
                docsetHint = hint
            } else {
                text = trimmed
                docsetHint = nil
            }
        }
    }

    public func matches(docset: Docset, hint: String) -> Bool {
        let hint = hint.lowercased()
        if let keyword = docset.keyword?.lowercased(), keyword == hint || keyword.hasPrefix(hint) { return true }
        let name = docset.name.lowercased()
        return name == hint || name.hasPrefix(hint)
    }

    /// Ranked results across every docset, best first.
    ///
    /// `perDocsetLimit` caps what each docset contributes before ranking, so a 300 000-row
    /// docset cannot push everything else off the list.
    public func find(
        _ rawQuery: String,
        limit: Int = 25,
        perDocsetLimit: Int = 2000,
        in docsets: [Docset]? = nil
    ) throws -> [Match] {
        let query = Query(rawQuery)
        var pool = docsets ?? library.docsets()
        if let hint = query.docsetHint {
            let filtered = pool.filter { matches(docset: $0, hint: hint) }
            if !filtered.isEmpty { pool = filtered }
        }

        var candidates: [(docset: Docset, entry: IndexEntry)] = []
        for docset in pool {
            guard let index = try? SearchIndex(url: docset.indexURL) else { continue }
            let rows = (try? index.candidates(matching: query.text, limit: perDocsetLimit)) ?? []
            candidates.append(contentsOf: rows.map { (docset, $0) })
        }
        return Ranking.rank(candidates, query: query.text, limit: limit)
    }

    public enum PageError: Error, CustomStringConvertible {
        case missingFile(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .missingFile(let path): return "that page is not in the docset: \(path)"
            case .unreadable(let path): return "cannot read that page: \(path)"
            }
        }
    }

    /// The file a match points at, plus its anchor — what the app hands to a web view.
    public func location(of match: Match) throws -> (url: URL, anchor: String?) {
        guard let url = match.docset.fileURL(forPath: match.entry.path) else {
            throw PageError.missingFile(match.entry.path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PageError.missingFile(match.entry.path)
        }
        return (url, Docset.anchor(in: match.entry.path))
    }

    /// The page as text — what the command prints.
    public func page(for match: Match) throws -> RenderedPage {
        let (url, anchor) = try location(of: match)
        guard let data = try? Data(contentsOf: url) else { throw PageError.unreadable(url.path) }
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !html.isEmpty else { throw PageError.unreadable(url.path) }
        return HTMLText.render(html, anchor: anchor)
    }
}
