import Foundation

/// One entry of a bot's `triggers` (PRD §7b "five ways to start a bot").
///
/// `chat`, `mention` and `task` start from something the user does. `schedule morning` and
/// `event <name>` start a bot on its own (M7), only when Settings ▸ Bots ▸ "Let bots run on their
/// own" is on. Both `schedule morning` and `schedule: morning` are accepted (YAML-ish habit).
public enum BotTrigger: Equatable, Sendable {
    case chat
    case mention
    case task
    case schedule(String)
    case event(String)

    /// Schedules that exist. Atlantis has no timers (AGENTS.md: idle = zero work), so a schedule is
    /// tied to an event the app already gets: `morning` = right after the morning SEQTA sync, or the
    /// first launch or wake after the morning time when the sync can't run.
    public static let schedules: Set<String> = ["morning"]

    /// Parses one entry. nil when the kind is unknown.
    public static func parse(_ raw: String) -> BotTrigger? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let kind = String(text.prefix { $0 != " " && $0 != ":" })
        var rest = text.dropFirst(kind.count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        switch kind {
        case "chat" where rest.isEmpty: return .chat
        case "mention" where rest.isEmpty: return .mention
        case "task" where rest.isEmpty: return .task
        case "schedule": return .schedule(rest)
        case "event": return .event(rest)
        default: return nil
        }
    }

    /// A problem with this entry for the bot file's error list, or nil when it's fine.
    public static func problem(_ raw: String) -> String? {
        guard let trigger = parse(raw) else {
            return "triggers: unknown trigger \"\(raw)\" (use chat, mention, task, schedule morning or event <name>)."
        }
        switch trigger {
        case .schedule(let when) where !schedules.contains(when):
            return "triggers: \"\(raw)\": the only schedule is morning (right after the morning SEQTA sync). Atlantis runs no timers."
        case .event(let name) where TeamEvent(rawValue: name) == nil:
            let known = TeamEvent.allCases.map(\.rawValue).joined(separator: ", ")
            return "triggers: unknown event \"\(name)\" (use \(known))."
        default:
            return nil
        }
    }
}

/// Events a bot can subscribe to with `event <name>`.
public enum TeamEvent: String, CaseIterable, Sendable {
    /// After a SEQTA sync, once for each assessment Atlantis hasn't seen before (the same dedupe
    /// that proposes it in the Inbox). The assessment is the run's data.
    case seqtaAssessmentNew = "seqta.assessment.new"
    /// At the morning trigger, one run with every overdue task (not one per task).
    case taskOverdue = "task.overdue"
}

extension BotDefinition {
    public var parsedTriggers: [BotTrigger] { triggers.compactMap(BotTrigger.parse) }
    /// `schedule morning`.
    public var runsInMorning: Bool { parsedTriggers.contains(.schedule("morning")) }
    public func subscribes(to event: TeamEvent) -> Bool { parsedTriggers.contains(.event(event.rawValue)) }
    /// Starts on its own (a schedule or an event), so it only runs while the Settings switch is on.
    public var hasAutomaticTriggers: Bool {
        parsedTriggers.contains { if case .schedule = $0 { true } else if case .event = $0 { true } else { false } }
    }
}

// MARK: - What starts a run

/// What started a run, written in the thread's front matter (`trigger: morning`) so Today can say
/// why a bot ran.
public enum RunTrigger: Equatable, Sendable {
    case chat
    case task
    case mention
    case morning
    case event(TeamEvent)
    /// Another bot handed this over (`atlantis_agent_delegate`), e.g. Chief → School.
    case delegate(from: String)

    public var raw: String {
        switch self {
        case .chat: "chat"
        case .task: "task"
        case .mention: "mention"
        case .morning: "morning"
        case .event(let event): "event " + event.rawValue
        case .delegate(let from): "delegate " + from
        }
    }

    public init?(raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        switch text {
        case "chat": self = .chat
        case "task": self = .task
        case "mention": self = .mention
        case "morning": self = .morning
        default:
            if text.hasPrefix("event "), let event = TeamEvent(rawValue: String(text.dropFirst(6))) {
                self = .event(event)
            } else if text.hasPrefix("delegate "), case let from = String(text.dropFirst(9)), BotFile.isValidID(from) {
                self = .delegate(from: from)
            } else {
                return nil
            }
        }
    }

    /// Short words for Today ("Morning", "New assessment", "From Chief").
    public func label(botName: (String) -> String = { $0.capitalized }) -> String {
        switch self {
        case .chat: "Chat"
        case .task: "Assigned task"
        case .mention: "@mention"
        case .morning: "Morning"
        case .event(.seqtaAssessmentNew): "New assessment"
        case .event(.taskOverdue): "Overdue tasks"
        case .delegate(let from): "From \(botName(from))"
        }
    }

