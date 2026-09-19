import XCTest
@testable import DocentKit

/// The declarations a repository's own code puts on offer. A miss here is an entry the
/// reader never sees, so every language gets the shapes people actually write.
final class SourceSymbolsTests: XCTestCase {
    private func symbols(_ source: String, _ language: SourceSymbols.Language) -> [SourceSymbols.Symbol] {
        SourceSymbols.symbols(in: source, language: language)
    }

    private func named(_ found: [SourceSymbols.Symbol], _ name: String) -> SourceSymbols.Symbol? {
        found.first { $0.name == name }
    }

    // MARK: - Swift

    func testSwiftTypesMethodsAndTheirDocumentation() {
        let found = symbols("""
        import Foundation

        /// Somewhere to draw.
        /// Holds the pixels.
        public struct Canvas {
            /// The width in pixels.
            public let width: Int
            var scratch: [UInt8] = []

            public init(width: Int) {
                let unused = width * 2
                self.width = width
            }

            /// Draws a line.
            public func draw(from: Point, to: Point) {
                let steps = 10
                func helper() {}
            }
        }
        """, .swift)

        XCTAssertEqual(named(found, "Canvas")?.kind, "Struct")
        XCTAssertEqual(named(found, "Canvas")?.doc, "Somewhere to draw.\nHolds the pixels.")
        XCTAssertEqual(named(found, "Canvas.width")?.kind, "Constant")
        XCTAssertEqual(named(found, "Canvas.width")?.doc, "The width in pixels.")
        XCTAssertEqual(named(found, "Canvas.scratch")?.kind, "Property")
        XCTAssertEqual(named(found, "Canvas.init")?.kind, "Constructor")
        XCTAssertEqual(named(found, "Canvas.draw")?.kind, "Method")
        XCTAssertEqual(named(found, "Canvas.draw")?.doc, "Draws a line.")
        XCTAssertEqual(named(found, "Canvas.draw")?.line, 16)

        // Locals inside a function body are not API, and indexing them buries what is.
        XCTAssertNil(named(found, "Canvas.unused"))
        XCTAssertNil(named(found, "Canvas.steps"))
        XCTAssertNil(named(found, "Canvas.helper"))
    }

    func testNestedTypesAreNamedOnceEach() {
        let found = symbols("""
        enum ImageFile {
            struct Failure: Error {
                let what: String
            }
        }
        """, .swift)
        XCTAssertNotNil(named(found, "ImageFile.Failure"))
        XCTAssertNotNil(named(found, "ImageFile.Failure.what"))
        XCTAssertNil(named(found, "ImageFile.ImageFile.Failure"), "the name was qualified twice")
    }

    func testEnumCasesAndExtensions() {
        let found = symbols("""
        enum Tool {
            case pencil, brush
            case fill
        }

        extension Canvas {
            func clear() {}
        }
        """, .swift)
        XCTAssertEqual(named(found, "Tool.pencil")?.kind, "Value")
        XCTAssertNotNil(named(found, "Tool.brush"))
        XCTAssertNotNil(named(found, "Tool.fill"))
        XCTAssertEqual(named(found, "Canvas")?.kind, "Category")
        XCTAssertEqual(named(found, "Canvas.clear")?.kind, "Method")
    }

    /// A brace inside a string literal used to move everything after it one level deeper.
    func testBracesInsideStringsDoNotMoveTheNesting() {
        let found = symbols("""
        struct A {
            func one() { print("{") }
            func two() {}
        }
        """, .swift)
        XCTAssertEqual(named(found, "A.two")?.kind, "Method")
    }

    func testAWordThatOnlyLooksLikeADeclaration() {
        let found = symbols("""
        let result = thing.func_like()
        // func commented() {}
        """, .swift)
        XCTAssertNil(named(found, "commented"))
        XCTAssertEqual(named(found, "result")?.kind, "Constant")
    }

    // MARK: - Other languages

    func testPython() {
        let found = symbols("""
        class Canvas:
            \"\"\"Somewhere to draw.\"\"\"

            def draw(self, x):
                \"\"\"Draws a dot.\"\"\"
                helper = 1

        def main():
            pass
        """, .python)
        XCTAssertEqual(named(found, "Canvas")?.kind, "Class")
        XCTAssertEqual(named(found, "Canvas")?.doc, "Somewhere to draw.")
        XCTAssertEqual(named(found, "Canvas.draw")?.kind, "Method")
        XCTAssertEqual(named(found, "Canvas.draw")?.doc, "Draws a dot.")
        XCTAssertEqual(named(found, "main")?.kind, "Function")
    }

