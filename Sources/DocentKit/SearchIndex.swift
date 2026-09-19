import Foundation
import SQLite3

/// One row of a docset's index: a symbol, what kind of thing it is, and the page it lives on.
public struct IndexEntry: Hashable, Sendable {
    public let name: String
    public let type: String
    public let path: String

    public init(name: String, type: String, path: String) {
        self.name = name
        self.type = type
        self.path = path
    }
}

public enum SearchIndexError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case query(String)
    case unknownSchema

    public var description: String {
        switch self {
        case .cannotOpen(let message): return "cannot read the docset index: \(message)"
        case .query(let message): return "the docset index refused a query: \(message)"
        case .unknownSchema: return "this docset's index is in a format Docent does not know"
        }
    }
}

/// Read-only access to a docset's `docSet.dsidx`.
///
/// Two schemas exist in the wild and both are common: the plain `searchIndex` table that
/// Dash-style docsets use, and the Core Data tables that `docsetutil` produced for Apple's
/// own. A docset is opened read-only and never written to.
public final class SearchIndex {
    enum Schema {
        case searchIndex
        case coreData
    }

    /// A budget for one query, counted by SQLite itself.
    ///
    /// A docset's index is a database file someone else built. A view defined as a
    /// recursive query makes an ordinary `SELECT … LIMIT 20` run forever, and a limit on
    /// *rows* cannot stop a join that never produces any. This stops it after a fixed
    /// amount of work instead.
    final class Budget {
        var ticks = 0
        var limit = 200_000
    }

    private var db: OpaquePointer?
    private let budget = Budget()
    let schema: Schema

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let uriPath = url.path
        guard sqlite3_open_v2(uriPath, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SearchIndexError.cannotOpen(message)
        }
        self.db = db

