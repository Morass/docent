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

extension HTMLTextTests {
    func testDashRefAnchorsSelectTheirSection() {
        let html = """
        <h1>package fmt</h1>
        <a name="//dash_ref_Println/Function/Println/0"></a><h2 id="Println">func Println</h2><p>Writes a line.</p>
        <a name="//dash_ref_Printf/Function/Printf/0"></a><h2 id="Printf">func Printf</h2><p>Formats.</p>
        """
        let text = HTMLText.render(html, anchor: "//dash_ref_Println/Function/Println/0").text
        XCTAssertTrue(text.contains("Writes a line."), text)
        XCTAssertFalse(text.contains("Formats."), text)
    }

    func testPercentEncodedAnchorFallsBackToTheDecodedSpelling() {
        let html = "<a name=\"example-Println\"></a><h2>Example</h2><p>Shown.</p><h2>Other</h2><p>Hidden.</p>"
        let text = HTMLText.render(html, anchor: "example%2DPrintln").text
        XCTAssertTrue(text.contains("Shown."), text)
        XCTAssertFalse(text.contains("Hidden."), text)
    }
}

extension HTMLTextTests {
    func testPermalinkGlyphsAreNotText() {
        let text = HTMLText.render("<h2>func Println <a href=\"#Println\">¶</a></h2><p>Body.</p>").text
        XCTAssertFalse(text.contains("¶"), text)
        XCTAssertTrue(text.contains("func Println"), text)
    }
}
