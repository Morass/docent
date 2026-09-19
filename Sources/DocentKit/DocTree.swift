import Foundation

/// The shape of a docset, for reading rather than searching: folders, the files in them,
/// and what each file declares.
///
/// Search answers "where is this"; a tree answers "what is in here", which is the question
/// someone has when they open a project they do not know yet.
public enum DocTree {
    public struct Node: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// The kind, when there is one worth showing beside the name.
        public let detail: String?
        /// The entry this node opens, or nothing for a folder that only holds others.
        public let entry: IndexEntry?
        public var children: [Node]

        public init(id: String, title: String, detail: String? = nil,
                    entry: IndexEntry? = nil, children: [Node] = []) {
            self.id = id
            self.title = title
            self.detail = detail
            self.entry = entry
            self.children = children
        }

        public var isLeaf: Bool { children.isEmpty }
    }

    /// A docset too large to lay out at once. Past this the window shows results and lets
    /// the reader search; drawing a hundred thousand rows helps nobody.
    public static let maximumEntries = 20_000

    /// The tree for a docset: its own structure when Docent indexed it, and a list by kind
    /// when it came from somewhere else and its paths mean nothing to a reader.
    public static func build(_ entries: [IndexEntry], indexPage: String = "index.html") -> [Node] {
        guard entries.count <= maximumEntries else { return [] }
        let hasStructure = entries.contains { $0.type == "File" }
        return hasStructure ? structure(entries, indexPage: indexPage) : byKind(entries)
    }

    // MARK: - A project's own shape

    /// Folders, then files, then what each file declares — with members under the type they
    /// belong to, the way the code is written.
    public static func structure(_ entries: [IndexEntry], indexPage: String = "index.html") -> [Node] {
        var pages: [String: [IndexEntry]] = [:]          // page path → its anchored entries
        var fileEntry: [String: IndexEntry] = [:]        // page path → the page's own entry
        var documents: [IndexEntry] = []
        var overview: IndexEntry?
        var order: [String] = []

        for entry in entries {
            let page = String(entry.path.split(separator: "#", maxSplits: 1).first ?? "")
            guard !page.isEmpty else { continue }
            if page == indexPage, !entry.path.contains("#") { overview = entry; continue }
            if !entry.path.contains("#") {
                if entry.type == "File" {
                    if fileEntry[page] == nil { order.append(page) }
                    fileEntry[page] = entry
                } else {
                    documents.append(entry)
                    if fileEntry[page] == nil, pages[page] == nil { order.append(page) }
                }
            } else {
                pages[page, default: []].append(entry)
                if fileEntry[page] == nil, pages[page]?.count == 1, !order.contains(page) { order.append(page) }
            }
        }

        // Documents keep the title their author gave them; code files are named by file.
        var documentTitle: [String: IndexEntry] = [:]
        for document in documents where documentTitle[String(document.path.split(separator: "#").first ?? "")] == nil {
            documentTitle[String(document.path.split(separator: "#").first ?? "")] = document
        }

        var roots: [Node] = []
        if let overview {
            roots.append(Node(id: "overview", title: overview.name, detail: nil, entry: overview))
        }

        var folders: [String: [Node]] = [:]              // folder path → file nodes
        var folderOrder: [String] = []
        for page in order {
            let entry = fileEntry[page] ?? documentTitle[page]
            let folder = (page as NSString).deletingLastPathComponent
            let title: String
            if let entry, entry.type != "File" {
                title = entry.name
            } else {
                title = Self.fileTitle(page)
            }
            let node = Node(id: page, title: title,
                            detail: entry?.type == "File" ? nil : entry?.type,
                            entry: entry ?? IndexEntry(name: title, type: "Guide", path: page),
                            children: symbolNodes(pages[page] ?? []))
            if folders[folder] == nil { folderOrder.append(folder) }
            folders[folder, default: []].append(node)
        }

        // Folders nest: Sources ▸ Daub ▸ Model, the way the project is laid out on disk,
        // rather than one flat row per full path.
        roots.append(contentsOf: (folders[""] ?? []).sorted(by: byTitle))
        var nested: [Node] = []
        for folder in folderOrder.sorted() where !folder.isEmpty {
            let files = (folders[folder] ?? []).sorted(by: byTitle)
            place(files, at: folder.split(separator: "/").map(String.init), in: &nested, prefix: [])
        }
        roots.append(contentsOf: nested)
        return roots
    }

    static func byTitle(_ a: Node, _ b: Node) -> Bool {
        a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    /// Files into the folder they belong to, making each folder on the way if it is not
    /// there yet. Folders come before files, as every file tree shows them.
    static func place(_ files: [Node], at path: [String], in nodes: inout [Node], prefix: [String]) {
        guard let first = path.first else {
            nodes.append(contentsOf: files)
            return
        }
        let id = "folder:" + (prefix + [first]).joined(separator: "/")
        let existing = nodes.firstIndex { $0.id == id }
        let index: Int
        if let existing {
            index = existing
        } else {
            // Before the files already in this folder, after the folders.
            let insertAt = nodes.firstIndex { $0.entry != nil } ?? nodes.count
            nodes.insert(Node(id: id, title: first, detail: nil, children: []), at: insertAt)
            index = insertAt
        }
        place(files, at: Array(path.dropFirst()), in: &nodes[index].children, prefix: prefix + [first])
    }

    /// `Sources/Canvas.swift.html` → `Canvas.swift`; `docs/DESIGN.html` → `DESIGN`.
    static func fileTitle(_ page: String) -> String {
        var name = (page as NSString).lastPathComponent
        for suffix in [".html", ".htm"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    /// `Canvas`, then `Canvas.draw` under it: a file's declarations nested the way they are
    /// written, so a type reads as a type and not as a list of forty equal names.
    static func symbolNodes(_ entries: [IndexEntry]) -> [Node] {
        var roots: [Node] = []
        var index: [String: [Int]] = [:]                 // name → path through the tree

        func insert(_ entry: IndexEntry) {
            let parts = entry.name.split(separator: ".").map(String.init)
            let parent = parts.dropLast().joined(separator: ".")
            let node = Node(id: entry.path, title: parts.last ?? entry.name,
                            detail: entry.type, entry: entry)
            if !parent.isEmpty, let route = index[parent] {
                var target = route
                withNode(&roots, at: &target) { $0.children.append(node) }
                index[entry.name] = route + [lastChildIndex(roots, at: route)]
            } else {
                roots.append(node)
                index[entry.name] = [roots.count - 1]
            }
        }

        func withNode(_ nodes: inout [Node], at route: inout [Int], _ body: (inout Node) -> Void) {
            guard let first = route.first, first < nodes.count else { return }
            if route.count == 1 {
                body(&nodes[first])
            } else {
                var rest = Array(route.dropFirst())
                withNode(&nodes[first].children, at: &rest) { body(&$0) }
            }
        }

        func lastChildIndex(_ nodes: [Node], at route: [Int]) -> Int {
            var current = nodes
            for (offset, step) in route.enumerated() {
                guard step < current.count else { return 0 }
                if offset == route.count - 1 { return max(0, current[step].children.count - 1) }
                current = current[step].children
            }
            return 0
        }

        for entry in entries { insert(entry) }
        return roots
    }

    // MARK: - Somebody else's docset

    /// Classes, Functions, Methods…: the shape a docset that is not ours still has.
    public static func byKind(_ entries: [IndexEntry]) -> [Node] {
        let groups = Dictionary(grouping: entries) { $0.type }
        return groups.keys.sorted().map { kind in
            let children = (groups[kind] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { Node(id: "\(kind)/\($0.name)/\($0.path)", title: $0.name, detail: nil, entry: $0) }
            return Node(id: "kind:" + kind, title: kind, detail: "\(children.count)", children: children)
        }
    }
}
