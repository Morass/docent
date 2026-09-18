import Foundation
import DocentKit

// docent — the command half of Docent. Everything it does is also what the app does;
// both sit on DocentKit, so a result in the terminal and a result in the window are the
// same result.

let version = "0.1.0"

struct CommandError: Error {
    let message: String
    let exitCode: Int32
    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
}

func fail(_ message: String, exitCode: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("docent: " + message + "\n").utf8))
    exit(exitCode)
}

// MARK: - Output

/// Colour only when a person is looking: a pipe gets plain text, so `docent find … | grep`
/// and anything reading Docent from a script sees exactly what it asked for.
let useColour: Bool = {
    if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
    if ProcessInfo.processInfo.environment["DOCENT_NO_COLOR"] != nil { return false }
    return isatty(STDOUT_FILENO) == 1
}()

/// Everything that came out of a docset goes through here before it is printed: a symbol
/// name is data, and a terminal acts on control characters in it.
func safe(_ text: String) -> String { SafeText.terminal(text) }

func dim(_ text: String) -> String { useColour ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
func bold(_ text: String) -> String { useColour ? "\u{1B}[1m\(text)\u{1B}[0m" : text }

func print(out text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

// MARK: - Help

let helpSummaries: [(String, String)] = [
    ("list", "the docsets Docent can see"),
    ("find", "search every docset for a symbol"),
    ("show", "print a symbol's documentation as text"),
    ("path", "print the file a symbol lives in"),
    ("add", "put a docset into your library"),
    ("help", "help for a command"),
]

func generalHelp() -> String {
    var lines = [
        "docent — read offline documentation sets from the terminal.",
        "",
        "USAGE",
        "  docent <command> [options]",
        "",
        "COMMANDS",
    ]
    for (name, summary) in helpSummaries {
        lines.append("  \(name.padding(toLength: 6, withPad: " ", startingAt: 0))  \(summary)")
    }
    lines += [
        "",
        "EXAMPLES",
        "  docent list",
        "  docent find NSPasteboard",
        "  docent show go:Println",
        "",
        "Docsets are read from ~/Library/Application Support/Docent/DocSets, and from Dash's",
        "and Zeal's folders if you have them. DOCENT_DOCSETS overrides that with a",
        "colon-separated list of folders.",
        "",
        "  docent help <command>   more about one command",
        "  docent --version        print the version",
    ]
    return lines.joined(separator: "\n")
}

let commandHelp: [String: String] = [
    "list": """
    docent list — the docsets Docent can see.

    USAGE
      docent list [--paths]

    OPTIONS
      --paths   also print where each docset is on disk

    Each line is a docset: its name, its keyword if it has one, and how many symbols it
    indexes. The keyword is what you can type as a prefix in a search, as in `go:Println`.
    """,
    "find": """
    docent find — search every docset for a symbol.

    USAGE
      docent find <query> [--limit N] [--docset NAME] [--json]

    OPTIONS
      --limit N       how many results to print (default 20)
      --docset NAME   only this docset, by name or keyword
      --json          print results as JSON, one object per match

    The query can name a docset itself: `docent find go:Println` searches only the Go
    docset. Matching is exact first, then prefixes, then anything containing the query,
    then a loose letters-in-order match — so a half-remembered name still finds the page.

    EXAMPLES
      docent find NSPasteboard
      docent find --docset swift "Array.map"
      docent find print --limit 5 --json
    """,
    "show": """
    docent show — print a symbol's documentation as text.

    USAGE
      docent show <query> [--docset NAME] [--all] [--index N]

    OPTIONS
      --docset NAME   only this docset, by name or keyword
      --index N       show the Nth result instead of the best one (1-based)
      --all           print the whole page, not just the section the symbol is on

    Docent prints the best match. When a docset points at one section of a long page,
    that section is what you get; --all prints the page it lives on.

    EXAMPLES
      docent show NSPasteboard
      docent show go:Println
      docent show print --index 2
    """,
    "path": """
    docent path — print the file a symbol lives in.

    USAGE
      docent path <query> [--docset NAME] [--index N]

    Prints the HTML file on disk, with the anchor if the docset points at one. Useful for
    opening a page in something else: `open "$(docent path NSPasteboard)"`.
    """,
    "add": """
    docent add — put a docset into your library.

    USAGE
      docent add <folder.docset | archive.tgz> [--replace]

    OPTIONS
      --replace   overwrite a docset of the same name that is already installed

    Copies a docset into ~/Library/Application Support/Docent/DocSets, which is where both
    the command and the app look for it. A `.tgz` or `.tar.gz` holding a docset is unpacked
    for you. Nothing is downloaded — point this at a folder or an archive you already have.

    EXAMPLES
      docent add ~/Downloads/Go.docset
      docent add ~/Downloads/Python_3.tgz
    """,
    "help": """
    docent help — help for a command.

    USAGE
      docent help [command]
    """,
]

// MARK: - Argument parsing

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ raw: [String], optionsTakingValues: Set<String>) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    options[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
                } else if optionsTakingValues.contains(name) {
                    guard let value = iterator.next() else { throw CommandError("--\(name) needs a value") }
                    options[name] = value
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
        }
    }

    func integer(_ name: String, default fallback: Int) throws -> Int {
        guard let raw = options[name] else { return fallback }
        guard let value = Int(raw), value > 0 else { throw CommandError("--\(name) needs a positive number, not \"\(raw)\"") }
        return value
    }
}

