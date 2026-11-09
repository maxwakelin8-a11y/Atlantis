import AtlantisCore
import Foundation
import Observation

/// The Inbox: proposals from SEQTA, agents and quick captures, kept in the vault file
/// `machine/atlantis/inbox.md` (PRD F4, §9).
///
/// The file is the source of truth. It's re-read before every write, and watched with a
/// file-system event source (no timers, no polling) so edits from Obsidian or an agent show up.
@MainActor @Observable
final class InboxStore {
    private(set) var items: [InboxItem] = []
    /// The last problem reading or writing the file, for the page to show.
    private(set) var lastError: String?
    /// Kinds the user said to accept without asking ("Always allow this kind").
    private(set) var allowedKinds: [String]

    /// Called when a proposal is accepted, before it's marked accepted. If it throws the item
    /// stays pending. Tasks are wired in here later; by default accepting only marks it.
    @ObservationIgnored var onAccept: @MainActor (InboxItem) async throws -> Void = { _ in }

    static let allowKindsKey = "inboxAllowKinds"

    @ObservationIgnored private let vault: VaultPaths
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var file = InboxFile()
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var accepting = Set<String>()

    init(vault: VaultPaths, defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        allowedKinds = defaults.stringArray(forKey: Self.allowKindsKey) ?? []
    }

    isolated deinit { source?.cancel() }

    var url: URL { vault.inbox }

    /// Waiting for a decision, in file order.
    var pending: [InboxItem] { items.filter { $0.state == .pending } }

    /// Accepted or dismissed, newest first.
    var done: [InboxItem] { items.filter { $0.state != .pending }.reversed() }

    // MARK: Loading and watching

    /// Reads the file and starts watching it. Safe to call again.
    func start() {
        reload()
        attachWatcher()
    }

    func reload() {
        do {
            let text = try TextFile.read(url) ?? ""
            let fresh = InboxFile(text: text)
            if fresh != file { file = fresh; items = fresh.items }
            lastError = nil
        } catch {
            lastError = "Couldn't read the Inbox file: \(error.localizedDescription)"
            Log.app.error("Inbox read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Watches the file. If it doesn't exist yet, watches the nearest folder that does, until it appears.
    /// Atomic saves (rename over the file) end the old watch, so each event re-opens it.
    private func attachWatcher() {
        source?.cancel()
        source = nil

        var target = url
        var fd = open(target.path, O_EVTONLY)
        while fd < 0, target.path != "/" {
            target = target.deletingLastPathComponent()
            fd = open(target.path, O_EVTONLY)
        }
        guard fd >= 0 else { return }

        let watched = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
        watched.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reload()
                self.attachWatcher()
            }
        }
        watched.setCancelHandler { close(fd) }
        source = watched
        watched.resume()
    }

    // MARK: Changing items

    /// Adds a proposal. If its kind is on the always-allow list it's accepted straight away.
    @discardableResult
    func post(_ item: InboxItem) async throws -> InboxItem {
        var item = item
        item.state = .pending
        try mutate { file in
            while file.item(id: item.id) != nil { item.id = InboxItem.newID() }
            file.append(item)
            return true
        }
        if isAllowed(kind: item.kind) {
            do { try await accept(id: item.id) } catch {
                lastError = "Couldn't accept \(item.title): \(error.localizedDescription)"
            }
        }
        return item
    }

    func accept(id: String) async throws {
        reload()
        guard let item = file.item(id: id), item.state == .pending, !accepting.contains(id) else { return }
        accepting.insert(id)
        defer { accepting.remove(id) }
        do { try await onAccept(item) } catch {
            lastError = "Couldn't accept \(item.title): \(error.localizedDescription)"
            throw error
        }
        try mutate { $0.setState(.accepted, id: id) }
    }

    func dismiss(id: String) throws {
        try mutate { $0.setState(.dismissed, id: id) }
    }

    /// Saves an edited proposal (title and fields). Only that item's line changes.
    func edit(_ item: InboxItem) throws {
        try mutate { $0.replace(item) }
    }

    // MARK: Always allow

    func isAllowed(kind: String) -> Bool {
        !kind.isEmpty && allowedKinds.contains(kind)
    }

    func setAllowed(_ allowed: Bool, kind: String) {
        guard !kind.isEmpty else { return }
        var kinds = allowedKinds.filter { $0 != kind }
        if allowed { kinds.append(kind) }
        allowedKinds = kinds
        defaults.set(kinds, forKey: Self.allowKindsKey)
    }

    // MARK: Writing

    /// Re-reads the file from disk, applies `change`, and writes it back atomically if it changed.
    private func mutate(_ change: (inout InboxFile) -> Bool) throws {
        do {
            let target = try vault.writableURL(url)
            var latest = InboxFile(text: try TextFile.read(target) ?? "")
            guard change(&latest) else {
                file = latest; items = latest.items
                return
            }
            try TextFile.write(latest.text, to: target)
            file = latest
            items = latest.items
            lastError = nil
        } catch {
            lastError = "Couldn't update the Inbox file: \(error.localizedDescription)"
            Log.app.error("Inbox write failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
