import Foundation
import WebKit
import Network
import DocentKit

/// End-to-end checks that need the real app rather than the library: the model, the
/// selection, the history and the page the window would show.
///
/// `swift test` cannot import an executable target, so the harness ships inside the binary
/// behind `DOCENT_SELFTEST` and exits when it is done. It reads only the docsets named by
/// `DOCENT_DOCSETS`, so it never touches the machine's own library.
enum SelfTest {
    static func runIfAsked() {
        guard let mode = ProcessInfo.processInfo.environment["DOCENT_SELFTEST"] else { return }
        let failures: [String]
        switch mode {
        case "browse": failures = browse()
        case "page": failures = MainActor.assumeIsolated { page() }
        case "network": failures = MainActor.assumeIsolated { network() }
        case "escape": failures = MainActor.assumeIsolated { escape() }
        case "theme": failures = MainActor.assumeIsolated { theme() }
        default:
            FileHandle.standardError.write(Data("selftest: no mode called \"\(mode)\"\n".utf8))
            exit(2)
        }
        if failures.isEmpty {
            print("selftest \(mode): ok")
            exit(0)
        }
        for failure in failures { FileHandle.standardError.write(Data("selftest \(mode): \(failure)\n".utf8)) }
        exit(1)
    }

    /// Proves the page half: the real web view, the real configuration and the real
    /// navigation delegate, loading a real file out of a docset. The window can look
    /// perfect while this is broken, and nothing else in the suite would notice.
    @MainActor
    private static func page() -> [String] {
        var failures: [String] = []
        let service = SearchService()
        // A symbol that is *not* the first thing on its page: landing at the top would look
        // like success otherwise.
        guard let match = (try? service.find("PrintTable", limit: 1))?.first else {
            return ["no docsets to load a page from — set DOCENT_DOCSETS"]
        }
        guard let location = try? service.location(of: match) else {
            return ["the best match for PrintTable resolves to no file"]
        }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        let probe = LoadProbe()
        webView.navigationDelegate = probe

        var target = location.url
        if let anchor = location.anchor, var components = URLComponents(url: location.url, resolvingAgainstBaseURL: false) {
            components.fragment = anchor
            target = components.url ?? location.url
        }
        probe.root = match.docset.readAccessURL
        webView.loadFileURL(target, allowingReadAccessTo: match.docset.readAccessURL)

        let deadline = Date().addingTimeInterval(10)
        while probe.finished == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        // Does the page land on the symbol, or at the top of a long page? And can the host
        // still run its own JavaScript while page scripts are off?
        var offset: Double? = nil
        var jsError: String? = nil
        if probe.finished != nil {
            let anchorScript = (AnchorScript.scroll(to: location.anchor ?? "") ?? "false") + ";window.pageYOffset"
            var done = false
            webView.evaluateJavaScript(anchorScript) { value, error in
                offset = (value as? NSNumber)?.doubleValue
                jsError = error.map { "\($0)" }
                done = true
            }
            let jsDeadline = Date().addingTimeInterval(5)
            while !done, Date() < jsDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        if let jsError { failures.append("the page could not be scrolled to its symbol: \(jsError)") }
        if location.anchor != nil, (offset ?? 0) <= 0 {
            failures.append("the page did not scroll to the symbol — a result halfway down a long page would land at the top")
        }

        switch probe.finished {
        case .some(.success):
            break
        case .some(.failure(let message)):
            failures.append("the page failed to load: \(message)")
        case nil:
            failures.append("the page never finished loading in ten seconds")
        }
        if probe.cancelled > 0 {
            failures.append("the navigation delegate cancelled the page's own file URL \(probe.cancelled) time(s)")
        }
        return failures
    }

    /// Proves the claim that a docset cannot phone home. A page with an `<img>` pointing at
    /// a listener on this machine is loaded; the listener must never hear from it.
    @MainActor
    private static func network() -> [String] {
        var failures: [String] = []
        let listener = Beacon()
        guard let port = listener.start() else { return ["could not open a local listener to test against"] }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("docent-network-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appendingPathComponent("beacon.html")
        let html = """
        <html><body><h1>Beacon</h1>
        <img src="http://127.0.0.1:\(port)/pixel.png">
        <link rel="stylesheet" href="http://127.0.0.1:\(port)/style.css">
        </body></html>
        """
        try? html.data(using: .utf8)!.write(to: page)

        var ready = false
        RemoteContentBlock.prepare { ready = true }
        let compileDeadline = Date().addingTimeInterval(10)
        while !ready, Date() < compileDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let list = RemoteContentBlock.ruleList else { return ["the network block list did not compile"] }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // The negative control: with the block left out, the beacon must fire. A test that
        // cannot fail proves nothing, and this one is the whole privacy claim.
        let control = ProcessInfo.processInfo.environment["DOCENT_SELFTEST_NO_BLOCK"] != nil
        if !control { configuration.userContentController.add(list) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let probe = LoadProbe()
        probe.root = URL(fileURLWithPath: directory.path, isDirectory: true)
        webView.navigationDelegate = probe
        webView.loadFileURL(page, allowingReadAccessTo: probe.root!)

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            if listener.hits > 0 { break }
        }
        if probe.finished == nil { failures.append("the beacon page never loaded, so the test proved nothing") }
        if listener.hits > 0 {
            failures.append("a page reached the network \(listener.hits) time(s) — a docset can tell its author when you read it")
        }
        listener.stop()
        if control {
            return failures.isEmpty
                ? ["negative control: without the block list the beacon did NOT fire, so this test cannot prove anything"]
                : []
        }
        return failures
    }

    /// Proves that a page cannot show a file outside its docset through a symlink. The
    /// command's read path resolves symlinks; this is the app's half of the same promise,
    /// and it was still lexical after round one.
    @MainActor
    private static func escape() -> [String] {
        var failures: [String] = []
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("docent-escape-\(UUID().uuidString)", isDirectory: true)
        let documents = directory.appendingPathComponent("Documents", isDirectory: true)
        try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        // A file outside the docset, and a link inside it that points at the file.
        let outside = directory.appendingPathComponent("outside.html")
        try? "<p>SECRET-OUTSIDE-THE-DOCSET</p>".data(using: .utf8)!.write(to: outside)
        try? fm.createSymbolicLink(at: documents.appendingPathComponent("leak.html"), withDestinationURL: outside)

        let page = documents.appendingPathComponent("page.html")
        try? "<h1>Page</h1><iframe src=\"leak.html\" width=\"400\" height=\"200\"></iframe>"
            .data(using: .utf8)!.write(to: page)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let probe = LoadProbe()
        probe.root = documents
        webView.navigationDelegate = probe
        webView.loadFileURL(page, allowingReadAccessTo: documents)

        let deadline = Date().addingTimeInterval(8)
        while probe.finished == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        // Give the frame a moment to try.
        let settle = Date().addingTimeInterval(1.5)
        while Date() < settle {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        var text: String?
        var done = false
        webView.evaluateJavaScript("document.documentElement.innerText + (document.querySelector('iframe') && document.querySelector('iframe').contentDocument ? document.querySelector('iframe').contentDocument.documentElement.innerText : '')") { value, _ in
            text = value as? String
            done = true
        }
        let jsDeadline = Date().addingTimeInterval(5)
        while !done, Date() < jsDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if probe.finished == nil { failures.append("the page never loaded, so the test proved nothing") }
        if probe.cancelled == 0 { failures.append("the navigation policy allowed the symlinked frame — it should have refused it") }
        if (text ?? "").contains("SECRET-OUTSIDE-THE-DOCSET") {
            failures.append("a page displayed a file from outside its docset through a symlink")
        }
        return failures
    }

    /// Measures what the reader actually sees: the contrast the page ends up with once the
    /// theme is injected, and whether code blocks were coloured. The palette unit tests check
    /// the numbers Docent *intends*; this checks the ones a real page ends up with.
    @MainActor
    private static func theme() -> [String] {
        var failures: [String] = []
        let service = SearchService()
        guard let match = (try? service.find("Print", limit: 1))?.first,
              let location = try? service.location(of: match) else {
            return ["no docsets to paint — set DOCENT_DOCSETS"]
        }

        for reading in [ReadingTheme.light, .dark] {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            let probe = LoadProbe()
            probe.root = match.docset.readAccessURL
            webView.navigationDelegate = probe
            webView.loadFileURL(location.url, allowingReadAccessTo: match.docset.readAccessURL)

            let deadline = Date().addingTimeInterval(8)
            while probe.finished == nil, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            guard probe.finished != nil else {
                failures.append("\(reading): the page never loaded")
                continue
            }

            if let css = reading.injectionScript { evaluate(css, in: webView) }
            if let highlighter = SyntaxHighlight.script { evaluate(highlighter, in: webView) }

            let measure = """
            (function(){
              function lum(c){var m=c.match(/\\d+/g);if(!m)return null;
                var v=m.slice(0,3).map(function(x){x=x/255;return x<=0.03928?x/12.92:Math.pow((x+0.055)/1.055,2.4);});
                return 0.2126*v[0]+0.7152*v[1]+0.0722*v[2];}
              var s=getComputedStyle(document.body);
              var a=lum(s.color), b=lum(s.backgroundColor);
              if(a===null||b===null) return '0|0';
              var ratio=(Math.max(a,b)+0.05)/(Math.min(a,b)+0.05);
              var tokens=document.querySelectorAll('.docent-kw,.docent-str,.docent-com,.docent-num,.docent-type').length;
              return ratio.toFixed(2)+'|'+tokens;})()
            """
            let answer = evaluate(measure, in: webView) as? String ?? "0|0"
            let parts = answer.split(separator: "|")
            let ratio = Double(parts.first ?? "0") ?? 0
            let tokens = Int(parts.last ?? "0") ?? 0

            if ratio < 7 {
                failures.append("\(reading): the page ends up at \(ratio):1 contrast — the trial called that unreadable")
            }
            if tokens == 0 {
                failures.append("\(reading): no code was highlighted on a page that has a code block")
            }
        }
        return failures
    }

    @discardableResult
    @MainActor
    private static func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return result
    }

    /// A socket on localhost that counts anyone who connects.
    private final class Beacon: @unchecked Sendable {
        private var listener: NWListener?
        private let lock = NSLock()
        private var count = 0

        var hits: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        func start() -> UInt16? {
            guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.lock.lock()
                self?.count += 1
                self?.lock.unlock()
                connection.cancel()
            }
            listener.start(queue: .global())
            let deadline = Date().addingTimeInterval(3)
            while listener.port == nil, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return listener.port?.rawValue
        }

        func stop() { listener?.cancel() }
    }

    /// The same policy the app uses, with a record of what it did.
    @MainActor
    private final class LoadProbe: NSObject, WKNavigationDelegate {
        enum Outcome { case success, failure(String) }
        var finished: Outcome?
        var cancelled = 0
        var root: URL?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let root, Containment.allows(url, under: root) else {
                cancelled += 1
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = .success
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finished = .failure(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finished = .failure("provisional: \(error.localizedDescription)")
        }
    }

    private static func browse() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let browser = MainActor.assumeIsolated { Browser() }
        MainActor.assumeIsolated {
            check(!browser.docsets.isEmpty, "no docsets visible — set DOCENT_DOCSETS to a folder holding one")

            browser.query = "Print"
            browser.searchAndWait()
            check(!browser.results.isEmpty, "searching for Print found nothing")
            check(browser.selection != nil, "a search left nothing selected")

            let first = browser.selectedMatch
            check(first != nil, "no selected match after a search")
            if let first {
                check(browser.location(of: first) != nil, "the selected match points at no file on disk")
                let text = browser.text(of: first) ?? ""
                check(!text.isEmpty, "the selected page rendered as empty text")
            }

            browser.moveSelection(by: 1)
            let second = browser.selectedMatch
            check(second != nil && second?.id != first?.id, "the keyboard did not move the selection")

            check(browser.canGoBack, "history did not record two visited symbols")
            browser.goBack()
            check(browser.selectedMatch?.id == first?.id, "going back did not return to the first symbol")
            check(browser.canGoForward, "forward is not available after going back")
            browser.goForward()
            check(browser.selectedMatch?.id == second?.id, "going forward did not return to the second symbol")

            browser.query = "zzzzzzzz"
            browser.searchAndWait()
            check(browser.results.isEmpty, "a query that matches nothing returned results")
            check(!browser.status.isEmpty, "a query that matches nothing said nothing to the user")
        }
        return failures
    }
}
