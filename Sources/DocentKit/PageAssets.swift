import Foundation

/// The pictures a page points at, brought into the docset beside it.
///
/// A docset is read from its own folder, so a page that says `<img src="Resources/shot.png">`
/// shows nothing unless that file was copied in too — and a README whose first line is a
/// screenshot is then a page that opens with a hole in it. This finds those references,
/// says where each file should be copied, and rewrites the page to point at the copy.
///
/// Only files inside the folder being indexed are taken, only pictures, and only ones of a
/// sane size: a documentation folder is somebody's repository, and "index my docs" is not
/// permission to copy whatever a crafted `src` names.
public enum PageAssets {
    public static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "avif", "svg", "bmp", "ico", "tiff", "tif",
    ]

    /// Big enough for a screenshot or a diagram, small enough that a docset does not
    /// quietly become a copy of a repository's binary assets.
    public static let maxBytes = 16 * 1024 * 1024

    public struct Copy: Equatable, Sendable {
        /// The file in the source folder.
        public let from: URL
        /// Where it belongs under the docset's `Documents`, e.g. `assets/Resources/shot.png`.
        public let to: String
    }

    /// Rewrites `html` so every local picture points at a copy inside the docset.
    ///
    /// - Parameters:
    ///   - pagePath: the page's own path under `Documents`, which decides how far back the
    ///     rewritten reference has to climb.
    ///   - sourceFile: the file the page was rendered from — references are relative to it.
    ///   - rootPath: the resolved folder being indexed; nothing outside it is copied.
    public static func relocate(
        html: String,
        pagePath: String,
        sourceFile: URL,
        rootPath: String
    ) -> (html: String, copies: [Copy]) {
        let depth = max(0, pagePath.split(separator: "/").count - 1)
        let upward = String(repeating: "../", count: depth)
        let directory = sourceFile.deletingLastPathComponent()

        var out = ""
        var rest = Substring(html)
        var copies: [Copy] = []
        var seen: [String: String] = [:]          // resolved source path -> docset path

        while let marker = rest.range(of: "src=\"") {
            guard let close = rest[marker.upperBound...].range(of: "\"") else { break }
            let reference = String(rest[marker.upperBound..<close.lowerBound])
            out += rest[..<marker.upperBound]

            if let resolved = resolve(reference, in: directory, rootPath: rootPath) {
                let docsetPath: String
                if let already = seen[resolved.path] {
                    docsetPath = already
                } else {
                    docsetPath = "assets/" + Indexer.assetPath(for: resolved.relative)
                    seen[resolved.path] = docsetPath
                    copies.append(Copy(from: resolved.url, to: docsetPath))
                }
                out += Markdown.escape(upward + docsetPath)
            } else {
                out += reference
            }
            out += rest[close.lowerBound..<close.upperBound]
            rest = rest[close.upperBound...]
        }
        return (out + rest, copies)
    }

    /// A reference that names a picture file inside the folder being indexed, or nothing.
    static func resolve(
        _ reference: String,
        in directory: URL,
        rootPath: String
    ) -> (url: URL, path: String, relative: String)? {
        // Anything that is not a plain relative path is left exactly as the author wrote it:
        // a remote image stays remote (and stays blocked), and an absolute path is not ours.
        guard !reference.isEmpty, !reference.hasPrefix("/"), !reference.hasPrefix("#") else { return nil }
        let lower = reference.lowercased()
        for scheme in ["http:", "https:", "data:", "file:", "mailto:", "javascript:", "//"]
        where lower.hasPrefix(scheme) { return nil }

        // A fragment or a query belongs to the reference, not to the file name.
        var path = reference
        for separator in ["#", "?"] {
            if let cut = path.range(of: separator) { path = String(path[..<cut.lowerBound]) }
        }
        guard !path.isEmpty else { return nil }
        let decoded = path.removingPercentEncoding ?? path

        let candidate = directory.appendingPathComponent(decoded)
        let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { return nil }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        guard allowedExtensions.contains(resolved.pathExtension.lowercased()) else { return nil }
        guard resolved.path.hasPrefix(rootPath + "/") else { return nil }

        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        guard (attributes?[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes?[.size] as? Int, size <= maxBytes else { return nil }

        return (resolved, resolved.path, String(resolved.path.dropFirst(rootPath.count + 1)))
    }
}
