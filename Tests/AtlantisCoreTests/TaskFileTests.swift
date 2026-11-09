import Foundation
import Testing
@testable import AtlantisCore

@Suite struct TaskFileTests {
    static let sample = """
    # Tasks

    Kept by something. Edit freely in Obsidian: one task per line, `[due:: YYYY-MM-DD]`. The `^t-…` at the end is the id.
    - [x] Donkey [due:: 2026-11-04] [project:: life-os] [added:: 2026-11-03] [done:: 2026-11-04] ^t-17aad059
    - [ ] Causes of WWI Essay [due:: 2026-11-10] [plan:: 2026-11-06] [project:: History] [area:: School] [from:: assessment:15206] [added:: 2026-11-05] ^t-f286e995
    - [ ] Turing draft [due:: 2026-11-12] [est:: 45m] [pri:: 1] [mode:: school] [custom:: keep me] ^t-aaaaaaaa
      - [ ] outline
      - [x] research
      A note under the task
    - [ ] No id yet [due:: 2026-11-13]
    - [ ] Café ☕ 日本語 [project:: ünï] ^t-bbbbbbbb

    Some trailing text.

    """

    // MARK: round trip

    @Test func unchangedFileRoundTripsExactly() {
        #expect(TaskFile(parsing: Self.sample).serialized() == Self.sample)
    }

    @Test(arguments: [
        "",
        "\n",
        "# Tasks",
        "- [ ] a",
        "- [ ] a\n",
        "- [ ] a\r\n- [x] b [due:: 2026-01-01] ^t-12345678\r\n",
        "- [ ] a\r\n- [x] b",
        "no tasks here\n\nat all\n",
        "  - [ ] orphan indent\n- [ ] real\n",
        "- [ ]   spaced   [due::2026-01-01]   [k:: v]  ^t-1234abcd   \n",
        "\u{FEFF}# BOM\n- [ ] a\n",
        "```\n- [ ] inside fence\n```\n- [ ] outside\n",
        "- [ ] a\n\n\n- [ ] b\n",
        "* [ ] star\n+ [X] plus\n- [-] cancelled\n",
        "- [ ] a\r- [ ] lone CR stays text\n",
    ])
    func oddFilesRoundTrip(text: String) {
        #expect(TaskFile(parsing: text).serialized() == text)
    }

    // MARK: parsing

    @Test func parsesTheRealFormat() throws {
        let file = TaskFile(parsing: Self.sample)
        let tasks = file.tasks
        #expect(tasks.count == 5)
        let donkey = tasks[0]
        #expect(donkey.title == "Donkey")
        #expect(donkey.isDone)
        #expect(donkey.due == DayStamp(year: 2026, month: 11, day: 4))
        #expect(donkey.doneDate == DayStamp(year: 2026, month: 11, day: 4))
        #expect(donkey.project == "life-os")
        #expect(donkey.id == "t-17aad059")

        let essay = tasks[1]
        #expect(essay.isOpen)
        #expect(essay.area == "School")
        #expect(essay.group == "School")
        #expect(essay.plan == DayStamp(year: 2026, month: 11, day: 6))
        #expect(essay.source == "assessment:15206")

        let turing = tasks[2]
        #expect(turing.estimateMinutes == 45)
        #expect(turing.priority == 1)
        #expect(turing.mode == "school")
        #expect(turing.field("custom") == "keep me")
        #expect(turing.subtasks == [Subtask(id: 0, isDone: false, title: "outline"), Subtask(id: 1, isDone: true, title: "research")])
        #expect(turing.notes == "A note under the task")

        #expect(tasks[3].blockID == nil)
        #expect(tasks[3].id.hasPrefix("~"))
        #expect(tasks[4].title == "Café ☕ 日本語")
        #expect(tasks[4].project == "ünï")
    }

    @Test func linesThatAreNotTasksStayOther() {
        let file = TaskFile(parsing: "# Tasks\n\n- plain bullet\n- [ ]no space\n[ ] no dash\n")
        #expect(file.tasks.isEmpty)
    }

    @Test func titleWithBracketsAndLinksIsNotAField() {
        let file = TaskFile(parsing: "- [ ] Read [[Some Note]] and [link](x) [due:: 2026-01-02]\n")
        #expect(file.tasks[0].title == "Read [[Some Note]] and [link](x)")
        #expect(file.tasks[0].due == DayStamp(year: 2026, month: 1, day: 2))
    }

    @Test func idLessDuplicatesGetDistinctIds() {
        let file = TaskFile(parsing: "- [ ] same\n- [ ] same\n")
        let ids = file.tasks.map(\.id)
        #expect(Set(ids).count == 2)
    }

