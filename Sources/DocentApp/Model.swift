import Foundation
import DocentKit
import SwiftUI

/// What the window is showing. One object, so the search field, the list and the page can
/// never disagree about which result is selected.
@MainActor
final class Browser: ObservableObject {
    @Published var query: String = "" { didSet { scheduleSearch() } }
    @Published private(set) var docsets: [Docset] = []
    @Published private(set) var results: [Match] = []
    @Published var selection: Match.ID? { didSet { pushHistoryIfNeeded() } }
    @Published var docsetFilter: String? {
        didSet {
            guard docsetFilter != oldValue else { return search() }
            expanded = []
            reloadTree()
            search()
        }
    }
    /// Which way pages are painted. Remembered between launches, because it is a reading
    /// preference and not a per-session choice.
    @Published var pageAppearance: PageAppearance = PageAppearance.remembered {
        didSet { pageAppearance.remember() }
    }
    @Published private(set) var status: String = ""
    /// The selected docset laid out as folders, files and declarations. Empty when nothing
    /// is selected, or when the docset is too large to draw at once.
    @Published private(set) var tree: [DocTree.Node] = []
    /// Which tree rows are open, kept here so it survives a search and coming back.
    @Published var expanded: Set<String> = []

    private let service: SearchService
    private var searchWorkItem: DispatchWorkItem?
    /// Searching happens off the main thread: a damaged or hostile index can take seconds
    /// to give up, and the window must keep drawing while it does.
    private let queue = DispatchQueue(label: "docent.search", qos: .userInitiated)
    private var generation = 0
    /// The last search whose results have actually been applied. Without this, a waiter
    /// cannot tell "no results yet" from "the previous query's results".
    private(set) var completedGeneration = 0
    private var history: [Match] = []
    private var historyIndex: Int = -1
    private var restoringHistory = false

    init(service: SearchService = SearchService()) {
        self.service = service
        reloadDocsets()
    }

    var selectedMatch: Match? {
        results.first { $0.id == selection }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    /// Indexing, from the window. The panel picks a folder; everything else — building the
    /// docset, installing it, reloading the library and selecting the result — happens here,
    /// so the menu item is three lines and this is what the self-test drives.
    @discardableResult
    func index(folder: URL, name: String? = nil, keyword: String? = nil, replace: Bool = false) -> Bool {
        let title = name ?? folder.lastPathComponent
        let word = keyword ?? Markdown.slug(title).nonEmpty
        let destination = service.library.prepareInstallDirectory()
            .appendingPathComponent(Indexer.folderName(for: title))

        if FileManager.default.fileExists(atPath: destination.path), !replace {
            status = "“\(title)” is already indexed. Index it again to rebuild it."
            pendingReindex = (folder, title, word)
            return false
        }
        pendingReindex = nil
        status = "Indexing \(title)…"
        indexing = true

        let indexer = Indexer(source: folder, name: title, keyword: word)
        queue.async { [weak self] in
            let outcome: Result<Indexer.Report, Error>
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                outcome = .success(try indexer.build(into: destination))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexing = false
                switch outcome {
                case .success(let report):
                    self.reloadDocsets()
                    self.docsetFilter = word ?? title
                    var line = "Indexed \(title): \(report.files) file\(report.files == 1 ? "" : "s"), \(report.entries) entries"
                    if report.pictures > 0 {
                        line += ", \(report.pictures) picture\(report.pictures == 1 ? "" : "s")"
                    }
                    self.status = line + "."
                case .failure(let error):
                    self.status = "Could not index \(title): \(error)"
                }
            }
        }
        return true
    }

    /// A folder the user asked for that is already indexed, kept so the menu can offer to
    /// rebuild it without asking them to find it again.
    @Published private(set) var pendingReindex: (folder: URL, name: String, keyword: String?)?
    @Published private(set) var indexing = false

    func rebuildPending() {
        guard let pending = pendingReindex else { return }
        index(folder: pending.folder, name: pending.name, keyword: pending.keyword, replace: true)
    }

    /// What `docent browse` asked the window to show, if anything. Applied when the window
    /// appears and whenever Docent comes forward, because the terminal can ask for a docset
    /// while the window is already open — and then macOS delivers no launch arguments.
    @discardableResult
    func applyOpenRequest(at url: URL? = nil, now: Date = Date()) -> Bool {
        let url = url ?? OpenRequest.url(library: service.library)
        guard let request = OpenRequest.consume(at: url, now: now) else { return false }
        reloadDocsets()
        if let wanted = request.docset {
            if docsets.contains(where: { service.matches(docset: $0, hint: wanted) }) {
                docsetFilter = wanted
            } else {
                status = "“\(wanted)” is not in the library."
            }
        }
        if let query = request.query { self.query = query }
        return true
    }

    func reloadDocsets() {
        docsets = service.docsets()
        reloadTree()
        status = docsets.isEmpty ? Browser.emptyLibraryMessage : ""
        search()
    }

    static let emptyLibraryMessage = """
    No docsets yet. Put a .docset folder in ~/Library/Application Support/Docent/DocSets \
    — Docent also reads Dash's and Zeal's folders if you already have them.
    """

