import Foundation

/// The declarations in a source file, so a repository's own code is searchable next to its
/// prose.
///
/// This is a reader, not a compiler: one pass over the lines, per-language rules, and a
/// brace or indentation count to work out what a declaration sits inside. It gets the
/// common shapes right and is content to miss an exotic one — the cost of a miss is an
/// entry you have to find by searching the page text, which is indexed anyway.
public enum SourceSymbols {
    public struct Symbol: Equatable, Sendable {
        /// Qualified where it helps: `Canvas.draw`, not a second `draw` next to five others.
        public let name: String
        /// A Dash entry type, so the window and Dash's own conventions agree.
        public let kind: String
        /// The declaration as written, trimmed.
        public let declaration: String
        /// The documentation comment above it, already stripped of its markers.
        public let doc: String
        public let line: Int
    }

    public enum Language: String, CaseIterable, Sendable {
        case swift, python, go, javascript, typescript, rust

        public static let byExtension: [String: Language] = [
            "swift": .swift,
            "py": .python,
            "go": .go,
            "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
            "ts": .typescript, "tsx": .typescript,
            "rs": .rust,
        ]

        public static func forExtension(_ ext: String) -> Language? {
            byExtension[ext.lowercased()]
        }

        public var name: String {
            switch self {
            case .javascript: return "JavaScript"
            case .typescript: return "TypeScript"
            default: return rawValue.capitalized
            }
        }
    }

    /// A file this size is machine-written or vendored; reading it symbol by symbol buys
    /// nothing and costs a visible pause.
    public static let maxSymbols = 4000

    public static func symbols(in source: String, language: Language) -> [Symbol] {
        switch language {
        case .swift: return swiftLike(source, language: .swift)
        case .rust: return swiftLike(source, language: .rust)
        case .go: return goSymbols(source)
        case .python: return pythonSymbols(source)
        case .javascript, .typescript: return scriptSymbols(source)
        }
    }

    // MARK: - Reading the lines

