import Foundation

/// Where docsets live. Docent reads the folders a user already has — its own, Dash's and
/// Zeal's — and never writes to them.
public struct DocsetLibrary: Sendable {
    public let searchPaths: [URL]

    public init(searchPaths: [URL]) {
        self.searchPaths = searchPaths
    }

    /// `DOCENT_DOCSETS` (colon-separated) replaces the defaults outright. That is the off
    /// switch every test, screenshot and example runs behind, so nothing here ever reads
    /// the real machine unless a person asked it to.
    public static func defaultSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL? = nil
    ) -> [URL] {
        let home = home ?? Home.directory(environment: environment)
        if let override = environment["DOCENT_DOCSETS"]?.trimmed, !override.isEmpty {
            return override.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return [
            home.appendingPathComponent("Library/Application Support/Docent/DocSets"),
            home.appendingPathComponent("Library/Application Support/Dash/DocSets"),
            home.appendingPathComponent(".local/share/Zeal/Zeal/docsets"),
        ]
    }

    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL? = nil
    ) -> DocsetLibrary {
        DocsetLibrary(searchPaths: defaultSearchPaths(environment: environment, home: home))
    }

    /// Every docset found, sorted by name, one entry per identifier: the same docset
    /// installed in two of the folders above is listed once, the earlier path winning.
    public func docsets() -> [Docset] {
        var found: [Docset] = []
        var seen = Set<String>()
        for path in searchPaths {
            for url in Self.docsetURLs(under: path) {
                guard let docset = Docset(contentsOf: url) else { continue }
                guard seen.insert(docset.identifier).inserted else { continue }
                found.append(docset)
            }
        }
        return found.sorted()
    }

    /// `.docset` folders directly under `root`, or one level below it (Dash nests some
    /// docsets under a vendor folder). Symlinks are not followed: a docset is a folder of
    /// someone else's HTML, and following links out of it is how a reader ends up printing
    /// a file nobody meant to publish.
    public static func docsetURLs(under root: URL) -> [URL] {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        func isRealDirectory(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }

        var result: [URL] = []
        for child in children(root).sorted(by: { $0.path < $1.path }) {
            guard isRealDirectory(child) else { continue }
            if child.pathExtension == "docset" {
                result.append(child)
            } else {
                for grandchild in children(child).sorted(by: { $0.path < $1.path })
                where grandchild.pathExtension == "docset" && isRealDirectory(grandchild) {
                    result.append(grandchild)
                }
            }
        }
        return result
    }
}
