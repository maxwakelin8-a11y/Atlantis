import Foundation

/// The file operations the Docs page (the Writer) may use, all confined to the Writer folder.
///
/// The page sends absolute paths; every one is resolved (`..` and symlinks) and refused unless it
/// is inside `root`. Symlinked entries are never listed or followed out of the folder. Writes are
/// atomic and limited to text files (AGENTS.md "Narrow bridge").
public struct WriterFiles: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case outsideFolder
        case notText
        case notFound
        case alreadyExists
        case tooBig
        case notAllowedType(String)
        case notAnImage
        case badImagePath

        public var errorDescription: String? {
            switch self {
            case .outsideFolder: "That path is outside the Writer folder."
            case .notText: "That file isn't UTF-8 text."
            case .notFound: "That file isn't there any more."
            case .alreadyExists: "Something with that name is already there."
            case .tooBig: "That file is too big."
            case .notAllowedType(let ext): "Docs can't write .\(ext) files."
            case .notAnImage: "That isn't a PNG, JPEG, GIF or WebP image."
            case .badImagePath: "Images can only go in a project's assets folder."
            }
        }
    }

    public enum Kind: String, Sendable { case dir, file }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let kind: Kind
    }

    public struct Stat: Sendable, Equatable {
        public let kind: Kind
        public let size: Int
        /// Milliseconds since 1970, like Node's `mtimeMs`.
        public let mtime: Double
    }

    /// Text files the page may write (docs, the project file, snapshots, text exports, the writing record).
    public static let writableExtensions: Set<String> = ["md", "markdown", "txt", "json", "jsonl", "html"]
    public static let maxRead = 20_000_000
    /// Image types the page may write, into a project's `assets` folder only.
    public static let writableImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    /// Image types the editor may display from the Writer folder (reading only).
    public static let displayableImageExtensions: Set<String> = writableImageExtensions.union(["heic", "heif", "svg", "avif"])
    public static let maxImage = 25_000_000

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `path` as a URL inside the folder, or `.outsideFolder`.
    public func resolve(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.outsideFolder }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Resolve symlinks in the part that exists; the rest is new names.
        var existing = url
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in rest {
            guard part != "..", part != "." else { throw Failure.outsideFolder }
            resolved.appendPathComponent(part)
        }
        let p = resolved.path
        guard p == root.path || p.hasPrefix(root.path + "/") else { throw Failure.outsideFolder }
        return resolved
    }

    public func list(_ path: String) throws -> [Entry] {
        let dir = try resolve(path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)
        return items.compactMap { item in
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { return nil }
            if v.isDirectory == true { return Entry(name: item.lastPathComponent, kind: .dir) }
            if v.isRegularFile == true { return Entry(name: item.lastPathComponent, kind: .file) }
            return nil
        }
        .sorted { $0.name < $1.name }
    }

    public func read(_ path: String) throws -> String {
        let url = try resolve(path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.notFound }
        guard size <= Self.maxRead else { throw Failure.tooBig }
        let data = try Data(contentsOf: url)
        guard let text = String(validating: data, as: UTF8.self) else { throw Failure.notText }
        return text
    }

    public func write(_ path: String, text: String) throws {
        let url = try resolve(path)
        let ext = url.pathExtension.lowercased()
        guard Self.writableExtensions.contains(ext) else { throw Failure.notAllowedType(ext) }
        let data = Data(text.utf8)
        // A save that changes nothing writes nothing.
        if let old = try? Data(contentsOf: url), old == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: try resolve(path), withIntermediateDirectories: true)
    }

    public func move(_ from: String, to: String) throws {
        let a = try resolve(from)
        let b = try resolve(to)
        guard a != root, FileManager.default.fileExists(atPath: a.path) else { throw Failure.notFound }
        guard !FileManager.default.fileExists(atPath: b.path) else { throw Failure.alreadyExists }
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: b)
    }

    public func stat(_ path: String) throws -> Stat? {
        let url = try resolve(path)
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return Stat(kind: v.isDirectory == true ? .dir : .file,
                    size: v.fileSize ?? 0,
                    mtime: (v.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
    }

    /// Copies a folder, leaving out top-level items named in `skip`.
    public func copyDir(_ from: String, to: String, skip: [String]) throws {
        let a = try resolve(from)
        let b = try resolve(to)
        guard !FileManager.default.fileExists(atPath: b.path) else { throw Failure.alreadyExists }
        guard !b.path.hasPrefix(a.path + "/") else { throw Failure.outsideFolder }
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        for item in try FileManager.default.contentsOfDirectory(atPath: a.path) where !skip.contains(item) {
            let src = a.appendingPathComponent(item)
            if (try? src.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            try FileManager.default.copyItem(at: src, to: b.appendingPathComponent(item))
        }
    }
}

// MARK: Images

extension WriterFiles {
    /// Saves a pasted or dropped image at `path`, which must be `<Writer>/<Project>/assets/<name>.<ext>`
    /// with a PNG, JPEG, GIF or WebP extension. The bytes must really be that kind of image, are
    /// capped at `maxImage`, and an existing file is never overwritten. Written atomically.
    public func writeImage(_ path: String, data: Data) throws {
        let url = try resolve(path)
        let ext = url.pathExtension.lowercased()
        guard Self.writableImageExtensions.contains(ext) else { throw Failure.notAllowedType(ext) }
        // Exactly <root>/<project>/assets/<file>: the project folder is a direct child of the root.
        let assets = url.deletingLastPathComponent()
        let project = assets.deletingLastPathComponent()
        guard assets.lastPathComponent == "assets", project.deletingLastPathComponent().path == root.path,
              !project.lastPathComponent.hasPrefix("."), url.lastPathComponent.first != "." else {
            throw Failure.badImagePath
        }
        guard data.count <= Self.maxImage else { throw Failure.tooBig }
        guard Self.looksLike(ext, data) else { throw Failure.notAnImage }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.alreadyExists }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// An image inside the Writer folder, for showing in the editor. Images only, size capped.
    public func readImage(_ path: String) throws -> (data: Data, ext: String) {
        let url = try resolve(path)
        let ext = url.pathExtension.lowercased()
        guard Self.displayableImageExtensions.contains(ext) else { throw Failure.notAllowedType(ext) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else { throw Failure.notFound }
        guard size <= Self.maxImage else { throw Failure.tooBig }
        return (try Data(contentsOf: url), ext)
    }

    static func looksLike(_ ext: String, _ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        switch ext {
        case "png": return b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "jpg", "jpeg": return b.starts(with: [0xFF, 0xD8, 0xFF])
        case "gif": return b.starts(with: Array("GIF8".utf8))
        case "webp": return b.count >= 12 && b.starts(with: Array("RIFF".utf8)) && Array(b[8..<12]) == Array("WEBP".utf8)
        default: return false
        }
    }
}
