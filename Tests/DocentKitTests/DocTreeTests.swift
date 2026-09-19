import XCTest
@testable import DocentKit

/// The shape a reader traverses when they do not yet know what to search for.
final class DocTreeTests: XCTestCase {
    private let project: [IndexEntry] = [
        IndexEntry(name: "Overview", type: "Guide", path: "index.html"),
        IndexEntry(name: "Project", type: "Guide", path: "README.html"),
        IndexEntry(name: "Install", type: "Section", path: "README.html#install"),
        IndexEntry(name: "Sources/Canvas.swift", type: "File", path: "Sources/Canvas.swift.html"),
        IndexEntry(name: "Canvas", type: "Struct", path: "Sources/Canvas.swift.html#canvas"),
        IndexEntry(name: "Canvas.draw", type: "Method", path: "Sources/Canvas.swift.html#canvasdraw"),
        IndexEntry(name: "Canvas.Layer", type: "Struct", path: "Sources/Canvas.swift.html#canvaslayer"),
        IndexEntry(name: "Canvas.Layer.merge", type: "Method", path: "Sources/Canvas.swift.html#canvaslayermerge"),
        IndexEntry(name: "Sources/IO/File.swift", type: "File", path: "Sources/IO/File.swift.html"),
        IndexEntry(name: "File", type: "Enum", path: "Sources/IO/File.swift.html#file"),
    ]

    private func find(_ nodes: [DocTree.Node], _ title: String) -> DocTree.Node? {
        for node in nodes {
            if node.title == title { return node }
            if let found = find(node.children, title) { return found }
        }
        return nil
    }

    func testTheOverviewComesFirst() {
        let tree = DocTree.build(project)
        XCTAssertEqual(tree.first?.title, "Overview")
        XCTAssertEqual(tree.first?.entry?.path, "index.html")
    }

    func testFilesSitInTheirFolders() {
        let tree = DocTree.build(project)
        let folder = find(tree, "Sources")
        XCTAssertNotNil(folder, "no folder for Sources: \(tree.map(\.title))")
        XCTAssertNil(folder?.entry, "a folder is not a page")
        XCTAssertNotNil(find(tree, "Canvas.swift"))
        XCTAssertNotNil(find(tree, "File.swift"))
        // Folders nest the way they do on disk.
        let io = folder?.children.first { $0.title == "IO" }
        XCTAssertNotNil(io, "IO should sit inside Sources: \(folder?.children.map(\.title) ?? [])")
        XCTAssertEqual(io?.children.map(\.title), ["File.swift"])
        XCTAssertEqual(folder?.children.first?.title, "IO", "folders come before files")
    }

    func testADocumentKeepsItsOwnTitle() {
        let tree = DocTree.build(project)
        let readme = find(tree, "Project")
        XCTAssertEqual(readme?.entry?.path, "README.html")
        XCTAssertEqual(readme?.children.first?.title, "Install")
    }

    /// A type's members belong under the type, not beside it.
    func testMembersNestUnderTheirType() {
        let tree = DocTree.build(project)
        let file = find(tree, "Canvas.swift")
        XCTAssertEqual(file?.children.count, 1, "only the type is top level in that file")
        let canvas = file?.children.first
        XCTAssertEqual(canvas?.title, "Canvas")
        XCTAssertEqual(canvas?.children.map(\.title), ["draw", "Layer"])
        XCTAssertEqual(canvas?.children.last?.children.map(\.title), ["merge"])
    }

    func testEveryLeafCanBeOpened() {
        func check(_ nodes: [DocTree.Node]) {
            for node in nodes {
                if node.isLeaf { XCTAssertNotNil(node.entry, "\(node.title) opens nothing") }
                check(node.children)
            }
        }
        check(DocTree.build(project))
    }

    /// Somebody else's docset has no file structure to show, but it still has kinds.
    func testADocsetFromElsewhereIsGroupedByKind() {
        let dash = [
            IndexEntry(name: "Println", type: "Function", path: "pkg/fmt.html#Println"),
            IndexEntry(name: "Printf", type: "Function", path: "pkg/fmt.html#Printf"),
            IndexEntry(name: "Writer", type: "Interface", path: "pkg/io.html#Writer"),
        ]
        let tree = DocTree.build(dash)
        XCTAssertEqual(tree.map(\.title), ["Function", "Interface"])
        XCTAssertEqual(tree.first?.children.map(\.title), ["Printf", "Println"])
    }

    func testAHugeDocsetIsNotLaidOutAtAll() {
        let many = (0..<(DocTree.maximumEntries + 1)).map {
            IndexEntry(name: "n\($0)", type: "Function", path: "p.html#\($0)")
        }
        XCTAssertTrue(DocTree.build(many).isEmpty, "a huge docset must fall back to searching")
    }
}