// MARK: - Commands

func service(for arguments: Arguments) -> SearchService {
    SearchService(library: .standard())
}

func resolveDocsets(_ arguments: Arguments, service: SearchService) throws -> [Docset]? {
    guard let wanted = arguments.options["docset"] else { return nil }
    let all = service.docsets()
    let matching = all.filter { service.matches(docset: $0, hint: wanted) }
    guard !matching.isEmpty else {
        let known = all.map { safe($0.keyword ?? $0.name) }.joined(separator: ", ")
        throw CommandError(known.isEmpty
            ? "no docsets installed, so --docset \(wanted) matches nothing"
            : "no docset called \"\(safe(wanted))\". Installed: \(known)")
    }
    return matching
}

func requireQuery(_ arguments: Arguments, command: String) throws -> String {
    guard let query = arguments.positional.first, !query.trimmed.isEmpty else {
        throw CommandError("\(command) needs something to look for. Try: docent \(command) NSPasteboard")
    }
    return arguments.positional.joined(separator: " ")
}

func runList(_ arguments: Arguments) throws {
    let service = service(for: arguments)
    let docsets = service.docsets()
    guard !docsets.isEmpty else {
        print(out: """
        No docsets found.

        Docent reads docsets from:
          ~/Library/Application Support/Docent/DocSets
          ~/Library/Application Support/Dash/DocSets
          ~/.local/share/Zeal/Zeal/docsets

        Put a .docset folder in the first of those, or point DOCENT_DOCSETS at the folder
        you keep them in.
        """)
        return
    }
    for docset in docsets {
        var line = bold(safe(docset.name))
        if let keyword = docset.keyword { line += dim("  \(safe(keyword)):") }
        if let count = try? symbolCount(of: docset) { line += dim("  \(count) symbols") }
        print(out: line)
        if arguments.flags.contains("paths") { print(out: dim("    " + docset.url.path)) }
    }
}

func symbolCount(of docset: Docset) throws -> Int {
    try SearchIndex(url: docset.indexURL).symbolCount()
}

func matches(for arguments: Arguments, command: String, limit: Int) throws -> [Match] {
    let service = service(for: arguments)
    let query = try requireQuery(arguments, command: command)
    let docsets = try resolveDocsets(arguments, service: service)
    let found = try service.find(query, limit: limit, in: docsets)
    guard !found.isEmpty else {
        throw CommandError("nothing matches \"\(safe(query))\"" + (service.docsets().isEmpty
            ? ". No docsets are installed — run `docent list` to see where they go."
            : ". Try fewer letters, or `docent list` to see what is installed."))
    }
    return found
}

