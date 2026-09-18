import XCTest
@testable import DocentKit

final class RankingTests: XCTestCase {
    private func order(_ names: [String], query: String) -> [String] {
        let docset = Docset.stub
        let candidates = names.map { (docset: docset, entry: IndexEntry(name: $0, type: "Method", path: "p.html")) }
        return Ranking.rank(candidates, query: query, limit: 0).map { $0.entry.name }
    }

    func testExactBeatsPrefixBeatsContains() {
        XCTAssertEqual(order(["mapValues", "map", "flatMap", "Map"], query: "map"),
                       ["map", "Map", "mapValues", "flatMap"])
    }

    func testShorterNameWinsWithinARung() {
        XCTAssertEqual(order(["printf", "print", "println"], query: "print").first, "print")
    }

    func testBoundaryPrefixBeatsPlainSubstring() {
        let result = order(["NSString.length", "lengthiness", "belength"], query: "length")
        XCTAssertEqual(result.first, "lengthiness")          // a real prefix still wins
        XCTAssertEqual(result[1], "NSString.length")          // then the separator boundary
        XCTAssertEqual(result.last, "belength")               // a bare substring is last
    }

    func testSubsequenceMatchesButRanksLast() {
        let result = order(["NSURLSession", "session"], query: "nsurls")
        XCTAssertEqual(result.first, "NSURLSession")
        XCTAssertEqual(result.count, 1, "a name without the query's letters in order must not match")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(Ranking.score(name: "Widget", query: "zzz"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(order(["b", "a"], query: "").count, 2)
    }

    func testOrderIsStableForIdenticalNames() {
        let docset = Docset.stub
        let candidates = [
            (docset: docset, entry: IndexEntry(name: "same", type: "Method", path: "b.html")),
            (docset: docset, entry: IndexEntry(name: "same", type: "Method", path: "a.html")),
        ]
        XCTAssertEqual(Ranking.rank(candidates, query: "same", limit: 0).map { $0.entry.path }, ["a.html", "b.html"])
    }

    func testLimitIsApplied() {
        XCTAssertEqual(order(["map", "mapValues", "flatMap"], query: "map").count, 3)
        let docset = Docset.stub
        let candidates = ["map", "mapValues", "flatMap"].map {
            (docset: docset, entry: IndexEntry(name: $0, type: "Method", path: "p.html"))
        }
        XCTAssertEqual(Ranking.rank(candidates, query: "map", limit: 2).count, 2)
    }
}

extension Docset {
    /// A docset value for pure ranking tests, which never touch the disk.
    static var stub: Docset {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docent-stub-\(UUID().uuidString)")
        let docset = try! Fixture.docset(in: root, name: "Stub", rows: [])
        return docset
    }
}

extension RankingTests {
    /// A camelCase hump starts a word even though no punctuation says so, which is how
    /// people search Objective-C and Swift APIs.
    func testACamelCaseHumpCountsAsAWordBoundary() {
        let humped = Ranking.score(name: "NSStringLength", query: "Length")
        let buried = Ranking.score(name: "stringlengthy", query: "length")
        XCTAssertNotNil(humped)
        XCTAssertNotNil(buried)
        XCTAssertGreaterThan(humped!, buried!, "a hump should rank above a name that merely contains the query")
    }

    func testTheHumpDoesNotOutrankARealPrefix() {
        let prefix = Ranking.score(name: "Length", query: "Length")!
        let hump = Ranking.score(name: "NSStringLength", query: "Length")!
        XCTAssertGreaterThan(prefix, hump)
    }
}