    func testGo() {
        let found = symbols("""
        // Canvas is somewhere to draw.
        type Canvas struct {
            Width int
        }

        // Draw draws a line.
        func (c *Canvas) Draw(x int) {}

        func New() *Canvas { return nil }
        """, .go)
        XCTAssertEqual(named(found, "Canvas")?.kind, "Struct")
        XCTAssertEqual(named(found, "Canvas")?.doc, "Canvas is somewhere to draw.")
        XCTAssertEqual(named(found, "Canvas.Draw")?.kind, "Method")
        XCTAssertEqual(named(found, "New")?.kind, "Function")
    }

    func testJavaScript() {
        let found = symbols("""
        /** Somewhere to draw. */
        export class Canvas {
            draw(x) {}
        }

        export const scale = (n) => n * 2;
        function main() {}
        """, .javascript)
        XCTAssertEqual(named(found, "Canvas")?.kind, "Class")
        XCTAssertEqual(named(found, "Canvas")?.doc, "Somewhere to draw.")
        XCTAssertEqual(named(found, "scale")?.kind, "Function")
        XCTAssertEqual(named(found, "main")?.kind, "Function")
    }

    func testRust() {
        let found = symbols("""
        /// Somewhere to draw.
        pub struct Canvas {
            pub width: u32,
        }

        impl Canvas {
            /// Draws a line.
            pub fn draw(&self) {}
        }
        """, .rust)
        XCTAssertEqual(named(found, "Canvas")?.kind, "Struct")
        XCTAssertEqual(named(found, "Canvas")?.doc, "Somewhere to draw.")
        XCTAssertEqual(named(found, "Canvas.draw")?.kind, "Method")
    }

    func testAnUnreadableFileIsNotACrash() {
        XCTAssertTrue(symbols("", .swift).isEmpty)
        XCTAssertTrue(symbols("}}}{{{\n</", .swift).isEmpty)
        XCTAssertTrue(symbols(String(repeating: "func ", count: 500), .swift).count <= SourceSymbols.maxSymbols)
    }
}

// MARK: - Through the indexer

final class IndexedCodeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("docent-code-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"),
                                                withIntermediateDirectories: true)
        try "# Project\n\n## Install\n\nRun make.\n"
            .write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try """
        /// Somewhere to draw.
        public struct Canvas {
            /// Copies the selection to the clipboard.
            public func copy() {}
        }
        """.write(to: root.appendingPathComponent("Sources/Canvas.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func index(includeCode: Bool = true) throws -> (Indexer.Report, SearchIndex) {
        let out = root.appendingPathComponent("Out-\(includeCode).docset")
        let report = try Indexer(source: root, name: "Project", keyword: "proj",
                                 includeCode: includeCode).build(into: out)
        return (report, try SearchIndex(url: out.appendingPathComponent("Contents/Resources/docSet.dsidx")))
    }

    func testCodeIsIndexedAlongsideTheProse() throws {
        let (report, index) = try index()
        XCTAssertEqual(report.symbols, 2)

        let names = try index.candidates(matching: "Canvas", limit: 20).map { $0.name }
        XCTAssertTrue(names.contains("Canvas"), "\(names)")
        XCTAssertTrue(names.contains("Canvas.copy"), "\(names)")
        let canvas = try index.candidates(matching: "Canvas", limit: 20).first { $0.name == "Canvas" }
        XCTAssertEqual(canvas?.type, "Struct")
        // The prose is still there.
        XCTAssertFalse(try index.candidates(matching: "Install", limit: 5).isEmpty)
    }

    /// The search that started this: a word that lives only in the code, found by text.
    func testAWordOnlyInTheCodeIsStillFound() throws {
        let (_, index) = try index()
        XCTAssertTrue(index.hasFullText)
        XCTAssertFalse(try index.textMatches("clipboard", limit: 5).isEmpty)
    }

    func testDocsOnlyLeavesTheCodeOut() throws {
        let (report, index) = try index(includeCode: false)
        XCTAssertEqual(report.symbols, 0)
        XCTAssertTrue(try index.candidates(matching: "Canvas", limit: 5).isEmpty)
        XCTAssertFalse(try index.candidates(matching: "Install", limit: 5).isEmpty)
    }

    /// A declaration's page has to land on the declaration, not at the top of the file.
    func testEachDeclarationHasItsOwnAnchor() throws {
        let (_, index) = try index()
        let copy = try index.candidates(matching: "Canvas.copy", limit: 5).first { $0.name == "Canvas.copy" }
        XCTAssertEqual(copy?.path.contains("#"), true, "\(copy?.path ?? "nothing")")
    }
}
