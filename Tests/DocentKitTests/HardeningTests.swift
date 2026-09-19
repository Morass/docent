import XCTest
@testable import DocentKit

/// One test per finding from the review round before publication. Each of these fails
/// against the code as it was.
final class HardeningTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docent-hardening-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The docset boundary

    /// A docset whose `Documents` is a symlink to somewhere else sets the read boundary to
    /// that somewhere else: an index row naming `hosts` would be served as documentation.
    func testADocsetThatPointsItsDocumentsOutsideIsNotADocset() throws {
        let bundle = root.appendingPathComponent("Escape.docset")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: resources.appendingPathComponent("docSet.dsidx"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Escape"], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("hosts"))
        try FileManager.default.createSymbolicLink(
            at: resources.appendingPathComponent("Documents"), withDestinationURL: outside)

        XCTAssertNil(Docset(contentsOf: bundle), "a docset may not point its Documents outside itself")
    }

    /// A named pipe has no size and blocks whoever opens it: a FIFO in place of a file
    /// inside a docset must not be read at all.
    func testANamedPipeIsNotAFile() throws {
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, "could not make a FIFO to test against")
        XCTAssertFalse(Containment.isOrdinaryFile(fifo))
        XCTAssertNil(Containment.read(fifo, limit: 1024), "a FIFO was opened, which blocks for ever")

        let file = root.appendingPathComponent("real.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertTrue(Containment.isOrdinaryFile(file))
        XCTAssertEqual(Containment.read(file, limit: 1024).map { String(decoding: $0, as: UTF8.self) }, "hello")
        XCTAssertNil(Containment.read(file, limit: 2), "the size limit was not enforced")
    }

    // MARK: - Writing a docset

    /// `docent index ./project --out ./project` used to delete the project.
    func testIndexingRefusesToWriteInsideTheFolderItIsReading() throws {
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "# P\n\n## S\n\ntext\n".write(to: project.appendingPathComponent("README.md"),
                                          atomically: true, encoding: .utf8)

        let indexer = Indexer(source: project, name: "P", keyword: "p")
        XCTAssertThrowsError(try indexer.build(into: project)) { error in
            XCTAssertTrue("\(error)".contains("inside the folder"), "\(error)")
        }
        XCTAssertThrowsError(try indexer.build(into: project.appendingPathComponent("out.docset")))
        // And the project is still there.
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("README.md").path))
    }

    /// Something that is not a docset at the destination is never deleted.
    func testIndexingWillNotDeleteWhateverIsInTheWay() throws {
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "# P\n\n## S\n\ntext\n".write(to: project.appendingPathComponent("README.md"),
                                          atomically: true, encoding: .utf8)
        let occupied = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("a picture".utf8).write(to: occupied.appendingPathComponent("holiday.png"))

        XCTAssertThrowsError(try Indexer(source: project, name: "P").build(into: occupied))
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.appendingPathComponent("holiday.png").path),
                      "it deleted a folder that was not a docset")
    }

    /// A rebuild replaces the docset and leaves nothing half-written behind.
    func testRebuildingLeavesOneWholeDocset() throws {
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "# P\n\n## One\n\ntext\n".write(to: project.appendingPathComponent("README.md"),
                                            atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("P.docset")
        _ = try Indexer(source: project, name: "P").build(into: out)
        try "# P\n\n## Two\n\ntext\n".write(to: project.appendingPathComponent("README.md"),
                                            atomically: true, encoding: .utf8)
        _ = try Indexer(source: project, name: "P").build(into: out)

        XCTAssertNotNil(Docset(contentsOf: out))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasPrefix(".docent-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "half-built folders were left behind: \(leftovers)")
    }

    // MARK: - Hostile input that used to be slow or huge

    func testAThousandEnumCasesOnOneLineCannotOutrunTheCap() {
        let cases = (0..<200_000).map { "c\($0)" }.joined(separator: ",")
        let found = SourceSymbols.symbols(in: "enum E {\ncase \(cases)\n}\n", language: .swift)
        XCTAssertLessThanOrEqual(found.count, SourceSymbols.maxSymbols)
    }

    func testAPageOfIdenticalHeadingsIsNotQuadratic() {
        let source = String(repeating: "# x\n\n", count: 20_000)
        let started = Date()
        let page = Markdown.render(source, fallbackTitle: "x")
        XCTAssertEqual(page.headings.count, 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "anchor collisions are quadratic again")
    }

    func testUnterminatedTagsAreNotQuadratic() {
        let html = String(repeating: "<a ", count: 60_000)
        let started = Date()
        _ = HTMLText.render(html).text
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "tag scanning is quadratic again")
    }

    func testAnAbsurdPathDoesNotBuildAnAbsurdTree() {
        let deep = String(repeating: "a/", count: 100_000) + "x.html"
        let tree = DocTree.build([IndexEntry(name: "deep", type: "File", path: deep)])
        XCTAssertTrue(tree.isEmpty, "a path with a hundred thousand folders was laid out")
    }

    // MARK: - Archives and links

    /// An archive can put spaces in the owner and group names, which shifts the column the
    /// size used to be read from.
    func testArchiveSizesSurviveSpacesInTheOwnerName() {
        let honest = "-rw-r--r--  0 owner staff 2560 18 Sep 21:44 a.txt"
        let crafted = "-rw-r--r--  0 owner extra staff 4000000000 18 Sep 21:44 big.bin"
        XCTAssertEqual(TarListing.unpackedBytes(honest), 2560)
        XCTAssertEqual(TarListing.unpackedBytes(crafted), 4_000_000_000,
                       "a crafted owner name hid the real size")
        let gnu = "-rw-r--r-- 0/0 1234 2026-09-18 21:44 a.txt"
        XCTAssertEqual(TarListing.unpackedBytes(gnu), 1234)
    }

    func testOnlyWebLinksLeaveTheReader() {
        for allowed in ["http://example.com", "https://example.com", "mailto:someone@example.com"] {
            XCTAssertTrue(NetworkBlock.opensOutside(URL(string: allowed)!), allowed)
        }
        for refused in ["smb://attacker/share", "ftp://host/x", "someapp://do-a-thing", "file:///etc/hosts"] {
            XCTAssertFalse(NetworkBlock.opensOutside(URL(string: refused)!), refused)
        }
    }
}

