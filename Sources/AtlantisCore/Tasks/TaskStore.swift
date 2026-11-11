import Foundation
import Observation

/// Reads and writes the vault's `machine/tasks.md` (PRD F2, §9).
///
/// - Edits made elsewhere (Obsidian, agents) show up live through a file watcher.
/// - Every write re-reads the file first and applies the change to that fresh text, so another
///   tool's edit made a moment ago is never overwritten (the conflict rule).
/// - Writes are atomic and touch only the edited task's lines.
///
/// Started lazily the first time Tasks (or anything that needs tasks) is shown.
@MainActor @Observable
public final class TaskStore {
    public enum Failure: Error, Equatable, LocalizedError {
        case vaultMissing(String)
        case taskNotFound
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case let .vaultMissing(path): "The LifeOS vault isn't at \(path)."
            case .taskNotFound: "That task was changed or removed in the file."
            case let .unreadable(why): "tasks.md couldn't be read: \(why)"
            }
        }
    }

    public private(set) var tasks: [TaskItem] = []
    public private(set) var isLoaded = false
    /// Set when the vault or file can't be used; cleared by the next good read or write.
    public private(set) var problem: String?
    /// Bumped on every change to `tasks`, so callers can cheaply see "something changed".
    public private(set) var revision = 0

    public let vault: VaultPaths
    @ObservationIgnored private let nowProvider: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var watcher: FileWatcher?
    /// The exact text `tasks` was built from, to ignore a watcher echo of our own write.
    @ObservationIgnored private var lastText: String?

    public init(vault: VaultPaths, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.vault = vault
        self.nowProvider = now
        self.calendar = calendar
    }

    public var now: Date { nowProvider() }
    public var today: DayStamp { DayStamp(nowProvider(), calendar: calendar) }
    public var timeZoneCalendar: Calendar { calendar }

    // MARK: Lifecycle

    /// Loads the file and starts watching it. Safe to call more than once.
    public func start() {
        guard watcher == nil else { return }
        reload()
        guard FileManager.default.fileExists(atPath: vault.root.path) else { return }
        let folder = FileManager.default.fileExists(atPath: vault.tasks.deletingLastPathComponent().path)
            ? vault.tasks.deletingLastPathComponent() : vault.root
        let watched = folder
        watcher = FileWatcher(folder: watched, fileName: vault.tasks.lastPathComponent) { [weak self] in
            Task { @MainActor [weak self] in self?.fileChanged(watching: watched) }
        }
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
    }

    private func fileChanged(watching folder: URL) {
        reload()
        // The machine/ folder may have appeared after we started on the vault root.
        let machine = vault.tasks.deletingLastPathComponent()
        if folder != machine, FileManager.default.fileExists(atPath: machine.path) {
            stop()
            start()
        }
    }

    /// Re-reads the file. Does nothing visible if its text hasn't changed.
    public func reload() {
        do {
            let text = try readText()
            apply(text)
            problem = nil
        } catch {
            problem = error.localizedDescription
            if !isLoaded { isLoaded = true }
        }
    }

    private func readText() throws -> String {
        guard FileManager.default.fileExists(atPath: vault.root.path) else { throw Failure.vaultMissing(vault.root.path) }
        do { return try TextFile.read(vault.tasks) ?? "" } catch { throw Failure.unreadable(error.localizedDescription) }
    }

    private func apply(_ text: String) {
        isLoaded = true
        guard text != lastText else { return }
        lastText = text
        tasks = TaskFile(parsing: text).tasks
        revision += 1
    }

    // MARK: Changes

    /// Re-reads, applies `change` to the fresh file, writes atomically and reloads. Throws if
    /// the file can't be read or written or `change` returns false.
    private func mutate(_ change: (inout TaskFile) throws -> Bool) throws {
        let text: String
        do { text = try readText() } catch { problem = error.localizedDescription; throw error }
        var file = TaskFile(parsing: text.isEmpty ? "# Tasks\n\n" : text)
        guard try change(&file) else {
            apply(text) // show what is really in the file
            throw Failure.taskNotFound
        }
        let out = file.serialized()
        do {
            let url = try vault.writableURL(vault.tasks)
            try TextFile.write(out, to: url)
        } catch {
            problem = error.localizedDescription
            throw error
        }
        apply(out)
        problem = nil
    }

    /// Adds a task after the last one. Returns its id.
    @discardableResult
    public func add(_ item: TaskItem) throws -> String {
        var id = ""
        let day = today
        try mutate { file in
            id = file.add(item, today: day)
            return true
        }
        return id
    }

    /// Applies `change` to the task with this id on the fresh file. Returns the id after the
    /// change (a task with no `^id` gets one when first edited).
    @discardableResult
    public func update(id: String, _ change: (inout TaskItem) -> Void) throws -> String {
        var newID = id
        try mutate { file in
            guard let updated = file.update(id: id, change) else { return false }
            newID = updated
            return true
        }
        return newID
    }

    /// Ticks a task off, with today's `done::` date. Ticking an already done task does nothing.
    @discardableResult
    public func complete(id: String) throws -> String {
        let day = today
        return try update(id: id) { task in
            guard !task.isDone else { return }
            task.markDone(on: day)
        }
    }

    @discardableResult
    public func reopen(id: String) throws -> String {
        try update(id: id) { $0.reopen() }
    }

    /// Removes a task and its continuation lines.
    public func delete(id: String) throws {
        try mutate { $0.remove(id: id) }
    }

    // MARK: Queries

    public func task(id: String) -> TaskItem? { tasks.first { $0.id == id } }

    /// Open tasks due on this day.
    public func tasks(dueOn day: DayStamp) -> [TaskItem] {
        tasks.filter { $0.isOpen && $0.due == day }
    }

    /// Open tasks due before today.
    public var overdue: [TaskItem] {
        let day = today
        return tasks.filter { $0.isOpen && ($0.due.map { $0 < day } ?? false) }
    }

    /// Open tasks for Today: overdue, due today, or pulled in with `plan::`/`scheduled::` today.
    public var forToday: [TaskItem] {
        let day = today
        return tasks.filter { task in
            guard task.isOpen else { return false }
            if let due = task.due, due <= day { return true }
            return task.plan == day || task.scheduledDay == day
        }
    }

    public var projects: [String] { distinct(tasks.compactMap(\.project)) }
    public var areas: [String] { distinct(tasks.compactMap(\.group)) }

    private func distinct(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
