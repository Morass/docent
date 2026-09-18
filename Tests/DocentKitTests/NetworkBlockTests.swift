import XCTest
@testable import DocentKit

final class NetworkBlockTests: XCTestCase {
    func testTheRuleListIsValidJSONWithOneRulePerScheme() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(NetworkBlock.ruleListJSON.utf8)) as? [[String: Any]]
        XCTAssertEqual(rules?.count, NetworkBlock.blockedSchemes.count + NetworkBlock.blockedBareSchemes.count + 1,
                       "one rule per scheme, plus remote file URLs")
        for rule in rules ?? [] {
            XCTAssertEqual((rule["action"] as? [String: Any])?["type"] as? String, "block")
            XCTAssertNotNil((rule["trigger"] as? [String: Any])?["url-filter"])
        }
    }

    /// `blob:https://…` has no `//` after the scheme, so a `^blob://` filter is a rule that
    /// can never match anything.
    func testTheBlobRuleCanActuallyMatchABlobURL() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(NetworkBlock.ruleListJSON.utf8)) as? [[String: Any]]
        let filters = (rules ?? []).compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        let blob = try XCTUnwrap(filters.first { $0.contains("blob") })
        let expression = try NSRegularExpression(pattern: blob)
        let url = "blob:https://example.com/9f3b"
        XCTAssertNotNil(expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)))
    }

    func testEveryNetworkSchemeAPageCouldUseIsCovered() {
        let filters = NetworkBlock.ruleListJSON
        for scheme in ["http", "https", "ws", "wss", "ftp"] {
            XCTAssertTrue(filters.contains(scheme.replacingOccurrences(of: "s", with: "s?")) || filters.contains(scheme),
                          "\(scheme) is not blocked")
        }
        // The docset's own pages are local file URLs and must keep loading; only the
        // host form is blocked, which the regular-expression test below pins down.
        XCTAssertFalse(filters.contains("^file:///"), "local file URLs must stay allowed — they are the docset")
    }
}

extension NetworkBlockTests {
    /// `file://host/share/x` is fetched over SMB — a page could use it as a beacon through
    /// the one scheme a reader has to allow.
    func testAFileURLWithAHostIsBlocked() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(NetworkBlock.ruleListJSON.utf8)) as? [[String: Any]]
        let filters = (rules ?? []).compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        XCTAssertTrue(filters.contains(NetworkBlock.remoteFileFilter), "remote file URLs are not blocked")

        // The filter must match a host form and not the ordinary three-slash local form.
        let expression = try NSRegularExpression(pattern: NetworkBlock.remoteFileFilter)
        func matches(_ url: String) -> Bool {
            expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        XCTAssertTrue(matches("file://evil.example/x.png"))
        XCTAssertFalse(matches("file:///docsets/Sparrow.docset/page.html"))
    }
}
