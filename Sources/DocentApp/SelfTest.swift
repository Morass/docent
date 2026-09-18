import Foundation
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

    private static func browse() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let browser = MainActor.assumeIsolated { Browser() }
        MainActor.assumeIsolated {
            check(!browser.docsets.isEmpty, "no docsets visible — set DOCENT_DOCSETS to a folder holding one")

            browser.query = "Print"
            browser.search()
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
            browser.search()
            check(browser.results.isEmpty, "a query that matches nothing returned results")
            check(!browser.status.isEmpty, "a query that matches nothing said nothing to the user")
        }
        return failures
    }
}
