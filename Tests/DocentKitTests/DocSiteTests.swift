import XCTest
@testable import DocentKit

/// What makes the pages a set of documentation rather than a pile of files: one way in,
/// links between them, and a name that takes you to what it names.
final class DocSiteTests: XCTestCase {
    private let pages: [DocSite.Page] = [
        DocSite.Page(relative: "README.md", pagePath: "README.html", title: "Project",
                     kind: .document, anchors: []),
        DocSite.Page(relative: "Sources/Canvas.swift", pagePath: "Sources/Canvas.swift.html",
                     title: "Sources/Canvas.swift", kind: .code("Swift"),
                     anchors: [("Canvas", "Struct", "canvas"), ("Canvas.draw", "Method", "canvasdraw")]),
        DocSite.Page(relative: "Sources/Pen.swift", pagePath: "Sources/Pen.swift.html",
                     title: "Sources/Pen.swift", kind: .code("Swift"),
                     anchors: [("Pen", "Struct", "pen"), ("Pen.draw", "Method", "pendraw")]),
    ]

    // MARK: - The table

    func testANameThatMeansOneThingBecomesALink() {
        let table = DocSite.linkTable(for: pages)
        XCTAssertEqual(table["Canvas"], "Sources/Canvas.swift.html#canvas")
        XCTAssertEqual(table["Pen.draw"], "Sources/Pen.swift.html#pendraw")
    }

    /// Two `draw`s in a project, and a link to one of them would be a lie half the time.
    func testANameThatMeansTwoThingsIsLeftAlone() {
        let ambiguous = pages + [DocSite.Page(
            relative: "Sources/Other.swift", pagePath: "Sources/Other.swift.html",
            title: "x", kind: .code("Swift"), anchors: [("Canvas", "Class", "canvas")])]
        XCTAssertNil(DocSite.linkTable(for: ambiguous)["Canvas"])
        XCTAssertNotNil(DocSite.linkTable(for: ambiguous)["Pen"])
    }

    // MARK: - Cross-links

    private var table: [String: String] { DocSite.linkTable(for: pages) }

    func testAKnownNameInProseLinksToIt() {
        let html = DocSite.crossLink("<p>Draws onto the Canvas.</p>", from: "Sources/Pen.swift.html",
                                     table: table)
        XCTAssertTrue(html.contains("<a href=\"../Sources/Canvas.swift.html#canvas\">Canvas</a>"), html)
    }

    func testAQualifiedNameLinksToTheMember() {
        let html = DocSite.crossLink("<p>See Canvas.draw for the details.</p>",
                                     from: "index.html", table: table)
        XCTAssertTrue(html.contains("#canvasdraw\">Canvas.draw</a>"), html)
    }

    /// A page linking to itself on every mention of its own name is noise, not navigation.
    func testAPageDoesNotLinkToItself() {
        let html = DocSite.crossLink("<p>Canvas holds the pixels.</p>",
                                     from: "Sources/Canvas.swift.html", table: table,
                                     skipping: ["Canvas", "Canvas.draw"])
        XCTAssertFalse(html.contains("<a"), html)
    }

    func testLinksAreNotPutInsideLinks() {
        let source = "<p><a href=\"x.html\">Canvas</a></p>"
        XCTAssertEqual(DocSite.crossLink(source, from: "index.html", table: table), source)
    }

    func testAttributesAreNotRewritten() {
        let source = "<img src=\"Canvas.png\" alt=\"x\">"
        XCTAssertEqual(DocSite.crossLink(source, from: "index.html", table: table), source)
    }

    /// `draw` is a verb as often as it is a method, so bare lowercase words are left alone.
    func testALowercaseWordIsNotAssumedToBeASymbol() {
        let small = DocSite.linkTable(for: [DocSite.Page(
            relative: "a.swift", pagePath: "a.swift.html", title: "a", kind: .code("Swift"),
            anchors: [("draw", "Function", "draw")])])
        let html = DocSite.crossLink("<p>Time to draw something.</p>", from: "index.html", table: small)
        XCTAssertFalse(html.contains("<a"), html)
    }

