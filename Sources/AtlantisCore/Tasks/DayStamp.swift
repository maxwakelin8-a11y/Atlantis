import Foundation

/// A calendar day with no time zone (`2026-11-12`). Tasks use these so "due today" never
/// shifts with the clock or the time zone.
public struct DayStamp: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Parses `YYYY-MM-DD`. A trailing time (`2026-11-04T16:00`) is ignored.
    public init?(_ string: String) {
        let head = string.prefix(10)
        let parts = head.split(separator: "-", omittingEmptySubsequences: false)
        guard head.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: DayStamp, b: DayStamp) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Midday on this day, so it is safe against daylight-saving edges. Nil for a day that
    /// doesn't exist (31 Feb).
    public func date(calendar: Calendar = .current) -> Date? {
        var c = DateComponents(year: year, month: month, day: day, hour: 12)
        c.calendar = calendar
        guard let date = calendar.date(from: c), DayStamp(date, calendar: calendar) == self else { return nil }
        return date
    }

    public func adding(days: Int, calendar: Calendar = .current) -> DayStamp {
        guard let date = date(calendar: calendar), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return self }
        return DayStamp(moved, calendar: calendar)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(until other: DayStamp, calendar: Calendar = .current) -> Int {
        guard let a = date(calendar: calendar), let b = other.date(calendar: calendar) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// 1 = Sunday … 7 = Saturday (Foundation's numbering).
    public func weekday(calendar: Calendar = .current) -> Int {
        guard let date = date(calendar: calendar) else { return 1 }
        return calendar.component(.weekday, from: date)
    }
}
