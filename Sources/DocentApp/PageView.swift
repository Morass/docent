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
        view.setValue(false, forKey: "drawsBackground")
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

        /// A docset points at one symbol on a page that may hold fifty. Without this the
        /// reader lands at the top of the page and has to go looking for what they picked.
        func scroll(_ webView: WKWebView, to anchor: String?) {
            guard let anchor, let script = AnchorScript.scroll(to: anchor) else { return }
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            scroll(webView, to: anchor)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }

            if url.isFileURL {
                guard let root else { return decisionHandler(.cancel) }
                let allowed = root.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                decisionHandler(path == allowed || path.hasPrefix(allowed + "/") ? .allow : .cancel)
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