// MARK: - The second seat's findings

extension HardeningTests {
    /// A line of four megabytes of `*` is inside the file size cap, and used to take
    /// minutes because each pass searched the remainder from its start.
    func testAWallOfEmphasisMarkersIsNotQuadratic() {
        let source = String(repeating: "*", count: 200_000)
        let started = Date()
        _ = Markdown.render(source, fallbackTitle: "x")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "inline markup is quadratic again")
    }

    func testAMillionLinksAreNotQuadratic() {
        let source = String(repeating: "[a](b) ", count: 60_000)
        let started = Date()
        _ = Markdown.render(source, fallbackTitle: "x")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "link parsing is quadratic again")
    }

    /// Sizes near `Int.max` used to trap while adding up — a crash before any cap could
    /// refuse the archive.
    func testAnArchiveCannotCrashTheSizeCheck() {
        let huge = "-rw-r--r--  0 o g \(Int.max) 18 Sep 21:44 a.bin\n"
            + "-rw-r--r--  0 o g \(Int.max) 18 Sep 21:44 b.bin"
        XCTAssertEqual(TarListing.unpackedBytes(huge), Int.max)
    }

    /// `--out ~/Applications/Thing.app` must not be treated as a docset to replace.
    func testOnlySomethingCalledDocsetLooksLikeOne() throws {
        let bundle = root.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertFalse(Indexer.looksLikeADocset(bundle))
    }

    func testALinkToDataOrAFileIsNotALink() {
        for target in ["data:text/html;base64,PHNjcmlwdD4=", "javascript:alert(1)", "file:///etc/hosts"] {
            let html = Markdown.render("[click](\(target))\n", fallbackTitle: "x").html
            XCTAssertFalse(html.contains("<a href"), "\(target) became a link: \(html)")
        }
        let good = Markdown.render("[docs](docs/DESIGN.md)\n", fallbackTitle: "x").html
        XCTAssertTrue(good.contains("<a href=\"docs/DESIGN.md\">"), good)
    }
}