    func testPunctuationAroundANameSurvives() {
        let html = DocSite.crossLink("<p>(Canvas), Pen.</p>", from: "index.html", table: table)
        XCTAssertTrue(html.contains("(<a href=\"Sources/Canvas.swift.html#canvas\">Canvas</a>),"), html)
        XCTAssertTrue(html.contains("<a href=\"Sources/Pen.swift.html#pen\">Pen</a>."), html)
    }

    // MARK: - Links the author wrote

    func testALinkToAnotherDocumentReachesThePageItBecame() {
        let paths = ["README.md": "README.html", "docs/DESIGN.md": "docs/DESIGN.html"]
        let html = DocSite.rewriteDocumentLinks("<a href=\"docs/DESIGN.md\">design</a>",
                                                pagePath: "README.html",
                                                sourceRelative: "README.md", pages: paths)
        XCTAssertTrue(html.contains("href=\"docs/DESIGN.html\""), html)
    }

    func testALinkFromANestedDocumentClimbsBack() {
        let paths = ["README.md": "README.html", "docs/DESIGN.md": "docs/DESIGN.html"]
        let html = DocSite.rewriteDocumentLinks("<a href=\"../README.md#install\">install</a>",
                                                pagePath: "docs/DESIGN.html",
                                                sourceRelative: "docs/DESIGN.md", pages: paths)
        XCTAssertTrue(html.contains("href=\"../README.html#install\""), html)
    }

    func testLinksOutOfTheProjectAreUntouched() {
        let paths = ["README.md": "README.html"]
        for reference in ["https://example.com/a.md", "#section", "/etc/hosts", "missing.md"] {
            let html = DocSite.rewriteDocumentLinks("<a href=\"\(reference)\">x</a>",
                                                    pagePath: "README.html",
                                                    sourceRelative: "README.md", pages: paths)
            XCTAssertTrue(html.contains("href=\"\(reference)\""), html)
        }
    }

    // MARK: - The overview

    func testTheOverviewOpensWithTheReadmeAndListsEverything() {
        let html = DocSite.overview(name: "Project", pages: pages,
                                    readme: "<h1 id=\"project\">Project</h1><p>Hello.</p>")
        XCTAssertEqual(html.components(separatedBy: "<h1").count - 1, 1, "two titles: \(html)")
        XCTAssertTrue(html.contains("Hello."), html)
        XCTAssertTrue(html.contains("href=\"Sources/Canvas.swift.html\""), html)
        XCTAssertTrue(html.contains("href=\"Sources/Canvas.swift.html#canvas\""), "no type list: \(html)")
        XCTAssertTrue(html.contains("2 declarations"), html)
    }

    func testTheOverviewStillWorksWithoutAReadme() {
        let html = DocSite.overview(name: "Project", pages: pages, readme: nil)
        XCTAssertTrue(html.contains("<h1>Project</h1>"), html)
    }

    // MARK: - A file's own page

    func testASourcePageOffersItsContentsAndItsMembers() {
        let symbols = [
            SourceSymbols.Symbol(name: "Canvas", kind: "Struct", declaration: "struct Canvas {", doc: "", line: 1),
            SourceSymbols.Symbol(name: "Canvas.draw", kind: "Method", declaration: "func draw() {}", doc: "", line: 2),
            SourceSymbols.Symbol(name: "helper", kind: "Function", declaration: "func helper() {}", doc: "", line: 5),
        ]
        let page = SourcePage.render(symbols: symbols, path: "Sources/Canvas.swift", language: .swift,
                                     breadcrumb: DocSite.breadcrumb(for: "Sources/Canvas.swift",
                                                                    pagePath: "Sources/Canvas.swift.html"))
        XCTAssertTrue(page.html.contains("<a href=\"../index.html\">Overview</a>"), page.html)
        XCTAssertTrue(page.html.contains("id=\"contents\""), page.html)
        XCTAssertTrue(page.html.contains("Members"), page.html)
        XCTAssertTrue(page.html.contains("<a href=\"#canvasdraw\">draw</a>"), page.html)
    }
}
