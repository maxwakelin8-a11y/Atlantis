import Foundation

/// Where Atlantis's files live in the LifeOS vault (PRD §9) and the local caches (PRD §7d).
///
/// Every vault write goes through `writableURL(_:)`, which refuses anything outside the vault
/// and anything in `human/` (AGENTS.md "Data rules").
public struct VaultPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var tasks: URL { root.appendingPathComponent("machine/tasks.md") }
    public var atlantisDir: URL { root.appendingPathComponent("machine/atlantis", isDirectory: true) }
    public var inbox: URL { atlantisDir.appendingPathComponent("inbox.md") }
    public var settings: URL { atlantisDir.appendingPathComponent("settings.md") }
    public var agentsDir: URL { atlantisDir.appendingPathComponent("agents", isDirectory: true) }
    public var threadsDir: URL { atlantisDir.appendingPathComponent("threads", isDirectory: true) }
    public var dailyDir: URL { root.appendingPathComponent("daily", isDirectory: true) }

    /// `daily/YYYY-MM-DD.md` for a calendar day in the given time zone.
    public func daily(for date: Date, calendar: Calendar = .current) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return dailyDir.appendingPathComponent(name)
    }

    public enum Failure: Error, Equatable {
        case outsideVault(String)
        case humanFolder(String)
    }

    /// Checks that `url` is inside the vault and not in `human/`, and returns it standardized.
    public func writableURL(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath + "/") else { throw Failure.outsideVault(url.path) }
        let relative = String(path.dropFirst(rootPath.count + 1))
        if relative == "human" || relative.hasPrefix("human/") { throw Failure.humanFolder(url.path) }
        return URL(fileURLWithPath: path)
    }
}

/// Local, rebuildable app data (not in the vault or iCloud).
public enum AppSupport {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atlantis", isDirectory: true)
    }
    /// SEQTA sync cache (PRD §7d).
    public static var seqtaCache: URL { root.appendingPathComponent("seqta", isDirectory: true) }
    /// Unix sockets for the MCP helper and agents (0600, peer-UID checked).
    public static var sockets: URL { root.appendingPathComponent("run", isDirectory: true) }
}

/// Atomic text-file writes that skip no-op writes (AGENTS.md: write atomically, change only
/// what changed).
public enum TextFile {
    /// Returns false when the file already had exactly this text (nothing written).
    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> Bool {
        let data = Data(text.utf8)
        if let existing = try? Data(contentsOf: url), existing == data { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }

    /// Reads UTF-8 text, or nil if the file doesn't exist.
    public static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }
}
