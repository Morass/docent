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

    private var db: OpaquePointer?
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
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0),
                  let path = sqlite3_column_text(statement, 2) else { continue }
            let type = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            rows.append(IndexEntry(name: String(cString: name), type: type, path: String(cString: path)))
        }
        return rows
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
