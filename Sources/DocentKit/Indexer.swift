import Foundation
import SQLite3

/// Builds a docset out of a folder of documentation.
///
/// Point it at a repository: every Markdown and HTML file becomes a page, every heading
/// becomes a searchable entry, and the result is an ordinary docset that the command and the
/// app read like any other. Nothing leaves the machine and the source folder is only ever
/// read.
public struct Indexer {
    public struct Report: Sendable {
        public let docset: URL
        public let files: Int
        public let entries: Int
        public let skipped: Int
        public let pictures: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        case notAFolder(String)
        case empty(String)
        case cannotWrite(String)

        public var description: String {
            switch self {
            case .notAFolder(let path): return "\(path) is not a folder"
            case .empty(let path): return "no Markdown or HTML files under \(path)"
            case .cannotWrite(let path): return "cannot write the docset at \(path)"
            }
        }
    }

    /// Folders that are never documentation, and would bury the index in noise.
    public static let ignoredFolders: Set<String> = [
        ".git", ".build", ".svn", ".hg", "node_modules", "vendor", "Pods", "DerivedData",
        "__pycache__", ".venv", "venv", "target", "dist", "build", ".next", ".cache",
    ]
    public static let readExtensions: Set<String> = ["md", "markdown", "mdown", "html", "htm"]

    /// Files bigger than this are skipped: a docs folder with a 50 MB generated HTML file in
    /// it should not turn one `index` into a hang.
    public static let maxFileBytes = 4 * 1024 * 1024

    public let source: URL
    public let name: String
    public let keyword: String?

    public init(source: URL, name: String, keyword: String? = nil) {
        self.source = source
        self.name = name
        self.keyword = keyword
    }

    public func build(into destination: URL) throws -> Report {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.notAFolder(source.path)
        }

