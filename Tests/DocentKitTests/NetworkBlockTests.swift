import XCTest
@testable import DocentKit

final class NetworkBlockTests: XCTestCase {
    func testTheRuleListIsValidJSONWithOneRulePerScheme() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(NetworkBlock.ruleListJSON.utf8)) as? [[String: Any]]
        XCTAssertEqual(rules?.count, NetworkBlock.blockedSchemes.count)
        for rule in rules ?? [] {
            XCTAssertEqual((rule["action"] as? [String: Any])?["type"] as? String, "block")
            XCTAssertNotNil((rule["trigger"] as? [String: Any])?["url-filter"])
        }
    }

    func testEveryNetworkSchemeAPageCouldUseIsCovered() {
        let filters = NetworkBlock.ruleListJSON
        for scheme in ["http", "https", "ws", "wss", "ftp"] {
            XCTAssertTrue(filters.contains(scheme.replacingOccurrences(of: "s", with: "s?")) || filters.contains(scheme),
                          "\(scheme) is not blocked")
        }
        XCTAssertFalse(filters.contains("file://"), "file: must stay allowed — that is the docset itself")
    }
}
