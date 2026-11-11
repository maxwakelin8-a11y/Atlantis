import Foundation

// MARK: - Day plan (PRD F6 "Plan your day")

/// Today's planned task time against the free time left (PRD F6: warn when estimates exceed it).
///
/// Free time is from `minute` (now) to `dayEnd`, minus classes on Today's timeline. Planned time is
/// the estimates of today's open tasks (due today or overdue, pulled in, or scheduled today); a task
/// with no estimate counts as `TodayModel.defaultTaskMinutes`.
public struct DayPlan: Equatable, Sendable {
    public var freeMinutes: Int
    public var plannedMinutes: Int
    public var taskCount: Int
    /// Tasks counted at the default length because they have no estimate.
    public var unestimated: Int

    /// The plan stops here (21:30): the evening is for rest, not more tasks.
    public static let dayEnd = 21 * 60 + 30

    public var overBy: Int { max(0, plannedMinutes - freeMinutes) }
    public var isOver: Bool { overBy > 0 }

    public static func build(_ model: TodayModel, minute: Int, dayEnd: Int = DayPlan.dayEnd) -> DayPlan {
        let start = min(max(minute, 0), dayEnd)
        // Classes clipped to the window, merged so overlaps count once.
        let classes = model.blocks.filter { $0.lesson != nil }
            .map { (max($0.start, start), min($0.end, dayEnd)) }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }
        var busy = 0
        var cursor = start
        for (from, to) in classes {
            let a = max(from, cursor)
            if to > a { busy += to - a; cursor = to }
        }
        let free = max(0, dayEnd - start - busy)

        var seen = Set<String>()
        var tasks: [TaskItem] = []
        let all = model.taskSections.flatMap(\.tasks) + model.anytime + model.blocks.compactMap(\.task)
        for task in all where task.isOpen && seen.insert(task.id).inserted { tasks.append(task) }
        let planned = tasks.reduce(0) { $0 + ($1.estimateMinutes ?? TodayModel.defaultTaskMinutes) }
        return DayPlan(freeMinutes: free, plannedMinutes: planned, taskCount: tasks.count,
                       unestimated: tasks.filter { $0.estimateMinutes == nil }.count)
    }

    /// "Tasks need 3 h 10 min; you have 2 h free" style, for Today and the bot's prompt.
    public var summary: String {
        let need = Self.duration(plannedMinutes), have = Self.duration(freeMinutes)
        if taskCount == 0 { return "No tasks planned today; \(have) free." }
        if isOver { return "Today's \(taskCount) task\(taskCount == 1 ? "" : "s") need about \(need), but you have \(have) free (\(Self.duration(overBy)) over)." }
        return "Today's \(taskCount) task\(taskCount == 1 ? "" : "s") need about \(need); you have \(have) free."
    }

    /// "1 h 20 min", "45 min".
    public static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

// MARK: - Morning

/// The morning run's prompt: "plan your day" for a bot with `schedule morning`, plus the overdue
/// list for a bot with `event task.overdue` (one run per bot, all overdue tasks together).
public enum MorningJob {
    public static func origin(day: DayStamp) -> String { "morning:\(day)" }

    public static func isMorning(origin: String, day: DayStamp) -> Bool { origin == Self.origin(day: day) }

    public static func title(day: DayStamp) -> String { "Morning plan · \(day)" }

