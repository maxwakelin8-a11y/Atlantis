import Foundation

/// A run Atlantis starts on its own (morning, an event, or a delegation from Chief), waiting its
/// turn. Each gets its own thread; its answer goes to the Inbox as a note linked by `origin`.
public struct QueuedRun: Equatable, Sendable, Identifiable {
    public var id: String
    public var bot: String
    public var trigger: RunTrigger
    /// The thread's title.
    public var title: String
    /// The line the thread shows as what started it.
    public var userText: String
    /// The run's user turn (instructions plus data).
    public var prompt: String
    /// Written on every Inbox item the run makes (`morning:2026-11-10`, `seqta:assessment:12`, …).
    public var origin: String
    /// Short words for the result note's title.
    public var subject: String
    /// 0 for runs Atlantis starts; 1 for a run another bot handed over (it can't hand on again).
    public var depth: Int
    /// The run that delegated this one, if any.
    public var parentRunID: String?
    public var queuedAt: Date

    public init(id: String = UUID().uuidString, bot: String, trigger: RunTrigger, title: String, userText: String,
                prompt: String, origin: String, subject: String, depth: Int = 0, parentRunID: String? = nil,
                queuedAt: Date = Date()) {
        self.id = id
        self.bot = bot
        self.trigger = trigger
        self.title = title
        self.userText = userText
        self.prompt = prompt
        self.origin = origin
        self.subject = subject
        self.depth = depth
        self.parentRunID = parentRunID
        self.queuedAt = queuedAt
    }
}

/// A first-in, first-out queue of automatic runs, one at a time, under a daily cap.
///
/// Pure state; the app owns one and starts the next run when the active one finishes (an event,
/// not a timer). The cap counts runs already started today plus everything waiting, so the queue
/// can never hold more than the day allows.
public struct RunQueue: Equatable, Sendable {
    public private(set) var waiting: [QueuedRun] = []
    public private(set) var active: QueuedRun?

    public init() {}

    public enum Admission: Equatable, Sendable {
        /// Waiting at this position (0 = next).
        case queued(position: Int)
        case refused(String)
    }

    /// Everything not finished yet: the active run, then the waiting ones.
    public var all: [QueuedRun] { (active.map { [$0] } ?? []) + waiting }

    /// Adds a run unless the same bot already has one for the same origin, or the day's cap would be passed.
    public mutating func enqueue(_ run: QueuedRun, startedToday: Int, cap: Int) -> Admission {
        if all.contains(where: { $0.bot == run.bot && $0.origin == run.origin }) {
            return .refused("\(run.bot) already has that run waiting.")
        }
        let used = startedToday + all.count
        guard used < cap else {
            return .refused("Bots have used today's \(cap) automatic runs (Settings ▸ Bots). It can run again tomorrow.")
        }
        waiting.append(run)
        return .queued(position: waiting.count - 1 + (active == nil ? 0 : 1))
    }

    /// Moves the first waiting run to active, if nothing is running.
    public mutating func startNext() -> QueuedRun? {
        guard active == nil, !waiting.isEmpty else { return nil }
        active = waiting.removeFirst()
        return active
    }

    public mutating func finishActive() { active = nil }

    /// Drops waiting runs that match (e.g. every automatic run when the user turns the switch off).
    /// The active run isn't touched; stop it separately.
    @discardableResult
    public mutating func removeWaiting(where shouldRemove: (QueuedRun) -> Bool) -> [QueuedRun] {
        let removed = waiting.filter(shouldRemove)
        waiting.removeAll(where: shouldRemove)
        return removed
    }
}

/// A run that never started (for Today: "skipped, daily cap").
public struct SkippedRun: Equatable, Sendable, Identifiable {
    public var id: String
    public var bot: String
    public var trigger: RunTrigger
    public var title: String
    public var reason: String
    public var at: Date

    public init(id: String = UUID().uuidString, bot: String, trigger: RunTrigger, title: String, reason: String, at: Date) {
        self.id = id
        self.bot = bot
        self.trigger = trigger
        self.title = title
        self.reason = reason
        self.at = at
    }
}

// MARK: - Delegation (Chief)

/// `atlantis_agent_delegate {bot, request}`: one bot (Chief) hands a request to another.
///
/// Rules, checked by `check` and enforced in the app before anything is queued:
/// - only Atlantis's own bots can delegate (plain MCP clients can't start bot runs);
/// - never to itself; only to a bot whose file loads and allows `chat`;
/// - depth 1: a delegated run can't delegate again;
/// - at most `maxPerRun` hand-offs per run;
/// - the target's daily cost cap must have room, and the run counts against the daily cap of
///   automatic runs like any other (the queue checks that).
public enum AgentDelegation {
    public static let toolName = "atlantis_agent_delegate"
    public static let maxDepth = 1
    public static let maxPerRun = 3
    public static let maxRequest = 2_000

