import SwiftUI
import WebKit
import DocentKit

extension URL {
    /// The same page without its `#symbol` part.
    var deletingFragment: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? self
    }
}

/// The page itself. A docset is someone else's HTML from the internet, so this web view is
/// deliberately a reader and not a browser: no JavaScript, and nothing but files inside the
/// docset may load. A link that points outside opens in the user's own browser, where they
/// can see where it goes.
/// Compiles the block list once and hands it to every web view.
@MainActor
enum RemoteContentBlock {
    private(set) static var ruleList: WKContentRuleList?
    private static var compiling = false

    static func prepare(then done: (() -> Void)? = nil) {
        if ruleList != nil { done?(); return }
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "docent-no-network",
            encodedContentRuleList: NetworkBlock.ruleListJSON
        ) { list, error in
            compiling = false
            if let error { FileHandle.standardError.write(Data("docent: could not compile the network block: \(error)\n".utf8)) }
            ruleList = list
            done?()
        }
    }
}

struct PageView: NSViewRepresentable {
    let location: (url: URL, anchor: String?)?
    let documentsRoot: URL?
    let theme: ReadingTheme
    /// Which page this is, so where the reader scrolled to can be remembered against it.
    var pageID: String = ""
    /// A link inside the page was clicked. Returning true means the window took it over.
    var follow: (URL, String?) -> Bool = { _, _ in false }
    /// Where the reader had got to, and where to put that back.
    var rememberScroll: (String, Double) -> Void = { _, _ in }
    var rememberedScroll: (String) -> Double? = { _ in nil }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = false
        if let list = RemoteContentBlock.ruleList {
            configuration.userContentController.add(list)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Opaque, and painted in the reading theme's own colour: a transparent web view puts
        // a docset's dark-on-white CSS over a dark window, which is the "text is barely
        // readable" the first trial found. The under-page colour also kills the white flash
        // before the stylesheet lands.
        view.underPageBackgroundColor = NSColor(hex: theme.palette.background) ?? .textBackgroundColor
        context.coordinator.theme = theme
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Never load a page before the block list is in place: the first page is exactly
        // when a beacon would fire.
        guard let list = RemoteContentBlock.ruleList else {
            RemoteContentBlock.prepare { view.needsDisplay = true }
            return
        }
        if !context.coordinator.blocked {
            view.configuration.userContentController.add(list)
            context.coordinator.blocked = true
        }
        if context.coordinator.theme != theme {
            context.coordinator.theme = theme
            view.underPageBackgroundColor = NSColor(hex: theme.palette.background) ?? .textBackgroundColor
            context.coordinator.applyTheme(to: view)     // live, without reloading the page
        }

        guard let location, let documentsRoot else {
            view.loadHTMLString("", baseURL: nil)
            context.coordinator.loaded = nil
            return
        }
        var target = location.url
        if let anchor = location.anchor,
           var components = URLComponents(url: location.url, resolvingAgainstBaseURL: false) {
            components.fragment = anchor
            target = components.url ?? location.url
        }
        context.coordinator.root = documentsRoot
        context.coordinator.follow = follow

        // Leaving a page: keep the reader's place on it first.
        if context.coordinator.pageID != pageID {
            context.coordinator.saveScroll(view)
            context.coordinator.pageID = pageID
            context.coordinator.rememberScroll = rememberScroll
            context.coordinator.restoreTo = rememberedScroll(pageID)
        }
        // Same page, different symbol: scroll rather than reload, so moving down a list of
        // methods on one class does not flash the page each time.
        if let loaded = context.coordinator.loaded,
           loaded.deletingFragment == target.deletingFragment,
           loaded != target {
            context.coordinator.loaded = target
            context.coordinator.scroll(view, to: location.anchor)
            return
        }
        guard context.coordinator.loaded != target else { return }
        context.coordinator.loaded = target
        context.coordinator.anchor = location.anchor
        view.loadFileURL(target, allowingReadAccessTo: documentsRoot)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        var root: URL?
        var anchor: String?
        var blocked = false
        var theme: ReadingTheme = .light
        var follow: (URL, String?) -> Bool = { _, _ in false }
        var pageID: String = ""
        var rememberScroll: (String, Double) -> Void = { _, _ in }
        /// How far down this page the reader was when they last left it.
        var restoreTo: Double?

        /// Reads the scroll position out of the web view and hands it to the model. The
        /// read is asynchronous, so it is started before the page changes, not after.
        func saveScroll(_ webView: WKWebView) {
            let id = pageID
            let remember = rememberScroll
            guard !id.isEmpty else { return }
            webView.evaluateJavaScript("window.pageYOffset") { value, _ in
                if let offset = (value as? NSNumber)?.doubleValue { remember(id, offset) }
            }
        }

        /// Paint and colour the page: the theme's stylesheet first, then the highlighter for
        /// code blocks the docset left plain.
        func applyTheme(to webView: WKWebView) {
            if let script = theme.injectionScript {
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
            if let highlighter = SyntaxHighlight.script {
                webView.evaluateJavaScript(highlighter, completionHandler: nil)
            }
        }

        /// A docset points at one symbol on a page that may hold fifty. Without this the
        /// reader lands at the top of the page and has to go looking for what they picked.
        func scroll(_ webView: WKWebView, to anchor: String?) {
            guard let anchor, let script = AnchorScript.scroll(to: anchor) else { return }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyTheme(to: webView)
            // Coming back to a page the reader has already read: put them where they were.
            // An anchor beats a remembered offset — they asked for that symbol by name.
            if anchor == nil, let offset = restoreTo, offset > 0 {
                webView.evaluateJavaScript("window.scrollTo(0, \(offset))", completionHandler: nil)
            } else {
                scroll(webView, to: anchor)
            }
            restoreTo = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }

            if url.isFileURL {
                guard let root, Containment.allows(url, under: root) else { return decisionHandler(.cancel) }
                // A click on a link is a move: hand it to the window so the tree, the page
                // and the history all agree, and Back returns to where the click happened.
                if navigationAction.navigationType == .linkActivated {
                    saveScroll(webView)
                    if follow(url.deletingFragment, url.fragment) { return decisionHandler(.cancel) }
                }
                decisionHandler(.allow)
                return
            }

            // Anything off the disk — an analytics beacon, a CDN font, a link someone
            // clicked — leaves the reader. Docent itself never goes to the network.
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}


extension NSColor {
    /// `#rrggbb` — the reading theme speaks CSS, and the window needs the same colour.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                  green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255,
                  alpha: 1)
    }
}