    public static func prompt(bot: BotDefinition, model: TodayModel, plan: DayPlan, overdue: [TaskItem],
                              minute: Int) -> String {
        let plans = bot.runsInMorning
        let overdueToo = bot.subscribes(to: .taskOverdue) && !overdue.isEmpty
        var data: [String] = ["date: \(model.day)", "now: \(TodayTime.format(minute))"]
        data.append("classes:")
        let classes = model.blocks.compactMap { block -> String? in
            guard let lesson = block.lesson else { return nil }
            return "  - \(block.startText)-\(block.endText) \(lesson.subject)"
        }
        data += classes.isEmpty ? ["  (none today)"] : classes
        data.append("free time left today (until \(TodayTime.format(DayPlan.dayEnd)), between classes): \(DayPlan.duration(plan.freeMinutes))")
        data.append("tasks for today:")
        let today = model.taskSections.flatMap(\.tasks) + model.anytime
        data += today.isEmpty ? ["  (none)"] : today.prefix(30).map(line)
        data.append("planned: \(DayPlan.duration(plan.plannedMinutes))" + (plan.unestimated > 0 ? " (\(plan.unestimated) without an estimate counted as \(TodayModel.defaultTaskMinutes) min)" : ""))
        if plan.isOver { data.append("warning: the plan is \(DayPlan.duration(plan.overBy)) more than the free time") }
        if !model.assessments.isEmpty {
            data.append("assessments due soon:")
            data += model.assessments.prefix(10).map { "  - \($0.assessment.title) (\($0.assessment.subject)), due \($0.day), \($0.countdown)" }
        }
        if overdueToo {
            data.append("overdue tasks (\(overdue.count)):")
            data += overdue.prefix(40).map(line)
        }

        var asks: [String] = []
        if plans {
            asks.append("Plan the user's day: pick at most three tasks that matter most today and say when they fit around classes. If the planned time is more than the free time, say so plainly and suggest what to move. Propose changes (a due date, a smaller first step) with your task tools; they go to the Inbox for the user to accept.")
        }
        if overdueToo {
            asks.append("Some tasks are overdue. For each, suggest one: do it today, move it to a realistic day, or drop it. Propose the changes with your task tools in one go.")
        }
        return """
        It's the morning of \(model.day) and Atlantis started you on your own (no one is waiting for a chat reply). \
        \(asks.joined(separator: " ")) Your final reply is posted to the user's Inbox as their morning note, so start \
        with a one-line summary, then at most five short lines. Don't post a separate Inbox note.

        \(UntrustedText.wrap(data.joined(separator: "\n"), source: "today"))
        """
    }

    static func line(_ task: TaskItem) -> String {
        var parts = ["  - [\(task.id)] \(task.title)"]
        if let due = task.due { parts.append("due \(due)") }
        if let estimate = task.estimateMinutes { parts.append(Estimate.format(estimate)) }
        if let project = task.project { parts.append(project) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - New assessments

/// `event seqta.assessment.new`: an assessment Atlantis hasn't seen before.
public enum AssessmentJob {
    /// Its id, or nil, for each `task.add` proposal `SeqtaProposals.make` returned: those are the
    /// assessments seen for the first time (the same dedupe as the Inbox, so once ever).
    public static func newAssessments(proposals: [InboxItem], assessments: [Assessment]) -> [Assessment] {
        let ids = proposals.compactMap { item -> Int? in
            guard item.source.hasPrefix("seqta:assessment:") else { return nil }
            return Int(item.source.dropFirst("seqta:assessment:".count))
        }
        return ids.compactMap { id in assessments.first { $0.id == id } }
    }

    /// The same as the assessment's Inbox source, so the run's proposals link to it.
    public static func origin(_ assessment: Assessment) -> String { SeqtaProposals.assessmentSource(assessment.id) }

    public static func title(_ assessment: Assessment) -> String {
        ThreadLog.title(from: "New: " + DailyNote.oneLine(assessment.title))
    }

    public static func prompt(_ assessment: Assessment, today: DayStamp) -> String {
        var lines = ["id: \(assessment.id)", "title: \(DailyNote.oneLine(assessment.title))",
                     "subject: \(assessment.subject)", "due: \(assessment.due)", "status: \(assessment.status)"]
        if let details = DailyNote.clean(assessment.details) {
            lines.append("details:")
            lines += String(details.prefix(6_000)).split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }
        }
        return """
        A new assessment just appeared in SEQTA (today is \(today)) and Atlantis started you on your own. Break it into \
        3 to 6 steps the user can do, each 25 to 45 minutes, with a due date for each step before the real due date. \
        Propose each step with atlantis_task_add (project: the subject, area: School), or atlantis_inbox_post if you \
        don't have it; they go to the Inbox and are \
        linked to this assessment. Your final reply is posted to the Inbox as a note: one line on what the \
        assessment is, then the plan in short lines.

        \(UntrustedText.wrap(lines.joined(separator: "\n"), source: "assessment"))
        """
    }
}

// MARK: - Overdue

public enum OverdueJob {
    /// Every open task due before today, oldest first. One run gets them all.
    public static func overdue(_ tasks: [TaskItem], today: DayStamp) -> [TaskItem] {
        tasks.filter { $0.isOpen && ($0.due.map { $0 < today } ?? false) }
            .sorted { ($0.due?.description ?? "", $0.title) < ($1.due?.description ?? "", $1.title) }
    }
}

// MARK: - Today's Team card

/// What Today's "Team" card shows (M7): today's bot runs, approvals waiting, and the morning note.
/// Pure: the page builds it from the stores it already observes.
public struct TeamCard: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case queued
        case running
        case waitingForApproval
        case done
        case failed(String)
        case skipped(String)
    }

