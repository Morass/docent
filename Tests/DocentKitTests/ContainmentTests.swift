import XCTest
@testable import DocentKit

final class ContainmentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docent-containment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAPlainFileInsideIsAllowed() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let page = docs.appendingPathComponent("page.html")
        try "x".data(using: .utf8)!.write(to: page)
        XCTAssertTrue(Containment.allows(page, under: docs))
    }

    /// The check the app's navigation policy used to do was lexical, so a symlink that
    /// *looks* inside was allowed and WebKit followed it out.
    func testASymlinkPointingOutIsRefused() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let link = docs.appendingPathComponent("leak.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertFalse(Containment.allows(link, under: docs))
    }

    func testAPathClimbingOutIsRefused() {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        XCTAssertFalse(Containment.allows(docs.appendingPathComponent("../../etc/hosts"), under: docs))
    }

    func testAFileURLWithAHostIsRefused() {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        XCTAssertFalse(Containment.allows(URL(string: "file://evil.example/x.html")!, under: docs))
    }

    func testANonFileURLIsRefused() {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        XCTAssertFalse(Containment.allows(URL(string: "https://example.com/x")!, under: docs))
    }
}
