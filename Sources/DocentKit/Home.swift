import Foundation

/// Where "home" is.
///
/// `FileManager.homeDirectoryForCurrentUser` and `NSHomeDirectory()` both ask the password
/// database, so they ignore `HOME` — which means a test, a sandbox or a `HOME=… docent …`
/// invocation silently reads and writes the *real* library. Everything in Docent that
/// touches a home directory goes through here instead, and the environment wins.
public enum Home {
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let home = environment["HOME"]?.trimmed, !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The folder Docent installs docsets into, and the first place it looks for them.
    public static func docsetsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        directory(environment: environment)
            .appendingPathComponent("Library/Application Support/Docent/DocSets")
    }
}
