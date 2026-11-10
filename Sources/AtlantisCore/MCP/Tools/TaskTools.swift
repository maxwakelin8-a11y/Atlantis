import Foundation

/// `atlantis_today`, `atlantis_tasks_list`, `atlantis_task_add`, `atlantis_task_update` (PRD §8).
enum TaskTools {
    static func register(in registry: ToolRegistry, context: MCPToolContext) {
        registerToday(registry, context)
        registerList(registry, context)
        registerAdd(registry, context)
        registerUpdate(registry, context)
    }

    // MARK: Today

    private static func registerToday(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_today",
            description: "What's on for a day: the timetable's lessons, tasks due or planned that day, overdue tasks, assessments due in the next 14 days, and what's next up. Reads Atlantis's local data only. Defaults to today.",
            inputSchema: schema(["date": prop("The day, YYYY-MM-DD. Default: today.")]),
            kind: .read
        )) { args in
            let date = try args.optionalDay("date") ?? context.today
            let tasks = await MainActor.run { () -> [TaskItem] in
                let store = context.tasks()
                store.reload()
                return store.tasks
            }
            // TodayModel builds "today" from a clock; for another day, use that day (DayStamp.date is midday).
            let isToday = date == context.today
            let clock = isToday ? context.now() : (date.date(calendar: context.calendar) ?? context.now())
            let model = TodayModel.build(
                lessons: context.cache.lessons()?.items ?? [],
                assessments: context.cache.assessments()?.items ?? [],
                notices: context.cache.notices()?.items ?? [],
                tasks: tasks, now: clock, calendar: context.calendar)
            let minute = isToday ? TodayTime.minuteOfDay(context.now(), calendar: context.calendar) : -1
            return .json(todayJSON(model, minute: minute, syncedAt: context.cache.meta().lastSync))
        }
    }

    private static func todayJSON(_ model: TodayModel, minute: Int, syncedAt: Date?) -> JSONValue {
        func block(_ b: TodayBlock) -> JSONValue {
            switch b.kind {
            case .lesson(let l):
                return .make(["type": .string("lesson"), "from": .string(b.startText), "until": .string(b.endText),
                              "subject": .string(l.subject), "room": .str(l.room.isEmpty ? nil : l.room),
                              "teacher": .str(l.teacher.isEmpty ? nil : l.teacher),
                              "topic": .str(Clip.optional(l.topic, 200)), "homework": .str(Clip.optional(l.homework, 300))])
            case .task(let t):
                return .make(["type": .string("task"), "from": .string(b.startText), "until": .string(b.endText),
                              "id": .string(t.id), "title": .string(t.title)])
            }
        }
        let upcoming = model.current(at: minute) ?? model.next(after: minute)
        return .make([
            "date": .string(model.day.description),
            "synced_at": syncedAt.map { .string(ISO8601DateFormatter().string(from: $0)) },
            "next_up": upcoming.map(block),
            "schedule": .array(model.blocks.map(block)),
            "anytime": .array(model.anytime.map(TaskJSON.make)),
            "tasks": .array(model.taskSections.map { section in
                .make(["section": .string(section.title), "overdue": .bool(section.isOverdue),
                       "tasks": .array(section.tasks.map(TaskJSON.make))])
            }),
            "assessments": .array(model.assessments.map { d in
                .make(["id": .int(d.assessment.id), "title": .string(d.assessment.title), "subject": .string(d.assessment.subject),
                       "due": .string(d.assessment.due), "when": .string(d.countdown), "days_away": .int(d.daysLeft),
                       "submitted": .bool(d.assessment.submitted)])
            }),
            "notices": .array(model.notices.prefix(10).map { n in
                .make(["title": .string(n.title), "from": .str(n.staff.isEmpty ? nil : n.staff),
                       "text": .string(Clip.text(n.contents, 300))])
            }),
            "top_three": .array(model.topThree.map(JSONValue.string)),
        ])
    }

    // MARK: List

    private static func registerList(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_tasks_list",
            description: "List the user's tasks from machine/tasks.md. Filter by status, due date range, project, or mode/area. Returns each task's id (use it with atlantis_task_update), title, due date, estimate, priority, mode, area, project and source.",
            inputSchema: schema([
                "status": prop("open (default), done, cancelled or all."),
                "due_from": prop("Only tasks due on or after this day, YYYY-MM-DD."),
                "due_to": prop("Only tasks due on or before this day, YYYY-MM-DD."),
                "overdue": prop("true: only open tasks due before today.", "boolean"),
                "project": prop("Project name (case-insensitive)."),
                "mode": prop("A mode (school, building, bjj, social) or an area name (case-insensitive)."),
                "search": prop("Text the title contains."),
                "limit": prop("Most tasks to return (1-200, default 50).", "integer"),
            ]),
            kind: .read
        )) { args in
            let status = try args.optionalChoice("status", ["open", "done", "cancelled", "all"]) ?? "open"
            let from = try args.optionalDay("due_from"), to = try args.optionalDay("due_to")
            let overdue = try args.optionalBool("overdue") ?? false
            let project = try args.optionalString("project", maxLength: 100)?.lowercased()
            let group = try args.optionalString("mode", maxLength: 100)?.lowercased()
            let search = try args.optionalString("search", maxLength: 200)?.lowercased()
            let limit = try args.optionalInt("limit", in: 1...200) ?? 50
            let today = context.today

            let matched = await MainActor.run { () -> [TaskItem] in
                let store = context.tasks()
                store.reload()
                return store.tasks.filter { task in
                    switch status {
                    case "open": guard task.isOpen else { return false }
                    case "done": guard task.isDone else { return false }
                    case "cancelled": guard task.isCancelled else { return false }
                    default: break
                    }
                    if from != nil || to != nil {
                        guard let due = task.due else { return false }
                        if let from, due < from { return false }
                        if let to, due > to { return false }
                    }
                    if overdue { guard task.isOpen, let due = task.due, due < today else { return false } }
                    if let project, task.project?.lowercased() != project { return false }
                    if let group, task.mode?.lowercased() != group, task.area?.lowercased() != group { return false }
                    if let search, !task.title.lowercased().contains(search) { return false }
                    return true
                }
            }
            let shown = matched.prefix(limit)
            return .json(.make([
                "count": .int(matched.count),
                "truncated": .bool(matched.count > limit),
                "tasks": .array(shown.map(TaskJSON.make)),
            ]))
        }
    }

    // MARK: Add

    private static func registerAdd(_ registry: ToolRegistry, _ context: MCPToolContext) {
        let definition = ToolDefinition(
            name: "atlantis_task_add",
            description: "Add a task to the user's task list. The user may have to approve it: if so the task is proposed in the Atlantis Inbox and isn't added yet (the reply says which). Don't retry a proposed task.",
            inputSchema: schema([
                "title": prop("The task, one line."),
                "due": prop("Due day, YYYY-MM-DD."),
                "est": prop("Time estimate like 45m, 1h or 1h30m."),
                "pri": prop("Priority 1 (high) to 3 (low).", "integer"),
                "mode": prop("school, building, bjj or social."),
                "area": prop("A free-form area, if no mode fits."),
                "project": prop("Project name."),
            ], required: ["title"]),
            kind: .gatedWrite)
        registry.register(definition, proposal: { args in
            let task = try NewTask(arguments: args, source: MCPCaller.source)
            return InboxProposal(kind: GatedAction.taskAdd.inboxKind, title: task.title, source: MCPCaller.source, fields: task.inboxFields)
        }) { args in
            let spec = try NewTask(arguments: args, source: MCPCaller.source)
            let id = try await add(spec, to: context.tasks)
            return .json(.make(["added": .bool(true), "id": .string(id), "title": .string(spec.title)]))
        }
    }

    /// Adds the task and returns its id. Shared with accepting an Inbox `task.add`.
    static func add(_ spec: NewTask, to provider: MCPToolContext.TaskStoreProvider) async throws -> String {
        try await MainActor.run {
            let store = provider()
            store.reload()
            if let problem = store.problem { throw ToolFailure(problem) }
            return try store.add(spec.makeTask())
        }
    }

    // MARK: Update

    private static func registerUpdate(_ registry: ToolRegistry, _ context: MCPToolContext) {
        let definition = ToolDefinition(
            name: "atlantis_task_update",
            description: "Change a task: rename it, complete or reopen or cancel it, move its due date, or edit its estimate, priority, mode, area or project. Use \"none\" to clear a field. The user may have to approve it: if so the change is proposed in the Atlantis Inbox and isn't applied yet.",
            inputSchema: schema([
                "id": prop("The task id from atlantis_tasks_list (like t-ab12cd34)."),
                "status": prop("open, done or cancelled."),
                "title": prop("New title."),
                "due": prop("New due day YYYY-MM-DD, or none."),
                "est": prop("New estimate like 45m, or none."),
                "pri": prop("New priority 1-3, or none.", "integer"),
                "mode": prop("school, building, bjj, social, or none."),
                "area": prop("New area, or none."),
                "project": prop("New project, or none."),
            ], required: ["id"]),
            kind: .gatedWrite)
        registry.register(definition, proposal: { args in
            let change = try TaskChange(arguments: args)
            // The title is read at proposal time so the Inbox shows which task it is.
            let title = await currentTitle(of: change.id, provider: context.tasks)
            return InboxProposal(kind: GatedAction.taskUpdate.inboxKind, title: change.summary(taskTitle: title),
                                 source: MCPCaller.source, fields: change.inboxFields)
        }) { args in
            let change = try TaskChange(arguments: args)
            let title = try await apply(change, to: context.tasks)
            return .json(.make(["updated": .bool(true), "id": .string(change.id), "title": .string(title)]))
        }
    }

    private static func currentTitle(of id: String, provider: MCPToolContext.TaskStoreProvider) async -> String? {
        await MainActor.run {
            let store = provider()
            store.reload()
            return store.task(id: id)?.title
        }
    }

    /// Applies the change on the fresh file. Returns the task's title after the change.
    static func apply(_ change: TaskChange, to provider: MCPToolContext.TaskStoreProvider) async throws -> String {
        try await MainActor.run {
            let store = provider()
            store.reload()
            if let problem = store.problem { throw ToolFailure(problem) }
            guard store.task(id: change.id) != nil else {
                throw ToolFailure("No task with id \(change.id). It may have been changed or removed; list tasks again.")
            }
            let today = store.today
            let newID = try store.update(id: change.id) { change.apply(to: &$0, today: today) }
            return store.task(id: newID)?.title ?? change.id
        }
    }
}
