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
}