    public struct Caller: Equatable, Sendable {
        public var bot: String?
        public var depth: Int
        public var runID: String?
        public init(bot: String?, depth: Int, runID: String?) {
            self.bot = bot
            self.depth = depth
            self.runID = runID
        }
    }

    /// The bot the request may go to, or why not.
    public static func check(caller: Caller, target: String, request: String, bots: [BotEntry],
                             delegationsThisRun: Int, spentToday: (String) -> Double) -> Result<BotDefinition, ToolFailure> {
        guard let from = caller.bot else {
            return .failure(ToolFailure("Only Atlantis's own bots can hand work to another bot."))
        }
        guard caller.depth < maxDepth else {
            return .failure(ToolFailure("This run was handed to you by another bot, so you can't hand it on. Answer it yourself."))
        }
        let id = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard id != from else { return .failure(ToolFailure("You can't hand work to yourself.")) }
        let clean = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .failure(ToolFailure("Say what the bot should do in request.")) }
        guard clean.count <= maxRequest else { return .failure(ToolFailure("The request is too long (keep it under \(maxRequest) characters).")) }
        guard delegationsThisRun < maxPerRun else {
            return .failure(ToolFailure("You've handed off \(maxPerRun) requests in this run, the most allowed. Answer with what you have."))
        }
        guard let entry = bots.first(where: { $0.id == id }) else {
            let names = bots.compactMap(\.definition).filter { $0.allowsChat && $0.id != from }.map(\.id).joined(separator: ", ")
            return .failure(ToolFailure("There's no bot called \(id). The team is: \(names)."))
        }
        guard let bot = entry.definition else {
            return .failure(ToolFailure("\(id)'s file has a problem, so it can't run. Tell the user."))
        }
        guard bot.allowsChat else {
            return .failure(ToolFailure("\(bot.name) doesn't take requests (chat isn't in its triggers)."))
        }
        let spent = spentToday(bot.id)
        guard spent < bot.dailyCostUSD else {
            return .failure(ToolFailure("\(bot.name) has used its \(UsageLedger.dollars(bot.dailyCostUSD)) for today, so it can't run until tomorrow."))
        }
        return .success(bot)
    }

    /// The prompt for the bot the request was handed to.
    public static func prompt(request: String, fromName: String) -> String {
        """
        \(fromName), the team's router, handed you a request from the user. Do it with your tools. Your final \
        reply is posted to the user's Inbox as a note, so make it complete on its own. If something should change \
        (a task, a doc), propose it with your write tools; the user decides. You can't hand this on to another bot.

        <user_message>
        \(UntrustedText.defuse(request))
        </user_message>
        """
    }

    /// `thread:chief/<thread id>`: links a delegated run's answer back to the thread that asked.
    public static func origin(fromBot: String, threadID: String) -> String { "thread:\(fromBot)/\(threadID)" }
}

/// What the app does with a checked delegation: queue the run. Answers what the tool returns.
public typealias AgentDelegateHandler = @Sendable (_ caller: AgentDelegation.Caller, _ bot: String, _ request: String) async -> Result<String, ToolFailure>

/// Registers `atlantis_agent_delegate`. The app supplies `handler` (it owns the bots and the queue);
/// without one (tests, or a build without bots) the tool says it isn't available.
public enum AgentTools {
    public static func register(in registry: ToolRegistry, handler: AgentDelegateHandler?) {
        registry.register(ToolDefinition(
            name: AgentDelegation.toolName,
            description: "Hand the user's request to another bot on the team (for example school, coach, builder or scout). The bot runs on its own afterwards and its answer goes to the user's Inbox. Use it when another bot is better placed; say in your reply who you asked and why. Bots that were handed a request can't hand it on.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "bot": ["type": "string", "description": "The bot's id (its file name), e.g. \"school\"."],
                    "request": ["type": "string", "description": "What the bot should do, in plain words, with the details it needs."],
                ],
                "required": ["bot", "request"],
                "additionalProperties": false,
            ],
            kind: .action
        )) { args in
            let bot = try args.requireString("bot", maxLength: 40)
            let request = try args.requireString("request", maxLength: AgentDelegation.maxRequest)
            guard let handler else { throw ToolFailure("Handing work to other bots isn't available here.") }
            let caller = AgentDelegation.Caller(bot: MCPCaller.agentName, depth: MCPCaller.agentDepth,
                                                runID: MCPCaller.agentRunID)
            switch await handler(caller, bot, request) {
            case .success(let text): return ToolResult(text: text)
            case .failure(let failure): return .error(failure.message)
            }
        }
    }
}
