import Foundation

/// One docset on disk: `Something.docset`, a folder holding an SQLite index and a tree of
/// HTML. Nothing here touches the network — a docset is a directory and that is all.
public struct Docset: Hashable, Sendable, Comparable {
    /// The `.docset` bundle itself.
    public let url: URL
    /// What to call it in a list: `CFBundleName`, else the folder name.
    public let name: String
    /// `CFBundleIdentifier`, else the folder name. Stable across renames.
    public let identifier: String
    /// The docset's own short prefix (`DocSetPlatformFamily`), e.g. `swift`, `go`.
    public let keyword: String?
    /// The page to open when nothing is selected, relative to `documentsURL`.
    public let indexPage: String

    public var indexURL: URL { url.appendingPathComponent("Contents/Resources/docSet.dsidx") }
    /// Marked as a directory on purpose: `WKWebView.loadFileURL(_:allowingReadAccessTo:)`
    /// treats a URL without the directory flag as a single *file*, and then refuses every
    /// page in the docset with "outside the sandbox".
    public var documentsURL: URL { url.appendingPathComponent("Contents/Resources/Documents", isDirectory: true) }
    public var iconURL: URL? {
        let icon = url.appendingPathComponent("icon.png")
        return FileManager.default.fileExists(atPath: icon.path) ? icon : nil
    }

    /// Reads the bundle's `Info.plist`. Returns nil when this is not a usable docset — no
    /// plist, no index, or no Documents folder — so a half-downloaded folder is skipped
    /// rather than crashing a listing.
    public init?(contentsOf url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let plist = Docset.readPlist(plistURL)

        let folderName = url.deletingPathExtension().lastPathComponent
        let name = (plist["CFBundleName"] as? String)?.trimmed.nonEmpty ?? folderName
        let identifier = (plist["CFBundleIdentifier"] as? String)?.trimmed.nonEmpty ?? folderName
        let keyword = (plist["DocSetPlatformFamily"] as? String)?.trimmed.nonEmpty
        let indexPage = (plist["dashIndexFilePath"] as? String)?.trimmed.nonEmpty ?? "index.html"

        self.url = url
        self.name = name
        self.identifier = identifier
        self.keyword = keyword
        self.indexPage = indexPage

        guard fm.fileExists(atPath: indexURL.path),
              fm.fileExists(atPath: documentsURL.path) else { return nil }

        // Every part of the bundle has to be *inside* the bundle. A docset whose
        // `Documents` is a symlink to `/etc` would otherwise set the read boundary to
        // `/etc`, and an index row naming `hosts` would be served as documentation.
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        for part in [plistURL, indexURL, documentsURL]
        where !Containment.allows(part, under: root) { return nil }
        guard Containment.isOrdinaryFile(plistURL), Containment.isOrdinaryFile(indexURL) else { return nil }
    }

    /// A plist is a few hundred bytes; anything bigger is not one, and a named pipe is not
    /// a file at all.
    static let maxPlistBytes = 1 << 20

    private static func readPlist(_ url: URL) -> [String: Any] {
        guard let data = Containment.read(url, limit: maxPlistBytes),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        return dict
    }

    /// The folder a web view is given read access to, with every symlink resolved.
    /// WebKit resolves the page's path before comparing, so handing it `/tmp/x` while the
    /// page resolves to `/private/tmp/x` makes it refuse the page as "outside the sandbox".
    public var readAccessURL: URL {
        URL(fileURLWithPath: documentsURL.resolvingSymlinksInPath().path, isDirectory: true)
    }

    /// Resolves a docset-relative path (which may carry an `#anchor`) to a file on disk.
    /// Paths that try to climb out of the docset return nil: an index is data, and a
    /// malicious or broken one must not be able to name `../../../etc/passwd`.
    ///
    /// Containment is checked after resolving symlinks on both sides, so a link *inside*
    /// the docset pointing somewhere else cannot be used to escape either.
    public func fileURL(forPath path: String) -> URL? {
        let path = Docset.normalizedPath(path)
        let withoutAnchor = String(path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let cleaned = withoutAnchor.removingPercentEncoding ?? withoutAnchor
        guard !cleaned.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: cleaned, relativeTo: documentsURL).standardizedFileURL
        guard Containment.allows(candidate, under: readAccessURL) else { return nil }
        return candidate.resolvingSymlinksInPath()
    }

    /// The `#anchor` part of a docset path, if it has one. Left percent-encoded: Dash
    /// writes `//dash_ref_example%2DPrintln/...` into both the index *and* the page, so
    /// decoding here would stop the two from matching.
    public static func anchor(in path: String) -> String? {
        let path = Docset.normalizedPath(path)
        guard let hash = path.firstIndex(of: "#") else { return nil }
        let raw = String(path[path.index(after: hash)...])
        return raw.nonEmpty
    }

    /// Strips the `<dash_entry_name=…>` directives Dash prefixes some index paths with.
    /// They are display hints for Dash's own sidebar, not part of the path, and a docset
    /// built in the last few years is full of them.
    public static func normalizedPath(_ path: String) -> String {
        var rest = Substring(path)
        while rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            rest = rest[rest.index(after: close)...]
        }
        return String(rest)
    }

    public static func < (lhs: Docset, rhs: Docset) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nonEmpty: String? { isEmpty ? nil : self }
}