    /// Typing is not a search per keystroke: a short coalescing delay keeps a big library
    /// responsive while someone types a whole symbol name.
    private func scheduleSearch() {
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search() }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func search() {
        let pool = docsetFilter.map { hint in docsets.filter { service.matches(docset: $0, hint: hint) } }
        let trimmed = query.trimmed
        // Picking a docset with an empty search field means "show me what is in here".
        if trimmed.isEmpty, let pool, !pool.isEmpty {
            browse(pool)
            return
        }
        guard !trimmed.isEmpty else {
            results = []
            selection = nil
            if !docsets.isEmpty { status = "" }
            generation += 1
            completedGeneration = generation
            return
        }

        generation += 1
        let mine = generation
        let searchService = self.service
        queue.async { [weak self] in
            let outcome: Result<[Match], Error>
            do {
                // Names first; if nothing is called this, look inside the pages of docsets
                // Docent indexed itself.
                var found = try searchService.find(trimmed, limit: 200, in: pool)
                if found.isEmpty {
                    found = try searchService.findInText(trimmed, limit: 50, in: pool)
                }
                outcome = .success(found)
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }   // a later search already won
                self.apply(outcome, for: trimmed)
                self.completedGeneration = mine
            }
        }
    }

    /// Rebuilds the tree for whatever docset is selected. Off the main thread: it reads
    /// every row of the index.
    private func reloadTree() {
        let hint = docsetFilter
        guard let hint else {
            tree = []
            return
        }
        let pool = docsets.filter { service.matches(docset: $0, hint: hint) }
        guard let docset = pool.first else {
            tree = []
            return
        }
        let generation = self.generation
        queue.async { [weak self] in
            let entries = (try? SearchIndex(url: docset.indexURL))
                .flatMap { try? $0.candidates(matching: "", limit: DocTree.maximumEntries + 1) } ?? []
            let built = DocTree.build(entries, indexPage: docset.indexPage)
            DispatchQueue.main.async {
                guard let self, self.docsetFilter == hint, self.generation >= generation else { return }
                self.tree = built
                // Folders open, files closed: the shape of the project at a glance, without
                // a thousand method names in the way.
                if self.expanded.isEmpty {
                    // Folders open, files closed: the shape of the project at a glance,
                    // without a thousand method names in the way.
                    var open: Set<String> = []
                    func openFolders(_ nodes: [DocTree.Node]) {
                        for node in nodes where node.entry == nil {
                            open.insert(node.id)
                            openFolders(node.children)
                        }
                    }
                    openFolders(built)
                    self.expanded = open
                }
            }
        }
    }

    /// Whether the window is showing the project rather than a list of matches.
    var showsTree: Bool { query.trimmed.isEmpty && !tree.isEmpty }

    /// The rows a reader can actually see, top to bottom — what the arrow keys move through.
    var visibleTreeRows: [DocTree.Node] {
        var rows: [DocTree.Node] = []
        func walk(_ nodes: [DocTree.Node]) {
            for node in nodes {
                rows.append(node)
                if expanded.contains(node.id) { walk(node.children) }
            }
        }
        walk(tree)
        return rows
    }

    /// Open or close the row that is selected, so the keyboard can walk the tree.
    func toggleSelectedRow(open: Bool) {
        let rows = visibleTreeRows
        guard let current = rows.firstIndex(where: { isSelected($0) }) else { return }
        let node = rows[current]
        if open {
            if !node.children.isEmpty { expanded.insert(node.id) }
        } else if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else if let parent = parentOf(node.id) {
            // Already closed: step out, the way a file tree does.
            expanded.remove(parent.id)
            select(parent)
        }
    }

    /// The tree row for whatever is being read, so the navigator can follow along.
    var selectedTreeRowID: String? {
        guard let match = selectedMatch else { return nil }
        func walk(_ nodes: [DocTree.Node]) -> String? {
            for node in nodes {
                if node.entry?.path == match.entry.path { return node.id }
                if let found = walk(node.children) { return found }
            }
            return nil
        }
        return walk(tree)
    }

    func isSelected(_ node: DocTree.Node) -> Bool {
        guard let entry = node.entry, let docset = currentDocset else { return false }
        return selection == Match(docset: docset, entry: entry, score: 0).id
    }

    private func parentOf(_ id: String) -> DocTree.Node? {
        func walk(_ nodes: [DocTree.Node], parent: DocTree.Node?) -> DocTree.Node? {
            for node in nodes {
                if node.id == id { return parent }
                if let found = walk(node.children, parent: node) { return found }
            }
            return nil
        }
        return walk(tree, parent: nil)
    }

    /// Follows a link inside a page: the window moves with it, so Back comes back here.
    /// Returns false when the target is not part of any docset, and the caller lets the
    /// web view deal with it.
    @discardableResult
    func followLink(to url: URL, anchor: String?) -> Bool {
        guard let match = service.match(forFile: url, anchor: anchor, in: docsets) else { return false }
        if !results.contains(where: { $0.id == match.id }) { results.insert(match, at: 0) }
        selection = match.id
        return true
    }

    /// Where the reader had scrolled to on a page, kept per page so going back returns to
    /// the paragraph they left rather than to the top of it.
    private var scrollOffsets: [String: Double] = [:]

    func rememberScroll(_ offset: Double, for id: Match.ID) {
        scrollOffsets[id] = offset
    }

    func rememberedScroll(for id: Match.ID) -> Double? { scrollOffsets[id] }

    /// Opens the page a tree row stands for, through the same selection the list uses.
    func select(_ node: DocTree.Node) {
        guard let entry = node.entry, let docset = currentDocset else { return }
        let match = Match(docset: docset, entry: entry, score: 0)
        if !results.contains(where: { $0.id == match.id }) { results.insert(match, at: 0) }
        selection = match.id
    }

    var currentDocset: Docset? {
        guard let hint = docsetFilter else { return nil }
        return docsets.first { service.matches(docset: $0, hint: hint) }
    }

    /// Everything in the selected docset, in index order.
    private func browse(_ pool: [Docset]) {
        generation += 1
        let mine = generation
        let searchService = service
        queue.async { [weak self] in
            let found = (try? searchService.find("", limit: 500, in: pool)) ?? []
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                self.results = found
                self.status = found.isEmpty ? "This docset has no entries." : ""
                // Picking a docset means "show me this": land on its front page, which for
                // a project Docent indexed is the README with the rest of the project laid
                // out under it. Keeping whatever was selected before would leave the reader
                // wherever their last search happened to stop.
                let front = found.first { match in
                    match.entry.path == match.docset.indexPage
                        || match.entry.path.hasPrefix(match.docset.indexPage + "#")
                }
                if let front {
                    self.selection = front.id
                } else if let current = self.selection, found.contains(where: { $0.id == current }) {
                    self.completedGeneration = mine
                    return
                } else {
                    self.selection = found.first?.id
                }
                self.completedGeneration = mine
            }
        }
    }

    private func apply(_ outcome: Result<[Match], Error>, for query: String) {
        switch outcome {
        case .success(let found):
            results = found
            // Say what was searched: with an indexed docset the page text was searched too,
            // and "no matches" after that means something different.
            status = found.isEmpty
                ? (service.canSearchText()
                   ? "Nothing is called “\(query)”, and no page mentions it."
                   : "Nothing matches “\(query)”.")
                : ""
            if let selection, found.contains(where: { $0.id == selection }) { return }
            selection = found.first?.id
        case .failure(let error):
            results = []
            status = "\(error)"
        }
    }

    /// The same search, run and applied before returning. The self-test uses it; the window
    /// never needs it.
    func searchAndWait(timeout: TimeInterval = 10) {
        search()
        let wanted = generation
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, completedGeneration < wanted {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    func location(of match: Match) -> (url: URL, anchor: String?)? {
        try? service.location(of: match)
    }

    func text(of match: Match) -> String? {
        try? service.page(for: match).text
    }

    // MARK: - Moving through results with the keyboard

    func moveSelection(by offset: Int) {
        // In the tree the arrows walk the rows the reader can see, not the flat result list
        // behind it: moving from a file to the method below it is the whole point.
        if showsTree {
            let rows = visibleTreeRows
            guard !rows.isEmpty else { return }
            let current = rows.firstIndex { isSelected($0) } ?? 0
            var next = min(max(0, current + offset), rows.count - 1)
            // Folders have no page; keep going the same way until something opens.
            while rows[next].entry == nil, next > 0, next < rows.count - 1 {
                next += offset > 0 ? 1 : -1
            }
            if rows[next].entry != nil { select(rows[next]) }
            return
        }
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? 0
        let next = min(max(0, current + offset), results.count - 1)
        selection = results[next].id
    }

    // MARK: - History

    private func pushHistoryIfNeeded() {
        guard !restoringHistory, let match = selectedMatch else { return }
        if historyIndex >= 0, historyIndex < history.count, history[historyIndex] == match { return }
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        history.append(match)
        historyIndex = history.count - 1
    }

    func goBack() { step(to: historyIndex - 1) }
    func goForward() { step(to: historyIndex + 1) }

    private func step(to index: Int) {
        guard index >= 0, index < history.count else { return }
        historyIndex = index
        let match = history[index]
        restoringHistory = true
        if !results.contains(where: { $0.id == match.id }) { results.insert(match, at: 0) }
        selection = match.id
        restoringHistory = false
    }
}

/// Follow the app's appearance, or pin pages light or dark.
enum PageAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light Pages"
        case .dark: return "Dark Pages"
        }
    }

    func theme(systemIsDark: Bool) -> ReadingTheme {
        switch self {
        case .system: return .matching(isDark: systemIsDark)
        case .light: return .light
        case .dark: return .dark
        }
    }

    private static let key = "PageAppearance"

    static var remembered: PageAppearance {
        PageAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    func remember() { UserDefaults.standard.set(rawValue, forKey: PageAppearance.key) }
}

extension Match: Identifiable {
    public var id: String { "\(docset.identifier)\u{1}\(entry.name)\u{1}\(entry.path)" }
}
