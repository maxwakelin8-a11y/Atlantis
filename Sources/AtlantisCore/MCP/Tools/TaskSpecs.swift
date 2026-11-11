import Foundation

/// A change to one task field: leave it, set it, or clear it.
enum Edit<Value: Sendable & Equatable>: Sendable, Equatable {
    case keep
    case set(Value)
    case clear

    var isKeep: Bool { if case .keep = self { true } else { false } }

    func apply(to current: inout Value?) {
        switch self {
        case .keep: break
        case .set(let value): current = value
        case .clear: current = nil
        }
    }

    /// Absent → keep; null, "" or "none" → clear; otherwise parsed.
    static func read(_ args: JSONValue, _ key: String, parse: (String) throws -> Value) throws -> Edit<Value> {
        guard let raw = args[key] else { return .keep }
        if raw.isNull { return .clear }
        let text: String
        if let string = raw.stringValue { text = string }
        else if let int = raw.intValue { text = String(int) }
        else { throw ToolFailure("Argument \"\(key)\" has the wrong type.") }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "none" { return .clear }
        return .set(try parse(trimmed))
    }
}

/// A task to add (`atlantis_task_add`, or an Inbox `task.add` item being accepted).
public struct NewTask: Sendable, Equatable {
    public var title: String
    public var due: DayStamp?
    public var estimate: Int?
    public var priority: Int?
    public var mode: String?
    public var area: String?
    public var project: String?
    /// `mcp:claude-code`, `seqta:assessment:1234`, … written as `source::`.
    public var source: String?

    init(arguments args: JSONValue, source: String?) throws {
        title = try Validate.taskTitle(try args.requireString("title", maxLength: 2_000))
        due = try args.optionalDay("due")
        estimate = try Self.readEstimate(args)
        priority = try args.optionalInt("pri", in: 1...3)
        mode = try args.optionalString("mode", maxLength: 40).map(Validate.mode)
        area = try args.optionalString("area", maxLength: 100).map { try Validate.label($0, "area") }
        project = try args.optionalString("project", maxLength: 100).map { try Validate.label($0, "project") }
        self.source = try source.map { try Validate.label($0, "source", maxLength: 100) }
    }

    private static func readEstimate(_ args: JSONValue) throws -> Int? {
        guard let raw = args["est"], !raw.isNull else { return nil }
        if let text = raw.stringValue { return try Validate.estimate(text) }
        if let minutes = raw.intValue { return try Validate.estimate(String(minutes)) }
        throw ToolFailure("Argument \"est\" must be like 45m, 1h or 1h30m.")
    }

    /// From an Inbox line: the item's title is the task title, its fields are the task fields.
    public init(item: InboxItem) throws {
        var args: [String: JSONValue] = ["title": .string(item.title)]
        for key in ["due", "est", "pri", "mode", "area", "project"] {
            if let value = item.field(key), !value.isEmpty { args[key] = .string(value) }
        }
        try self.init(arguments: .object(args), source: item.source.isEmpty ? nil : item.source)
    }

    public func makeTask() -> TaskItem {
        var task = TaskItem(title: title)
        task.due = due
        task.estimateMinutes = estimate
        task.priority = priority
        task.mode = mode
        task.area = area
        task.project = project
        if let source { task.setField("source", source) }
        return task
    }

    /// Inbox fields for this task (the title is the item's title).
    var inboxFields: [InboxItem.Field] {
        var fields: [InboxItem.Field] = []
        if let due { fields.append(.init(key: "due", value: due.description)) }
        if let estimate { fields.append(.init(key: "est", value: Estimate.format(estimate))) }
        if let priority { fields.append(.init(key: "pri", value: String(priority))) }
        if let mode { fields.append(.init(key: "mode", value: mode)) }
        if let area { fields.append(.init(key: "area", value: area)) }
        if let project { fields.append(.init(key: "project", value: project)) }
        return fields
    }

    var summary: String {
        var out = "Add task: \(title)"
        if let due { out += " (due \(due))" }
        return Clip.text(out, 200)
    }
}

/// A change to an existing task (`atlantis_task_update`, or an Inbox `task.update` item).
public struct TaskChange: Sendable, Equatable {
    public enum Status: String, Sendable { case open, done, cancelled }