        let bundle = destination
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let documents = resources.appendingPathComponent("Documents", isDirectory: true)
        if fm.fileExists(atPath: bundle.path) { try fm.removeItem(at: bundle) }
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleName": name,
            "CFBundleIdentifier": "docent.indexed." + Markdown.slug(name),
            "isDashDocset": true,
            "dashIndexFilePath": "index.html",
        ]
        if let keyword { info["DocSetPlatformFamily"] = keyword }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        var rows: [IndexEntry] = []
        var files = 0
        var skipped = 0
        var pictures: [String: String] = [:]      // source path -> path under Documents
        var contents: [(title: String, path: String)] = []
        /// Page text, for the full-text table: searching your own documentation by heading
        /// alone is not what anyone means by "search my docs".
        var bodies: [(title: String, path: String, text: String)] = []

        // Both sides resolved, and compared as a prefix rather than by length: a source
        // under /var (which is /private/var) otherwise loses the first few characters of
        // every relative path.
        let rootPath = source.resolvingSymlinksInPath().standardizedFileURL.path
        for file in try documentationFiles() {
            let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { skipped += 1; continue }
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            guard let size = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int, size <= Indexer.maxFileBytes else {
                skipped += 1
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                skipped += 1
                continue
            }

            let pagePath = Indexer.pagePath(for: relative)
            let target = documents.appendingPathComponent(pagePath)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            /// Copies the pictures a page points at and hands back the page pointing at them.
            func withPictures(_ html: String) throws -> String {
                let (rewritten, copies) = PageAssets.relocate(
                    html: html, pagePath: pagePath, sourceFile: file, rootPath: rootPath)
                for copy in copies where pictures[copy.from.path] == nil {
                    let into = documents.appendingPathComponent(copy.to)
                    try fm.createDirectory(at: into.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: into.path) { try? fm.removeItem(at: into) }
                    try fm.copyItem(at: copy.from, to: into)
                    pictures[copy.from.path] = copy.to
                }
                return rewritten
            }

            if ["html", "htm"].contains(file.pathExtension.lowercased()) {
                // The bytes are written as they are unless a picture reference had to move:
                // rewriting means re-encoding, and a page that declares another charset is
                // better left alone than half-converted.
                let isUTF8 = String(data: data, encoding: .utf8) != nil
                let rewritten = isUTF8 ? try withPictures(text) : text
                if isUTF8, rewritten != text {
                    try Data(rewritten.utf8).write(to: target)
                } else {
                    try data.write(to: target)
                }
                let title = HTMLText.extractTitle(text) ?? relative
                rows.append(IndexEntry(name: title, type: "Guide", path: pagePath))
                contents.append((title, pagePath))
                bodies.append((title, pagePath, HTMLText.render(text).text))
            } else {
                let page = Markdown.render(text, fallbackTitle: relative)
                try Data(try withPictures(Markdown.document(page, sourcePath: relative)).utf8).write(to: target)
                rows.append(IndexEntry(name: page.title, type: "Guide", path: pagePath))
                contents.append((page.title, pagePath))
                for heading in page.headings where heading.level > 1 {
                    rows.append(IndexEntry(name: heading.text, type: "Section", path: "\(pagePath)#\(heading.anchor)"))
                }
                bodies.append((page.title, pagePath, text))
            }
            files += 1
        }

        guard files > 0 else { throw Failure.empty(source.path) }

        try Indexer.contentsPage(name: name, entries: contents)
            .data(using: .utf8)!
            .write(to: documents.appendingPathComponent("index.html"))
        rows.append(IndexEntry(name: name, type: "Guide", path: "index.html"))

        let index = resources.appendingPathComponent("docSet.dsidx")
        try write(rows, to: index)
        try writeFullText(bodies, to: index)
        return Report(docset: bundle, files: files, entries: rows.count, skipped: skipped,
                      pictures: pictures.count)
    }

    /// Every documentation file under the source folder, sorted, with noise folders and
    /// symlinks left out — a link out of the tree would copy files nobody meant to index.
    func documentationFiles() throws -> [URL] {
        let fm = FileManager.default
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values?.isDirectory == true {
                if Indexer.ignoredFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true,
                  Indexer.readExtensions.contains(url.pathExtension.lowercased()) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    /// The `.docset` folder a name installs as.
    public static func folderName(for name: String) -> String {
        let safe = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let trimmed = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (trimmed.isEmpty ? "Docs" : trimmed) + ".docset"
    }

    /// `docs/guide.md` → `docs/guide.html`, with anything awkward in a name flattened.
    static func pagePath(for relative: String) -> String {
        let components = relative.split(separator: "/").map { component -> String in
            let safe = component.map { character -> Character in
                character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                    ? character : "-"
            }
            return String(safe)
        }
        var path = components.joined(separator: "/")
        for suffix in [".md", ".markdown", ".mdown"] where path.lowercased().hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count)) + ".html"
        }
        return path
    }

    /// `Resources/shot.png` → the same shape, with anything awkward in a name flattened.
    /// Unlike a page, the extension is left alone: it is what makes the file a picture.
    static func assetPath(for relative: String) -> String {
        relative.split(separator: "/").map { component in
            String(component.map { character in
                character.isLetter || character.isNumber || character == "." || character == "-"
                    || character == "_" ? character : "-"
            })
        }.joined(separator: "/")
    }

    static func contentsPage(name: String, entries: [(title: String, path: String)]) -> String {
        let items = entries.map { entry in
            "<li><a href=\"\(Markdown.escape(entry.path))\">\(Markdown.escape(entry.title))</a></li>"
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(Markdown.escape(name))</title></head>
        <body><h1>\(Markdown.escape(name))</h1>
        <ul>
        \(items)
        </ul></body></html>
        """
    }

    /// A full-text table beside the ordinary index.
    ///
    /// It lives in the same SQLite file under a name of Docent's own, so other docset
    /// readers ignore it and the docset stays a perfectly ordinary docset.
    private func writeFullText(_ bodies: [(title: String, path: String, text: String)], to url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            throw Failure.cannotWrite(url.path)
        }
        defer { sqlite3_close(db) }

        // FTS5 is part of the system SQLite, but a build without it should not lose the
        // whole docset — the index is what matters, the text search is a bonus.
        guard sqlite3_exec(db, "CREATE VIRTUAL TABLE docentText USING fts5(title, path UNINDEXED, body)", nil, nil, nil) == SQLITE_OK else {
            return
        }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO docentText(title, path, body) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK else {
            throw Failure.cannotWrite(url.path)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for body in bodies {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, body.title, -1, transient)
            sqlite3_bind_text(statement, 2, body.path, -1, transient)
            sqlite3_bind_text(statement, 3, body.text, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.cannotWrite(url.path) }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func write(_ rows: [IndexEntry], to url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else { throw Failure.cannotWrite(url.path) }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.cannotWrite(url.path) }
        }
        try exec("CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)")
        try exec("CREATE UNIQUE INDEX anchor ON searchIndex (name, type, path)")
        try exec("BEGIN")

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO searchIndex(name, type, path) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK else {
            throw Failure.cannotWrite(url.path)
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, row.name, -1, transient)
            sqlite3_bind_text(statement, 2, row.type, -1, transient)
            sqlite3_bind_text(statement, 3, row.path, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.cannotWrite(url.path) }
        }
        try exec("COMMIT")
    }
}
