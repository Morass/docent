import SwiftUI
import AppKit
import DocentKit

@main
struct DocentApp: App {
    /// File ▸ Index Folder… — pick a folder of documentation and turn it into a docset
    /// without leaving the window.
    @MainActor
    private func indexFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index"
        panel.message = "Choose a folder of documentation — a repository, or a docs folder inside one."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        if !browser.index(folder: folder) {
            let alert = NSAlert()
            alert.messageText = "“\(folder.lastPathComponent)” is already indexed."
            alert.informativeText = "Rebuild it from the folder as it is now?"
            alert.addButton(withTitle: "Rebuild")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { browser.rebuildPending() }
        }
    }

    @StateObject private var browser = Browser()
    @FocusState private var searchFocused: Bool

    init() {
        RemoteContentBlock.prepare()
        SelfTest.runIfAsked()
    }

    var body: some Scene {
        WindowGroup("Docent") {
            BrowserWindow(browser: browser)
                .frame(minWidth: 720, minHeight: 440)
                .onAppear { Screenshot.scheduleIfRequested(browser: browser) }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Index Folder…") { indexFolder() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { NotificationCenter.default.post(name: .docentFocusSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Back") { browser.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!browser.canGoBack)
                Button("Forward") { browser.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!browser.canGoForward)
                Divider()
                Picker("Page Appearance", selection: $browser.pageAppearance) {
                    ForEach(PageAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                Button("Reload Docsets") { browser.reloadDocsets() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct BrowserWindow: View {
    @ObservedObject var browser: Browser
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // A plain split view rather than NavigationSplitView: its sidebar column is drawn
        // by AppKit outside the window's layer tree, which makes it impossible to capture
        // and gives nothing back in a three-pane reader like this one.
        HSplitView {
            sidebar
            searchColumn
            page
        }
        .onAppear {
            searchFocused = true
            browser.applyOpenRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            browser.applyOpenRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .docentFocusSearch)) { _ in
            searchFocused = true
        }
    }

    private var sidebar: some View {
        // Plain rows rather than a vibrant sidebar List: vibrancy cannot be drawn into a
        // bitmap (it comes out as a white slab in the README picture) and buys nothing here.
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text("DOCSETS")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

                docsetRow(title: "All docsets", keyword: nil, tag: nil)
                ForEach(browser.docsets, id: \.identifier) { docset in
                    docsetRow(title: docset.name, keyword: docset.keyword, tag: docset.keyword ?? docset.name)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(minWidth: 160, idealWidth: 210, maxWidth: 320)
    }

    private func docsetRow(title: String, keyword: String?, tag: String?) -> some View {
        let selected = browser.docsetFilter == tag
        return Button {
            browser.docsetFilter = tag
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let keyword {
                    Text(keyword).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    /// The search field lives above the results rather than in the toolbar: it is the first
    /// thing the window is for, it keeps the keyboard on one column, and ↑/↓ can move the
    /// selection while the cursor stays in the field.
    private var searchColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.primary.opacity(0.7))
                TextField("Search the docsets", text: $browser.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.upArrow) { browser.moveSelection(by: -1); return .handled }
                    .onKeyPress(.downArrow) { browser.moveSelection(by: 1); return .handled }
                if !browser.query.isEmpty {
                    Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            Divider()
            results
            // What just happened: indexing progress, the result of it, or why a search found
            // nothing. Without this the menu item looks like it did nothing.
            if !browser.status.isEmpty || browser.indexing {
                Divider()
                HStack(spacing: 6) {
                    if browser.indexing {
                        ProgressView().controlSize(.small)
                    }
                    Text(browser.status)
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 480)
    }

    private var results: some View {
        Group {
            if browser.results.isEmpty {
                ContentUnavailableView(
                    browser.query.isEmpty ? "Search your docsets" : "No matches",
                    systemImage: "magnifyingglass",
                    description: Text(browser.status.isEmpty
                                      ? "Type a symbol name. “go:Println” searches one docset."
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
                        // `.secondary` is barely there against a dark list; the first trial
                        // called the window low-contrast and this line was part of it.
                        .foregroundStyle(Color.primary.opacity(0.78))
                    }
                    .tag(match.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private var page: some View {
        Group {
            if let match = browser.selectedMatch, let location = browser.location(of: match) {
                PageView(location: location,
                         documentsRoot: match.docset.readAccessURL,
                         theme: browser.pageAppearance.theme(systemIsDark: colorScheme == .dark))
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("\(match.entry.name) — \(match.docset.name)")
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "book.closed",
                    description: Text(browser.docsets.isEmpty ? Browser.emptyLibraryMessage : "Pick a result to read it.")
                )
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension Notification.Name {
    static let docentFocusSearch = Notification.Name("docent.focusSearch")
}
