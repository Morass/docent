import Foundation
import SQLite3
@testable import DocentKit

/// Builds a real docset in a temporary folder: an Info.plist, a `docSet.dsidx` with rows in
/// it, and HTML files on disk. Every test runs against one of these and never against a
/// docset the machine happens to have.
enum Fixture {
    enum Schema { case searchIndex, coreData }

    struct Row {
        let name: String
        let type: String
        let path: String
        init(_ name: String, _ type: String, _ path: String) {
            self.name = name
            self.type = type
            self.path = path
        }
    }

    @discardableResult
    static func docset(
        in root: URL,
        name: String = "Pretend",
        identifier: String? = nil,
        keyword: String? = "pretend",
        schema: Schema = .searchIndex,
        rows: [Row] = [Row("Widget", "Class", "widget.html"), Row("Widget.spin", "Method", "widget.html#spin")],
        pages: [String: String] = ["widget.html": "<html><head><title>Widget</title></head><body><h1>Widget</h1><p>A widget spins.</p><a name=\"spin\"></a><h2>spin()</h2><p>Spins the widget.</p><h2>stop()</h2><p>Stops it.</p></body></html>"]
    ) throws -> Docset {
        let fm = FileManager.default
        let bundle = root.appendingPathComponent("\(name).docset")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let documents = resources.appendingPathComponent("Documents")
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleName": name,
            "CFBundleIdentifier": identifier ?? name.lowercased(),
            "isDashDocset": true,
        ]
        if let keyword { info["DocSetPlatformFamily"] = keyword }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        for (path, html) in pages {
            let url = documents.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try html.data(using: .utf8)!.write(to: url)
        }

        try writeIndex(at: resources.appendingPathComponent("docSet.dsidx"), schema: schema, rows: rows)

        guard let docset = Docset(contentsOf: bundle) else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture docset did not load"])
        }
        return docset
    }

    static func writeIndex(at url: URL, schema: Schema, rows: [Row]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            throw NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot create fixture index"])
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw NSError(domain: "Fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

        switch schema {
        case .searchIndex:
            try exec("CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)")
            for row in rows {
                try exec("INSERT INTO searchIndex(name, type, path) VALUES (\(quoted(row.name)), \(quoted(row.type)), \(quoted(row.path)))")
            }
        case .coreData:
            try exec("CREATE TABLE ZTOKENTYPE(Z_PK INTEGER PRIMARY KEY, ZTYPENAME TEXT)")
            try exec("CREATE TABLE ZFILEPATH(Z_PK INTEGER PRIMARY KEY, ZPATH TEXT)")
            try exec("CREATE TABLE ZTOKENMETAINFORMATION(Z_PK INTEGER PRIMARY KEY, ZFILE INTEGER, ZANCHOR TEXT)")
            try exec("CREATE TABLE ZTOKEN(Z_PK INTEGER PRIMARY KEY, ZTOKENNAME TEXT, ZTOKENTYPE INTEGER, ZMETAINFORMATION INTEGER)")
            for (offset, row) in rows.enumerated() {
                let pk = offset + 1
                let parts = row.path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let file = String(parts[0])
                let anchor = parts.count > 1 ? String(parts[1]) : ""
                try exec("INSERT INTO ZTOKENTYPE(Z_PK, ZTYPENAME) VALUES (\(pk), \(quoted(row.type)))")
                try exec("INSERT INTO ZFILEPATH(Z_PK, ZPATH) VALUES (\(pk), \(quoted(file)))")
                try exec("INSERT INTO ZTOKENMETAINFORMATION(Z_PK, ZFILE, ZANCHOR) VALUES (\(pk), \(pk), \(quoted(anchor)))")
                try exec("INSERT INTO ZTOKEN(Z_PK, ZTOKENNAME, ZTOKENTYPE, ZMETAINFORMATION) VALUES (\(pk), \(quoted(row.name)), \(pk), \(pk))")
            }
        }
    }
}

extension Fixture {
    /// Replaces an index with a database that has tables Docent does not understand.
    static func writeIndexWithNoKnownTables(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            throw NSError(domain: "Fixture", code: 4)
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE somethingElse(a TEXT)", nil, nil, nil)
    }
}

extension Fixture {
    /// Replaces the metadata table with a view that never stops producing rows — the shape
    /// a review seat used to hang a search.
    static func makeMetaInformationEndless(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            throw NSError(domain: "Fixture", code: 5)
        }
        defer { sqlite3_close(db) }
        for sql in [
            "DROP TABLE ZTOKENMETAINFORMATION",
            """
            CREATE VIEW ZTOKENMETAINFORMATION AS
            WITH RECURSIVE endless(n) AS (SELECT 1 UNION ALL SELECT n FROM endless)
            SELECT 999 AS Z_PK, 1 AS ZFILE, NULL AS ZANCHOR FROM endless
            """,
        ] {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw NSError(domain: "Fixture", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }
}
