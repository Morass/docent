import XCTest
@testable import DocentKit

/// Pictures are the part of a README a reader looks at first. These cover both halves:
/// writing `<img>` at all, and making the file it points at exist inside the docset.
final class PageAssetsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docent-assets-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/images"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func picture(_ relative: String, bytes: Int = 64) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x89, count: bytes).write(to: url)
        return url
    }

    private func relocate(_ html: String, page: String = "README.html", from: String = "README.md")
        -> (html: String, copies: [PageAssets.Copy]) {
        PageAssets.relocate(html: html, pagePath: page,
                            sourceFile: root.appendingPathComponent(from),
                            rootPath: root.path)
    }

    // MARK: - Markdown

    func testAnImageBecomesAPictureAndNotAStrayExclamationMark() {
        let html = Markdown.render("![A screenshot](Resources/shot.png)\n", fallbackTitle: "x").html
        XCTAssertTrue(html.contains("<img src=\"Resources/shot.png\" alt=\"A screenshot\">"), html)
        XCTAssertFalse(html.contains("!<a"), html)
    }

    func testAPlainLinkIsStillALink() {
        let html = Markdown.render("[the design](docs/DESIGN.md)\n", fallbackTitle: "x").html
        XCTAssertTrue(html.contains("<a href=\"docs/DESIGN.md\">the design</a>"), html)
    }

    func testAltTextCarriesNoMarkup() {
        let html = Markdown.render("![the `make` target](a.png)\n", fallbackTitle: "x").html
        XCTAssertTrue(html.contains("alt=\"the make target\""), html)
    }

    func testAnImageWithAnAwkwardTargetIsLeftAsText() {
        let html = Markdown.render("![x](javascript:alert(1))\n", fallbackTitle: "x").html
        XCTAssertFalse(html.contains("<img"), html)
    }

    // MARK: - Finding and moving the file

    func testALocalPictureIsCopiedAndPointedAt() throws {
        try picture("Resources/shot.png")
        let (html, copies) = relocate("<p><img src=\"Resources/shot.png\" alt=\"s\"></p>")
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies.first?.to, "assets/Resources/shot.png")
        XCTAssertTrue(html.contains("src=\"assets/Resources/shot.png\""), html)
    }

    /// A page one folder down has to climb back out, or the picture is looked for in a
    /// folder that does not have it.
    func testANestedPageClimbsBackToTheAssets() throws {
        try picture("docs/images/plot.png")
        let (html, copies) = relocate("<img src=\"images/plot.png\">",
                                      page: "docs/guide.html", from: "docs/guide.md")
        XCTAssertEqual(copies.first?.to, "assets/docs/images/plot.png")
        XCTAssertTrue(html.contains("src=\"../assets/docs/images/plot.png\""), html)
    }

    func testTheSamePictureTwiceIsCopiedOnce() throws {
        try picture("a.png")
        let (_, copies) = relocate("<img src=\"a.png\"><img src=\"./a.png\">")
        XCTAssertEqual(copies.count, 1)
    }

    func testRemoteAndInlinePicturesAreLeftExactlyAsWritten() {
        let source = "<img src=\"https://example.com/a.png\"><img src=\"data:image/png;base64,AA\">"
        let (html, copies) = relocate(source)
        XCTAssertEqual(html, source)
        XCTAssertTrue(copies.isEmpty)
    }

    /// "Index my documentation" is not permission to copy whatever a crafted reference
    /// names — the private key beside the repository included.
    func testAPictureOutsideTheFolderIsNotTaken() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("docent-outside-\(UUID().uuidString).png")
        try Data(repeating: 0x89, count: 16).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let (html, copies) = relocate("<img src=\"../\(outside.lastPathComponent)\">")
        XCTAssertTrue(copies.isEmpty, "it copied a file from outside the folder")
        XCTAssertTrue(html.contains("src=\"../\(outside.lastPathComponent)\""), html)

        let (_, absolute) = relocate("<img src=\"/etc/hosts\">")
        XCTAssertTrue(absolute.isEmpty)
    }

    func testASymlinkIsNotFollowed() throws {
        let real = try picture("real.png")
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let (_, copies) = relocate("<img src=\"link.png\">")
        XCTAssertTrue(copies.isEmpty)
    }

    func testOnlyPicturesAndOnlySaneOnes() throws {
        try picture("notes.pdf")
        try picture("huge.png", bytes: PageAssets.maxBytes + 1)
        let (_, copies) = relocate("<img src=\"notes.pdf\"><img src=\"huge.png\">")
        XCTAssertTrue(copies.isEmpty)
    }

    func testAMissingFileIsLeftAlone() {
        let (html, copies) = relocate("<img src=\"gone.png\">")
        XCTAssertTrue(copies.isEmpty)
        XCTAssertTrue(html.contains("src=\"gone.png\""), html)
    }

    // MARK: - The whole way through the indexer

    func testIndexingARepositoryBringsItsPicturesWithIt() throws {
        try picture("Resources/shot.png")
        try "# Thing\n\n![A screenshot](Resources/shot.png)\n"
            .write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let out = root.deletingLastPathComponent()
            .appendingPathComponent("docent-built-\(UUID().uuidString).docset")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let report = try Indexer(source: root, name: "Thing", keyword: "thing").build(into: out)
        XCTAssertEqual(report.pictures, 1)

        let documents = out.appendingPathComponent("Contents/Resources/Documents")
        let copied = documents.appendingPathComponent("assets/Resources/shot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))

        let page = try String(contentsOf: documents.appendingPathComponent("README.html"), encoding: .utf8)
        XCTAssertTrue(page.contains("src=\"assets/Resources/shot.png\""), page)
    }

    /// The terminal cannot show the picture, but it can say one was there.
    func testShownAsTextAPictureLeavesItsCaption() {
        let text = HTMLText.render("<p><img src=\"a.png\" alt=\"The window, with a picture open\"></p>").text
        XCTAssertTrue(text.contains("[The window, with a picture open]"), text)
    }
}
