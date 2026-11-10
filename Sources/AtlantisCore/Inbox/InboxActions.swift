import Foundation

/// What accepting an Inbox proposal does (PRD F4). `InboxStore.onAccept` calls `apply`; the
/// proposal is marked accepted only if this doesn't throw.
///
/// - `task.add`: adds the task (title, fields, `source::`). Accepting twice never makes a second
///   task with the same source.
/// - `task.update`: applies the change to the task named by `[task:: <id>]`.
/// - Other kinds are only marked accepted for now.
@MainActor
public struct InboxActions {
    public let tasks: TaskStore

    public init(tasks: TaskStore) {
        self.tasks = tasks
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
        default:
            break
        }
    }
}
