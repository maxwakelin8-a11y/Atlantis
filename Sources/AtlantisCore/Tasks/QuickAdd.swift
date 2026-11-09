import Foundation

/// What the quick-add field understood from a line like `Turing draft thu 45m #school !1 +turing`.
public struct QuickAddResult: Equatable, Sendable {
    public var title = ""
    public var due: DayStamp?
    public var estimateMinutes: Int?
    public var mode: String?
    public var area: String?
    public var priority: Int?
    public var project: String?

    public init() {}

    /// A task with these fields (no id or added date yet; the store gives those).
    public func makeTask() -> TaskItem {
        var task = TaskItem(title: title)
        task.due = due
        task.estimateMinutes = estimateMinutes
        task.priority = priority
        task.mode = mode
        task.area = area
        task.project = project
        return task
    }
}

/// Natural-language quick add (PRD F2). Pure: the clock is passed in so tests can fix it.
///
/// Recognised anywhere in the text (the first date wins; the rest stays in the title):
/// - dates: `today`, `tomorrow`/`tmr`, weekdays (`thu`, the next one after today),
///   `next mon` (that weekday in next week), `next week` (next Monday), `in 3 days`/`in 2 weeks`,
///   `12 nov`, `nov 12`, `12th november 2027`, `12/11`, `12/11/2026`, `2026-11-12`.
///   A word like `by`/`due`/`on` right before a date is dropped.
/// - `45m`, `1h`, `1h30m`, `1.5h`: estimate
/// - `#school`: a mode (school, building, bjj, social) or else an area
/// - `!1`…`!3`: priority
/// - `+turing`: project
public enum QuickAdd {
    public static func parse(
        _ text: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        knownProjects: [String] = [],
        knownAreas: [String] = []
    ) -> QuickAddResult {
        let today = DayStamp(now, calendar: calendar)
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result = QuickAddResult()
        var words: [String] = []
        var i = 0

        func known(_ name: String, in list: [String]) -> String? {
            list.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        }

        while i < tokens.count {
            let token = tokens[i]
            let lower = token.lowercased()

            if lower.count == 2, lower.first == "!", let level = Int(lower.dropFirst()), (1...3).contains(level) {
                if result.priority == nil { result.priority = level } else { words.append(token) }
                i += 1; continue
            }
            if token.count > 1, token.first == "#" {
                let name = String(token.dropFirst())
                if TaskModes.all.contains(name.lowercased()) {
                    result.mode = name.lowercased()
                } else {
                    result.area = known(name, in: knownAreas) ?? (name.prefix(1).uppercased() + name.dropFirst())
                }
                i += 1; continue
            }
            if token.count > 1, token.first == "+" {
                let name = String(token.dropFirst())
                result.project = known(name, in: knownProjects) ?? name
                i += 1; continue
            }
            if result.estimateMinutes == nil, let minutes = Estimate.parse(token), token.contains(where: \.isLetter) {
                result.estimateMinutes = minutes
                i += 1; continue
            }
            if result.due == nil, let (day, used) = parseDate(tokens, at: i, today: today, calendar: calendar) {
                result.due = day
                if let last = words.last?.lowercased(), ["by", "due", "on", "before", "until"].contains(last) {
                    words.removeLast()
                }
                i += used; continue
            }
            words.append(token)
            i += 1
        }
        result.title = words.joined(separator: " ")
        return result
    }

    // MARK: Dates

