import Foundation
import Testing
@testable import AtlantisCore

// All data here is made up.

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Australia/Adelaide")!
    return c
}()

private func at(_ hour: Int, _ minute: Int, day: Int = 9) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func lesson(_ from: String, _ until: String, _ code: String, subject: String, room: String = "R1",
                    date: String = "2026-11-09", topic: String? = nil, homework: String? = nil) -> Lesson {
    Lesson(id: "\(date)T\(from)-\(code)", date: date, from: from, until: until, subject: subject, code: code,
           room: room, teacher: "Mx Teacher", colour: "#336699", topic: topic, homework: homework)
}

private func tasks(_ text: String) -> [TaskItem] { TaskFile(parsing: text).tasks }

@Suite struct TodayModelTests {
    let lessons = [
        lesson("08:55", "09:40", "SCI9", subject: "Science"),
        lesson("11:45", "12:30", "ENG9", subject: "English", topic: "Persuasive writing"),
        lesson("12:30", "13:15", "ENG9", subject: "English", homework: "Read chapter 4"),
        lesson("09:40", "10:25", "HIS9", subject: "History"),
        lesson("09:00", "09:45", "MAT9", subject: "Maths", date: "2026-11-10"),
    ]

    @Test func timelineHasTodaysClassesInOrderWithDoublePeriodsMerged() {
        let model = TodayModel.build(lessons: lessons, assessments: [], notices: [], tasks: [], now: at(10, 0), calendar: calendar)
        #expect(model.day == DayStamp("2026-11-09"))
        #expect(model.blocks.map(\.title) == ["Science", "History", "English"])
        let english = model.blocks[2]
        #expect(english.startText == "11:45" && english.endText == "13:15")
        #expect(english.lesson?.topic == "Persuasive writing" && english.lesson?.homework == "Read chapter 4")
    }

    @Test func scheduledTasksJoinTheTimeline() {
        let list = tasks("""
        - [ ] Essay plan [scheduled:: 2026-11-09T16:00] [est:: 45m] ^t-00000001
        - [ ] Anytime thing [scheduled:: 2026-11-09] ^t-00000002
        - [ ] Tomorrow [scheduled:: 2026-11-10T09:00] ^t-00000003
        - [x] Done already [scheduled:: 2026-11-09T08:00] ^t-00000004
        """)
        let model = TodayModel.build(lessons: lessons, assessments: [], notices: [], tasks: list, now: at(10, 0), calendar: calendar)
        #expect(model.blocks.map(\.title) == ["Science", "History", "English", "Essay plan"])
        #expect(model.blocks.last?.startText == "16:00" && model.blocks.last?.endText == "16:45")
        #expect(model.anytime.map(\.title) == ["Anytime thing"])
    }

    @Test func nowAndNext() {
        let model = TodayModel.build(lessons: lessons, assessments: [], notices: [], tasks: [], now: at(9, 0), calendar: calendar)
        let minute = TodayTime.minuteOfDay(at(9, 0), calendar: calendar)
        #expect(model.current(at: minute)?.title == "Science")
        #expect(model.next(after: minute)?.title == "History")
        #expect(model.current(at: TodayTime.minutes("10:40")!) == nil)
        #expect(model.next(after: TodayTime.minutes("13:20")!) == nil)
    }

    @Test func todaysTasksAreOverdueDueTodayAndPlanned() {
        let list = tasks("""
        - [ ] Late [due:: 2026-11-05] ^t-00000001
        - [ ] Due now [due:: 2026-11-09] ^t-00000002
        - [ ] Pulled in [plan:: 2026-11-09] ^t-00000003
        - [ ] Later [due:: 2026-11-12] ^t-00000004
        - [x] Finished [due:: 2026-11-09] ^t-00000005
        """)
        let model = TodayModel.build(lessons: [], assessments: [], notices: [], tasks: list, now: at(10, 0), calendar: calendar)
        #expect(model.taskSections.map(\.id) == ["overdue", "today"])
        #expect(model.taskSections[0].tasks.map(\.title) == ["Late"])
        #expect(model.taskSections[1].tasks.map(\.title) == ["Due now", "Pulled in"])
        #expect(model.openTaskCount == 3)
    }

