import Foundation

/// One line of the CLI's `--output-format stream-json --verbose` output, reduced to what Atlantis uses.
public enum StreamItem: Equatable, Sendable {
    public struct Initialized: Equatable, Sendable {
        public var model: String?
        public var tools: [String]
        public var mcpServers: [String: String] // name → status
    }

    public enum Block: Equatable, Sendable {
        case text(String)
        case toolUse(id: String, name: String)
    }

    public struct Result: Equatable, Sendable {
        public var subtype: String
        public var isError: Bool
        public var text: String?
        public var costUSD: Double?
        public var turns: Int?
        public var durationMs: Int?
    }

    case initialized(Initialized)
    case textDelta(String)
    /// Part (or all) of an assistant message. The CLI may send one line per content block.
    case assistant(messageID: String?, blocks: [Block], usage: TokenUsage?)
    case toolResult(id: String, isError: Bool)
    case result(Result)
    /// Anything else (hooks, status, rate limits, partial events we don't show).
    case other

    /// Parses one line. Unreadable lines are `.other`: the stream is the CLI's, not ours to fail on.
    public static func parse(_ line: String) -> StreamItem {
        guard let data = line.data(using: .utf8), let json = try? JSONValue.parse(data) else { return .other }
        // Lines from inside a subagent carry a parent id. Bots have no subagents; ignore them if any appear.
        if let parent = json["parent_tool_use_id"], !parent.isNull { return .other }
        switch json["type"]?.stringValue {
        case "system":
            guard json["subtype"]?.stringValue == "init" else { return .other }
            var servers: [String: String] = [:]
            for server in json["mcp_servers"]?.arrayValue ?? [] {
                if let name = server["name"]?.stringValue { servers[name] = server["status"]?.stringValue ?? "" }
            }
            return .initialized(.init(model: json["model"]?.stringValue,
                                      tools: (json["tools"]?.arrayValue ?? []).compactMap(\.stringValue),
                                      mcpServers: servers))
        case "stream_event":
            let event = json["event"]
            guard event?["type"]?.stringValue == "content_block_delta",
                  event?["delta"]?["type"]?.stringValue == "text_delta",
                  let text = event?["delta"]?["text"]?.stringValue else { return .other }
            return .textDelta(text)
        case "assistant":
            let message = json["message"]
            var blocks: [Block] = []
            for block in message?["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue { blocks.append(.text(text)) }
                case "tool_use":
                    if let id = block["id"]?.stringValue, let name = block["name"]?.stringValue {
                        blocks.append(.toolUse(id: id, name: name))
                    }
                default: break
                }
            }
            return .assistant(messageID: message?["id"]?.stringValue, blocks: blocks,
                              usage: message?["usage"].flatMap(TokenUsage.init(json:)))
        case "user":
            for block in json["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                if let id = block["tool_use_id"]?.stringValue {
                    return .toolResult(id: id, isError: block["is_error"]?.boolValue ?? false)
                }
            }
            return .other
        case "result":
            return .result(.init(subtype: json["subtype"]?.stringValue ?? "",
                                 isError: json["is_error"]?.boolValue ?? false,
                                 text: json["result"]?.stringValue,
                                 costUSD: json["total_cost_usd"]?.doubleValue,
                                 turns: json["num_turns"]?.intValue,
                                 durationMs: json["duration_ms"]?.intValue))
        default:
            return .other
        }
    }
}

/// Tokens one assistant message used.
public struct TokenUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        func n(_ key: String) -> Int { json[key]?.intValue ?? 0 }
        self.init(input: n("input_tokens"), output: n("output_tokens"),
                  cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens"))
    }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }

    /// A deliberate over-estimate in dollars (top-tier rates for every model), used only when a run
    /// was stopped before the CLI reported its own cost, so the daily cap errs on the safe side.
    public var conservativeCostUSD: Double {
        (Double(input) * 15 + Double(output) * 75 + Double(cacheWrite) * 18.75 + Double(cacheRead) * 1.5) / 1_000_000
    }
}

/// How a run ended, as the daemon reports it and the thread log records it.
public struct RunSummary: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case ok
        /// The user pressed Stop.
        case stopped
        case stepLimit = "step-limit"
        case costLimit = "cost-limit"
        /// Refused before or right after starting (lockdown check, bad request, provider not set up).
        case refused
        case failed
    }

    public var status: Status
    public var message: String?
    public var steps: Int
    public var costUSD: Double
    /// True when `costUSD` is Atlantis's over-estimate rather than the CLI's figure.
    public var costEstimated: Bool
    /// The bot's spend today after this run.
    public var todayCostUSD: Double
    public var durationMs: Int
    /// Everything the bot said, text blocks joined by blank lines.
    public var text: String

    public init(status: Status, message: String? = nil, steps: Int = 0, costUSD: Double = 0, costEstimated: Bool = false,
                todayCostUSD: Double = 0, durationMs: Int = 0, text: String = "") {
        self.status = status
        self.message = message
        self.steps = steps
        self.costUSD = costUSD
        self.costEstimated = costEstimated
        self.todayCostUSD = todayCostUSD
        self.durationMs = durationMs
        self.text = text
    }
}

/// What the daemon streams to the app during a run (one frame each).
public enum AgentEvent: Codable, Sendable, Equatable {
    case started(runID: String)
    /// A few more characters of the reply being written.
    case textDelta(String)
    /// A finished text block (replaces the deltas shown for it).
    case text(String)
    /// The bot called a tool (the Atlantis name, `atlantis_today`).
    case toolCall(id: String, name: String)
    case toolResult(id: String, isError: Bool)
    case progress(steps: Int)
    case finished(RunSummary)
}

