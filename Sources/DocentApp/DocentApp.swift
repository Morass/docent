import SwiftUI
import DocentKit

@main
struct DocentApp: App {
    @StateObject private var browser = Browser()
    @FocusState private var searchFocused: Bool

    init() {
        SelfTest.runIfAsked()
    }

    var body: some Scene {
        WindowGroup("Docent") {
            BrowserWindow(browser: browser)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Back") { browser.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!browser.canGoBack)
                Button("Forward") { browser.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!browser.canGoForward)
                Divider()
                Button("Reload Docsets") { browser.reloadDocsets() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) { }
        }
    }
}

struct BrowserWindow: View {
    @ObservedObject var browser: Browser
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            resultsList
        } detail: {
            page
        }
        .onAppear { searchFocused = true }
        .searchable(text: $browser.query, placement: .toolbar, prompt: "Search the docsets")
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { browser.docsetFilter },
            set: { browser.docsetFilter = $0 }
        )) {
            Section("Docsets") {
                Text("All docsets").tag(String?.none)
                ForEach(browser.docsets, id: \.identifier) { docset in
                    HStack {
                        Text(docset.name)
                        Spacer()
                        if let keyword = docset.keyword {
                            Text(keyword).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    .tag(String?.some(docset.keyword ?? docset.name))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 210)
    }

    private var resultsList: some View {
        Group {
            if browser.results.isEmpty {
                ContentUnavailableView(
                    browser.query.isEmpty ? "Search your docsets" : "No matches",
                    systemImage: "magnifyingglass",
                    description: Text(browser.status.isEmpty
                                      ? "Type a symbol name. `go:Println` searches one docset."
                                      : browser.status)
                )
            } else {
                List(browser.results, selection: $browser.selection) { match in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.entry.name).font(.body)
                        HStack(spacing: 6) {
                            Text(match.entry.type)
                            Text("·")
                            Text(match.docset.name)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(match.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 300)
    }

    private var page: some View {
        Group {
            if let match = browser.selectedMatch, let location = browser.location(of: match) {
                PageView(location: location, documentsRoot: match.docset.documentsURL)
                    .navigationTitle(match.entry.name)
                    .navigationSubtitle(match.docset.name)
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "book.closed",
                    description: Text(browser.docsets.isEmpty ? Browser.emptyLibraryMessage : "Pick a result to read it.")
                )
            }
        }
    }
}