    public struct Run: Equatable, Sendable, Identifiable {
        public var id: String
        public var bot: String
        public var avatar: String
        public var botName: String
        public var title: String
        /// "Morning", "New assessment", "Chat", "From Chief".
        public var trigger: String
        public var status: Status
        public var at: Date
        /// Open it on the Agents page (nil while queued or skipped).
        public var threadID: String?
    }

    public struct Note: Equatable, Sendable {
        public var inboxID: String
        public var bot: String
        public var lines: [String]
    }

    /// A run in progress, as the app knows it.
    public struct Live: Equatable, Sendable {
        public var threadID: String
        public var bot: String
        public var waiting: Bool
        public init(threadID: String, bot: String, waiting: Bool) {
            self.threadID = threadID
            self.bot = bot
            self.waiting = waiting
        }
    }

    public var runs: [Run]
    /// Bot proposals waiting in the Inbox (each `ask` approval is one of these too).
    public var pendingApprovals: Int
    public var morning: Note?
    public var automaticRuns: Bool

    public var isEmpty: Bool { runs.isEmpty && pendingApprovals == 0 && morning == nil }

    public static let maxRuns = 6

    public static func build(threads: [ThreadSummary], live: [Live], queued: [QueuedRun], skipped: [SkippedRun],
                             bots: [BotDefinition], inbox: [InboxItem], day: DayStamp, automaticRuns: Bool,
                             calendar: Calendar = .current) -> TeamCard {
        func bot(_ id: String) -> BotDefinition? { bots.first { $0.id == id } }
        func name(_ id: String) -> String { bot(id)?.name ?? id.capitalized }
        func avatar(_ id: String) -> String { bot(id)?.avatar ?? "🤖" }

        var runs: [Run] = []
        for thread in threads where DayStamp(thread.created, calendar: calendar) == day {
            let liveRun = live.first { $0.threadID == thread.id }
            let status: Status
            if let liveRun { status = liveRun.waiting ? .waitingForApproval : .running }
            else {
                switch thread.status {
                case nil: status = .running // just started; its reply isn't written yet
                case .ok?: status = .done
                case .stopped?: status = .failed("Stopped")
                case .stepLimit?: status = .failed("Step limit")
                case .costLimit?: status = .failed("Cost cap")
                case .refused?: status = .failed("Refused")
                case .failed?: status = .failed("Failed")
                }
            }
            runs.append(Run(id: "thread:" + thread.id, bot: thread.bot, avatar: avatar(thread.bot), botName: name(thread.bot),
                            title: thread.title, trigger: (thread.trigger ?? .chat).label(botName: name),
                            status: status, at: thread.created, threadID: thread.id))
        }
        for item in queued {
            runs.append(Run(id: "queued:" + item.id, bot: item.bot, avatar: avatar(item.bot), botName: name(item.bot),
                            title: item.title, trigger: item.trigger.label(botName: name), status: .queued,
                            at: item.queuedAt, threadID: nil))
        }
        for item in skipped where DayStamp(item.at, calendar: calendar) == day {
            runs.append(Run(id: "skipped:" + item.id, bot: item.bot, avatar: avatar(item.bot), botName: name(item.bot),
                            title: item.title, trigger: item.trigger.label(botName: name), status: .skipped(item.reason),
                            at: item.at, threadID: nil))
        }
        // Waiting first (queued at the end of the day's list reads oddly), then newest first.
        runs.sort { a, b in
            let pa = a.status == .queued ? 1 : 0, pb = b.status == .queued ? 1 : 0
            if pa != pb { return pa < pb }
            return a.at > b.at
        }

        let pending = inbox.filter { $0.state == .pending && $0.source.hasPrefix("agent:") && $0.kind != "note" }.count
        let origin = MorningJob.origin(day: day)
        let morning = inbox.last { $0.kind == "note" && $0.source.hasPrefix("agent:") && AgentOrigin.of($0) == origin
            && !AgentResultNote.failed($0) }.map { item -> Note in
            let body = InboxText.decode(item.field("body") ?? "")
            let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.prefix(3).map { String($0.prefix(200)) }
            return Note(inboxID: item.id, bot: String(item.source.dropFirst("agent:".count)), lines: Array(lines))
        }
        return TeamCard(runs: Array(runs.prefix(maxRuns)), pendingApprovals: pending, morning: morning,
                        automaticRuns: automaticRuns)
    }
}

