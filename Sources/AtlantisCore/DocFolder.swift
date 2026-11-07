import Foundation

/// The Docs folder (`~/Documents/Docs`): finds, reads and safely writes `.md` files inside it.
///
/// Rules (AGENTS.md): paths must stay inside the folder, files are written atomically, a save
/// that changes nothing writes nothing, and a file changed by another app since it was opened
/// is never overwritten.
public struct DocFolder: Sendable {
    public enum Failure: Error, Equatable {
        case outsideFolder
        case notMarkdown
        case notUTF8
        case changedOnDisk
    }

    /// A file as it was read: exact bytes plus the text the editor gets.
    public struct Snapshot: Sendable, Equatable {
        public let url: URL
        public let data: Data
        public let text: String
    }

    public enum SaveResult: Sendable, Equatable {
        case unchanged
        case written(Snapshot)
    }

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Creates the folder if it doesn't exist yet.
    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Checks that `url` is a `.md` file inside the folder (after resolving `..` and symlinks).
    public func resolve(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { throw Failure.outsideFolder }
        guard resolved.pathExtension.lowercased() == "md" else { throw Failure.notMarkdown }
        return resolved
    }

    /// All `.md` files in the folder, newest first. Skips hidden files and `assets` folders.
    public func list() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in walker {
            if url.lastPathComponent == "assets" { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            files.append((url.standardizedFileURL, date))
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Reads a doc. Refuses files that aren't valid UTF-8 rather than changing their bytes.
    public func read(_ url: URL) throws -> Snapshot {
        let url = try resolve(url)
        return try Self.snapshot(of: url)
    }

    /// Saves `text` to the doc `original` came from.
    /// - Returns `.unchanged` (nothing written) when the bytes are the same as on disk.
    /// - Throws `.changedOnDisk` if another app changed the file since `original` was read.
    public func save(_ text: String, over original: Snapshot) throws -> SaveResult {
        let url = try resolve(original.url)
        let current = try? Data(contentsOf: url)
        if let current, current != original.data { throw Failure.changedOnDisk }
        let data = Data(text.utf8)
        if data == current { return .unchanged }
        try data.write(to: url, options: .atomic)
        return .written(Snapshot(url: url, data: data, text: text))
    }

    /// Creates an empty doc with a free name like "Untitled 2.md".
    public func create(named base: String = "Untitled") throws -> Snapshot {
        try ensureExists()
        var url = root.appendingPathComponent("\(base).md")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = root.appendingPathComponent("\(base) \(n).md")
        }
        try Data().write(to: url, options: .withoutOverwriting) // fails if the name was just taken
        return Snapshot(url: url, data: Data(), text: "")
    }

    /// Reads any markdown file without the folder check. Only for read-only uses (tests,
    /// the round-trip check); never pass the result to `save`.
    public static func snapshot(of url: URL) throws -> Snapshot {
        let data = try Data(contentsOf: url)
        guard let text = String(validating: data, as: UTF8.self) else { throw Failure.notUTF8 }
        return Snapshot(url: url, data: data, text: text)
    }
}
