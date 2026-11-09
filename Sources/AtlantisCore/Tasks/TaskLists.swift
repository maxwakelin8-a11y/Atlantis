import Foundation

/// The views of the Tasks page (PRD F2).
public enum TaskListKind: String, CaseIterable, Identifiable, Sendable {
    case today, upcoming, project, area, done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .project: "Project"
        case .area: "Area"
        case .done: "Done"
        }
    }
}

public struct TaskSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var tasks: [TaskItem]
    /// The "Overdue" group is drawn in the warning colour.
    public var isOverdue = false
}

/// Turns the flat task list into the sections each view shows. Pure, so it is tested without UI.
public enum TaskLists {
    public static func sections(
        _ kind: TaskListKind,
        tasks: [TaskItem],
        today: DayStamp,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [TaskSection] {
        switch kind {
        case .today: todaySections(tasks, today: today)
        case .upcoming: upcomingSections(tasks, today: today, calendar: calendar, locale: locale)
        case .project: grouped(tasks.filter(\.isOpen), by: \.project, none: "No project")
        case .area: grouped(tasks.filter(\.isOpen), by: \.group, none: "No area")
        case .done: doneSections(tasks, today: today, calendar: calendar, locale: locale)
        }
    }

    /// Priority 1 first, then earlier due dates, then file order.
    static func sorted(_ tasks: [TaskItem]) -> [TaskItem] {
        let indexed = tasks.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            let (px, py) = (x.priority ?? 4, y.priority ?? 4)
            if px != py { return px < py }
            if x.due != y.due { return (x.due ?? .distantFuture) < (y.due ?? .distantFuture) }
            return a.offset < b.offset
        }
        return indexed.map(\.element)
    }

    /// Earlier due dates first, then priority, then file order.
    static func sortedByDue(_ tasks: [TaskItem]) -> [TaskItem] {
        let indexed = tasks.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.due != y.due { return (x.due ?? .distantFuture) < (y.due ?? .distantFuture) }
            let (px, py) = (x.priority ?? 4, y.priority ?? 4)
            if px != py { return px < py }
            return a.offset < b.offset
        }
        return indexed.map(\.element)
    }

    static func todaySections(_ tasks: [TaskItem], today: DayStamp) -> [TaskSection] {
        let open = tasks.filter(\.isOpen)
        let overdue = open.filter { $0.due.map { $0 < today } ?? false }
        let now = open.filter { task in
            if task.due == today { return true }
            if let due = task.due, due < today { return false }
            return task.plan == today || task.scheduledDay == today
        }
        return [
            TaskSection(id: "overdue", title: "Overdue", tasks: sortedByDue(overdue), isOverdue: true),
            TaskSection(id: "today", title: "Today", tasks: sorted(now)),
        ].filter { !$0.tasks.isEmpty }
    }

    static func upcomingSections(_ tasks: [TaskItem], today: DayStamp, calendar: Calendar, locale: Locale) -> [TaskSection] {
        let open = tasks.filter(\.isOpen)
        var byDay: [DayStamp: [TaskItem]] = [:]
        for task in open { if let due = task.due, due > today { byDay[due, default: []].append(task) } }
        var out = byDay.keys.sorted().map { day in
            TaskSection(id: day.description, title: DayLabel.title(for: day, today: today, calendar: calendar, locale: locale),
                        tasks: sorted(byDay[day]!))
        }
        let undated = open.filter { task in
            task.due == nil && task.plan != today && task.scheduledDay != today
        }
        if !undated.isEmpty { out.append(TaskSection(id: "undated", title: "No date", tasks: sorted(undated))) }
        return out
    }

    static func grouped(_ tasks: [TaskItem], by key: KeyPath<TaskItem, String?>, none: String) -> [TaskSection] {
        var order: [String] = []
        var names: [String: String] = [:]
        var buckets: [String: [TaskItem]] = [:]
        var rest: [TaskItem] = []
        for task in tasks {
            guard let name = task[keyPath: key]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { rest.append(task); continue }
            let k = name.lowercased()
            if names[k] == nil { names[k] = name; order.append(k) }
            buckets[k, default: []].append(task)
        }
        var out = order.sorted { names[$0]!.localizedCaseInsensitiveCompare(names[$1]!) == .orderedAscending }
            .map { TaskSection(id: "g-\($0)", title: names[$0]!, tasks: sortedByDue(buckets[$0]!)) }
        if !rest.isEmpty { out.append(TaskSection(id: "g-none", title: none, tasks: sortedByDue(rest))) }
        return out
    }

    static func doneSections(_ tasks: [TaskItem], today: DayStamp, calendar: Calendar, locale: Locale) -> [TaskSection] {
        let closed = tasks.filter { !$0.isOpen }
        var byDay: [DayStamp: [TaskItem]] = [:]
        var earlier: [TaskItem] = []
        for task in closed {
            if let day = task.doneDate { byDay[day, default: []].append(task) } else { earlier.append(task) }
        }
        var out = byDay.keys.sorted(by: >).map { day in
            TaskSection(id: day.description, title: DayLabel.title(for: day, today: today, calendar: calendar, locale: locale),
                        tasks: byDay[day]!)
        }
        if !earlier.isEmpty { out.append(TaskSection(id: "earlier", title: "Earlier", tasks: earlier)) }
        return out
    }
}

/// Short, friendly names for days ("Today", "Tomorrow", "Thursday", "12 Nov").
public enum DayLabel {
    public static func title(for day: DayStamp, today: DayStamp, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let delta = today.days(until: day, calendar: calendar)
        switch delta {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: break
        }
        guard let date = day.date(calendar: calendar) else { return day.description }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if (2...6).contains(delta) { formatter.setLocalizedDateFormatFromTemplate("EEEE") }
        else if day.year == today.year { formatter.setLocalizedDateFormatFromTemplate("EEE d MMM") }
        else { formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy") }
        return formatter.string(from: date)
    }

    /// For the small due pill on a row: "Today", "Tomorrow", "Thu", "12 Nov".
    public static func short(for day: DayStamp, today: DayStamp, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let delta = today.days(until: day, calendar: calendar)
        switch delta {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: break
        }
        guard let date = day.date(calendar: calendar) else { return day.description }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if (2...6).contains(delta) { formatter.setLocalizedDateFormatFromTemplate("EEE") }
        else if day.year == today.year { formatter.setLocalizedDateFormatFromTemplate("d MMM") }
        else { formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy") }
        return formatter.string(from: date)
    }
}

extension DayStamp {
    static let distantFuture = DayStamp(year: 9999, month: 12, day: 31)
}
