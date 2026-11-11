import Foundation

/// Each bot's estimated spend per day, so the daily cost cap holds across runs and restarts.
///
/// A small JSON file in Application Support (not the vault): `{"days": {"2026-11-10": {"school":
/// {"cost_usd": 0.0123, "runs": 2}}}}`. The daemon writes it after each run; the app reads it to show
/// "today $0.02 of $1.00". Keeps the last 31 days.
public final class UsageLedger: @unchecked Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var costUSD: Double
        public var runs: Int

        enum CodingKeys: String, CodingKey {
            case costUSD = "cost_usd"
            case runs
        }
    }

    private struct File: Codable {
        var days: [String: [String: Day]] = [:]
    }

    public let url: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public static var defaultURL: URL {
        AppSupport.root.appendingPathComponent("agents/usage.json")
    }

    public init(url: URL = UsageLedger.defaultURL, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.calendar = calendar
        self.now = now
    }

    /// `YYYY-MM-DD` for today in the user's time zone.
    public func todayKey() -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// What each bot has used today.
    public func today() -> [String: Day] {
        lock.withLock { read().days[todayKey()] ?? [:] }
    }

    public func spentToday(bot: String) -> Double {
        today()[bot]?.costUSD ?? 0
    }

    /// Dollars left today under `cap` (never below zero).
    public func remaining(bot: String, cap: Double) -> Double {
        max(0, cap - spentToday(bot: bot))
    }

    /// A message for the user when the bot can't start another run today, else nil.
    public func refusal(bot: String, name: String, cap: Double) -> String? {
        let spent = spentToday(bot: bot)
        guard spent >= cap else { return nil }
        return "\(name) has used its \(Self.dollars(cap)) for today (\(Self.dollars(spent)) so far). It can run again tomorrow, or raise budget.daily_cost_usd in its file."
    }

    /// Adds a run's cost; returns today's new total for the bot.
    @discardableResult
    public func record(bot: String, costUSD: Double) -> Double {
        lock.withLock {
            var file = read()
            let key = todayKey()
            var day = file.days[key]?[bot] ?? Day(costUSD: 0, runs: 0)
            day.costUSD += max(0, costUSD)
            day.runs += 1
            file.days[key, default: [:]][bot] = day
            // Keep a month: older days are only history.
            let keep = file.days.keys.sorted().suffix(31)
            file.days = file.days.filter { keep.contains($0.key) }
            write(file)
            return day.costUSD
        }
    }

    /// `$0.42`, `$0.004` below a cent, `<$0.001` below that, so small runs don't read as free.
    public static func dollars(_ value: Double) -> String {
        if value > 0, value < 0.001 { return "<$0.001" }
        if value > 0, value < 0.01 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }

    private func read() -> File {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    private func write(_ file: File) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}