func runFind(_ arguments: Arguments) throws {
    let limit = try arguments.integer("limit", default: 20)
    let found = try matches(for: arguments, command: "find", limit: limit)

    if arguments.flags.contains("json") {
        var objects: [[String: String]] = []
        for match in found {
            objects.append([
                "name": match.entry.name,
                "type": match.entry.type,
                "docset": match.docset.name,
                "path": match.entry.path,
                "file": (try? SearchService().location(of: match).url.path) ?? "",
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        print(out: String(data: data, encoding: .utf8) ?? "[]")
        return
    }

    let nameWidth = min(52, found.map(\.entry.name.count).max() ?? 10)
    let typeWidth = min(14, found.map(\.entry.type.count).max() ?? 6)
    for (offset, match) in found.enumerated() {
        let number = dim(String(format: "%2d.", offset + 1))
        let name = safe(match.entry.name).padding(toWidth: nameWidth)
        let type = dim(safe(match.entry.type).padding(toWidth: typeWidth))
        print(out: "\(number) \(bold(name))  \(type)  \(dim(safe(match.docset.name)))")
    }
}

func pick(_ found: [Match], arguments: Arguments) throws -> Match {
    let index = try arguments.integer("index", default: 1)
    guard index <= found.count else {
        throw CommandError("only \(found.count) result\(found.count == 1 ? "" : "s") for that, so --index \(index) is past the end")
    }
    return found[index - 1]
}

func runShow(_ arguments: Arguments) throws {
    let limit = max(20, try arguments.integer("index", default: 1))
    let found = try matches(for: arguments, command: "show", limit: limit)
    let match = try pick(found, arguments: arguments)
    let service = service(for: arguments)

    let page: RenderedPage
    if arguments.flags.contains("all") {
        let (url, _) = try service.location(of: match)
        let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        page = HTMLText.render(html)
    } else {
        page = try service.page(for: match)
    }

    var header = bold(safe(match.entry.name))
    if !match.entry.type.isEmpty { header += dim("  \(safe(match.entry.type))") }
    header += dim("  \(safe(match.docset.name))")
    print(out: header)
    print(out: dim(String(repeating: "─", count: 60)))
    print(out: page.text.isEmpty ? dim("(this page has no text — try --all, or `docent path` to open it)") : safe(page.text))

    if found.count > 1 {
        print(out: "")
        print(out: dim("\(found.count - 1) other match\(found.count == 2 ? "" : "es") — docent find \"\(arguments.positional.joined(separator: " "))\""))
    }
}

/// `~` means the home Docent is using, which is `$HOME`. Foundation's own
/// `expandingTildeInPath` asks the password database instead, so it would quietly reach
/// into the real account's home from inside a sandbox or a test.
func expandTilde(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = Home.directory().path
    return path == "~" ? home : home + String(path.dropFirst(1))
}

/// A docset is an archive from the internet. `add` therefore treats it as hostile until it
/// has been looked at: what the archive claims to contain, how much it unpacks to, whether
/// anything in it points outside itself, and whether it is a docset at all.
enum AddLimits {
    static let maxEntries = 200_000
    static let maxBytes = 4 * 1024 * 1024 * 1024   // 4 GB unpacked
}

func runAdd(_ arguments: Arguments) throws {
    guard let source = arguments.positional.first else {
        throw CommandError("add needs a .docset folder or an archive. Try: docent add ~/Downloads/Go.docset")
    }
    let fm = FileManager.default
    let sourceURL = URL(fileURLWithPath: expandTilde(source)).standardizedFileURL
    guard fm.fileExists(atPath: sourceURL.path) else {
        throw CommandError("there is nothing at \(safe(sourceURL.path))")
    }

    let destinationRoot = Home.docsetsDirectory()
    try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

    // Adding a docset from the library back into the library would delete it: the old copy
    // is removed before the new one is written, and they are the same folder.
    let resolvedSource = sourceURL.resolvingSymlinksInPath().path
    let resolvedRoot = destinationRoot.resolvingSymlinksInPath().path
    if resolvedSource == resolvedRoot || resolvedSource.hasPrefix(resolvedRoot + "/") {
        throw CommandError("that docset is already in your library — adding it to itself would delete it")
    }

    let scratch = fm.temporaryDirectory.appendingPathComponent("docent-add-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: scratch) }

    let staged: URL
    if sourceURL.pathExtension == "docset" {
        staged = sourceURL
    } else if ["tgz", "gz", "tar", "bz2", "xz"].contains(sourceURL.pathExtension) {
        try checkArchive(sourceURL)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try unpack(sourceURL, into: scratch)
        guard let found = DocsetLibrary.docsetURLs(under: scratch).first else {
            throw CommandError("that archive holds no .docset folder")
        }
        staged = found
    } else {
        throw CommandError("add takes a .docset folder or a .tgz archive, not \(safe(sourceURL.lastPathComponent))")
    }

    guard let docset = Docset(contentsOf: staged) else {
        throw CommandError("\(safe(staged.lastPathComponent)) is not a usable docset — it has no index or no Documents folder")
    }
    if let escaping = firstEscapingLink(in: staged) {
        throw CommandError("this docset contains a link pointing outside itself (\(safe(escaping))) — not installing it")
    }

    let destination = destinationRoot.appendingPathComponent(staged.lastPathComponent)
    let alreadyThere = fm.fileExists(atPath: destination.path)
    if alreadyThere, !arguments.flags.contains("replace") {
        throw CommandError("\(safe(staged.lastPathComponent)) is already installed. Pass --replace to overwrite it.")
    }

    // Put the new copy in place first, then remove the old one: a failure halfway through
    // must not leave the user with neither.
    let incoming = destinationRoot.appendingPathComponent(".docent-incoming-\(UUID().uuidString)")
    if staged == sourceURL {
        try fm.copyItem(at: staged, to: incoming)
    } else {
        try fm.moveItem(at: staged, to: incoming)
    }

    let displaced = destinationRoot.appendingPathComponent(".docent-replaced-\(UUID().uuidString)")
    do {
        if alreadyThere { try fm.moveItem(at: destination, to: displaced) }
        try fm.moveItem(at: incoming, to: destination)
    } catch {
        try? fm.removeItem(at: incoming)
        if fm.fileExists(atPath: displaced.path), !fm.fileExists(atPath: destination.path) {
            try? fm.moveItem(at: displaced, to: destination)
        }
        throw CommandError("could not install \(safe(staged.lastPathComponent)): \(error.localizedDescription)")
    }
    if fm.fileExists(atPath: displaced.path) { try? fm.removeItem(at: displaced) }

    var line = "added \(bold(safe(docset.name)))"
    if let keyword = docset.keyword { line += " (\(safe(keyword)):)" }
    if let installed = Docset(contentsOf: destination), let count = try? symbolCount(of: installed) {
        line += " — \(count) symbols"
    }
    print(out: line)
    print(out: dim("  " + destination.path))
}

/// Reads the archive's table of contents before unpacking a byte of it.
func checkArchive(_ url: URL) throws {
    let listing = try run("/usr/bin/tar", ["-tvf", url.path], failure: "could not read \(safe(url.lastPathComponent))")
    var entries = 0
    var bytes = 0
    for line in listing.split(separator: "\n") {
        entries += 1
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        if columns.count > 4, let size = Int(columns[2]) { bytes += size }
        if let name = columns.last {
            let path = String(name)
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                throw CommandError("that archive contains a path that climbs out of it (\(safe(path))) — not unpacking it")
            }
        }
        if entries > AddLimits.maxEntries {
            throw CommandError("that archive contains more than \(AddLimits.maxEntries) files — not unpacking it")
        }
        if bytes > AddLimits.maxBytes {
            throw CommandError("that archive unpacks to more than \(AddLimits.maxBytes / (1024 * 1024 * 1024)) GB — not unpacking it")
        }
    }
    if entries == 0 { throw CommandError("that archive is empty") }
}

func unpack(_ url: URL, into directory: URL) throws {
    _ = try run("/usr/bin/tar", ["-xf", url.path, "-C", directory.path],
                failure: "could not unpack \(safe(url.lastPathComponent))")
}

@discardableResult
func run(_ tool: String, _ arguments: [String], failure: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw CommandError(failure) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CommandError(failure) }
    return String(data: data, encoding: .utf8) ?? ""
}

/// The first symlink inside the docset that resolves outside it, if there is one.
func firstEscapingLink(in docset: URL) -> String? {
    let fm = FileManager.default
    let root = docset.resolvingSymlinksInPath().standardizedFileURL.path
    guard let walker = fm.enumerator(at: docset, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                     options: []) else { return nil }
    for case let url as URL in walker {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        if target != root, !target.hasPrefix(root + "/") {
            return url.lastPathComponent
        }
    }
    return nil
}

func runPath(_ arguments: Arguments) throws {
    let limit = max(20, try arguments.integer("index", default: 1))
    let found = try matches(for: arguments, command: "path", limit: limit)
    let match = try pick(found, arguments: arguments)
    let (url, anchor) = try service(for: arguments).location(of: match)
    print(out: safe(url.path + (anchor.map { "#\($0)" } ?? "")))
}

extension String {
    func padding(toWidth width: Int) -> String {
        count >= width ? self : padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

// MARK: - Entry point

let rawArguments = Array(CommandLine.arguments.dropFirst())

if rawArguments.isEmpty || rawArguments.first == "--help" || rawArguments.first == "-h" {
    print(out: generalHelp())
    exit(0)
}
if rawArguments.first == "--version" || rawArguments.first == "-v" {
    print(out: "docent \(version)")
    exit(0)
}

let command = rawArguments[0]
let rest = Array(rawArguments.dropFirst())

do {
    if command == "help" {
        let topic = rest.first(where: { !$0.hasPrefix("-") })
        if let topic {
            guard let help = commandHelp[topic] else {
                throw CommandError("no command called \"\(topic)\". Commands: " + helpSummaries.map(\.0).joined(separator: ", "))
            }
            print(out: help)
        } else {
            print(out: generalHelp())
        }
        exit(0)
    }

    guard commandHelp[command] != nil else {
        throw CommandError("no command called \"\(command)\". Commands: " + helpSummaries.map(\.0).joined(separator: ", "))
    }

    let arguments = try Arguments(rest, optionsTakingValues: ["limit", "docset", "index"])
    if arguments.flags.contains("help") {
        print(out: commandHelp[command] ?? generalHelp())
        exit(0)
    }

    switch command {
    case "list": try runList(arguments)
    case "find": try runFind(arguments)
    case "show": try runShow(arguments)
    case "path": try runPath(arguments)
    case "add": try runAdd(arguments)
    default: throw CommandError("no command called \"\(command)\"")
    }
} catch let error as CommandError {
    fail(error.message, exitCode: error.exitCode)
} catch let error as SearchService.PageError {
    fail(error.description)
} catch let error as SearchIndexError {
    fail(error.description)
} catch {
    fail("\(error)")
}
