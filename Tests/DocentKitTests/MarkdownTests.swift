import XCTest
@testable import DocentKit

final class MarkdownTests: XCTestCase {
    func testHeadingsBecomeAnchorsAndAreListed() {
        let page = Markdown.render("# Title\n\n## Getting started\n\ntext\n", fallbackTitle: "x.md")
        XCTAssertEqual(page.title, "Title")
        XCTAssertEqual(page.headings.map(\.text), ["Title", "Getting started"])
        XCTAssertEqual(page.headings.last?.anchor, "getting-started")
        XCTAssertTrue(page.html.contains("<h2 id=\"getting-started\">"), page.html)
    }

    func testDuplicateHeadingsGetDistinctAnchors() {
        let page = Markdown.render("## Install\n\n## Install\n", fallbackTitle: "x.md")
        XCTAssertEqual(page.headings.map(\.anchor), ["install", "install-2"])
    }

    /// A wrapped paragraph is one paragraph. Before this, every line of a wrapped list item
    /// rendered as its own block and a document read as confetti.
    func testSoftWrappedLinesJoin() {
        let page = Markdown.render("A sentence that was\nwrapped in the source.\n\nNext.\n", fallbackTitle: "x")
        XCTAssertTrue(page.html.contains("<p>A sentence that was wrapped in the source.</p>"), page.html)
        XCTAssertTrue(page.html.contains("<p>Next.</p>"), page.html)
    }

    func testListItemsKeepTheirWrappedText() {
        let page = Markdown.render("- first item\n  continued here\n- second\n", fallbackTitle: "x")
        XCTAssertTrue(page.html.contains("<li>first item continued here</li>"), page.html)
        XCTAssertTrue(page.html.contains("<li>second</li>"), page.html)
    }

    func testFencedCodeIsLiteralAndKeepsItsLanguage() {
        let page = Markdown.render("```swift\nlet x = \"<b>\"\n```\n", fallbackTitle: "x")
        XCTAssertTrue(page.html.contains("<code class=\"language-swift\">"), page.html)
        XCTAssertTrue(page.html.contains("&lt;b&gt;"), "code must be escaped, not rendered: \(page.html)")
        XCTAssertFalse(page.html.contains("<b>"), page.html)
    }

    func testTablesSurvive() {
        let page = Markdown.render("| a | b |\n|---|---|\n| 1 | 2 |\n", fallbackTitle: "x")
        XCTAssertTrue(page.html.contains("<th>a</th>"), page.html)
        XCTAssertTrue(page.html.contains("<td>2</td>"), page.html)
    }

    func testInlineMarkupAndLinks() {
        let page = Markdown.render("Use `code`, **bold**, *italic* and [docs](guide.md).", fallbackTitle: "x")
        XCTAssertTrue(page.html.contains("<code>code</code>"), page.html)
        XCTAssertTrue(page.html.contains("<strong>bold</strong>"), page.html)
        XCTAssertTrue(page.html.contains("<em>italic</em>"), page.html)
        XCTAssertTrue(page.html.contains("<a href=\"guide.md\">docs</a>"), page.html)
    }

    /// The source is somebody's file and the output is HTML a web view will run.
    func testHTMLInTheSourceIsEscapedNotPassedThrough() {
        let page = Markdown.render("A <script>alert(1)</script> line.\n", fallbackTitle: "x")
        XCTAssertFalse(page.html.contains("<script>"), page.html)
        XCTAssertTrue(page.html.contains("&lt;script&gt;"), page.html)
    }

    func testJavascriptLinksAreNotLinks() {
        let page = Markdown.render("[click](javascript:alert(1))", fallbackTitle: "x")
        XCTAssertFalse(page.html.contains("<a href=\"javascript:"), page.html)
    }

    func testTitleFallsBackToTheFileName() {
        XCTAssertEqual(Markdown.render("no heading here\n", fallbackTitle: "docs/guide.md").title, "docs/guide.md")
    }

    func testSlugMatchesGitHubStyleAnchors() {
        XCTAssertEqual(Markdown.slug("What it touches"), "what-it-touches")
        XCTAssertEqual(Markdown.slug("1. Pick the idea"), "1-pick-the-idea")
        XCTAssertEqual(Markdown.slug("`code` and — dashes"), "code-and-dashes")
    }
}
