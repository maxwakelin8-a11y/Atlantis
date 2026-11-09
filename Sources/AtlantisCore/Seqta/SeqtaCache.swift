import Foundation

/// What a cache file holds: the items and when they were synced.
public struct CachedList<Item: Codable & Sendable>: Codable, Sendable {
    public var version: Int
    public var syncedAt: Date
    public var items: [Item]

    public init(syncedAt: Date, items: [Item]) {
        self.version = SeqtaCache.schemaVersion
        self.syncedAt = syncedAt
        self.items = items
    }
}

/// `meta.json`: when each part was last synced and the bookkeeping the sync rules need.
public struct SeqtaMeta: Codable, Sendable, Equatable {
    public struct KindInfo: Codable, Sendable, Equatable {
        public var syncedAt: Date
        public var count: Int
    }

    public var version = SeqtaCache.schemaVersion
    /// The last sync that wrote anything, manual or morning.
    public var lastSync: Date?
    public var lastReason: SeqtaSyncReason?
    /// Local day ("YYYY-MM-DD") of the last automatic sync that reached SEQTA. The morning
    /// sync never runs twice on the same day (AGENTS.md hard rule).
    public var lastAutoSyncDay: String?
    public var kinds: [String: KindInfo] = [:]
    /// What failed in the last sync, by kind. Empty when it all worked.
    public var failures: [String: String] = [:]
    /// Assessments whose marks appeared in the last sync.
    public var newMarkAssessmentIDs: [Int] = []

    public init() {}
}

public enum SeqtaSyncReason: String, Codable, Sendable {
    /// The user asked (button, menu, MCP refresh tool).
    case manual
    /// The once-a-day sync at launch or wake.
    case morning
}

/// SEQTA data saved as JSON, one file per kind, in `AppSupport.seqtaCache` (PRD §7d). Local,
/// not iCloud, and safe to delete: the next sync rebuilds it. Pages and the MCP read tools read
/// it; only the sync writes it.
public struct SeqtaCache: Sendable {
    public static let schemaVersion = 1

    public enum Kind: String, CaseIterable, Sendable {
        case lessons, assessments, notices, subjects, messages, files
        public var fileName: String { "\(rawValue).json" }
    }

    public let root: URL

    public init(root: URL = AppSupport.seqtaCache) {
        self.root = root
    }

    private var metaURL: URL { root.appendingPathComponent("meta.json") }
    private func url(_ kind: Kind) -> URL { root.appendingPathComponent(kind.fileName) }

    // MARK: Reading

    public func load<Item: Codable & Sendable>(_ kind: Kind, as type: Item.Type = Item.self) -> CachedList<Item>? {
        guard let data = try? Data(contentsOf: url(kind)) else { return nil }
        return try? Self.decoder.decode(CachedList<Item>.self, from: data)
    }

    public func lessons() -> CachedList<Lesson>? { load(.lessons) }
    public func assessments() -> CachedList<Assessment>? { load(.assessments) }
    public func notices() -> CachedList<Notice>? { load(.notices) }
    public func subjects() -> CachedList<Subject>? { load(.subjects) }
    public func messages() -> CachedList<MessageSummary>? { load(.messages) }
    public func files() -> CachedList<SubjectFile>? { load(.files) }

    /// Missing or unreadable meta is just "never synced".
    public func meta() -> SeqtaMeta {
        guard let data = try? Data(contentsOf: metaURL), let meta = try? Self.decoder.decode(SeqtaMeta.self, from: data) else {
            return SeqtaMeta()
        }
        return meta
    }

    // MARK: Writing

    /// Replaces one kind's file (atomically).
    public func save<Item: Codable & Sendable>(_ items: [Item], kind: Kind, syncedAt: Date) throws {
        try write(Self.encoder.encode(CachedList(syncedAt: syncedAt, items: items)), to: url(kind))
    }

    public func saveMeta(_ meta: SeqtaMeta) throws {
        try write(Self.encoder.encode(meta), to: metaURL)
    }

    /// Reads `meta`, lets `change` edit it, and writes it back.
    public func updateMeta(_ change: (inout SeqtaMeta) -> Void) throws {
        var meta = meta()
        change(&meta)
        try saveMeta(meta)
    }

    // MARK: Message bodies

    /// Whole messages are read on demand (one request each) and kept here, so reading one twice
    /// costs nothing. One small file per message.
    private var bodiesURL: URL { root.appendingPathComponent("message-bodies", isDirectory: true) }
    private func bodyURL(_ id: Int) -> URL { bodiesURL.appendingPathComponent("\(id).json") }

    public func message(id: Int) -> Message? {
        guard let data = try? Data(contentsOf: bodyURL(id)) else { return nil }
        return try? Self.decoder.decode(Message.self, from: data)
    }

    public func saveMessage(_ message: Message) throws {
        try write(Self.encoder.encode(message), to: bodyURL(message.id))
    }

    /// Whether this message's body has been opened (and so cached) on this Mac.
    public func hasMessage(id: Int) -> Bool { FileManager.default.fileExists(atPath: bodyURL(id).path) }

    /// Deletes every cache file (the cache is rebuildable).
    public func clear() throws {
        for kind in Kind.allCases { try? FileManager.default.removeItem(at: url(kind)) }
        try? FileManager.default.removeItem(at: metaURL)
        try? FileManager.default.removeItem(at: bodiesURL)
    }

    /// Atomic write; the files hold schoolwork and names, so they're private to the user.
    private func write(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        for dir in [root, url.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
