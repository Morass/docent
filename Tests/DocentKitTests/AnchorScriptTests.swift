import XCTest
@testable import DocentKit

final class AnchorScriptTests: XCTestCase {
    func testNoScriptWithoutAnAnchor() {
        XCTAssertNil(AnchorScript.scroll(to: ""))
    }

    /// The anchor is docset data. It must arrive as a JSON string literal — quotes escaped,
    /// nothing able to close the literal and start a statement of its own.
    func testAnchorIsEncodedAsDataNotPastedIntoTheSource() throws {
        let hostile = "x\");alert('pwned');//"
        let script = try XCTUnwrap(AnchorScript.scroll(to: hostile))
        XCTAssertFalse(script.contains(hostile), "the raw anchor was pasted in unescaped: \(script)")

        let literal = try XCTUnwrap(script.range(of: "var names=").map { range -> String in
            let rest = script[range.upperBound...]
            let end = rest.firstIndex(of: "]") ?? rest.endIndex
            return String(rest[...end])
        })
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String]
        XCTAssertEqual(decoded, [hostile], "the literal must decode back to exactly what was asked for")
    }

    func testQuotesAndNewlinesInAnAnchorCannotBreakOut() throws {
        let script = try XCTUnwrap(AnchorScript.scroll(to: "a\"b\nc"))
        XCTAssertFalse(script.contains("a\"b"), script)
        XCTAssertFalse(script.contains("\n c"), script)
    }

    func testDashRefAnchorsAlsoTryTheirPlainSpelling() throws {
        let script = try XCTUnwrap(AnchorScript.scroll(to: "//dash_ref_example%2DPrintln/Sample/Println/0"))
        XCTAssertTrue(script.contains("example-Println"), script)
    }
}
