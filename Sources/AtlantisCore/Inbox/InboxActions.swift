import Foundation

/// What accepting an Inbox proposal does (PRD F4). `InboxStore.onAccept` calls `apply`; the
/// proposal is marked accepted only if this doesn't throw.
///
/// - `task.add`: adds the task (title, fields, `source::`). Accepting twice never makes a second
///   task with the same source.
/// - `task.update`: applies the change to the task named by `[task:: <id>]`.
/// - `doc.edit`: creates or replaces a doc in the Writer folder (see `DocWrite`). Replacing
///   refuses if the doc changed since the proposal was made.
/// - `whiteboard.draw`: adds an agent's drawing to a board (see `WhiteboardDraw`), creating the
///   board if needed. Only adds, so it applies even if the board changed since.
/// - Other kinds are only marked accepted for now.
@MainActor
public struct InboxActions {
    public let tasks: TaskStore
    /// The Writer folder, read when a `doc.edit` is accepted (Settings can move it).
    public let writerRoot: () -> URL?
    /// The Whiteboards folder, for `whiteboard.draw`.
    public let whiteboardRoot: () -> URL?
    /// Told which board an accepted drawing went to, so an open copy updates.
    public let boardChanged: (String) -> Void

    public init(tasks: TaskStore, writerRoot: @escaping () -> URL? = { nil },
                whiteboardRoot: @escaping () -> URL? = { nil }, boardChanged: @escaping (String) -> Void = { _ in }) {
        self.tasks = tasks
        self.writerRoot = writerRoot
        self.whiteboardRoot = whiteboardRoot
        self.boardChanged = boardChanged
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public func apply(_ item: InboxItem) throws {
        switch item.kind {
        case "task.add":
            tasks.start()
            if !item.source.isEmpty,
               tasks.tasks.contains(where: { $0.source.map(SeqtaProposals.normalized) == SeqtaProposals.normalized(item.source) }) {
                return
            }
            try tasks.add(InboxTaskActions.task(from: item))
        case "task.update":
            tasks.start()
            guard let id = InboxTaskActions.target(of: item) else { throw TaskStore.Failure.taskNotFound }
            let day = tasks.today
            try tasks.update(id: id) { InboxTaskActions.apply(item, to: &$0, today: day) }
        case "doc.edit":
            guard let root = writerRoot() else { throw Failure(message: "No Writer folder is set.") }
            do {
                try DocWrite(item: item).apply(in: WriterFiles(root: root))
            } catch let failure as ToolFailure {
                throw Failure(message: failure.message)
            }
        case "whiteboard.draw":
            guard let root = whiteboardRoot() else { throw Failure(message: "No Whiteboards folder is set.") }
            do {
                let draw = try WhiteboardDraw(item: item)
                _ = try draw.apply(in: WhiteboardFiles(root: root))
                boardChanged(draw.path)
            } catch let failure as ToolFailure {
                throw Failure(message: failure.message)
            } catch let failure as WhiteboardFiles.Failure {
                throw Failure(message: failure.errorDescription ?? "That board can't be changed.")
            }
        default:
            break
        }
    }
}
