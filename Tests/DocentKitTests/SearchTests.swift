import XCTest
@testable import DocentKit

final class SearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBothIndexSchemasReadTheSameWay() throws {
        for schema in [Fixture.Schema.searchIndex, .coreData] {
            let folder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let docset = try Fixture.docset(in: folder, schema: schema)
            let index = try SearchIndex(url: docset.indexURL)
            let rows = try index.candidates(matching: "spin")
            XCTAssertEqual(rows.map(\.name), ["Widget.spin"], "schema \(schema)")
            XCTAssertEqual(rows.first?.path, "widget.html#spin", "schema \(schema)")
        }
    }

    func testWildcardsTypedByTheUserAreLiteral() throws {
        let docset = try Fixture.docset(in: root, rows: [
            .init("100%", "Constant", "p.html"),
            .init("Widget", "Class", "p.html"),
        ])
        let index = try SearchIndex(url: docset.indexURL)
        XCTAssertEqual(try index.candidates(matching: "%").map(\.name), ["100%"])
    }

    func testSubsequencePatternEscapes() {
        XCTAssertEqual(SearchIndex.subsequencePattern(for: "ab"), "%a%b%")
        XCTAssertEqual(SearchIndex.subsequencePattern(for: "a_b"), "%a%\\_%b%")
        XCTAssertEqual(SearchIndex.subsequencePattern(for: "50%"), "%5%0%\\%%")
    }

    func testFindRanksAcrossDocsets() throws {
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        _ = try Fixture.docset(in: a, name: "Go", identifier: "go", keyword: "go",
                               rows: [.init("Println", "Function", "fmt.html#Println")])
        _ = try Fixture.docset(in: b, name: "Python", identifier: "py", keyword: "python",
                               rows: [.init("print", "Function", "functions.html#print")])

        let service = SearchService(library: DocsetLibrary(searchPaths: [a, b]))
        let names = try service.find("print").map(\.entry.name)
        XCTAssertEqual(names, ["print", "Println"])
    }

    func testDocsetPrefixNarrowsTheSearch() throws {
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        _ = try Fixture.docset(in: a, name: "Go", identifier: "go", keyword: "go",
                               rows: [.init("Println", "Function", "fmt.html#Println")])
        _ = try Fixture.docset(in: b, name: "Python", identifier: "py", keyword: "python",
                               rows: [.init("print", "Function", "functions.html#print")])

        let service = SearchService(library: DocsetLibrary(searchPaths: [a, b]))
        XCTAssertEqual(try service.find("go:print").map(\.entry.name), ["Println"])
        XCTAssertEqual(try service.find("python:print").map(\.entry.name), ["print"])
    }

    func testAQueryThatLooksLikeASymbolIsNotADocsetHint() {
        XCTAssertNil(SearchService.Query("NSString::length").docsetHint)
        XCTAssertEqual(SearchService.Query("NSString::length").text, "NSString::length")
        XCTAssertEqual(SearchService.Query("go:Println").docsetHint, "go")
        XCTAssertEqual(SearchService.Query("go:Println").text, "Println")
    }

    func testAnUnknownDocsetHintSearchesEverythingRatherThanNothing() throws {
        let docset = try Fixture.docset(in: root)
        let service = SearchService(library: DocsetLibrary(searchPaths: [root]))
        XCTAssertEqual(try service.find("nosuchdocset:Widget").map(\.entry.name).first, "Widget")
        XCTAssertEqual(docset.name, "Pretend")
    }

    func testPageRendersTheAnchoredSectionOnly() throws {
        _ = try Fixture.docset(in: root)
        let service = SearchService(library: DocsetLibrary(searchPaths: [root]))
        let match = try XCTUnwrap(try service.find("Widget.spin").first)
        let page = try service.page(for: match)
        XCTAssertTrue(page.text.contains("Spins the widget."), page.text)
        XCTAssertFalse(page.text.contains("Stops it."), page.text)
        XCTAssertEqual(page.title, "Widget")
    }

    func testAMissingPageIsAnHonestError() throws {
        _ = try Fixture.docset(in: root, rows: [.init("Ghost", "Class", "not-here.html")])
        let service = SearchService(library: DocsetLibrary(searchPaths: [root]))
        let match = try XCTUnwrap(try service.find("Ghost").first)
        XCTAssertThrowsError(try service.page(for: match))
    }

    func testAnIndexInAnUnknownFormatIsReportedNotCrashed() throws {
        let docset = try Fixture.docset(in: root)
        try Fixture.writeIndexWithNoKnownTables(at: docset.indexURL)
        XCTAssertThrowsError(try SearchIndex(url: docset.indexURL))
        let service = SearchService(library: DocsetLibrary(searchPaths: [root]))
        XCTAssertEqual(try service.find("Widget").count, 0, "a broken docset is skipped, not fatal")
    }
}
