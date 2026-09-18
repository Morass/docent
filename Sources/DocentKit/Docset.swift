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
    public var documentsURL: URL { url.appendingPathComponent("Contents/Resources/Documents") }
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
    }

    private static func readPlist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        return dict
    }

    /// Resolves a docset-relative path (which may carry an `#anchor`) to a file on disk.
    /// Paths that try to climb out of the docset return nil: an index is data, and a
    /// malicious or broken one must not be able to name `../../../etc/passwd`.
    public func fileURL(forPath path: String) -> URL? {
        let withoutAnchor = String(path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let cleaned = withoutAnchor.removingPercentEncoding ?? withoutAnchor
        guard !cleaned.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: cleaned, relativeTo: documentsURL).standardizedFileURL
        let root = documentsURL.standardizedFileURL.path
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else { return nil }
        return resolved
    }

    /// The `#anchor` part of a docset path, if it has one.
    public static func anchor(in path: String) -> String? {
        guard let hash = path.firstIndex(of: "#") else { return nil }
        let raw = String(path[path.index(after: hash)...])
        guard !raw.isEmpty else { return nil }
        return raw.removingPercentEncoding ?? raw
    }

    public static func < (lhs: Docset, rhs: Docset) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nonEmpty: String? { isEmpty ? nil : self }
}