    @Test func assessmentsInTheNext14DaysWithCountdowns() {
        let items = [
            Assessment(id: 3, title: "Far", subject: "S", code: "S", due: "2026-11-24", status: "PENDING"),
            Assessment(id: 1, title: "Today", subject: "S", code: "S", due: "2026-11-09", status: "PENDING"),
            Assessment(id: 2, title: "Soon", subject: "S", code: "S", due: "2026-11-12", status: "PENDING"),
            Assessment(id: 4, title: "Past", subject: "S", code: "S", due: "2026-11-01", status: "OVERDUE"),
            Assessment(id: 5, title: "Marked", subject: "S", code: "S", due: "2026-11-10", status: "MARKS_RELEASED"),
            Assessment(id: 6, title: "Edge", subject: "S", code: "S", due: "2026-11-23", status: "PENDING"),
        ]
        let model = TodayModel.build(lessons: [], assessments: items, notices: [], tasks: [], now: at(23, 30), calendar: calendar)
        #expect(model.assessments.map(\.assessment.title) == ["Today", "Soon", "Edge"])
        #expect(model.assessments.map(\.countdown) == ["today", "in 3 days", "in 14 days"])
    }

    @Test func onlyTodaysNotices() {
        let notices = [Notice(id: 1, date: "2026-11-09", title: "Now"), Notice(id: 2, date: "2026-11-08", title: "Old")]
        let model = TodayModel.build(lessons: [], assessments: [], notices: notices, tasks: [], now: at(8, 0), calendar: calendar)
        #expect(model.notices.map(\.title) == ["Now"])
    }

    @Test func emptyEverythingIsFine() {
        let model = TodayModel.build(lessons: [], assessments: [], notices: [], tasks: [], now: at(8, 0), calendar: calendar)
        #expect(model.blocks.isEmpty && model.taskSections.isEmpty && model.assessments.isEmpty && !model.hasClasses)
        #expect(model.next(after: 0) == nil)
    }

    @Test func countdownText() {
        #expect(Countdown.text(days: 0) == "today")
        #expect(Countdown.text(days: 1) == "tomorrow")
        #expect(Countdown.text(days: 5) == "in 5 days")
        #expect(Countdown.text(minutes: 5) == "in 5 min")
        #expect(Countdown.text(minutes: 80) == "in 1 h 20 min")
        #expect(Countdown.text(minutes: 120) == "in 2 h")
    }

    @Test func planFileListsBlocks() throws {
        let list = tasks("- [ ] Gym [scheduled:: 2026-11-09T17:00] [mode:: bjj] ^t-00000009\n")
        let model = TodayModel.build(lessons: lessons, assessments: [], notices: [], tasks: list, now: at(8, 0), calendar: calendar)
        let plan = PlanFile(model: model)
        #expect(plan.date == "2026-11-09")
        #expect(plan.blocks.map(\.kind) == ["class", "class", "class", "task"])
        #expect(plan.blocks.last?.mode == "bjj" && plan.blocks.last?.taskID == "t-00000009")
        #expect(plan.blocks.first?.mode == "school" && plan.blocks.first?.start == "08:55")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)/plan.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try plan.write(to: url))
        #expect(try !plan.write(to: url)) // same plan: no write
        let decoded = try JSONDecoder().decode(PlanFile.self, from: Data(contentsOf: url))
        #expect(decoded == plan)
    }
}

@Suite struct DailyNoteTests {
    let note = """
    ---
    type: Journal
    date: 2026-11-09
    classes: []
    assessments_due: []
    notices: []
    synced_at:
    bjj: yes
    tasks:
      - keep me
    mood: good
    ---

    # 2026-11-09

    <!-- machine:start (written by the morning sync) -->
    _Not synced yet._
    <!-- machine:end -->

    ## Top 3

    1. Finish the essay
    2.
    3. Train

    ## Notes

    My own words. classes: [] should stay.

    """

    var content: DailyNote.Content {
        DailyNote.content(
            lessons: [
                lesson("09:40", "10:25", "HIS9", subject: "History", topic: "Causes: part 2"),
                lesson("08:55", "09:40", "SCI9", subject: "Science", homework: "Lab report"),
                lesson("09:00", "09:45", "MAT9", subject: "Maths", date: "2026-11-10"),
            ],
            assessments: [Assessment(id: 7, title: "Source analysis", subject: "History", code: "HIS9", due: "2026-11-12", status: "PENDING")],
            notices: [Notice(id: 1, date: "2026-11-09", title: "Sports day", label: "Year 9", staff: "Mx Coach", contents: "Wear house\ncolours")],
            syncedAt: at(7, 0), now: at(7, 0), calendar: calendar)
    }

