import XCTest
@testable import DocentKit

final class IndexerTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docent-index-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try write("# Repo\n\nIntro.\n\n## Install\n\nRun it.\n", to: "README.md")
        try write("# Guide\n\n## Details\n\nMore.\n", to: "docs/guide.md")
        try write("<html><head><title>Generated</title></head><body><p>x</p></body></html>", to: "docs/api.html")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = source.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
    }

    private func build() throws -> (Indexer.Report, Docset) {
        let destination = root.appendingPathComponent("Repo.docset")
        let report = try Indexer(source: source, name: "Repo", keyword: "repo").build(into: destination)
        let docset = try XCTUnwrap(Docset(contentsOf: destination))
        return (report, docset)
    }

    func testEveryDocumentAndHeadingIsSearchable() throws {
        let (report, docset) = try build()
        XCTAssertEqual(report.files, 3)

        let index = try SearchIndex(url: docset.indexURL)
        let names = try index.candidates(matching: "").map(\.name)
        XCTAssertTrue(names.contains("Repo"), "\(names)")
        XCTAssertTrue(names.contains("Install"), "\(names)")
        XCTAssertTrue(names.contains("Details"), "\(names)")
        XCTAssertTrue(names.contains("Generated"), "an HTML file's <title> should be its entry: \(names)")
    }

    func testAHeadingEntryPointsAtItsAnchoredSection() throws {
        let (_, docset) = try build()
        let service = SearchService(library: DocsetLibrary(searchPaths: [root]))
        let match = try XCTUnwrap(try service.find("Install").first)
        let page = try service.page(for: match)
        XCTAssertTrue(page.text.contains("Run it."), page.text)
        XCTAssertFalse(page.text.contains("Intro."), "the anchor should land on the section, not the file: \(page.text)")
    }

    func testNoiseFoldersAreSkipped() throws {
        try write("# Hidden\n", to: "node_modules/pkg/readme.md")
        try write("# Also hidden\n", to: ".git/notes.md")
        let (report, docset) = try build()
        XCTAssertEqual(report.files, 3, "node_modules and .git must not be indexed")
        let names = try SearchIndex(url: docset.indexURL).candidates(matching: "").map(\.name)
        XCTAssertFalse(names.contains("Hidden"))
    }

    func testSymlinksAreNotFollowedOutOfTheTree() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "# Secret\n".data(using: .utf8)!.write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked"), withDestinationURL: outside)

        let (_, docset) = try build()
        let names = try SearchIndex(url: docset.indexURL).candidates(matching: "").map(\.name)
        XCTAssertFalse(names.contains("Secret"), "a link out of the folder must not pull files in: \(names)")
    }

    func testAFolderWithNoDocumentationIsAnHonestError() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Indexer(source: empty, name: "Empty").build(into: root.appendingPathComponent("Empty.docset")))
    }

    func testRebuildingReplacesRatherThanAccumulates() throws {
        _ = try build()
        let (report, docset) = try build()
        XCTAssertEqual(report.files, 3)
        let rows = try SearchIndex(url: docset.indexURL).symbolCount()
        XCTAssertLessThan(rows, 20, "a rebuild should not double the index")
    }

    func testPagePathsAreFlattenedSafely() {
        XCTAssertEqual(Indexer.pagePath(for: "docs/guide.md"), "docs/guide.html")
        XCTAssertEqual(Indexer.pagePath(for: "a b/c;d.markdown"), "a-b/c-d.html")
        XCTAssertEqual(Indexer.folderName(for: "My Project"), "My-Project.docset")
    }
}