/// Reads a run's stream, enforces the lockdown and step budget, and says when to stop.
/// Pure logic, so it's tested with recorded stream-json lines.
public struct RunMonitor: Sendable {
    public let bot: String
    public let allowedTools: Set<String>
    public let maxSteps: Int
    /// The app refuses tool calls past `maxSteps` and asks the bot to answer; if it keeps calling
    /// tools anyway, the run is killed here.
    public var hardStepLimit: Int { maxSteps + 2 }

    public private(set) var steps = 0
    public private(set) var stop: RunSummary.Status?
    public private(set) var stopMessage: String?
    public private(set) var result: StreamItem.Result?
    public private(set) var initialized = false
    public private(set) var textBlocks: [String] = []
    private var toolIDs = Set<String>()
    private var usageByMessage: [String: TokenUsage] = [:]
    private var anonymousUsage = TokenUsage()

    public init(bot: String, allowedTools: [String], maxSteps: Int) {
        self.bot = bot
        self.allowedTools = Set(allowedTools)
        self.maxSteps = maxSteps
    }

    /// Tokens seen so far (each message counted once).
    public var usage: TokenUsage { usageByMessage.values.reduce(anonymousUsage, +) }

    /// Feeds one line; returns the events to send on. Check `stop` afterwards.
    public mutating func consume(_ line: String) -> [AgentEvent] {
        guard stop == nil else { return [] }
        switch StreamItem.parse(line) {
        case .initialized(let info):
            initialized = true
            checkLockdown(info)
            return []
        case .textDelta(let text):
            return [.textDelta(text)]
        case .assistant(let messageID, let blocks, let usage):
            if let usage {
                if let messageID { usageByMessage[messageID] = usage } else { anonymousUsage = anonymousUsage + usage }
            }
            var events: [AgentEvent] = []
            for block in blocks {
                switch block {
                case .text(let text):
                    textBlocks.append(text)
                    events.append(.text(text))
                case .toolUse(let id, let name):
                    guard toolIDs.insert(id).inserted else { continue }
                    steps += 1
                    events.append(.toolCall(id: id, name: ClaudeCLI.atlantisTool(name) ?? name))
                    events.append(.progress(steps: steps))
                    if steps > hardStepLimit {
                        stop = .stepLimit
                        stopMessage = "\(bot) kept calling tools past its limit of \(maxSteps) steps, so the run was stopped."
                    }
                }
            }
            return events
        case .toolResult(let id, let isError):
            return [.toolResult(id: id, isError: isError)]
        case .result(let info):
            result = info
            return []
        case .other:
            return []
        }
    }

    /// The CLI must offer nothing but this bot's Atlantis tools, from the one Atlantis server.
    private mutating func checkLockdown(_ info: StreamItem.Initialized) {
        let extraTools = info.tools.filter { name in
            guard let tool = ClaudeCLI.atlantisTool(name) else { return true }
            return !allowedTools.contains(tool)
        }
        let extraServers = info.mcpServers.keys.filter { $0 != ClaudeCLI.serverName }.sorted()
        guard extraTools.isEmpty, extraServers.isEmpty else {
            stop = .refused
            let what = (extraTools + extraServers.map { "server \($0)" }).prefix(6).joined(separator: ", ")
            stopMessage = "Stopped before starting: the Claude CLI offered more than \(bot)'s own tools (\(what)). Atlantis only runs bots locked to their tools."
            return
        }
    }

    /// The run's summary once the process has exited. `todayCostUSD` is filled in by the ledger.
    public func summary(cancelled: Bool, exitCode: Int32?, errorTail: String, durationMs: Int) -> RunSummary {
        let text = textBlocks.joined(separator: "\n\n")
        let cost: Double
        let estimated: Bool
        if let reported = result?.costUSD {
            cost = reported
            estimated = false
        } else {
            cost = usage.conservativeCostUSD
            estimated = cost > 0
        }
        func make(_ status: RunSummary.Status, _ message: String?) -> RunSummary {
            RunSummary(status: status, message: message, steps: steps, costUSD: cost, costEstimated: estimated,
                       durationMs: result?.durationMs ?? durationMs, text: text)
        }
        if let stop { return make(stop, stopMessage) }
        if cancelled { return make(.stopped, "Stopped.") }
        guard let result else {
            let detail = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = exitCode.map { " (exit \($0))" } ?? ""
            return make(.failed, detail.isEmpty ? "The Claude CLI ended without an answer\(code)." : String(detail.suffix(400)))
        }
        if result.subtype.contains("max_turns") {
            return make(.stepLimit, "\(bot) reached its step limit before finishing.")
        }
        if result.subtype.contains("budget") {
            return make(.costLimit, "\(bot) reached today's cost limit during this run.")
        }
        if result.isError || result.subtype != "success" {
            let detail = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return make(.failed, detail.isEmpty ? "The run failed (\(result.subtype))." : String(detail.prefix(400)))
        }
        // Finished, but only after the app refused calls past the limit: say the answer may be partial.
        var done = steps > maxSteps
            ? make(.stepLimit, "\(bot) reached its limit of \(maxSteps) step\(maxSteps == 1 ? "" : "s"), so some lookups were refused and the answer may be incomplete.")
            : make(.ok, nil)
        if text.isEmpty, let final = result.text, !final.isEmpty { done.text = final }
        return done
    }
}
