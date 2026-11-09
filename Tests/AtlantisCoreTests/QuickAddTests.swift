import Foundation
import Testing
@testable import AtlantisCore

@Suite struct QuickAddTests {
    /// Monday 9 November 2026, 10:00 in Perth.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        c.firstWeekday = 2
        return c
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 10))!

    static func parse(_ text: String, projects: [String] = [], areas: [String] = []) -> QuickAddResult {
        QuickAdd.parse(text, now: now, calendar: calendar, knownProjects: projects, knownAreas: areas)
    }
    static func day(_ y: Int, _ m: Int, _ d: Int) -> DayStamp { DayStamp(year: y, month: m, day: d) }

    @Test func theExampleFromThePRD() {
        let r = Self.parse("Turing draft thu 45m #school !1 +turing")
        #expect(r.title == "Turing draft")
        #expect(r.due == Self.day(2026, 11, 12))
        #expect(r.estimateMinutes == 45)
        #expect(r.mode == "school")
        #expect(r.area == nil)
        #expect(r.priority == 1)
        #expect(r.project == "turing")
    }

    @Test func plainTextIsJustATitle() {
        let r = Self.parse("  Buy   milk  ")
        #expect(r.title == "Buy milk")
        #expect(r.due == nil && r.estimateMinutes == nil && r.priority == nil && r.project == nil)
    }

    @Test(arguments: [
        ("today", (2026, 11, 9)),
        ("tomorrow", (2026, 11, 10)),
        ("tmr", (2026, 11, 10)),
        ("mon", (2026, 11, 16)),      // today is Monday: the next one
        ("monday", (2026, 11, 16)),
        ("tue", (2026, 11, 10)),
        ("fri", (2026, 11, 13)),
        ("sun", (2026, 11, 15)),
        ("next mon", (2026, 11, 16)),
        ("next fri", (2026, 11, 20)),
        ("next sun", (2026, 11, 22)),
        ("next week", (2026, 11, 16)),
        ("in 3 days", (2026, 11, 12)),
        ("in 2 weeks", (2026, 11, 23)),
        ("12 nov", (2026, 11, 12)),
        ("12th nov", (2026, 11, 12)),
        ("nov 12", (2026, 11, 12)),
        ("12 November", (2026, 11, 12)),
        ("9 nov", (2026, 11, 9)),
        ("5 nov", (2027, 11, 5)),      // already passed: next year
        ("1 jan", (2027, 1, 1)),
        ("3 mar 2028", (2028, 3, 3)),
        ("2026-11-12", (2026, 11, 12)),
        ("12/11", (2026, 11, 12)),
        ("12/11/2026", (2026, 11, 12)),
        ("1/2/27", (2027, 2, 1)),
    ])
    func dates(text: String, expected: (Int, Int, Int)) {
        let r = Self.parse("Task \(text)")
        #expect(r.due == Self.day(expected.0, expected.1, expected.2), "\(text)")
        #expect(r.title == "Task", "\(text)")
    }

    @Test func nextWeekdayOnASaturday() {
        // Saturday 14 Nov: "next mon" is 16 Nov, "next fri" is 20 Nov, "fri" is 20 Nov.
        let sat = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9))!
        func parse(_ s: String) -> DayStamp? { QuickAdd.parse(s, now: sat, calendar: Self.calendar).due }
        #expect(parse("x next mon") == Self.day(2026, 11, 16))
        #expect(parse("x next fri") == Self.day(2026, 11, 20))
        #expect(parse("x fri") == Self.day(2026, 11, 20))
        #expect(parse("x sat") == Self.day(2026, 11, 21))
    }

    @Test func impossibleOrAmbiguousDatesStayInTheTitle() {
        #expect(Self.parse("Essay 31 feb").due == nil)
        #expect(Self.parse("Essay 31 feb").title == "Essay 31 feb")
        #expect(Self.parse("Read chapter 5").due == nil)
        #expect(Self.parse("Read chapter 5").title == "Read chapter 5")
        #expect(Self.parse("Maybe may").due == nil)
        #expect(Self.parse("Call tom").due == nil)
        #expect(Self.parse("Task 32/13").due == nil)
    }

    @Test func prepositionsBeforeADateAreDropped() {
        #expect(Self.parse("Essay by friday").title == "Essay")
        #expect(Self.parse("Essay due 12 nov").title == "Essay")
        #expect(Self.parse("Pay on tomorrow").title == "Pay")
        #expect(Self.parse("Go by bus").title == "Go by bus")
    }

    @Test func onlyTheFirstDateCounts() {
        let r = Self.parse("Meet fri then sat")
        #expect(r.due == Self.day(2026, 11, 13))
        #expect(r.title == "Meet then sat")
    }

    @Test func estimates() {
        #expect(Self.parse("a 45m").estimateMinutes == 45)
        #expect(Self.parse("a 1h").estimateMinutes == 60)
        #expect(Self.parse("a 1h30m").estimateMinutes == 90)
        #expect(Self.parse("a 1.5h").estimateMinutes == 90)
        #expect(Self.parse("a 2hr").estimateMinutes == 120)
        #expect(Self.parse("a 45").estimateMinutes == nil)
        #expect(Self.parse("a 45").title == "a 45")
        #expect(Self.parse("45m a").title == "a")
    }

    @Test func tagsPriorityAndProject() {
        let r = Self.parse("x #bjj !3 +Life-OS")
        #expect(r.mode == "bjj" && r.priority == 3 && r.project == "Life-OS")
        let areas = Self.parse("x #reading")
        #expect(areas.area == "Reading" && areas.mode == nil)
        #expect(Self.parse("x !4").priority == nil)
        #expect(Self.parse("x !4").title == "x !4")
        #expect(Self.parse("x !1 !2").priority == 1)
        #expect(Self.parse("wow! really").title == "wow! really")
        #expect(Self.parse("c# is fun").title == "c# is fun")
    }

    @Test func knownProjectsAndAreasKeepTheirSpelling() {
        let r = Self.parse("Essay +history #school #maths", projects: ["History"], areas: ["Maths"])
        #expect(r.project == "History")
        #expect(r.mode == "school")
        #expect(r.area == "Maths")
        #expect(Self.parse("x #MATHS", areas: ["Maths"]).area == "Maths")
    }

    @Test func makesATask() {
        let t = Self.parse("Turing draft thu 45m #school !1 +turing").makeTask()
        #expect(t.title == "Turing draft")
        #expect(t.due == Self.day(2026, 11, 12))
        #expect(t.estimateMinutes == 45)
        #expect(t.mode == "school")
        #expect(t.priority == 1)
        #expect(t.project == "turing")
    }

    @Test func onlyAnEmptyTitleWhenNothingIsLeft() {
        #expect(Self.parse("tomorrow").title == "")
        #expect(Self.parse("").title == "")
        #expect(Self.parse("   ").title == "")
    }
}
