import Foundation

/// Is this file inside that folder, once every symlink on both sides is resolved?
///
/// One answer, used by everything that opens a file from a docset: the command, the app's
/// navigation policy and the self-tests. The first round of review fixed the command's copy
/// of this check and left the app's behind, which is what happens when the same question is
/// answered in three places.
public enum Containment {
    public static func allows(_ url: URL, under root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL else { return false }
        // `file://host/share/…` is an SMB mount, not a local file.
        guard url.host == nil || url.host?.isEmpty == true else { return false }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
    }

    /// An ordinary file, and not a door into something else.
    ///
    /// A named pipe has no size and blocks whoever opens it until a writer turns up, so a
    /// FIFO planted in a docset (as a page, as `Info.plist`, as the handoff file) hangs
    /// Docent for ever while passing every size check. Devices and sockets are no better.
    public static func isOrdinaryFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFREG
    }

    /// Reads a file that has to be an ordinary one, and no bigger than `limit`.
    public static func read(_ url: URL, limit: Int) -> Data? {
        guard isOrdinaryFile(url) else { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil,
              size <= limit else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
