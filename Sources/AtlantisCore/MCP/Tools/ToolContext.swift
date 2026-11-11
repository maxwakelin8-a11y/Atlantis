import Foundation

/// How a manual SEQTA refresh went, for the tool's reply.
public struct SeqtaRefreshOutcome: Sendable, Equatable {
    public var ok: Bool
    public var message: String
    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

/// Everything the Atlantis tools need from the app. The app passes the real stores; tests pass
/// temporary folders. Locations are closures because Settings can change them while the app runs.
public struct MCPToolContext: Sendable {
    public typealias TaskStoreProvider = @MainActor @Sendable () -> TaskStore

    public var vault: @Sendable () -> VaultPaths
    public var writerRoot: @Sendable () -> URL
    public var cache: SeqtaCache
    public var tasks: TaskStoreProvider
    public var inbox: any InboxPosting
    /// Runs the app's manual SEQTA sync (the app's sync joins one already running and never opens a second).
    public var refreshSeqta: @Sendable () async -> SeqtaRefreshOutcome
    /// Turns HTML into a PDF or .docx at `target` (the app's DocsExport).
    public var exportDocument: @Sendable (_ html: String, _ format: String, _ target: URL) async throws -> Void
    public var now: @Sendable () -> Date
    public var calendar: Calendar
    /// Agents can't ask for another SEQTA sync inside this window (no polling).
    public var minRefreshInterval: TimeInterval
    /// Queues a run of another bot for `atlantis_agent_delegate` (the app's team queue). nil: not available.
    public var delegate: AgentDelegateHandler?
    /// The Whiteboards folder. nil: no whiteboard tools work (e.g. the agent daemon's own context).
    public var whiteboardRoot: (@Sendable () -> URL)?
    /// Called after an agent drew on a board, so an open copy picks the change up at once.
    public var boardChanged: @Sendable (_ path: String) async -> Void
    /// Shows a board on the Whiteboard page. nil: not available.
    public var openBoard: (@Sendable (_ path: String) async -> Void)?

    public init(vault: @escaping @Sendable () -> VaultPaths,
                writerRoot: @escaping @Sendable () -> URL,
                cache: SeqtaCache,
                tasks: @escaping TaskStoreProvider,
                inbox: any InboxPosting,
                refreshSeqta: @escaping @Sendable () async -> SeqtaRefreshOutcome,
                exportDocument: @escaping @Sendable (String, String, URL) async throws -> Void,
                now: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .current,
                minRefreshInterval: TimeInterval = 300,
                delegate: AgentDelegateHandler? = nil,
                whiteboardRoot: (@Sendable () -> URL)? = nil,
                boardChanged: @escaping @Sendable (String) async -> Void = { _ in },
                openBoard: (@Sendable (String) async -> Void)? = nil) {
        self.vault = vault
        self.writerRoot = writerRoot
        self.cache = cache
        self.tasks = tasks
        self.inbox = inbox
        self.refreshSeqta = refreshSeqta
        self.exportDocument = exportDocument
        self.now = now
        self.calendar = calendar
        self.minRefreshInterval = minRefreshInterval
        self.delegate = delegate
        self.whiteboardRoot = whiteboardRoot
        self.boardChanged = boardChanged
        self.openBoard = openBoard
    }

    var writer: WriterFiles { WriterFiles(root: writerRoot()) }
    var today: DayStamp { DayStamp(now(), calendar: calendar) }
}

/// The gated write actions the Settings allow list controls (PRD §8: the `write*` tools).
public enum GatedAction: String, CaseIterable, Sendable {
    case taskAdd = "atlantis_task_add"
    case taskUpdate = "atlantis_task_update"
    case docWrite = "atlantis_doc_write"
    case whiteboardDraw = "atlantis_whiteboard_draw"

    /// The Inbox kind a not-allowed call becomes.
    public var inboxKind: String {
        switch self {
        case .taskAdd: "task.add"
        case .taskUpdate: "task.update"
        case .docWrite: "doc.edit"
        case .whiteboardDraw: "whiteboard.draw"
        }
    }

    public var label: String {
        switch self {
        case .taskAdd: "Add tasks"
        case .taskUpdate: "Change, complete or move tasks"
        case .docWrite: "Create docs"
        case .whiteboardDraw: "Draw on whiteboards"
        }
    }

    public var detail: String {
        switch self {
        case .taskAdd: "Agents add a task straight to tasks.md."
        case .taskUpdate: "Agents edit, tick off or reschedule existing tasks."
        case .docWrite: "Agents create a new doc in a Writer project. Changing an existing doc always waits in the Inbox."
        case .whiteboardDraw: "Agents create boards and add shapes, text and arrows. They never move or delete what's already there."
        }
    }
}

/// The allow list: which `write*` actions run without asking. Kept in UserDefaults for now;
/// PRD §9 puts it in `machine/atlantis/settings.md` front matter, which can replace this later.
public struct DefaultsActionAllowList: ActionAllowList, @unchecked Sendable { // UserDefaults is thread-safe
    public static let key = "mcpAllowedActions"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var allowed: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    public func isAllowed(tool: String) -> Bool {
        GatedAction(rawValue: tool) != nil && allowed.contains(tool)
    }

    public func setAllowed(_ allowed: Bool, action: GatedAction) {
        var all = self.allowed
        if allowed { all.insert(action.rawValue) } else { all.remove(action.rawValue) }
        defaults.set(all.sorted(), forKey: Self.key)
    }
}
