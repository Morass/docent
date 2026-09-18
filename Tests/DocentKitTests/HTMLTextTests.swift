import XCTest
@testable import DocentKit

final class HTMLTextTests: XCTestCase {
    func testHeadingsListsAndParagraphs() {
        let html = "<h1>Widget</h1><p>First.</p><ul><li>one</li><li>two</li></ul><p>Last.</p>"
        let text = HTMLText.render(html).text
        XCTAssertTrue(text.hasPrefix("# Widget"), text)
        XCTAssertTrue(text.contains("  • one"), text)
        XCTAssertTrue(text.contains("  • two"), text)
        XCTAssertTrue(text.contains("Last."), text)
    }

    func testScriptAndStyleContentIsNotText() {
        let html = "<style>body { color: red }</style><script>var x = 1;</script><p>Visible.</p>"
        XCTAssertEqual(HTMLText.render(html).text, "Visible.")
    }

    func testPreKeepsItsLineBreaks() {
        let html = "<p>Before</p><pre>line one\n  line two</pre><p>After</p>"
        let text = HTMLText.render(html).text
        XCTAssertTrue(text.contains("line one\n  line two"), text)
    }

    func testEntitiesAreDecoded() {
        let text = HTMLText.render("<p>a &amp; b &lt;c&gt; &#39;d&#39; &#x2014; &nbsp;e</p>").text
        XCTAssertTrue(text.contains("a & b <c> 'd' —"), text)
    }

    func testTitleIsRead() {
        XCTAssertEqual(HTMLText.render("<html><head><title> Widget — docs </title></head><body>x</body></html>").title,
                       "Widget — docs")
    }

    func testAttributeWithAngleBracketDoesNotEndTheTag() {
        let text = HTMLText.render("<p title=\"a > b\">kept</p>").text
        XCTAssertEqual(text, "kept")
    }

    func testAnchorSelectsOneSectionOnly() {
        let html = """
        <h1>Widget</h1><p>Intro.</p>
        <a name="spin"></a><h2>spin()</h2><p>Spins the widget.</p>
        <a name="stop"></a><h2>stop()</h2><p>Stops it.</p>
        """
        let text = HTMLText.render(html, anchor: "spin").text
        XCTAssertTrue(text.contains("Spins the widget."), text)
        XCTAssertFalse(text.contains("Stops it."), text)
        XCTAssertFalse(text.contains("Intro."), text)
    }

    func testMissingAnchorFallsBackToTheWholePage() {
        let text = HTMLText.render("<p>Only.</p>", anchor: "nothing-like-this").text
        XCTAssertEqual(text, "Only.")
    }

    func testIdAnchorsWorkTooAndKeepTheirOwnHeading() {
        let html = "<h2 id=\"alpha\">Alpha</h2><p>About alpha.</p><h2 id=\"beta\">Beta</h2><p>About beta.</p>"
        let text = HTMLText.render(html, anchor: "alpha").text
        XCTAssertTrue(text.contains("Alpha"), text)
        XCTAssertTrue(text.contains("About alpha."), text)
        XCTAssertFalse(text.contains("About beta."), text)
    }

    func testCommentsAreDropped() {
        XCTAssertEqual(HTMLText.render("<!-- hidden --><p>shown</p>").text, "shown")
    }

    func testTableRowsBecomeLines() {
        let html = "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>"
        let text = HTMLText.render(html).text
        XCTAssertTrue(text.contains("a | b"), text)
        XCTAssertTrue(text.contains("c | d"), text)
    }
}

extension HTMLTextTests {
    func testAtMostOneBlankLineAndNoWhitespaceOnlyLines() {
        let html = "<h2>Title</h2>\n  \n<pre>code()</pre>\n \n<p>Body.</p>"
        let text = HTMLText.render(html).text
        XCTAssertFalse(text.contains("\n\n\n"), text.debugDescription)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertFalse(!line.isEmpty && line.allSatisfy(\.isWhitespace), "whitespace-only line in \(text.debugDescription)")
        }
    }
}
