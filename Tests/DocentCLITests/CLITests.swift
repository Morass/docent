import XCTest
import DocentKit

/// Runs the real binary. Every case gets a HOME of its own under the test's temporary
/// directory and an explicit `DOCENT_DOCSETS`, so a test can never read — or report on —
/// the docsets of the machine it happens to run on.
final class CLITests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var docsets: URL!

    static let binary: URL = {
        if let override = ProcessInfo.processInfo.environment["DOCENT_BIN"] {
            return URL(fileURLWithPath: override)
        }
        // The test bundle sits beside the products SwiftPM built, so the binary under test
        // is its neighbour. `Bundle.main` is the test *runner* (xctest itself), which lives
        // somewhere else entirely — a trap worth one comment.
        var url = Bundle(for: CLITests.self).bundleURL
        while url.pathExtension == "xctest" || url.lastPathComponent == "Contents" || url.lastPathComponent == "MacOS" {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("docent")
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docent-e2e-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        docsets = root.appendingPathComponent("docsets")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docsets, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.binary.path),
                      "built binary not found at \(Self.binary.path) — set DOCENT_BIN")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    struct Run {
        let out: String
        let err: String
        let status: Int32
    }

    @discardableResult
    func docent(_ arguments: [String], withDocsets: Bool = true) throws -> Run {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        // An allow-list, not the ambient environment: PATH and HOME only, plus the docsets
        // the case set up.
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        if withDocsets { environment["DOCENT_DOCSETS"] = docsets.path }
        process.environment = environment

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    func makeGopher() throws {
        let bundle = docsets.appendingPathComponent("Gopher.docset")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let documents = resources.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleName": "Gopher",
            "CFBundleIdentifier": "gopher",
            "DocSetPlatformFamily": "go",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try """
        <html><head><title>package fmt</title></head><body>
        <h1>package fmt</h1><p>Formatted I/O.</p>
        <a name="Println"></a><h2>func Println</h2><pre>func Println(a ...any) (n int, err error)</pre>
        <p>Println writes to standard output.</p>
        <a name="Printf"></a><h2>func Printf</h2><p>Printf formats.</p>
        </body></html>
        """.data(using: .utf8)!.write(to: documents.appendingPathComponent("fmt.html"))

        let index = resources.appendingPathComponent("docSet.dsidx")
        let sql = """
        CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT);
        INSERT INTO searchIndex(name,type,path) VALUES
          ('fmt','Package','fmt.html'),
          ('fmt.Println','Function','fmt.html#Println'),
          ('fmt.Printf','Function','fmt.html#Printf');
        """
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [index.path, sql]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0, "could not build the fixture index")
    }

    // MARK: - Cases

    func testHelpListsEveryCommand() throws {
        let run = try docent(["--help"])
        XCTAssertEqual(run.status, 0)
        for command in ["list", "find", "show", "path", "help"] {
            XCTAssertTrue(run.out.contains(command), "help does not mention \(command)")
        }
    }

    func testEveryCommandHasItsOwnHelpWithAnExample() throws {
        for command in ["list", "find", "show", "path"] {
            let viaHelp = try docent(["help", command])
            let viaFlag = try docent([command, "--help"])
            XCTAssertEqual(viaHelp.status, 0)
            XCTAssertEqual(viaHelp.out, viaFlag.out, "`docent help \(command)` and `docent \(command) --help` must agree")
            XCTAssertTrue(viaHelp.out.contains("USAGE"), "\(command) help has no usage")
        }
    }

    func testVersionIsPrinted() throws {
        let run = try docent(["--version"])
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.out.hasPrefix("docent "), run.out)
    }

    func testNoDocsetsSaysWhereTheyGo() throws {
        let run = try docent(["list"])
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.out.contains("No docsets found"), run.out)
        XCTAssertTrue(run.out.contains("DOCENT_DOCSETS"), run.out)
    }

    func testAnEmptyHomeFindsNothingOfTheRealMachine() throws {
        let run = try docent(["list"], withDocsets: false)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.out.contains("No docsets found"), "a sandboxed HOME must see no docsets: \(run.out)")
    }

    func testListNamesTheDocsetItsKeywordAndItsSize() throws {
        try makeGopher()
        let run = try docent(["list"])
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.out.contains("Gopher"), run.out)
        XCTAssertTrue(run.out.contains("go:"), run.out)
        XCTAssertTrue(run.out.contains("3 symbols"), run.out)
    }

    func testFindRanksExactFirst() throws {
        try makeGopher()
        let run = try docent(["find", "fmt"])
        XCTAssertEqual(run.status, 0)
        let names = run.out.split(separator: "\n").map(String.init)
        XCTAssertTrue(names[0].contains("fmt "), names.joined(separator: " / "))
        XCTAssertEqual(names.count, 3)
    }

    func testFindJSONIsParseable() throws {
        try makeGopher()
        let run = try docent(["find", "Print", "--json"])
        XCTAssertEqual(run.status, 0)
        let objects = try JSONSerialization.jsonObject(with: Data(run.out.utf8)) as? [[String: String]]
        XCTAssertEqual(objects?.count, 2)
        XCTAssertEqual(objects?.first?["docset"], "Gopher")
        XCTAssertTrue(objects?.first?["file"]?.hasSuffix("fmt.html") == true)
    }

    func testShowPrintsOnlyTheSectionTheSymbolIsOn() throws {
        try makeGopher()
        let run = try docent(["show", "fmt.Println"])
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.out.contains("Println writes to standard output."), run.out)
        XCTAssertFalse(run.out.contains("Printf formats."), run.out)
    }

    func testShowAllPrintsThePage() throws {
        try makeGopher()
        let run = try docent(["show", "fmt.Println", "--all"])
        XCTAssertTrue(run.out.contains("Printf formats."), run.out)
    }

    func testPathPrintsFileAndAnchor() throws {
        try makeGopher()
        let run = try docent(["path", "fmt.Printf"])
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.out.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("fmt.html#Printf"), run.out)
    }

    func testPipedOutputCarriesNoEscapeCodes() throws {
        try makeGopher()
        for arguments in [["list"], ["find", "fmt"], ["show", "fmt"]] {
            let run = try docent(arguments)
            XCTAssertFalse(run.out.contains("\u{1B}["), "escape codes in piped output of \(arguments)")
        }
    }

    func testUnknownCommandFailsWithAdvice() throws {
        let run = try docent(["frobnicate"])
        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(run.err.contains("no command called"), run.err)
        XCTAssertTrue(run.err.contains("find"), "the error should list the commands: \(run.err)")
        XCTAssertEqual(run.out, "")
    }

    func testNothingMatchesIsNotACrash() throws {
        try makeGopher()
        let run = try docent(["find", "zzzz"])
        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(run.err.contains("nothing matches"), run.err)
    }

    func testBadOptionValueIsExplained() throws {
        try makeGopher()
        let run = try docent(["find", "fmt", "--limit", "nope"])
        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(run.err.contains("--limit"), run.err)
    }

    func testUnknownDocsetListsWhatIsInstalled() throws {
        try makeGopher()
        let run = try docent(["find", "fmt", "--docset", "rust"])
        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(run.err.contains("go"), run.err)
    }

    func testIndexPastTheEndIsExplained() throws {
        try makeGopher()
        let run = try docent(["show", "fmt", "--index", "99"])
        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(run.err.contains("past the end"), run.err)
    }
}
