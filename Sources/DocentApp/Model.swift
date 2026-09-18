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
    @Published private(set) var status: String = ""

    private let service: SearchService
    private var searchWorkItem: DispatchWorkItem?
    /// Searching happens off the main thread: a damaged or hostile index can take seconds
    /// to give up, and the window must keep drawing while it does.
    private let queue = DispatchQueue(label: "docent.search", qos: .userInitiated)
    private var generation = 0
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
            return
        }

        generation += 1
        let mine = generation
        let searchService = self.service
        queue.async { [weak self] in
            let outcome: Result<[Match], Error>
            do {
                outcome = .success(try searchService.find(trimmed, limit: 200, in: pool))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }   // a later search already won
                self.apply(outcome, for: trimmed)
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
        let deadline = Date().addingTimeInterval(timeout)
        let wanted = generation
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if generation == wanted, !results.isEmpty || !status.isEmpty || query.trimmed.isEmpty { return }
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

extension Match: Identifiable {
    public var id: String { "\(docset.identifier)\u{1}\(entry.name)\u{1}\(entry.path)" }
}