    @Test func fieldsAfterTextAreKept() {
        let text = "- [ ] Title [due:: 2026-01-02] trailing words [x:: y] ^t-00000001\n"
        var file = TaskFile(parsing: text)
        file.update(id: "t-00000001") { $0.priority = 2 }
        #expect(file.serialized() == "- [ ] Title [due:: 2026-01-02] trailing words [x:: y] [pri:: 2] ^t-00000001\n")
    }

    // MARK: edits

    @Test func editingRewritesOnlyThatLine() {
        var file = TaskFile(parsing: Self.sample)
        let id = file.update(id: "t-aaaaaaaa") { task in
            task.title = "Turing final draft"
            task.due = DayStamp(year: 2026, month: 11, day: 14)
            task.setField("pri", nil)
        }
        #expect(id == "t-aaaaaaaa")
        let expected = Self.sample.replacingOccurrences(
            of: "- [ ] Turing draft [due:: 2026-11-12] [est:: 45m] [pri:: 1] [mode:: school] [custom:: keep me] ^t-aaaaaaaa",
            with: "- [ ] Turing final draft [due:: 2026-11-14] [est:: 45m] [mode:: school] [custom:: keep me] ^t-aaaaaaaa")
        #expect(file.serialized() == expected)
    }

    @Test func settingAFieldToItsOldValueDoesNotRewrite() {
        var file = TaskFile(parsing: "- [ ] a  [due::2026-01-02]   ^t-00000001\n")
        file.update(id: "t-00000001") { $0.due = DayStamp(year: 2026, month: 1, day: 2); $0.title = "a" }
        // The value is the same, so the odd spacing of the original line stays.
        #expect(file.serialized() == "- [ ] a  [due::2026-01-02]   ^t-00000001\n")
    }

    @Test func completingAddsDoneDateAndKeepsOrder() {
        var file = TaskFile(parsing: Self.sample)
        let day = DayStamp(year: 2026, month: 11, day: 9)
        file.update(id: "t-f286e995") { $0.markDone(on: day) }
        let line = file.serialized().split(separator: "\n").first { $0.contains("t-f286e995") }!
        #expect(line == "- [x] Causes of WWI Essay [due:: 2026-11-10] [plan:: 2026-11-06] [project:: History] [area:: School] [from:: assessment:15206] [added:: 2026-11-05] [done:: 2026-11-09] ^t-f286e995")
        file.update(id: "t-f286e995") { $0.reopen() }
        #expect(file.serialized() == Self.sample.replacingOccurrences(of: "- [ ] Causes", with: "- [ ] Causes"))
    }

    @Test func editingAnIdLessTaskGivesItAnId() throws {
        var file = TaskFile(parsing: Self.sample)
        let oldID = file.tasks[3].id
        let newID = try #require(file.update(id: oldID) { $0.priority = 3 })
        #expect(newID.hasPrefix("t-"))
        #expect(newID.count == 10)
        #expect(file.task(id: newID)?.priority == 3)
        #expect(file.serialized().contains("- [ ] No id yet [due:: 2026-11-13] [pri:: 3] ^\(newID)\n"))
    }

    @Test func updatingAMissingTaskDoesNothing() {
        var file = TaskFile(parsing: Self.sample)
        let result = file.update(id: "t-ffffffff") { $0.title = "x" }
        #expect(result == nil)
        #expect(file.serialized() == Self.sample)
    }

    @Test func subtasksAndNotesSurviveEditsToTheTask() {
        var file = TaskFile(parsing: Self.sample)
        file.update(id: "t-aaaaaaaa") { $0.title = "Renamed" }
        #expect(file.serialized().contains("  - [ ] outline\n  - [x] research\n  A note under the task\n"))
        file.update(id: "t-aaaaaaaa") { $0.toggleSubtask(0) }
        #expect(file.serialized().contains("  - [x] outline\n  - [x] research\n"))
        file.update(id: "t-aaaaaaaa") { $0.addSubtask("write intro") }
        #expect(file.serialized().contains("  A note under the task\n  - [ ] write intro\n- [ ] No id yet"))
        file.update(id: "t-aaaaaaaa") { $0.setNotes("one\n\ntwo") }
        #expect(file.serialized().contains("^t-aaaaaaaa\n  one\n  two\n  - [x] outline\n"))
        file.update(id: "t-aaaaaaaa") { $0.setNotes("") }
        #expect(file.task(id: "t-aaaaaaaa")?.notes == "")
        #expect(file.task(id: "t-aaaaaaaa")?.subtasks.count == 3)
    }

    @Test func removeTakesTheContinuationLinesToo() {
        var file = TaskFile(parsing: Self.sample)
        let removed = file.remove(id: "t-aaaaaaaa")
        #expect(removed)
        #expect(!file.serialized().contains("outline"))
        #expect(!file.serialized().contains("Turing"))
        #expect(file.serialized().contains("No id yet"))
        let again = file.remove(id: "t-aaaaaaaa")
        #expect(!again)
    }

