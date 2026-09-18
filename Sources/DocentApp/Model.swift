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
    @Published var docsetFilter: String? { didSet { search() } }
    /// Which way pages are painted. Remembered between launches, because it is a reading
    /// preference and not a per-session choice.
    @Published var pageAppearance: PageAppearance = PageAppearance.remembered {
        didSet { pageAppearance.remember() }
    }
    @Published private(set) var status: String = ""

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

    func reloadDocsets() {
        docsets = service.docsets()
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

    private func apply(_ outcome: Result<[Match], Error>, for query: String) {
        switch outcome {
        case .success(let found):
            results = found
            status = found.isEmpty ? "Nothing matches “\(query)”." : ""
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
