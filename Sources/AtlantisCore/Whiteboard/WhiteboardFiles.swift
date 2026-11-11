import CryptoKit
import Foundation
import Synchronization

/// The Whiteboards folder: plain `.excalidraw` files (Excalidraw's own JSON format), so boards
/// open in excalidraw.com or Obsidian too. Default: iCloud Drive/Whiteboards.
///
/// Paths are relative to the folder, like `Science/Cells.excalidraw`: never absolute, never `..`,
/// never hidden, and resolved through `WriterFiles.resolve` so symlinks can't lead out. All
/// writes go through one lock, so the page's saves and an agent's drawing never interleave.
public struct WhiteboardFiles: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case badPath
        case notFound
        case alreadyExists
        case tooBig
        case notABoard

        public var errorDescription: String? {
            switch self {
            case .badPath: "Boards are .excalidraw files inside the Whiteboards folder, like \"Science/Cells.excalidraw\"."
            case .notFound: "That board isn't there any more."
            case .alreadyExists: "A board with that name is already there."
            case .tooBig: "That board is too big (over 50 MB)."
            case .notABoard: "That file isn't an Excalidraw board."
            }
        }
    }

    public struct Board: Sendable, Equatable, Identifiable {
        /// Relative path, e.g. `Science/Cells.excalidraw`.
        public let path: String
        public let modified: Date
        public let size: Int
        public var id: String { path }
        /// File name without `.excalidraw`.
        public var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        /// The sub-folder, or "" for boards at the top.
        public var folder: String { (path as NSString).deletingLastPathComponent }
    }

    /// What a save did.
    public enum SaveResult: Sendable, Equatable {
        /// Written (or already identical). `hash` is the file's hash now.
        case saved(hash: String)
        /// The file changed since `expected`: nothing written. Here is what's on disk.
        case conflict(text: String, hash: String)
    }

    public static let fileExtension = "excalidraw"
    public static let maxSize = 50_000_000
    private static let maxDepth = 4
    private static let lock = Mutex(())

    public let root: URL
    private var checker: WriterFiles { WriterFiles(root: root) }

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Paths

    /// Checks a relative board path. `addExtension` adds `.excalidraw` to a name without one.
    public static func validate(_ raw: String, addExtension: Bool = false) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300, !text.hasPrefix("/"), !text.hasPrefix("~"),
              !text.contains("\\"), !text.contains("\0") else { throw Failure.badPath }
        var parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= maxDepth else { throw Failure.badPath }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..", !part.hasPrefix("."), part.count <= 120,
                  !part.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == ":" }) else {
                throw Failure.badPath
            }
        }
        if addExtension, (parts[parts.count - 1] as NSString).pathExtension.lowercased() != fileExtension {
            parts[parts.count - 1] += ".\(fileExtension)"
        }
        guard (parts.last! as NSString).pathExtension.lowercased() == fileExtension else { throw Failure.badPath }
        return parts.joined(separator: "/")
    }

    /// The file for a relative path, checked to be inside the folder (symlinks included).
    public func url(_ path: String) throws -> URL {
        let relative = try Self.validate(path)
        do { return try checker.resolve(root.appendingPathComponent(relative).path) }
        catch { throw Failure.badPath }
    }

    // MARK: Reading

    /// Every board, newest first. Hidden files, symlinks and anything deeper than 4 levels are skipped.
    public func list() -> [Board] {
        var found: [Board] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        func visit(_ dir: URL, rel: String, depth: Int) {
            guard depth < Self.maxDepth, found.count < 2_000,
                  let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                            options: [.skipsHiddenFiles]) else { return }
            for item in items {
                guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                let name = item.lastPathComponent
                let childRel = rel.isEmpty ? name : "\(rel)/\(name)"
                if values.isDirectory == true {
                    visit(item, rel: childRel, depth: depth + 1)
                } else if item.pathExtension.lowercased() == Self.fileExtension {
                    found.append(Board(path: childRel, modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0))
                }
            }
        }
        visit(root, rel: "", depth: 0)
        return found.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
    }

    public func exists(_ path: String) -> Bool {
        (try? url(path)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public func read(_ path: String) throws -> String {
        let file = try url(path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.notFound }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxSize else { throw Failure.tooBig }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw Failure.notABoard }
        return text
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Writing

    /// Makes a new empty board with a free name ("Untitled board", "Untitled board 2", …).
    /// Returns its path.
    public func create(named name: String = "Untitled board", in folder: String = "") throws -> String {
        try ensureRoot()
        let base = Self.cleanName(name)
        return try Self.lock.withLock { _ in
            for n in 1..<1_000 {
                let fileName = n == 1 ? base : "\(base) \(n)"
                let path = try Self.validate(folder.isEmpty ? fileName : "\(folder)/\(fileName)", addExtension: true)
                let file = try url(path)
                if FileManager.default.fileExists(atPath: file.path) { continue }
                try TextFile.write(WhiteboardScene.emptyBoard, to: file)
                return path
            }
            throw Failure.alreadyExists
        }
    }

    /// Writes the page's copy of a board, unless the file changed since the page last saw it
    /// (`expected` is the hash of that version; nil means "the file must not exist yet").
    public func save(_ path: String, text: String, expected: String?) throws -> SaveResult {
        guard text.utf8.count <= Self.maxSize else { throw Failure.tooBig }
        let file = try url(path)
        return try Self.lock.withLock { _ in
            // A board deleted or moved away while open is written back rather than lost.
            if let current = try? TextFile.read(file) {
                let hash = Self.hash(current)
                if hash != expected && hash != Self.hash(text) { return .conflict(text: current, hash: hash) }
            }
            try TextFile.write(text, to: file)
            return .saved(hash: Self.hash(text))
        }
    }

    /// Read-change-write under the lock (agents drawing). `change` gets the current text, or nil
    /// if the board doesn't exist yet, and returns the new text.
    @discardableResult
    public func update(_ path: String, _ change: (String?) throws -> String) throws -> String {
        let file = try url(path)
        return try Self.lock.withLock { _ in
            let current = try TextFile.read(file)
            if current == nil {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let next = try change(current)
            guard next.utf8.count <= Self.maxSize else { throw Failure.tooBig }
            try TextFile.write(next, to: file)
            return next
        }
    }

    /// Renames a board in its folder. Returns the new path.
    public func rename(_ path: String, to newName: String) throws -> String {
        let from = try url(path)
        let folder = (try Self.validate(path) as NSString).deletingLastPathComponent
        let fileName = Self.cleanName(newName)
        let target = try Self.validate(folder.isEmpty ? fileName : "\(folder)/\(fileName)", addExtension: true)
        let to = try url(target)
        guard from.path != to.path else { return target }
        return try Self.lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: from.path) else { throw Failure.notFound }
            // Case-only renames are allowed (same file on a case-insensitive disk).
            if FileManager.default.fileExists(atPath: to.path), from.path.lowercased() != to.path.lowercased() {
                throw Failure.alreadyExists
            }
            try FileManager.default.moveItem(at: from, to: to)
            return target
        }
    }

    /// Moves a board to the Bin (recoverable from Finder).
    public func trash(_ path: String) throws {
        let file = try url(path)
        try Self.lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.notFound }
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    /// A file name from what the user typed: no slashes, colons or leading dots.
    static func cleanName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".\(fileExtension)") { name = String(name.dropLast(fileExtension.count + 1)) }
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.unicodeScalars.filter { $0.properties.generalCategory != .control })
        return name.isEmpty ? "Untitled board" : String(name.prefix(100))
    }
}
