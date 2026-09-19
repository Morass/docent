import XCTest
@testable import DocentKit

final class OpenRequestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docent-request-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testARequestSurvivesTheTrip() throws {
        let url = root.appendingPathComponent("request.json")
        try OpenRequest(docset: "mine", query: "Install").write(to: url)
        let read = OpenRequest.consume(at: url)
        XCTAssertEqual(read?.docset, "mine")
        XCTAssertEqual(read?.query, "Install")
    }

    /// Acted on once. A request left behind would send the window to the same docset on
    /// every launch afterwards.
    func testConsumingDeletesIt() throws {
        let url = root.appendingPathComponent("request.json")
        try OpenRequest(docset: "mine").write(to: url)
        XCTAssertNotNil(OpenRequest.consume(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(OpenRequest.consume(at: url))
    }

    func testAnOldRequestIsIgnoredButStillCleanedUp() throws {
        let url = root.appendingPathComponent("request.json")
        try OpenRequest(docset: "mine", written: Date().addingTimeInterval(-3600)).write(to: url)
        XCTAssertNil(OpenRequest.consume(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRubbishIsNotARequest() throws {
        let url = root.appendingPathComponent("request.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(OpenRequest.consume(at: url))
    }

    /// It lives inside the folder the library reads, hidden — so the docset scanner walks
    /// past it, and a sandboxed library gets its own.
    func testItLivesWhereTheLibraryLooksAndIsNotADocset() throws {
        let library = DocsetLibrary(searchPaths: [root])
        let url = OpenRequest.url(library: library)
        XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("."), url.lastPathComponent)

        try OpenRequest(docset: "mine").write(to: url)
        XCTAssertTrue(DocsetLibrary.docsetURLs(under: root).isEmpty)
        XCTAssertTrue(library.docsets().isEmpty)
    }

    func testAHugeFileIsNotReadIn() throws {
        let url = root.appendingPathComponent("request.json")
        try Data(repeating: 0x7B, count: 200 * 1024).write(to: url)
        XCTAssertNil(OpenRequest.consume(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
