import Foundation

/// SEQTA homework and assessments as Inbox proposals (PRD F3: never added silently).
///
/// A source (`seqta:assessment:<id>`, `seqta:homework:<lesson id>`) is proposed once, ever: not
/// if any Inbox item has it (pending, accepted or dismissed), and not if a task already has it
/// as `source::` or the older `from::` (`assessment:<id>`). The same homework text for the same
/// subject (a double period, or set again next lesson) is proposed once too.
public enum SeqtaProposals {
    public static let kind = "task.add"
    public static let area = "School"

    public static func assessmentSource(_ id: Int) -> String { "seqta:assessment:\(id)" }
    public static func homeworkSource(_ lessonID: String) -> String { "seqta:homework:\(lessonID)" }

    public static func make(lessons: [Lesson], assessments: [Assessment], inbox: [InboxItem], tasks: [TaskItem],
                            now: Date, calendar: Calendar = .current) -> [InboxItem] {
        let today = DayStamp(now, calendar: calendar)
        let created = today.description
        var known = Set<String>()
        for item in inbox where !item.source.isEmpty { known.insert(normalized(item.source)) }
        for task in tasks { if let source = task.source { known.insert(normalized(source)) } }
        // Homework already proposed or added, by subject + text.
        var knownHomework = Set<String>()
        for item in inbox where item.source.hasPrefix("seqta:homework:") {
            knownHomework.insert(homeworkKey(item.field("project") ?? "", item.title))
        }
        for task in tasks where task.source?.hasPrefix("seqta:homework:") == true {
            knownHomework.insert(homeworkKey(task.project ?? "", task.title))
        }

        var out: [InboxItem] = []
        let lastDay = today.adding(days: TodayModel.assessmentDays, calendar: calendar)
        for item in assessments.sorted(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            let source = assessmentSource(item.id)
            guard let due = DayStamp(item.due), due >= today, due <= lastDay, !item.submitted,
                  item.status.uppercased() != "MARKS_RELEASED", !known.contains(source) else { continue }
            known.insert(source)
            out.append(InboxItem(kind: kind, title: DailyNote.oneLine(item.title), source: source, created: created,
                                 fields: fields(due: item.due, project: item.subject)))
        }
        for lesson in lessons.sorted(by: { ($0.date, $0.from, $0.id) < ($1.date, $1.from, $1.id) }) {
            guard let homework = DailyNote.clean(lesson.homework), let day = DayStamp(lesson.date), day >= today else { continue }
            let source = homeworkSource(lesson.id)
            let title = DailyNote.truncate(homework, 120)
            let key = homeworkKey(lesson.subject, title)
            guard !known.contains(source), !knownHomework.contains(key) else { continue }
            known.insert(source)
            knownHomework.insert(key)
            out.append(InboxItem(kind: kind, title: title, source: source, created: created,
                                 fields: fields(due: lesson.date, project: lesson.subject)))
        }
        return out
    }

    private static func fields(due: String, project: String) -> [InboxItem.Field] {
        var out = [InboxItem.Field(key: "due", value: due)]
        if !project.isEmpty { out.append(.init(key: "project", value: DailyNote.oneLine(project))) }
        out.append(.init(key: "area", value: area))
        return out
    }

    /// `assessment:12` (the older `from::` form) and `seqta:assessment:12` are the same source.
    static func normalized(_ source: String) -> String {
        let s = source.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("assessment:") || s.hasPrefix("homework:") { return "seqta:" + s }
        return s
    }

    private static func homeworkKey(_ subject: String, _ title: String) -> String {
        DailyNote.oneLine(subject).lowercased() + "|" + DailyNote.oneLine(title).lowercased()
    }
}

/// What accepting an Inbox proposal does to the task list (PRD F4).
public enum InboxTaskActions {
    /// Fields that describe the proposal itself, not the task.
    static let reserved: Set<String> = ["task", "id", "title", "notes"]

    /// A `task.add` proposal as a new task: its title, every field (`due`, `project`, `area`, …)
    /// and `source::`.
    public static func task(from item: InboxItem) -> TaskItem {
        var task = TaskItem(title: cleanTitle(item.title))
        if let title = item.field("title"), !title.isEmpty { task.title = title }
        for field in item.fields where !reserved.contains(field.key.lowercased()) {
            task.setField(field.key, field.value)
        }
        if !item.source.isEmpty { task.setField("source", item.source) }
        if let notes = item.field("notes"), !notes.isEmpty { task.setNotes(notes) }
        return task
    }

    /// The task a `task.update` proposal changes (`[task:: t-ab12cd34]`).
    public static func target(of item: InboxItem) -> String? {
        let id = (item.field("task") ?? item.field("id"))?.trimmingCharacters(in: .whitespaces)
        guard let id, !id.isEmpty else { return nil }
        return id.hasPrefix("^") ? String(id.dropFirst()) : id
    }

    /// Applies a `task.update` proposal: `title` renames, `notes` replaces the notes, `status`
    /// `done`/`open` ticks or reopens (`cancelled` cancels), every other field is set (an empty value or
    /// `none` removes it).
    public static func apply(_ item: InboxItem, to task: inout TaskItem, today: DayStamp) {
        for field in item.fields {
            switch field.key.lowercased() {
            case "task", "id": continue
            case "title": if !field.value.isEmpty { task.title = field.value }
            case "notes": task.setNotes(field.value)
            case "status":
                switch field.value.lowercased() {
                case "done", "x": task.markDone(on: today)
                case "open", "todo": task.reopen()
                case "cancelled", "canceled": task.status = "-"
                default: break
                }
            default:
                let clears = field.value.isEmpty || field.value.lowercased() == "none"
                task.setField(field.key, clears ? nil : field.value)
            }
        }
    }

    /// "Add task: Essay" → "Essay" (titles written by agents sometimes carry the kind).
    static func cleanTitle(_ title: String) -> String {
        for prefix in ["Add task: ", "Add task:", "Task: "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return title
    }
}