// MARK: - End of day (PRD F6 "Shutdown")

/// What the End of day sheet does with one of today's open tasks.
public enum ShutdownChoice: String, CaseIterable, Sendable {
    case keep, done, tomorrow, drop

    public var label: String {
        switch self {
        case .keep: "Keep"
        case .done: "Done"
        case .tomorrow: "Tomorrow"
        case .drop: "Drop"
        }
    }
}

public enum Shutdown {
    /// Moves a task to tomorrow: `due` becomes tomorrow, and a `plan::` or `scheduled::` for today or
    /// earlier is cleared (it was for today). Other fields stay.
    public static func moveToTomorrow(_ task: inout TaskItem, today: DayStamp, calendar: Calendar = .current) {
        task.due = today.adding(days: 1, calendar: calendar)
        if let plan = task.plan, plan <= today { task.plan = nil }
        if let scheduled = task.scheduledDay, scheduled <= today { task.setField("scheduled", nil) }
    }

    /// Drops a task: cancelled (`- [-]`), kept in the file.
    public static func drop(_ task: inout TaskItem) { task.status = "-" }

    /// Today's open tasks for the End of day sheet: overdue and today's (the Today lists), then
    /// the ones scheduled today, each once, in that order.
    public static func openTasks(_ model: TodayModel) -> [TaskItem] {
        var seen = Set<String>()
        let all = model.taskSections.flatMap(\.tasks) + model.blocks.compactMap(\.task) + model.anytime
        return all.filter { $0.isOpen && seen.insert($0.id).inserted }
    }

    public struct Tally: Equatable, Sendable {
        public var done = 0, moved = 0, dropped = 0, kept = 0
        public init() {}
    }

    /// How many tasks got each choice (tasks without a choice are kept).
    public static func tally(_ tasks: [TaskItem], choices: [String: ShutdownChoice]) -> Tally {
        var tally = Tally()
        for task in tasks {
            switch choices[task.id] ?? .keep {
            case .keep: tally.kept += 1
            case .done: tally.done += 1
            case .tomorrow: tally.moved += 1
            case .drop: tally.dropped += 1
            }
        }
        return tally
    }

    /// The line for the daily note: "17:42 · 3 done, 2 moved to tomorrow, 1 dropped, 1 left open".
    public static func line(time: String, done: Int, moved: Int, dropped: Int, kept: Int) -> String {
        var parts: [String] = []
        if done > 0 { parts.append("\(done) done") }
        if moved > 0 { parts.append("\(moved) moved to tomorrow") }
        if dropped > 0 { parts.append("\(dropped) dropped") }
        if kept > 0 { parts.append("\(kept) left open") }
        return "\(time) · " + (parts.isEmpty ? "nothing left for today" : parts.joined(separator: ", "))
    }
}
