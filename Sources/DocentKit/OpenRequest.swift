import Foundation

/// What the window should show the moment it comes up, written by `docent browse` and read
/// once by the app.
///
/// A small file rather than launch arguments: macOS hands `--args` to an app only when it
/// is not already running, and "Docent is already open" is the ordinary case for someone
/// reading documentation while they work.
public struct OpenRequest: Equatable, Sendable, Codable {
    /// A docset name or keyword — whatever the sidebar would be clicked on.
    public var docset: String?
    /// What to type into the search field, if anything.
    public var query: String?
    public var written: Date

    public init(docset: String? = nil, query: String? = nil, written: Date = Date()) {
        self.docset = docset
        self.query = query
        self.written = written
    }

    /// How long a request is worth acting on. Opening Docent by hand the next morning must
    /// not silently jump to whatever the terminal asked for last night.
    public static let lifetime: TimeInterval = 120

    public func isFresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(written)
        return age >= -5 && age <= Self.lifetime
    }

    /// Hidden, and inside the folder both halves already agree on: the library scanner
    /// skips hidden entries, and a sandboxed `DOCENT_DOCSETS` gets its own request file
    /// instead of reaching into the real one.
    public static func url(library: DocsetLibrary = .standard()) -> URL {
        library.installDirectory.appendingPathComponent(".open-request.json")
    }

    public func write(to url: URL = OpenRequest.url()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        // Nobody else's business which project someone is reading.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Read it and delete it. A request is acted on once, whatever happens next — a crash
    /// while opening a docset must not leave the app jumping to it on every launch.
    @discardableResult
    public static func consume(at url: URL = OpenRequest.url(), now: Date = Date()) -> OpenRequest? {
        // A request is a couple of hundred bytes; anything larger is not one. A named pipe
        // is not one either, and opening one would block the window for ever.
        let data = Containment.read(url, limit: 64 * 1024)
        try? FileManager.default.removeItem(at: url)
        guard let data, let request = try? JSONDecoder().decode(OpenRequest.self, from: data) else { return nil }
        return request.isFresh(now: now) ? request : nil
    }
}
