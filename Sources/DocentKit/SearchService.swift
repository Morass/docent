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

    /// Pages whose *text* mentions the query, for docsets Docent indexed itself.
    ///
    /// A docset from a vendor indexes symbols, and searching its prose is not something its
    /// index can do. One built by `docent index` carries a full-text table, because "search
    /// my own documentation" means the words in it, not just the headings.
    public func findInText(
        _ rawQuery: String,
        limit: Int = 25,
        in docsets: [Docset]? = nil
    ) throws -> [Match] {
        let query = Query(rawQuery)
        var pool = docsets ?? library.docsets()
        if let hint = query.docsetHint {
            let filtered = pool.filter { matches(docset: $0, hint: hint) }
            if !filtered.isEmpty { pool = filtered }
        }
        guard !query.text.isEmpty else { return [] }

        var found: [Match] = []
        for docset in pool {
            guard let index = try? SearchIndex(url: docset.indexURL), index.hasFullText else { continue }
            let rows = (try? index.textMatches(query.text, limit: limit)) ?? []
            found.append(contentsOf: rows.map { Match(docset: docset, entry: $0, score: 0) })
        }
        return Array(found.prefix(limit))
    }

    /// Is a text search even possible here — did Docent build any of these docsets?
    public func canSearchText(in docsets: [Docset]? = nil) -> Bool {
        (docsets ?? library.docsets()).contains { docset in
            (try? SearchIndex(url: docset.indexURL))?.hasFullText == true
        }
    }

    public enum PageError: Error, CustomStringConvertible {
        case missingFile(String)
        case unreadable(String)
        case tooLarge(path: String, bytes: Int)

        public var description: String {
            switch self {
            case .missingFile(let path): return "that page is not in the docset: \(path)"
            case .unreadable(let path): return "cannot read that page: \(path)"
            case .tooLarge(let path, let bytes):
                let megabytes = Double(bytes) / 1_048_576
                return String(format: "that page is %.0f MB, too big to print as text — open it instead: %@", megabytes, path)
            }
        }
    }

    /// A documentation page is a few hundred kilobytes. Anything past this is either broken
    /// or hostile, and rendering it would hold several copies of it in memory.
    public static let pageSizeLimit = 16 * 1024 * 1024

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
    ///
    /// `wholePage` is `docent show --all`: the same file, rendered without slicing out the
    /// symbol's section. It goes through here rather than reading the file itself, because
    /// the size cap and the encoding fallback belong to *reading a docset page*, not to one
    /// of the two commands that does it.
    public func page(for match: Match, wholePage: Bool = false) throws -> RenderedPage {
        let (url, anchor) = try location(of: match)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size, size > SearchService.pageSizeLimit {
            throw PageError.tooLarge(path: url.path, bytes: size)
        }
        guard let data = try? Data(contentsOf: url) else { throw PageError.unreadable(url.path) }
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !html.isEmpty else { throw PageError.unreadable(url.path) }
        return HTMLText.render(html, anchor: wholePage ? nil : anchor)
    }
}