    /// A line with its string literals and trailing comment blanked out, so counting braces
    /// does not trip over a `{` inside a message.
    static func withoutLiterals(_ line: String) -> String {
        var out = ""
        var quote: Character? = nil
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == open, previous != "\\" { quote = nil }
                out.append(" ")
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
                out.append(" ")
            } else if character == "/", line.index(after: index) < line.endIndex,
                      line[line.index(after: index)] == "/" {
                break                                   // the rest is a comment
            } else {
                out.append(character)
            }
            previous = character
            index = line.index(after: index)
        }
        return out
    }

    static func depthChange(_ line: String) -> Int {
        let cleaned = withoutLiterals(line)
        return cleaned.filter { $0 == "{" }.count - cleaned.filter { $0 == "}" }.count
    }

    /// The documentation above a declaration, as prose.
    struct DocBuffer {
        private var lines: [String] = []
        mutating func add(_ text: String) { lines.append(text) }
        mutating func clear() { lines.removeAll() }
        mutating func take() -> String {
            defer { lines.removeAll() }
            return lines.joined(separator: "\n").trimmed
        }
        var isEmpty: Bool { lines.isEmpty }
    }

    /// `/// Draws the line.` → `Draws the line.`
    static func docText(_ line: String, markers: [String]) -> String? {
        let trimmed = line.trimmed
        for marker in markers where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The identifier after a keyword, or nothing when what follows is not a name.
    static func name(after keyword: String, in line: String) -> String? {
        guard let found = word(after: keyword, in: line), !reserved.contains(found) else { return nil }
        return found
    }

    static func word(after keyword: String, in line: String) -> String? {
        guard let range = line.range(of: keyword) else { return nil }
        var cursor = range.upperBound
        while cursor < line.endIndex, line[cursor] == " " { cursor = line.index(after: cursor) }
        var name = ""
        while cursor < line.endIndex, line[cursor].isLetter || line[cursor].isNumber || line[cursor] == "_" {
            name.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        return name.isEmpty ? nil : name
    }

    static let modifiers: Set<String> = [
        "public", "private", "internal", "fileprivate", "open", "package", "final", "static",
        "class", "override", "mutating", "nonmutating", "convenience", "required", "dynamic",
        "lazy", "weak", "unowned", "indirect", "nonisolated", "isolated", "async", "unsafe",
        "export", "default", "pub", "const", "extern", "declare", "abstract", "readonly",
    ]

    /// Words that are never the *name* of anything: `public class func draw()` declares a
    /// method called `draw`, not a class called `func`.
    static let reserved: Set<String> = modifiers.union([
        "func", "fn", "var", "let", "init", "deinit", "subscript", "case", "struct", "enum",
        "protocol", "extension", "actor", "typealias", "where", "return", "if", "else", "for",
        "while", "guard", "switch", "do", "try", "in", "is", "as", "self", "super", "type",
    ])

    /// `func draw(` at the start of a declaration, and not `self.draw(` in the middle of one.
    /// The keyword may be followed by a space or by an opening bracket, because `init(` and
    /// `func draw(` are both declarations and only one of them has a name after a space.
    static func declares(_ keyword: String, in line: String) -> Bool {
        let cleaned = " " + withoutLiterals(line).trimmed + " "
        var search = cleaned.startIndex
        while let range = cleaned.range(of: " " + keyword, range: search..<cleaned.endIndex) {
            let next = range.upperBound < cleaned.endIndex ? cleaned[range.upperBound] : " "
            if next == " " || next == "(" || next == "<" || next == "?" {
                // Everything before it must be modifiers, not an expression.
                let before = String(cleaned[..<range.lowerBound]).trimmed
                if before.isEmpty || before.split(separator: " ").allSatisfy({ piece in
                    modifiers.contains(String(piece)) || piece.hasPrefix("@") || piece.hasPrefix("#")
                }) {
                    return true
                }
            }
            search = range.upperBound
        }
        return false
    }
}

// MARK: - Swift and Rust

extension SourceSymbols {
    /// Brace-nested languages with `///` documentation: close enough in shape that one
    /// reader serves both, with a small table of what the type keywords are called.
    static func swiftLike(_ source: String, language: Language) -> [Symbol] {
        let typeKeywords: [String: String] = language == .swift
            ? ["struct": "Struct", "class": "Class", "enum": "Enum", "protocol": "Protocol",
               "actor": "Class", "extension": "Extension", "typealias": "Type"]
            : ["struct": "Struct", "enum": "Enum", "trait": "Trait", "impl": "Extension",
               "mod": "Module", "type": "Type"]
        let functionKeyword = language == .swift ? "func" : "fn"
        let docMarkers = ["///", "//!"]

        var symbols: [Symbol] = []
        var doc = DocBuffer()
        var depth = 0
        var stack: [(name: String, depth: Int, isEnum: Bool)] = []

        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if symbols.count >= maxSymbols { break }
            let line = String(rawLine)
            let trimmed = line.trimmed
            let number = offset + 1

            if let text = docText(line, markers: docMarkers) {
                doc.add(text)
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                if trimmed.isEmpty { doc.clear() }
                continue
            }

            while let last = stack.last, depth <= last.depth { stack.removeLast() }
            let container = stack.last
            let prefix = stack.map(\.name).joined(separator: ".")
            func qualified(_ name: String) -> String { prefix.isEmpty ? name : prefix + "." + name }
            // API sits exactly one level inside its type (or at the top of the file). A `let`
            // two levels in is a local variable in a function body, and indexing those buries
            // the real entries: daub's 27 files gave 472 "constants" before this rule.
            let isMemberLevel = depth == (container?.depth ?? -1) + 1

            var matched = false
            for (keyword, kind) in typeKeywords where declares(keyword, in: line) {
                guard let name = name(after: keyword + " ", in: withoutLiterals(line)) else { continue }
                // An extension documents the type it extends; nesting it under itself reads
                // as `Canvas.Canvas`.
                let full = kind == "Extension" ? name : qualified(name)
                symbols.append(Symbol(name: full, kind: kind == "Extension" ? "Category" : kind,
                                      declaration: trimmed, doc: doc.take(), line: number))
                // The stack holds simple names: pushing the qualified one and joining the
                // stack again gives `ImageFile.ImageFile.Failure`.
                stack.append((name: name, depth: depth, isEnum: kind == "Enum"))
                matched = true
                break
            }
            if !matched, isMemberLevel, declares(functionKeyword, in: line),
               let name = name(after: functionKeyword + " ", in: withoutLiterals(line)) {
                symbols.append(Symbol(name: qualified(name),
                                      kind: container == nil ? "Function" : "Method",
                                      declaration: trimmed, doc: doc.take(), line: number))
                matched = true
            }
            if !matched, language == .swift, declares("init", in: line) || trimmed.hasPrefix("init(") {
                symbols.append(Symbol(name: qualified("init"), kind: "Constructor",
                                      declaration: trimmed, doc: doc.take(), line: number))
                matched = true
            }
            if !matched {
                for keyword in (language == .swift ? ["var", "let"] : ["const", "static"])
                where declares(keyword, in: line) {
                    guard let name = name(after: keyword + " ", in: withoutLiterals(line)) else { continue }
                    // A local inside a function body is not API; only members and top-level
                    // declarations are worth an entry.
                    guard isMemberLevel else { continue }
                    // A script's top-level `let w = 40` is a local with nowhere to hide, and
                    // a docset that opens with `w`, `ink` and `out` looks like nonsense.
                    // At the top level, something has to mark it as API.
                    if container == nil {
                        let isDocumented = !doc.isEmpty
                        let isExported = ["public", "open", "package", "pub", "static"].contains {
                            trimmed.hasPrefix($0 + " ") || trimmed.contains(" " + $0 + " ")
                        }
                        guard isDocumented || isExported else { doc.clear(); continue }
                    }
                    symbols.append(Symbol(name: qualified(name),
                                          kind: keyword == "let" || keyword == "const" ? "Constant" : "Property",
                                          declaration: trimmed, doc: doc.take(), line: number))
                    matched = true
                    break
                }
            }
            if !matched, isMemberLevel, container?.isEnum == true, trimmed.hasPrefix("case ") {
                for piece in trimmed.dropFirst(5).split(separator: ",") {
                    // The cap belongs in every loop that appends, not only in the outer
                    // one: `case c0,c1,…,c99999` on a single line is one line of input and
                    // a hundred thousand symbols out.
                    guard symbols.count < maxSymbols else { break }
                    let name = String(piece).trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    guard !name.isEmpty else { continue }
                    symbols.append(Symbol(name: qualified(String(name)), kind: "Value",
                                          declaration: trimmed, doc: doc.isEmpty ? "" : doc.take(), line: number))
                }
                matched = true
            }
            if !matched { doc.clear() }

            depth += depthChange(line)
        }
        return symbols
    }
}