    private static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]
    private static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12,
    ]

    /// Tries to read a date starting at `tokens[i]`. Returns it with the number of tokens used.
    static func parseDate(_ tokens: [String], at i: Int, today: DayStamp, calendar: Calendar) -> (DayStamp, Int)? {
        let t = tokens[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",."))
        let next = i + 1 < tokens.count ? tokens[i + 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.")) : nil

        switch t {
        case "today": return (today, 1)
        case "tomorrow", "tmr", "tmrw": return (today.adding(days: 1, calendar: calendar), 1)
        default: break
        }

        if t == "next", let next {
            if next == "week" { return (nextWeekday(2, after: today, calendar: calendar, inNextWeek: true), 2) }
            if let wd = weekdays[next] { return (nextWeekday(wd, after: today, calendar: calendar, inNextWeek: true), 2) }
        }
        if let wd = weekdays[t] { return (nextWeekday(wd, after: today, calendar: calendar, inNextWeek: false), 1) }

        if t == "in", let next, let n = Int(next), n > 0, n <= 366, i + 2 < tokens.count {
            switch tokens[i + 2].lowercased() {
            case "day", "days", "d": return (today.adding(days: n, calendar: calendar), 3)
            case "week", "weeks", "w": return (today.adding(days: 7 * n, calendar: calendar), 3)
            default: break
            }
        }

        if let day = DayStamp(t), day.date(calendar: calendar) != nil { return (day, 1) }

        // 12/11 or 12/11/2026 (day first, as in Australia).
        let slash = t.split(separator: "/", omittingEmptySubsequences: false)
        if slash.count == 2 || slash.count == 3, let d = Int(slash[0]), let m = Int(slash[1]) {
            var year: Int?
            if slash.count == 3 {
                guard let y = Int(slash[2]) else { return nil }
                year = y < 100 ? 2000 + y : y
            }
            if let day = resolve(day: d, month: m, year: year, today: today, calendar: calendar) { return (day, 1) }
            return nil
        }

        // 12 nov [2027], 12th november, nov 12, nov 12th
        if let d = dayNumber(t), let next, let m = months[next] {
            var used = 2
            var year: Int?
            if i + 2 < tokens.count, tokens[i + 2].count == 4, let y = Int(tokens[i + 2]), (2000...2100).contains(y) { year = y; used = 3 }
            if let day = resolve(day: d, month: m, year: year, today: today, calendar: calendar) { return (day, used) }
        }
        if let m = months[t], let next, let d = dayNumber(next) {
            var used = 2
            var year: Int?
            if i + 2 < tokens.count, tokens[i + 2].count == 4, let y = Int(tokens[i + 2]), (2000...2100).contains(y) { year = y; used = 3 }
            if let day = resolve(day: d, month: m, year: year, today: today, calendar: calendar) { return (day, used) }
        }
        return nil
    }

    private static func dayNumber(_ s: String) -> Int? {
        var digits = s
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) && digits.count > suffix.count {
            digits = String(digits.dropLast(suffix.count)); break
        }
        guard let n = Int(digits), (1...31).contains(n) else { return nil }
        return n
    }

    /// A real date for day/month. Without a year, the next one that isn't in the past.
    private static func resolve(day: Int, month: Int, year: Int?, today: DayStamp, calendar: Calendar) -> DayStamp? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        if let year {
            let stamp = DayStamp(year: year, month: month, day: day)
            return stamp.date(calendar: calendar) == nil ? nil : stamp
        }
        for y in [today.year, today.year + 1] {
            let stamp = DayStamp(year: y, month: month, day: day)
            if stamp.date(calendar: calendar) != nil, stamp >= today { return stamp }
        }
        return nil
    }

    /// Soonest `weekday` (1 = Sunday…7) after today. With `inNextWeek`, the one in next
    /// calendar week (weeks start Monday) instead.
    static func nextWeekday(_ weekday: Int, after today: DayStamp, calendar: Calendar, inNextWeek: Bool) -> DayStamp {
        let current = today.weekday(calendar: calendar)
        if inNextWeek {
            let sinceMonday = (current + 5) % 7 // Mon = 0 … Sun = 6
            let nextMonday = today.adding(days: 7 - sinceMonday, calendar: calendar)
            let offset = (weekday + 5) % 7
            return nextMonday.adding(days: offset, calendar: calendar)
        }
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }
        return today.adding(days: delta, calendar: calendar)
    }
}