        sqlite3_progress_handler(db, 1_000, { pointer in
            guard let pointer else { return 0 }
            let budget = Unmanaged<Budget>.fromOpaque(pointer).takeUnretainedValue()
            budget.ticks += 1
            return budget.ticks > budget.limit ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())

        let tables = Set(SearchIndex.strings(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        if tables.contains("searchIndex") {
            schema = .searchIndex
        } else if tables.contains("ZTOKEN") || tables.contains("ztoken") {
            schema = .coreData
        } else {
            sqlite3_close(db)
            self.db = nil
            throw SearchIndexError.unknownSchema
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private static func strings(_ db: OpaquePointer, sql: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let c = sqlite3_column_text(statement, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    private var selectSQL: String {
        switch schema {
        case .searchIndex:
            return """
            SELECT name, type, path FROM searchIndex
            """
        case .coreData:
            return """
            SELECT ZTOKENNAME AS name, ZTYPENAME AS type,
                   ZPATH || CASE WHEN ZANCHOR IS NOT NULL AND ZANCHOR <> '' THEN '#' || ZANCHOR ELSE '' END AS path
            FROM ZTOKEN
            JOIN ZTOKENMETAINFORMATION ON ZTOKEN.ZMETAINFORMATION = ZTOKENMETAINFORMATION.Z_PK
            JOIN ZFILEPATH ON ZTOKENMETAINFORMATION.ZFILE = ZFILEPATH.Z_PK
            JOIN ZTOKENTYPE ON ZTOKEN.ZTOKENTYPE = ZTOKENTYPE.Z_PK
            """
        }
    }

    /// Rows whose name could match `query`, cheaply narrowed by SQL before the ranking in
    /// `Ranking` decides the order. The pattern is a subsequence match (`a%b%c`), which is
    /// a superset of "contains", so one query feeds both exact and fuzzy results.
    ///
    /// `limit` caps what a single docset can contribute, so one enormous docset cannot
    /// crowd everything else out of a search across a library.
    public func candidates(matching query: String, limit: Int = 2000) throws -> [IndexEntry] {
        budget.ticks = 0
        let trimmed = query.trimmed
        var sql = selectSQL
        if !trimmed.isEmpty {
            sql += " WHERE name LIKE ? ESCAPE '\\'"
        }
        sql += " LIMIT ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var parameter: Int32 = 1
        if !trimmed.isEmpty {
            let pattern = SearchIndex.subsequencePattern(for: trimmed)
            sqlite3_bind_text(statement, parameter, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            parameter += 1
        }
        sqlite3_bind_int(statement, parameter, Int32(max(1, limit)))

        var rows: [IndexEntry] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 0), let path = sqlite3_column_text(statement, 2) {
                let type = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                rows.append(IndexEntry(name: String(cString: name), type: type, path: String(cString: path)))
            }
            step = sqlite3_step(statement)
        }
        if step == SQLITE_INTERRUPT {
            throw SearchIndexError.query("this docset's index takes too long to search — it may be damaged")
        }
        return rows
    }

    /// Does this docset carry the full-text table `docent index` writes?
    public var hasFullText: Bool {
        guard let db else { return false }
        return !SearchIndex.strings(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='docentText'").isEmpty
    }

    /// Pages whose *text* matches, for docsets Docent indexed itself. The query is passed to
    /// FTS5 as a quoted phrase, so what the user typed is data and not an FTS expression.
    public func textMatches(_ query: String, limit: Int = 50) throws -> [IndexEntry] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty, hasFullText else { return [] }
        budget.ticks = 0

        var statement: OpaquePointer?
        let sql = """
        SELECT title, path, snippet(docentText, 2, '', '', '…', 12) FROM docentText
        WHERE docentText MATCH ? ORDER BY rank LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let phrase = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, phrase, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var rows: [IndexEntry] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let title = sqlite3_column_text(statement, 0), let path = sqlite3_column_text(statement, 1) {
                // One line: a snippet with the file's own newlines in it wrecks a table.
                let snippet = (sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "").squeezed.trimmed
                rows.append(IndexEntry(name: String(cString: title), type: snippet.nonEmpty ?? "Text", path: String(cString: path)))
            }
            step = sqlite3_step(statement)
        }
        if step == SQLITE_INTERRUPT {
            throw SearchIndexError.query("this docset's index takes too long to search — it may be damaged")
        }
        return rows
    }

    /// The entry for a page, for following a link inside one: the page's own entry if it
    /// has one, otherwise the first symbol on it, so a click always lands on something the
    /// rest of the window can select.
    public func entry(atPath path: String, anchor: String? = nil) throws -> IndexEntry? {
        budget.ticks = 0
        let wanted = anchor.map { "\(path)#\($0)" }
        let sql = selectSQL + " WHERE path = ? OR path = ? OR path LIKE ? LIMIT 200"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, wanted ?? path, -1, transient)
        sqlite3_bind_text(statement, 2, path, -1, transient)
        sqlite3_bind_text(statement, 3, path + "#%", -1, transient)

        var rows: [IndexEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0),
                  let found = sqlite3_column_text(statement, 2) else { continue }
            let type = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            rows.append(IndexEntry(name: String(cString: name), type: type, path: String(cString: found)))
        }
        if let wanted, let exact = rows.first(where: { $0.path == wanted }) { return exact }
        if anchor == nil, let page = rows.first(where: { $0.path == path }) { return page }
        return rows.first { $0.path == path } ?? rows.first
    }

    /// How many symbols the docset indexes. Counted by SQLite: building a million rows in
    /// memory to take `.count` of them is the same answer and a hundred times the work.
    public func symbolCount() throws -> Int {
        budget.ticks = 0
        let sql: String
        switch schema {
        case .searchIndex: sql = "SELECT count(*) FROM searchIndex"
        case .coreData: sql = "SELECT count(*) FROM ZTOKEN"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SearchIndexError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SearchIndexError.query("could not count the symbols in this docset")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// `%f%o%o%` — every character of the query, in order, anywhere in the name.
    /// The LIKE wildcards a user typed are escaped, so searching for `%` finds a literal
    /// percent sign instead of every symbol in the docset.
    static func subsequencePattern(for query: String) -> String {
        var pattern = "%"
        for character in query {
            switch character {
            case "%", "_", "\\":
                pattern.append("\\")
                pattern.append(character)
            default:
                pattern.append(character)
            }
            pattern.append("%")
        }
        return pattern
    }
}