// MARK: - Go

extension SourceSymbols {
    static func goSymbols(_ source: String) -> [Symbol] {
        var symbols: [Symbol] = []
        var doc = DocBuffer()

        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if symbols.count >= maxSymbols { break }
            let line = String(rawLine)
            let trimmed = line.trimmed
            let number = offset + 1

            if trimmed.hasPrefix("//") {
                doc.add(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.isEmpty { doc.clear(); continue }

            if trimmed.hasPrefix("func ") {
                // `func (c *Canvas) Draw(` — the receiver decides whether it is a method.
                var name = word(after: "func ", in: trimmed)
                var kind = "Function"
                if trimmed.hasPrefix("func ("), let close = trimmed.range(of: ")") {
                    let receiver = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<close.lowerBound]
                    let type = receiver.split(separator: " ").last.map { $0.replacingOccurrences(of: "*", with: "") } ?? ""
                    let rest = String(trimmed[close.upperBound...]).trimmed
                    let method = String(rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                    if !method.isEmpty {
                        name = type.isEmpty ? method : type + "." + method
                        kind = "Method"
                    }
                }
                if let name {
                    symbols.append(Symbol(name: name, kind: kind, declaration: trimmed, doc: doc.take(), line: number))
                    continue
                }
            }
            if trimmed.hasPrefix("type "), let name = word(after: "type ", in: trimmed) {
                let kind = trimmed.contains(" interface") ? "Interface" : (trimmed.contains(" struct") ? "Struct" : "Type")
                symbols.append(Symbol(name: name, kind: kind, declaration: trimmed, doc: doc.take(), line: number))
                continue
            }
            for keyword in ["const ", "var "] where trimmed.hasPrefix(keyword) {
                guard let name = word(after: keyword, in: trimmed) else { continue }
                symbols.append(Symbol(name: name, kind: keyword == "const " ? "Constant" : "Variable",
                                      declaration: trimmed, doc: doc.take(), line: number))
            }
            doc.clear()
        }
        return symbols
    }
}

// MARK: - Python

extension SourceSymbols {
    /// Indentation decides what a `def` belongs to, and the docstring comes *after* the
    /// declaration rather than before it.
    static func pythonSymbols(_ source: String) -> [Symbol] {
        var symbols: [Symbol] = []
        var stack: [(name: String, indent: Int)] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for (offset, line) in lines.enumerated() {
            if symbols.count >= maxSymbols { break }
            let trimmed = line.trimmed
            guard trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ") || trimmed.hasPrefix("class ") else { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            while let last = stack.last, indent <= last.indent { stack.removeLast() }

            let isClass = trimmed.hasPrefix("class ")
            let keyword = isClass ? "class " : "def "
            guard let name = word(after: keyword, in: trimmed) else { continue }
            let prefix = stack.map(\.name).joined(separator: ".")
            let full = prefix.isEmpty ? name : prefix + "." + name

            symbols.append(Symbol(name: full,
                                  kind: isClass ? "Class" : (stack.isEmpty ? "Function" : "Method"),
                                  declaration: trimmed,
                                  doc: docstring(after: offset, in: lines),
                                  line: offset + 1))
            stack.append((name: name, indent: indent))
        }
        return symbols
    }

