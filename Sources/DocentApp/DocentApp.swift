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
    /// Redraws the window when the network block finishes compiling, so the first page
    /// loads by itself rather than waiting for the next thing the reader does.
    @ObservedObject private var blockReady = RemoteContentBlock.Readiness.shared
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
                    // Only while the tree is up and the field is empty: in a search the
                    // arrows belong to the text.
                    .onKeyPress(.leftArrow) {
                        guard browser.showsTree else { return .ignored }
                        browser.toggleSelectedRow(open: false)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        guard browser.showsTree else { return .ignored }
                        browser.toggleSelectedRow(open: true)
                        return .handled
                    }
                if !browser.query.isEmpty {
                    Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            Divider()
            // Nothing typed and a docset picked: show the project, not an empty result
            // list. Typing swaps it for the matches and clearing brings the tree back.
            if browser.showsTree {
                tree
            } else {
                results
            }
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

    /// The project as a navigator: folders, the files in them, and what each file
    /// declares. Rows open and close like a file tree, and a row opens its page.
    private var tree: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(browser.tree) { node in
                        TreeRow(node: node, depth: 0, browser: browser)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Going back lands on a row that may be off screen; bring it into view, the way
            // a navigator follows the document you are looking at.
            .onChange(of: browser.selection) { _, _ in
                guard let id = browser.selectedTreeRowID else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id, anchor: .center) }
            }
        }
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

    /// Back, forward, and what you are reading. A link in a page moves the whole window,
    /// so Back is the way home from a name you clicked to find out what it was.
    private func pageBar(for match: Match) -> some View {
        HStack(spacing: 8) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left").frame(width: 14)
            }
            .disabled(!browser.canGoBack)
            .help("Back (⌘[)")

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right").frame(width: 14)
            }
            .disabled(!browser.canGoForward)
            .help("Forward (⌘])")

            Text(match.entry.name)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1).truncationMode(.middle)
            Text(match.entry.type)
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.65))
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var page: some View {
        Group {
            if let match = browser.selectedMatch, let location = browser.location(of: match),
               blockReady.isReady || RemoteContentBlock.ruleList != nil {
                VStack(spacing: 0) {
                    pageBar(for: match)
                    Divider()
                    PageView(location: location,
                             documentsRoot: match.docset.readAccessURL,
                             theme: browser.pageAppearance.theme(systemIsDark: colorScheme == .dark),
                             pageID: match.id,
                             follow: { url, anchor in browser.followLink(to: url, anchor: anchor) },
                             rememberScroll: { browser.rememberScroll($1, for: $0) },
                             rememberedScroll: { browser.rememberedScroll(for: $0) })
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("\(match.entry.name) — \(match.docset.name)")
            } else if browser.selectedMatch != nil {
                // Something is selected but the reader cannot see it yet: say so, rather
                // than showing an empty page that looks like a broken one.
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the reader…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
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

/// One row of the navigator, and its children when it is open.
private struct TreeRow: View {
    let node: DocTree.Node
    let depth: Int
    @ObservedObject var browser: Browser

    private var isOpen: Bool { browser.expanded.contains(node.id) }
    private var isSelected: Bool {
        guard let entry = node.entry, let docset = browser.currentDocset else { return false }
        return browser.selection == Match(docset: docset, entry: entry, score: 0).id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if !node.children.isEmpty {
                    if isOpen { browser.expanded.remove(node.id) } else { browser.expanded.insert(node.id) }
                }
                browser.select(node)
            } label: {
                HStack(spacing: 4) {
                    // The twisty is a hit target of its own, so opening a type does not
                    // also mean leaving the page you were reading.
                    Group {
                        if node.children.isEmpty {
                            Image(systemName: "circle.fill").font(.system(size: 3))
                                .foregroundStyle(Color.primary.opacity(0.35))
                                .frame(width: 12)
                        } else {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.7))
                                .frame(width: 12)
                        }
                    }
                    Text(node.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = node.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(Color.primary.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .padding(.trailing, 8)
                .padding(.leading, CGFloat(depth) * 13 + 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                .contentShape(Rectangle())
                .id(node.id)
            }
            .buttonStyle(.plain)

            if isOpen {
                ForEach(node.children) { child in
                    TreeRow(node: child, depth: depth + 1, browser: browser)
                }
            }
        }
    }
}

extension Notification.Name {
    static let docentFocusSearch = Notification.Name("docent.focusSearch")
}
