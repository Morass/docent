import XCTest
@testable import DocentKit

final class DocsetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadsNameKeywordAndIdentifierFromThePlist() throws {
        let docset = try Fixture.docset(in: root, name: "Gopher", identifier: "com.example.gopher", keyword: "go")
        XCTAssertEqual(docset.name, "Gopher")
        XCTAssertEqual(docset.identifier, "com.example.gopher")
        XCTAssertEqual(docset.keyword, "go")
    }

    func testAFolderWithoutAnIndexIsNotADocset() throws {
        let bundle = root.appendingPathComponent("Broken.docset/Contents/Resources/Documents")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertNil(Docset(contentsOf: root.appendingPathComponent("Broken.docset")))
    }

    func testPathsCannotClimbOutOfTheDocset() throws {
        let docset = try Fixture.docset(in: root)
        XCTAssertNotNil(docset.fileURL(forPath: "widget.html"))
        XCTAssertNil(docset.fileURL(forPath: "../../../../etc/passwd"))
        XCTAssertNil(docset.fileURL(forPath: "sub/../../../secrets.txt"))
        XCTAssertNil(docset.fileURL(forPath: ""))
    }

    func testPathKeepsItsAnchorSeparately() {
        XCTAssertEqual(Docset.anchor(in: "widget.html#spin"), "spin")
        XCTAssertNil(Docset.anchor(in: "widget.html"))
        XCTAssertNil(Docset.anchor(in: "widget.html#"))
        XCTAssertEqual(Docset.anchor(in: "widget.html#//apple_ref/occ/instm/Widget/spin"), "//apple_ref/occ/instm/Widget/spin")
    }

    func testPercentEncodedPathsResolve() throws {
        let docset = try Fixture.docset(in: root, pages: ["a b.html": "<p>x</p>"], )
        XCTAssertNotNil(docset.fileURL(forPath: "a%20b.html"))
    }

    func testLibraryFindsDocsetsOneLevelDeepAndDeduplicates() throws {
        let first = root.appendingPathComponent("one")
        let second = root.appendingPathComponent("two/vendor")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        _ = try Fixture.docset(in: first, name: "Alpha", identifier: "alpha")
        _ = try Fixture.docset(in: second, name: "Beta", identifier: "beta")
        _ = try Fixture.docset(in: root.appendingPathComponent("two"), name: "AlphaCopy", identifier: "alpha")

        let library = DocsetLibrary(searchPaths: [first, root.appendingPathComponent("two")])
        let names = library.docsets().map(\.name)
        XCTAssertEqual(names, ["Alpha", "Beta"], "the same identifier twice is listed once, earliest path winning")
    }

    func testSearchPathsHonourTheEnvironmentOverride() {
        let paths = DocsetLibrary.defaultSearchPaths(
            environment: ["DOCENT_DOCSETS": "/tmp/a:/tmp/b"],
            home: URL(fileURLWithPath: "/Users/pretend")
        )
        XCTAssertEqual(paths.map(\.path), ["/tmp/a", "/tmp/b"])
    }

    func testDefaultSearchPathsCoverDashAndZeal() {
        let paths = DocsetLibrary.defaultSearchPaths(environment: [:], home: URL(fileURLWithPath: "/Users/pretend")).map(\.path)
        XCTAssertEqual(paths.count, 3)
        XCTAssertTrue(paths[0].hasSuffix("Application Support/Docent/DocSets"))
        XCTAssertTrue(paths.contains { $0.contains("Dash/DocSets") })
        XCTAssertTrue(paths.contains { $0.contains("Zeal") })
    }

    func testSymlinkedDocsetsAreNotFollowed() throws {
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let docset = try Fixture.docset(in: real, name: "Real", identifier: "real")
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("Real.docset"),
            withDestinationURL: docset.url
        )
        XCTAssertTrue(DocsetLibrary(searchPaths: [linked]).docsets().isEmpty)
    }
}

extension DocsetTests {
    /// `FileManager.homeDirectoryForCurrentUser` ignores `HOME`, so a tool built on it
    /// writes to the real library even when a caller has carefully redirected HOME.
    func testHomeFollowsTheEnvironment() {
        XCTAssertEqual(Home.directory(environment: ["HOME": "/tmp/pretend-home"]).path, "/tmp/pretend-home")
        XCTAssertEqual(Home.docsetsDirectory(environment: ["HOME": "/tmp/pretend-home"]).path,
                       "/tmp/pretend-home/Library/Application Support/Docent/DocSets")
    }

    func testSearchPathsFollowTheEnvironmentsHome() {
        let paths = DocsetLibrary.defaultSearchPaths(environment: ["HOME": "/tmp/pretend-home"]).map(\.path)
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/tmp/pretend-home/") }, "\(paths)")
    }
}

extension DocsetTests {
    /// Paths in a modern Dash docset are not plain paths: they carry display directives and
    /// percent-encoded `//dash_ref_…` anchors, and a reader that takes them literally finds
    /// no file at all.
    func testDashEntryDirectivesAreStrippedFromPaths() throws {
        let docset = try Fixture.docset(in: root, pages: ["pkg/fmt.html": "<p>x</p>"])
        let path = "<dash_entry_name=Println><dash_entry_menuDescription=fmt>pkg/fmt.html#//dash_ref_Println/Function/Println/0"
        XCTAssertEqual(Docset.normalizedPath(path), "pkg/fmt.html#//dash_ref_Println/Function/Println/0")
        XCTAssertEqual(docset.fileURL(forPath: path)?.lastPathComponent, "fmt.html")
        XCTAssertEqual(Docset.anchor(in: path), "//dash_ref_Println/Function/Println/0")
    }

    func testAnchorKeepsItsPercentEncoding() {
        XCTAssertEqual(Docset.anchor(in: "p.html#//dash_ref_example%2DPrintln/Sample/Println/0"),
                       "//dash_ref_example%2DPrintln/Sample/Println/0")
    }
}

extension DocsetTests {
    /// WebKit reads the directory flag on the URL it is given read access to, not the disk.
    func testDocumentsURLIsMarkedAsADirectory() throws {
        let docset = try Fixture.docset(in: root)
        XCTAssertTrue(docset.documentsURL.hasDirectoryPath,
                      "a read-access URL without the directory flag makes WebKit refuse every page")
    }
}

extension DocsetTests {
    func testASymlinkInsideTheDocsetCannotPointOutOfIt() throws {
        let docset = try Fixture.docset(in: root)
        let escape = docset.documentsURL.appendingPathComponent("escape.html")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNil(docset.fileURL(forPath: "escape.html"),
                     "a link inside the docset must not be a way out of it")
    }

    func testResolvedPathsAreReturnedSoWebKitAgreesWithUs() throws {
        let docset = try Fixture.docset(in: root)
        let file = try XCTUnwrap(docset.fileURL(forPath: "widget.html"))
        XCTAssertEqual(file.path, file.resolvingSymlinksInPath().path)
        XCTAssertTrue(file.path.hasPrefix(docset.readAccessURL.path + "/"))
    }
}