    /// The `"""…"""` immediately under a `def`, one line or many.
    static func docstring(after index: Int, in lines: [String]) -> String {
        var cursor = index + 1
        while cursor < lines.count, lines[cursor].trimmed.isEmpty { cursor += 1 }
        guard cursor < lines.count else { return "" }
        let first = lines[cursor].trimmed
        for marker in ["\"\"\"", "'''"] where first.hasPrefix(marker) {
            let body = String(first.dropFirst(3))
            if body.hasSuffix(marker), body.count >= 3 { return String(body.dropLast(3)).trimmed }
            var collected = [body]
            cursor += 1
            while cursor < lines.count, !lines[cursor].contains(marker), collected.count < 200 {
                collected.append(lines[cursor].trimmed)
                cursor += 1
            }
            if cursor < lines.count {
                let last = lines[cursor].trimmed
                collected.append(String(last.prefix(while: { _ in true }).replacingOccurrences(of: marker, with: "")))
            }
            return collected.joined(separator: "\n").trimmed
        }
        return ""
    }
}

// MARK: - JavaScript and TypeScript

extension SourceSymbols {
    static func scriptSymbols(_ source: String) -> [Symbol] {
        var symbols: [Symbol] = []
        var doc = DocBuffer()
        var depth = 0
        var stack: [(name: String, depth: Int)] = []

        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if symbols.count >= maxSymbols { break }
            let line = String(rawLine)
            let trimmed = line.trimmed
            let number = offset + 1

            if trimmed.hasPrefix("/**") || trimmed.hasPrefix("*") || trimmed.hasPrefix("//") {
                let text = trimmed
                    .replacingOccurrences(of: "/**", with: "")
                    .replacingOccurrences(of: "*/", with: "")
                    .drop { $0 == "*" || $0 == "/" || $0 == " " }
                doc.add(String(text))
                continue
            }
            if trimmed.isEmpty { doc.clear(); continue }

            while let last = stack.last, depth <= last.depth { stack.removeLast() }
            let prefix = stack.map(\.name).joined(separator: ".")
            func qualified(_ name: String) -> String { prefix.isEmpty ? name : prefix + "." + name }

            var matched = false
            for (keyword, kind) in [("class", "Class"), ("interface", "Interface")]
            where declares(keyword, in: line) {
                guard let name = name(after: keyword + " ", in: withoutLiterals(line)) else { continue }
                symbols.append(Symbol(name: qualified(name), kind: kind, declaration: trimmed,
                                      doc: doc.take(), line: number))
                stack.append((name: name, depth: depth))
                matched = true
                break
            }
            if !matched, declares("function", in: line),
               let name = name(after: "function ", in: withoutLiterals(line)) {
                symbols.append(Symbol(name: qualified(name), kind: stack.isEmpty ? "Function" : "Method",
                                      declaration: trimmed, doc: doc.take(), line: number))
                matched = true
            }
            if !matched, depth == (stack.last?.depth ?? -1) + 1 {
                // `export const draw = (…) => …` is how most of a modern module is written.
                for keyword in ["const", "let", "var"] where declares(keyword, in: line) {
                    guard let name = name(after: keyword + " ", in: withoutLiterals(line)) else { continue }
                    let isFunction = trimmed.contains("=>") || trimmed.contains("function")
                    symbols.append(Symbol(name: qualified(name),
                                          kind: isFunction ? "Function" : "Constant",
                                          declaration: trimmed, doc: doc.take(), line: number))
                    matched = true
                    break
                }
            }
            if !matched { doc.clear() }
            depth += depthChange(line)
        }
        return symbols
    }
}
