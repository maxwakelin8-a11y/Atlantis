import Foundation
import Testing
@testable import AtlantisCore

@Suite struct TaskListsTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()
    static let locale = Locale(identifier: "en_AU")
    static let today = DayStamp(year: 2026, month: 11, day: 9)

    static let tasks: [TaskItem] = TaskFile(parsing: """
    - [ ] Late [due:: 2026-11-05] ^t-00000001
    - [ ] Today low [due:: 2026-11-09] [pri:: 3] ^t-00000002
    - [ ] Today high [due:: 2026-11-09] [pri:: 1] [project:: History] ^t-00000003
    - [ ] Planned [plan:: 2026-11-09] [area:: School] ^t-00000004
    - [ ] Tomorrow [due:: 2026-11-10] [project:: history] [mode:: school] ^t-00000005
    - [ ] Later [due:: 2026-11-30] [project:: Turing] ^t-00000006
    - [ ] Whenever ^t-00000007
    - [x] Done today [done:: 2026-11-09] [due:: 2026-11-08] ^t-00000008
    - [x] Done old [done:: 2026-11-01] ^t-00000009
    - [-] Dropped ^t-0000000a
    """).tasks

    static func sections(_ kind: TaskListKind) -> [TaskSection] {
        TaskLists.sections(kind, tasks: tasks, today: today, calendar: calendar, locale: locale)
    }
    static func ids(_ s: TaskSection) -> [String] { s.tasks.map { String($0.id.suffix(1)) } }

    @Test func todayHasOverdueThenTodayByPriority() {
        let s = Self.sections(.today)
        #expect(s.map(\.title) == ["Overdue", "Today"])
        #expect(s[0].isOverdue)
        #expect(Self.ids(s[0]) == ["1"])
        #expect(Self.ids(s[1]) == ["3", "2", "4"]) // pri 1, pri 3, then the one with no priority
    }

    @Test func upcomingGroupsByDayThenUndated() {
        let s = Self.sections(.upcoming)
        #expect(s.map(\.title) == ["Tomorrow", "Mon, 30 Nov", "No date"])
        #expect(Self.ids(s[2]) == ["7"])
    }

    @Test func projectGroupsMergeCaseAndPutNoneLast() {
        let s = Self.sections(.project)
        #expect(s.map(\.title) == ["History", "Turing", "No project"])
        #expect(Self.ids(s[0]) == ["3", "5"])
    }

    @Test func areaUsesAreaOrMode() {
        let s = Self.sections(.area)
        #expect(s.map(\.title) == ["School", "No area"])
        #expect(Self.ids(s[0]).sorted() == ["4", "5"]) // area "School" and mode "school" are one group
    }

    @Test func doneShowsClosedTasksNewestFirst() {
        let s = Self.sections(.done)
        #expect(s.map(\.title) == ["Today", "Sun, 1 Nov", "Earlier"])
        #expect(Self.ids(s[2]) == ["a"]) // cancelled
    }

    @Test func dayLabels() {
        let t = Self.today
        func title(_ y: Int, _ m: Int, _ d: Int) -> String {
            DayLabel.title(for: DayStamp(year: y, month: m, day: d), today: t, calendar: Self.calendar, locale: Self.locale)
        }
        func short(_ y: Int, _ m: Int, _ d: Int) -> String {
            DayLabel.short(for: DayStamp(year: y, month: m, day: d), today: t, calendar: Self.calendar, locale: Self.locale)
        }
        #expect(title(2026, 11, 9) == "Today")
        #expect(title(2026, 11, 10) == "Tomorrow")
        #expect(title(2026, 11, 8) == "Yesterday")
        #expect(title(2026, 11, 12) == "Thursday")
        #expect(title(2026, 11, 20) == "Fri, 20 Nov")
        #expect(title(2027, 1, 5).contains("2027"))
        #expect(short(2026, 11, 12) == "Thu")
        #expect(short(2026, 11, 20) == "20 Nov")
    }
}