    /// Started by Atlantis, not the user: counts against the daily cap of automatic runs.
    public var isAutomatic: Bool {
        switch self {
        case .morning, .event, .delegate: true
        case .chat, .task, .mention: false
        }
    }
}

// MARK: - Unattended runs

extension Autonomy {
    /// The autonomy for a run no one is watching (morning, events, hand-offs): `ask` becomes
    /// `suggest`, so writes wait in the Inbox instead of holding the one-at-a-time queue on an
    /// approval card. `suggest` and `act` (the user's own allow list) stay as they are.
    public static func unattended(_ autonomy: Autonomy) -> Autonomy { autonomy == .ask ? .suggest : autonomy }
}

// MARK: - Settings

/// The Settings that govern automatic runs (Settings ▸ Bots). Defaults are the safe ones.
public struct TeamSettings: Equatable, Sendable {
    /// "Let bots run on their own". Off by default: chat, assign and @mention still work.
    public var automaticRuns: Bool
    /// Most automatic runs (schedule, events, delegations) per day across all bots, on top of each
    /// bot's own cost cap.
    public var dailyCap: Int
    /// When the morning trigger may run without a sync (minutes after midnight, default 07:00).
    public var morningMinute: Int

    public static let defaultDailyCap = 10
    public static let dailyCapRange = 1...30
    public static let defaultMorningMinute = 7 * 60

    public init(automaticRuns: Bool = false, dailyCap: Int = TeamSettings.defaultDailyCap,
                morningMinute: Int = TeamSettings.defaultMorningMinute) {
        self.automaticRuns = automaticRuns
        self.dailyCap = min(max(dailyCap, Self.dailyCapRange.lowerBound), Self.dailyCapRange.upperBound)
        self.morningMinute = min(max(morningMinute, 0), 23 * 60 + 59)
    }
}

// MARK: - The morning trigger

/// Decides when `schedule morning` (and the morning's `task.overdue`) fire. Pure, for the tests.
///
/// It is driven by events the app already has, never a timer:
/// - **after a sync**: a SEQTA sync just finished (the morning one, or the day's first refresh);
/// - **launch or wake**: the morning sync was attempted (or skipped: no SEQTA address, already
///   synced, signed out) at launch or wake. Fires only from the morning time (07:00) on.
public enum MorningTrigger {
    public enum Cause: Equatable, Sendable {
        case afterSync
        case launchOrWake
    }

    /// Whether the morning trigger may fire now. Once per local day: `lastDay` is the day it last fired.
    public static func shouldFire(settings: TeamSettings, lastDay: String?, today: String, cause: Cause,
                                  minute: Int) -> Bool {
        guard settings.automaticRuns, lastDay != today else { return false }
        switch cause {
        case .afterSync: return true
        case .launchOrWake: return minute >= settings.morningMinute
        }
    }

    /// The bots that run at the morning trigger: each with `schedule morning`, or with
    /// `event task.overdue` when something is overdue. One run per bot.
    public static func bots(_ bots: [BotDefinition], overdue: [TaskItem]) -> [BotDefinition] {
        bots.filter { $0.runsInMorning || (!overdue.isEmpty && $0.subscribes(to: .taskOverdue)) }
    }
}

// MARK: - Remembering what ran

/// What automatic runs happened today, so the rules hold across relaunches:
/// `~/Library/Application Support/Atlantis/agents/triggers.json` (not the vault).
/// `{"day": "2026-11-10", "runs": 3, "morning_day": "2026-11-10"}`.
public final class TriggerLedger: @unchecked Sendable {
    struct File: Codable, Equatable {
        var day: String = ""
        /// Automatic runs started on `day`.
        var runs: Int = 0
        /// The day the morning trigger last fired.
        var morningDay: String?

        enum CodingKeys: String, CodingKey {
            case day, runs
            case morningDay = "morning_day"
        }
    }

    public let url: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public static var defaultURL: URL { AppSupport.root.appendingPathComponent("agents/triggers.json") }

    public init(url: URL = TriggerLedger.defaultURL, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.calendar = calendar
        self.now = now
    }

    public func todayKey() -> String { SeqtaMorningGate.dayString(now(), calendar: calendar) }

    public var morningDay: String? { lock.withLock { read().morningDay } }

    public func markMorning() {
        lock.withLock {
            var file = read()
            file.morningDay = todayKey()
            write(file)
        }
    }

    /// Automatic runs started today.
    public var runsToday: Int {
        lock.withLock {
            let file = read()
            return file.day == todayKey() ? file.runs : 0
        }
    }

    public func countRun() {
        lock.withLock {
            var file = read()
            let today = todayKey()
            if file.day != today { file.day = today; file.runs = 0 }
            file.runs += 1
            write(file)
        }
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