    // MARK: adding

    @Test func addAppendsAfterTheLastTaskAndItsChildren() {
        var file = TaskFile(parsing: "# T\n- [ ] a ^t-00000001\n  - [ ] sub\n\nTrailing\n")
        var item = TaskItem(title: "New one")
        item.due = DayStamp(year: 2026, month: 11, day: 12)
        let id = file.add(item, today: DayStamp(year: 2026, month: 11, day: 9))
        #expect(id.hasPrefix("t-") && id.count == 10)
        #expect(file.serialized() == "# T\n- [ ] a ^t-00000001\n  - [ ] sub\n- [ ] New one [due:: 2026-11-12] [added:: 2026-11-09] ^\(id)\n\nTrailing\n")
    }

    @Test func addToAFileWithoutTasksGoesAtTheEnd() {
        var file = TaskFile(parsing: "# Tasks\n\nIntro\n")
        let id = file.add(TaskItem(title: "First"), today: DayStamp(year: 2026, month: 1, day: 2))
        #expect(file.serialized() == "# Tasks\n\nIntro\n- [ ] First [added:: 2026-01-02] ^\(id)\n")
    }

    @Test func addKeepsTheNoTrailingNewlineState() {
        var file = TaskFile(parsing: "- [ ] a ^t-00000001")
        let id = file.add(TaskItem(title: "b"), today: DayStamp(year: 2026, month: 1, day: 2))
        #expect(file.serialized() == "- [ ] a ^t-00000001\n- [ ] b [added:: 2026-01-02] ^\(id)")
    }

    @Test func addUsesCRLFInACRLFFile() {
        var file = TaskFile(parsing: "# T\r\n- [ ] a ^t-00000001\r\n")
        let id = file.add(TaskItem(title: "b"), today: DayStamp(year: 2026, month: 1, day: 2))
        #expect(file.serialized() == "# T\r\n- [ ] a ^t-00000001\r\n- [ ] b [added:: 2026-01-02] ^\(id)\r\n")
    }

    @Test func editingOnTheLastLineWithoutNewlineAddsNoNewline() {
        var file = TaskFile(parsing: "- [ ] a ^t-00000001")
        file.update(id: "t-00000001") { $0.priority = 1 }
        #expect(file.serialized() == "- [ ] a [pri:: 1] ^t-00000001")
        file.update(id: "t-00000001") { $0.addSubtask("s") }
        #expect(file.serialized() == "- [ ] a [pri:: 1] ^t-00000001\n  - [ ] s")
    }

    @Test func addedIDsAreUnique() {
        var file = TaskFile(parsing: "")
        var ids = Set<String>()
        for n in 0..<200 { ids.insert(file.add(TaskItem(title: "t\(n)"), today: DayStamp(year: 2026, month: 1, day: 1))) }
        #expect(ids.count == 200)
        #expect(file.tasks.count == 200)
    }

    // MARK: fields

    @Test func estimateParsingAndFormatting() {
        #expect(Estimate.parse("45m") == 45)
        #expect(Estimate.parse("1h") == 60)
        #expect(Estimate.parse("1h30m") == 90)
        #expect(Estimate.parse("1.5h") == 90)
        #expect(Estimate.parse("90 min") == 90)
        #expect(Estimate.parse("2hrs") == 120)
        #expect(Estimate.parse("45") == nil)
        #expect(Estimate.parse("m") == nil)
        #expect(Estimate.parse("0m") == nil)
        #expect(Estimate.parse("abc") == nil)
        #expect(Estimate.format(45) == "45m")
        #expect(Estimate.format(60) == "1h")
        #expect(Estimate.format(95) == "1h35m")
    }

    @Test func groupSetterPicksModeOrArea() {
        var t = TaskItem(title: "x")
        t.group = "School"
        #expect(t.mode == "school" && t.area == nil)
        t.group = "Reading"
        #expect(t.area == "Reading")
        t.group = nil
        #expect(t.area == nil && t.mode == nil)
        var withArea = TaskItem(title: "y")
        withArea.area = "School"
        withArea.group = "History"
        #expect(withArea.area == "History" && withArea.mode == nil)
    }

    @Test func dayStampBasics() {
        #expect(DayStamp("2026-11-04T16:00") == DayStamp(year: 2026, month: 11, day: 4))
        #expect(DayStamp("2026-13-01") == nil)
        #expect(DayStamp("tomorrow") == nil)
        let d = DayStamp(year: 2026, month: 12, day: 31)
        #expect(d.adding(days: 1) == DayStamp(year: 2027, month: 1, day: 1))
        #expect(d.days(until: DayStamp(year: 2027, month: 1, day: 3)) == 3)
        #expect(DayStamp(year: 2026, month: 2, day: 31).date() == nil)
    }
}