    public var id: String
    public var status: Status?
    public var title: String?
    var due: Edit<DayStamp>
    var estimate: Edit<Int>
    var priority: Edit<Int>
    var mode: Edit<String>
    var area: Edit<String>
    var project: Edit<String>

    init(arguments args: JSONValue) throws {
        id = try Validate.taskID(try args.requireString("id", maxLength: 100))
        status = try args.optionalChoice("status", ["open", "done", "cancelled"]).flatMap(Status.init(rawValue:))
        title = try args.optionalString("title", maxLength: 2_000).map { try Validate.taskTitle($0) }
        due = try .read(args, "due") { try Validate.day($0, "due") }
        estimate = try .read(args, "est", parse: Validate.estimate)
        priority = try .read(args, "pri") { try Validate.priority($0) }
        mode = try .read(args, "mode", parse: Validate.mode)
        area = try .read(args, "area") { try Validate.label($0, "area") }
        project = try .read(args, "project") { try Validate.label($0, "project") }
        guard !isEmpty else {
            throw ToolFailure("Nothing to change. Give at least one of: status, title, due, est, pri, mode, area, project (use \"none\" to clear a field).")
        }
    }

    /// From an Inbox line. Fields: `task` (the id), `status`, `title` (the new title), `due`, `est`, `pri`, `mode`, `area`, `project`.
    public init(item: InboxItem) throws {
        var args: [String: JSONValue] = [:]
        if let id = item.field("task") { args["id"] = .string(id) }
        if let title = item.field("title") { args["title"] = .string(title) }
        for key in ["status", "due", "est", "pri", "mode", "area", "project"] {
            if let value = item.field(key) { args[key] = .string(value) }
        }
        try self.init(arguments: .object(args))
    }

    var isEmpty: Bool {
        status == nil && title == nil && due.isKeep && estimate.isKeep && priority.isKeep
            && mode.isKeep && area.isKeep && project.isKeep
    }

    func apply(to task: inout TaskItem, today: DayStamp) {
        if let title { task.title = title }
        switch status {
        case .done: if !task.isDone { task.markDone(on: today) }
        case .open: if !task.isOpen { task.reopen() }
        case .cancelled: task.status = "-"
        case nil: break
        }
        var due = task.due; self.due.apply(to: &due); task.due = due
        var est = task.estimateMinutes; estimate.apply(to: &est); task.estimateMinutes = est
        var pri = task.priority; priority.apply(to: &pri); task.priority = pri
        var mode = task.mode; self.mode.apply(to: &mode); task.mode = mode
        var area = task.area; self.area.apply(to: &area); task.area = area
        var project = task.project; self.project.apply(to: &project); task.project = project
    }

    /// Inbox fields for this change (the id as `task`; a new title as `title`).
    var inboxFields: [InboxItem.Field] {
        var fields: [InboxItem.Field] = [.init(key: "task", value: id)]
        if let status { fields.append(.init(key: "status", value: status.rawValue)) }
        if let title { fields.append(.init(key: "title", value: title)) }
        func add<V>(_ key: String, _ edit: Edit<V>, _ text: (V) -> String) {
            switch edit {
            case .keep: break
            case .set(let value): fields.append(.init(key: key, value: text(value)))
            case .clear: fields.append(.init(key: key, value: "none"))
            }
        }
        add("due", due) { $0.description }
        add("est", estimate) { Estimate.format($0) }
        add("pri", priority) { String($0) }
        add("mode", mode) { $0 }
        add("area", area) { $0 }
        add("project", project) { $0 }
        return fields
    }

    /// What changes, in a few words, for the Inbox title.
    func summary(taskTitle: String?) -> String {
        var parts: [String] = []
        if let status { parts.append(status == .done ? "complete" : status == .open ? "reopen" : "cancel") }
        if title != nil { parts.append("rename") }
        if !due.isKeep { parts.append("move") }
        if !(estimate.isKeep && priority.isKeep && mode.isKeep && area.isKeep && project.isKeep) { parts.append("edit") }
        let verb = parts.isEmpty ? "update" : parts.joined(separator: ", ")
        return Clip.text("Update task (\(verb)): \(taskTitle ?? id)", 200)
    }
}
