import Foundation

/// One thing on today's timeline: a class (or a double period merged into one) or a task with a
/// `scheduled::` time today. Times are minutes since local midnight.
public struct TodayBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case lesson(Lesson)
        case task(TaskItem)
    }

    public var id: String
    public var start: Int
    public var end: Int
    public var kind: Kind

    public var title: String {
        switch kind {
        case let .lesson(lesson): lesson.subject
        case let .task(task): task.title.isEmpty ? "Untitled" : task.title
        }
    }

    public var lesson: Lesson? { if case let .lesson(l) = kind { l } else { nil } }
    public var task: TaskItem? { if case let .task(t) = kind { t } else { nil } }

    /// "08:55" style times.
    public var startText: String { TodayTime.format(start) }
    public var endText: String { TodayTime.format(end) }

    public func contains(minute: Int) -> Bool { start <= minute && minute < end }
}

/// An assessment due soon, with whole days left (0 = today).
public struct DueAssessment: Identifiable, Equatable, Sendable {
    public var assessment: Assessment
    public var day: DayStamp
    public var daysLeft: Int
    public var id: Int { assessment.id }

    /// "today", "tomorrow", "in 3 days".
    public var countdown: String { Countdown.text(days: daysLeft) }
}

/// Everything the Today screen shows (PRD F1), built from the SEQTA cache, the task list and
/// the daily note. Pure: the page, `plan.json` and the tests all build it the same way.
public struct TodayModel: Equatable, Sendable {
    public var day: DayStamp
    /// Classes and timed scheduled tasks, by start time.
    public var blocks: [TodayBlock]
    /// Tasks scheduled today with no time.
    public var anytime: [TaskItem]
    /// Overdue and today's tasks (due today or earlier, or `plan::`/`scheduled::` today).
    public var taskSections: [TaskSection]
    /// Due today up to 14 days ahead, soonest first.
    public var assessments: [DueAssessment]
    /// Today's notices.
    public var notices: [Notice]
    /// From the daily note's `## Top 3` (read-only).
    public var topThree: [String]

    public static let assessmentDays = 14
    /// A scheduled task with no estimate takes this long on the timeline.
    public static let defaultTaskMinutes = 30

    public var hasClasses: Bool { blocks.contains { $0.lesson != nil } }
    public var openTaskCount: Int { taskSections.reduce(0) { $0 + $1.tasks.count } }

    /// The block happening at `minute`, if any.
    public func current(at minute: Int) -> TodayBlock? {
        blocks.last { $0.contains(minute: minute) }
    }

    /// The next block that starts after `minute`.
    public func next(after minute: Int) -> TodayBlock? {
        blocks.first { $0.start > minute }
    }

    public static func build(lessons: [Lesson], assessments: [Assessment], notices: [Notice], tasks: [TaskItem],
                             topThree: [String] = [], now: Date, calendar: Calendar = .current) -> TodayModel {
        let today = DayStamp(now, calendar: calendar)
        let todayText = today.description

        // Classes today, with back-to-back periods of the same class shown as one block.
        let todays = lessons.filter { $0.date == todayText }
            .compactMap { lesson -> (Lesson, Int, Int)? in
                guard let start = TodayTime.minutes(lesson.from), let end = TodayTime.minutes(lesson.until) else { return nil }
                return (lesson, start, max(end, start))
            }
            .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
        var blocks: [TodayBlock] = []
        for (lesson, start, end) in todays {
            if let last = blocks.last, case var .lesson(previous) = last.kind,
               previous.code == lesson.code, previous.room == lesson.room, last.end == start {
                previous.until = lesson.until
                previous.topic = previous.topic ?? lesson.topic
                previous.homework = previous.homework ?? lesson.homework
                blocks[blocks.count - 1].end = end
                blocks[blocks.count - 1].kind = .lesson(previous)
                continue
            }
            blocks.append(TodayBlock(id: "lesson:" + lesson.id, start: start, end: end, kind: .lesson(lesson)))
        }

        // Tasks with `scheduled::` today: timed ones on the timeline, the rest as "anytime".
        var anytime: [TaskItem] = []
        for task in tasks where task.isOpen && task.scheduledDay == today {
            guard let start = task.field("scheduled").flatMap(TodayTime.minutes(afterT:)) else {
                anytime.append(task)
                continue
            }
            let end = min(start + (task.estimateMinutes ?? defaultTaskMinutes), 24 * 60)
            blocks.append(TodayBlock(id: "task:" + task.id, start: start, end: end, kind: .task(task)))
        }
        blocks.sort { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }

        let lastDay = today.adding(days: assessmentDays, calendar: calendar)
        let due = assessments.compactMap { item -> DueAssessment? in
            guard let day = DayStamp(item.due), day >= today, day <= lastDay,
                  item.status.uppercased() != "MARKS_RELEASED" else { return nil }
            return DueAssessment(assessment: item, day: day, daysLeft: today.days(until: day, calendar: calendar))
        }
        .sorted { ($0.day, $0.assessment.id) < ($1.day, $1.assessment.id) }

        return TodayModel(
            day: today,
            blocks: blocks,
            anytime: anytime,
            taskSections: TaskLists.sections(.today, tasks: tasks, today: today, calendar: calendar),
            assessments: due,
            notices: notices.filter { $0.date == todayText },
            topThree: topThree
        )
    }
}

/// "HH:mm" ⇄ minutes since midnight.
public enum TodayTime {
    public static func minutes(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)),
              (0...24).contains(h), (0...59).contains(m) else { return nil }
        return min(h * 60 + m, 24 * 60)
    }

    /// The time in a `2026-11-04T16:00` value, or nil if it has none.
    public static func minutes(afterT value: String) -> Int? {
        guard let t = value.firstIndex(where: { $0 == "T" || $0 == " " }) else { return nil }
        return minutes(String(value[value.index(after: t)...]))
    }

    public static func format(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Minutes since local midnight for an instant.
    public static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

public enum Countdown {
    /// "today", "tomorrow", "in 3 days", "1 day ago", "3 days ago".
    public static func text(days: Int) -> String {
        switch days {
        case 0: "today"
        case 1: "tomorrow"
        case -1: "yesterday"
        case ..<0: "\(-days) days ago"
        default: "in \(days) days"
        }
    }

    /// "in 5 min", "in 1 h 20 min".
    public static func text(minutes: Int) -> String {
        if minutes < 60 { return "in \(max(minutes, 0)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }
}