    /// The text outside the machine-owned parts, which must never change.
    private func userParts(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        var inFM = false
        for (index, line) in lines.enumerated() {
            if index == 0 && line == "---" { inFM = true; out.append(line); continue }
            if inFM {
                if line == "---" { inFM = false; out.append(line); continue }
                if let key = line.split(separator: ":").first, !line.hasPrefix(" "), !line.hasPrefix("-") {
                    skipping = DailyNote.machineKeys.contains(String(key))
                }
                if !skipping { out.append(line) }
                continue
            }
            if line.hasPrefix("<!-- machine:start") { skipping = true; out.append(line); continue }
            if line.hasPrefix("<!-- machine:end") { skipping = false }
            if !skipping { out.append(line) }
        }
        return out
    }

    @Test func fillsOnlyTheMachineParts() {
        let out = DailyNote.apply(content, to: note)
        #expect(userParts(out) == userParts(note))
        #expect(out.contains("""
        classes:
          - { time: "08:55-09:40", subject: Science, room: R1, teacher: Mx Teacher, homework: Lab report }
          - { time: "09:40-10:25", subject: History, room: R1, teacher: Mx Teacher, topic: "Causes: part 2" }
        assessments_due:
          - { due: 2026-11-12, title: Source analysis, subject: History, status: PENDING }
        notices:
          - { title: Sports day, label: Year 9, from: Mx Coach, summary: Wear house colours }
        synced_at: 2026-11-09T07:00:00+10:30
        bjj: yes
        """))
        #expect(out.contains("""
        <!-- machine:start (written by the morning sync) -->
        ### Classes
        - 08:55-09:40 **Science** · R1 · Mx Teacher
          - Homework: Lab report
        - 09:40-10:25 **History** · R1 · Mx Teacher: _Causes: part 2_

        ### Due in the next 14 days
        - Thu 12 Nov: Source analysis (History), in 3 days

        ### Notices
        - **Sports day** (Year 9, Mx Coach)

        _Synced from SEQTA at 07:00._
        <!-- machine:end -->
        """))
        #expect(!out.contains("—"))
    }

    @Test func secondApplyIsANoOp() {
        let once = DailyNote.apply(content, to: note)
        #expect(DailyNote.apply(content, to: once) == once)
    }

    @Test func keepsCRLFAndEverythingElseByteForByte() {
        let crlf = note.replacingOccurrences(of: "\n", with: "\r\n")
        let out = DailyNote.apply(content, to: crlf)
        #expect(!out.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(out.replacingOccurrences(of: "\r\n", with: "\n") == DailyNote.apply(content, to: note))
    }

    @Test func missingMarkersAndKeys() {
        let plain = "---\ntype: Journal\nmood: ok\n---\n\n# Day\n\n## Notes\nhi\n"
        let out = DailyNote.apply(content, to: plain)
        #expect(out.hasPrefix("---\ntype: Journal\nmood: ok\nclasses:\n"))
        #expect(out.hasSuffix("synced_at: 2026-11-09T07:00:00+10:30\n---\n\n# Day\n\n## Notes\nhi\n"))
        #expect(!out.contains("### Classes")) // no markers: the block stays out

        let noFrontMatter = "# Day\n<!-- machine:start -->\nold\n<!-- machine:end -->\nafter\n"
        let out2 = DailyNote.apply(content, to: noFrontMatter)
        #expect(out2.hasPrefix("# Day\n<!-- machine:start -->\n### Classes\n"))
        #expect(out2.hasSuffix("<!-- machine:end -->\nafter\n"))
        #expect(!out2.contains("classes:"))
    }

    @Test func emptyDay() {
        let empty = DailyNote.content(lessons: [], assessments: [], notices: [], syncedAt: at(7, 0), now: at(7, 0), calendar: calendar)
        let out = DailyNote.apply(empty, to: note)
        #expect(out.contains("classes: []\nassessments_due: []\nnotices: []\nsynced_at: 2026-11-09T07:00:00+10:30\n"))
        #expect(out.contains("_No classes today._") && out.contains("_Nothing due._") && out.contains("_No notices today._"))
    }

    @Test func yamlQuoting() {
        #expect(DailyNote.yamlScalar("Plain words") == "Plain words")
        #expect(DailyNote.yamlScalar("Ratio: 2") == "\"Ratio: 2\"")
        #expect(DailyNote.yamlScalar("\"Quoted\" title") == "\"\\\"Quoted\\\" title\"")
        #expect(DailyNote.yamlScalar("- dash") == "\"- dash\"")
        #expect(DailyNote.yamlScalar("yes") == "\"yes\"")
        #expect(DailyNote.yamlScalar("42") == "\"42\"")
        #expect(DailyNote.yamlScalar("") == "\"\"")
        #expect(DailyNote.yamlScalar("Maths, Year 9") == "\"Maths, Year 9\"")
        #expect(DailyNote.yamlScalar("Read {ch 4}") == "\"Read {ch 4}\"")
        #expect(DailyNote.yamlScalar("Q[1]") == "\"Q[1]\"")
    }

    @Test func readsTopThree() {
        #expect(DailyNote.topThree(in: note) == ["Finish the essay", "Train"])
        #expect(DailyNote.topThree(in: "## Top 3\n\n- [ ] Box item\n* Star\n## Notes\n1. not this") == ["Box item", "Star"])
        #expect(DailyNote.topThree(in: "no section") == [])
    }

    @Test func templateAndFileUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultPaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // No template: nothing is created.
        #expect(try DailyNote.update(content, vault: vault, now: at(7, 0), calendar: calendar) == .noTemplate)
        let template = root.appendingPathComponent(DailyNote.templatePath)
        try FileManager.default.createDirectory(at: template.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(note.replacingOccurrences(of: "2026-11-09", with: "{{date}}").utf8).write(to: template)

        #expect(try DailyNote.update(content, vault: vault, now: at(7, 0), calendar: calendar) == .written)
        let url = vault.daily(for: at(7, 0), calendar: calendar)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("date: 2026-11-09") && written.contains("### Classes"))
        #expect(try DailyNote.update(content, vault: vault, now: at(7, 0), calendar: calendar) == .unchanged)
        #expect(DailyNote.topThree(vault: vault, now: at(7, 0), calendar: calendar) == ["Finish the essay", "Train"])
        // The template itself is never written.
        #expect(try String(contentsOf: template, encoding: .utf8).contains("{{date}}"))

        let missing = VaultPaths(root: root.appendingPathComponent("nope"))
        #expect(try DailyNote.update(content, vault: missing, now: at(7, 0), calendar: calendar) == .noVault)
        #expect(!FileManager.default.fileExists(atPath: missing.root.path))
    }
}

@Suite struct SeqtaProposalTests {
    let assessments = [
        Assessment(id: 11, title: "Essay", subject: "History", code: "HIS9", due: "2026-11-12", status: "PENDING"),
        Assessment(id: 12, title: "Old one", subject: "History", code: "HIS9", due: "2026-11-01", status: "OVERDUE"),
        Assessment(id: 13, title: "Handed in", subject: "Science", code: "SCI9", due: "2026-11-13", status: "PENDING", submitted: true),
        Assessment(id: 14, title: "Test", subject: "Maths", code: "MAT9", due: "2026-11-20", status: "PENDING"),
    ]
    let lessons = [
        lesson("11:45", "12:30", "ENG9", subject: "English", homework: "Read chapter 4"),
        lesson("12:30", "13:15", "ENG9", subject: "English", homework: "Read chapter 4"),
        lesson("09:00", "09:45", "SCI9", subject: "Science", date: "2026-11-10", homework: "Lab report"),
        lesson("09:00", "09:45", "HIS9", subject: "History", date: "2026-11-02", homework: "Old homework"),
    ]

    @Test func proposesNewAssessmentsAndHomeworkOnce() {
        let items = SeqtaProposals.make(lessons: lessons, assessments: assessments, inbox: [], tasks: [], now: at(8, 0), calendar: calendar)
        #expect(items.map(\.source) == ["seqta:assessment:11", "seqta:assessment:14",
                                        "seqta:homework:2026-11-09T11:45-ENG9", "seqta:homework:2026-11-10T09:00-SCI9"])
        #expect(items.allSatisfy { $0.kind == "task.add" && $0.state == .pending && $0.created == "2026-11-09" })
        #expect(items[0].title == "Essay")
        #expect(items[0].fields == [.init(key: "due", value: "2026-11-12"), .init(key: "project", value: "History"),
                                    .init(key: "area", value: "School")])
        #expect(items[2].title == "Read chapter 4" && items[2].field("due") == "2026-11-09")
    }

    @Test func neverProposesAKnownSourceAgain() {
        let first = SeqtaProposals.make(lessons: lessons, assessments: assessments, inbox: [], tasks: [], now: at(8, 0), calendar: calendar)
        var inbox = first
        inbox[0].state = .dismissed
        inbox[1].state = .accepted
        #expect(SeqtaProposals.make(lessons: lessons, assessments: assessments, inbox: inbox, tasks: [], now: at(8, 0), calendar: calendar).isEmpty)

        // Existing tasks with source:: or the older from:: count too.
        let list = tasks("""
        - [ ] Essay [from:: assessment:11] ^t-00000001
        - [x] Test [source:: seqta:assessment:14] ^t-00000002
        - [ ] Read chapter 4 [project:: English] [source:: seqta:homework:2026-11-02T09:00-ENG9] ^t-00000003
        """)
        let rest = SeqtaProposals.make(lessons: lessons, assessments: assessments, inbox: [], tasks: list, now: at(8, 0), calendar: calendar)
        #expect(rest.map(\.source) == ["seqta:homework:2026-11-10T09:00-SCI9"])
    }

    @Test func acceptingMakesATask() {
        let item = InboxItem(kind: "task.add", title: "Essay", source: "seqta:assessment:11",
                             fields: [.init(key: "due", value: "2026-11-12"), .init(key: "project", value: "History"),
                                      .init(key: "area", value: "School")])
        let task = InboxTaskActions.task(from: item)
        #expect(task.title == "Essay" && task.due == DayStamp("2026-11-12") && task.project == "History" && task.area == "School")
        #expect(task.source == "seqta:assessment:11")
        var file = TaskFile(parsing: "# Tasks\n")
        _ = file.add(task, today: DayStamp("2026-11-09")!)
        #expect(file.serialized().contains("- [ ] Essay [due:: 2026-11-12] [project:: History] [area:: School] [source:: seqta:assessment:11]"))

        #expect(InboxTaskActions.task(from: InboxItem(kind: "task.add", title: "Add task: Thing")).title == "Thing")
    }

    @Test func acceptingAnUpdateChangesTheTask() throws {
        var task = try #require(tasks("- [ ] Essay [due:: 2026-11-12] [pri:: 3] ^t-00000001\n").first)
        let item = InboxItem(kind: "task.update", title: "Move the essay",
                             fields: [.init(key: "task", value: "t-00000001"), .init(key: "due", value: "2026-11-14"),
                                      .init(key: "pri", value: ""), .init(key: "est", value: "45m")])
        #expect(InboxTaskActions.target(of: item) == "t-00000001")
        InboxTaskActions.apply(item, to: &task, today: DayStamp("2026-11-09")!)
        #expect(task.due == DayStamp("2026-11-14") && task.priority == nil && task.estimateMinutes == 45)
        #expect(task.field("task") == nil)
    }
}

@MainActor
@Suite struct InboxActionsTests {
    let root: URL
    let store: TaskStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inboxactions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("machine"), withIntermediateDirectories: true)
        let vault = VaultPaths(root: root)
        try Data("# Tasks\n\n- [ ] Essay [due:: 2026-11-12] ^t-00000001\n".utf8).write(to: vault.tasks)
        store = TaskStore(vault: vault, now: { at(8, 0) }, calendar: calendar)
    }

    @Test func acceptAddsTheTaskOnce() throws {
        let item = InboxItem(kind: "task.add", title: "Test", source: "seqta:assessment:14",
                             fields: [.init(key: "due", value: "2026-11-20"), .init(key: "project", value: "Maths")])
        let actions = InboxActions(tasks: store)
        try actions.apply(item)
        try actions.apply(item) // accepting twice never makes a second task
        let added = store.tasks.filter { $0.source == "seqta:assessment:14" }
        #expect(added.count == 1)
        #expect(added.first?.title == "Test" && added.first?.project == "Maths")
        #expect(store.tasks.count == 2)
    }

    @Test func acceptAppliesAnUpdate() throws {
        let item = InboxItem(kind: "task.update", title: "Move the essay",
                             fields: [.init(key: "task", value: "t-00000001"), .init(key: "due", value: "2026-11-14")])
        try InboxActions(tasks: store).apply(item)
        #expect(store.tasks.first?.due == DayStamp("2026-11-14"))

        let missing = InboxItem(kind: "task.update", title: "Nope", fields: [.init(key: "task", value: "t-99999999")])
        #expect(throws: (any Error).self) { try InboxActions(tasks: store).apply(missing) }
    }

    @Test func otherKindsChangeNothing() throws {
        let before = try String(contentsOf: VaultPaths(root: root).tasks, encoding: .utf8)
        try InboxActions(tasks: store).apply(InboxItem(kind: "note.add", title: "Hi"))
        #expect(try String(contentsOf: VaultPaths(root: root).tasks, encoding: .utf8) == before)
    }
}
