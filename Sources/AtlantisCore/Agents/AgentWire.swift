import Darwin
import Foundation

/// Everything the daemon needs for one run. The app builds it (it owns the vault and the MCP
/// grants); the daemon only runs the provider and keeps the daily ledger.
public struct AgentRunSpec: Codable, Sendable, Equatable {
    public var runID: String
    public var bot: String
    public var botName: String
    public var provider: AgentProviderKind
    public var model: String
    public var tools: [String]
    public var maxSteps: Int
    public var dailyCostUSD: Double
    public var systemPrompt: String
    public var prompt: String
    /// The MCP grant the app issued for this run; `atlantis-mcp` sends it with every call.
    public var grantToken: String
    public var mcpHelperPath: String
    public var mcpSocketPath: String
    /// The app's choice of `claude` binary (Settings), else the daemon looks for one.
    public var claudePath: String?

    public init(runID: String, bot: String, botName: String, provider: AgentProviderKind, model: String, tools: [String],
                maxSteps: Int, dailyCostUSD: Double, systemPrompt: String, prompt: String, grantToken: String,
                mcpHelperPath: String, mcpSocketPath: String, claudePath: String? = nil) {
        self.runID = runID
        self.bot = bot
        self.botName = botName
        self.provider = provider
        self.model = model
        self.tools = tools
        self.maxSteps = maxSteps
        self.dailyCostUSD = dailyCostUSD
        self.systemPrompt = systemPrompt
        self.prompt = prompt
        self.grantToken = grantToken
        self.mcpHelperPath = mcpHelperPath
        self.mcpSocketPath = mcpSocketPath
        self.claudePath = claudePath
    }

    /// Problems that make the daemon refuse the run before starting anything.
    public func problems() -> [String] {
        var out: [String] = []
        if !BotFile.isValidID(bot) { out.append("bad bot id") }
        if !BotFile.isValidModel(model) { out.append("bad model") }
        if tools.isEmpty || tools.contains(where: { !BotFile.allowedTools.contains($0) }) { out.append("bad tool list") }
        if !BotFile.maxStepsRange.contains(maxSteps) { out.append("bad step limit") }
        if !BotFile.dailyCostRange.contains(dailyCostUSD) { out.append("bad cost cap") }
        if grantToken.count < 32 { out.append("missing grant token") }
        if !mcpHelperPath.hasPrefix("/") || !mcpSocketPath.hasPrefix("/") { out.append("bad helper paths") }
        if prompt.isEmpty || prompt.count > 200_000 { out.append("bad prompt") }
        return out
    }
}

/// One request to the daemon. `run` streams `AgentEvent` frames back on the same connection;
/// the others get one `AgentReply`.
public struct AgentRequest: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable { case ping, run, stop, usage }
    public var op: Op
    public var run: AgentRunSpec?
    public var runID: String?

    public init(op: Op, run: AgentRunSpec? = nil, runID: String? = nil) {
        self.op = op
        self.run = run
        self.runID = runID
    }
}

public struct AgentReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    public var version: String?
    /// Today's spend per bot (for `usage`).
    public var usage: [String: Double]?

    public init(ok: Bool, message: String? = nil, version: String? = nil, usage: [String: Double]? = nil) {
        self.ok = ok
        self.message = message
        self.version = version
        self.usage = usage
    }
}

public enum AgentDaemonInfo {
    public static let version = "0.1.0"

    /// `ATLANTIS_AGENTD_SOCKET` moves it (testing a debug build beside the real app).
    public static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["ATLANTIS_AGENTD_SOCKET"], override.hasPrefix("/") { return override }
        return AppSupport.sockets.appendingPathComponent("agentd.sock").path
    }
}

public enum AgentClientError: Error, Equatable, CustomStringConvertible {
    case notRunning
    case closedEarly
    case badReply
    case socket(String)

    public var description: String {
        switch self {
        case .notRunning: "The agent helper isn't running."
        case .closedEarly: "The agent helper stopped before the run finished."
        case .badReply: "The agent helper sent something unreadable."
        case .socket(let detail): "Couldn't talk to the agent helper: \(detail)"
        }
    }
}

/// The app's side of the daemon socket.
public struct AgentDaemonClient: Sendable {
    public let path: String

    public init(path: String = AgentDaemonInfo.defaultSocketPath) { self.path = path }

    /// One request, one reply (`ping`, `stop`, `usage`).
    public func request(_ request: AgentRequest, timeout: Double = 5) async throws -> AgentReply {
        let path = self.path
        return try await onWorker {
            let fd = try Self.open(path, timeout: timeout)
            defer { close(fd) }
            try Self.send(request, fd)
            let frame = try Self.mapped { try Framing.readFrame(from: fd) }
            guard let reply = try? JSONDecoder().decode(AgentReply.self, from: frame) else { throw AgentClientError.badReply }
            return reply
        }
    }

    /// Starts a run and calls `onEvent` for each event until it finishes. Returns the summary.
    /// `idleTimeout` is the longest gap allowed between two events (a slow tool or model).
    public func run(_ spec: AgentRunSpec, idleTimeout: Double = 600,
                    onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> RunSummary {
        let path = self.path
        return try await onWorker {
            let fd = try Self.open(path, timeout: idleTimeout)
            defer { close(fd) }
            try Self.send(AgentRequest(op: .run, run: spec), fd)
            while true {
                let frame: Data
                do { frame = try Self.mapped { try Framing.readFrame(from: fd) } } catch AgentClientError.socket {
                    throw AgentClientError.closedEarly
                }
                guard let event = try? JSONDecoder().decode(AgentEvent.self, from: frame) else { throw AgentClientError.badReply }
                onEvent(event)
                if case .finished(let summary) = event { return summary }
            }
        }
    }

    private func onWorker<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
        }
    }

    static func open(_ path: String, timeout: Double) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentClientError.socket(String(cString: strerror(errno))) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        do {
            try MCPSocketClient.connect(fd, to: path)
        } catch MCPSocketError.appNotRunning {
            close(fd)
            throw AgentClientError.notRunning
        } catch {
            close(fd)
            throw AgentClientError.socket(String(describing: error))
        }
        Framing.setTimeouts(fd, seconds: timeout)
        return fd
    }

    static func send(_ request: AgentRequest, _ fd: Int32) throws {
        let data = try JSONEncoder().encode(request)
        try mapped { try Framing.writeFrame(data, to: fd) }
    }

    static func mapped<T>(_ work: () throws -> T) throws -> T {
        do { return try work() } catch let failure as Framing.Failure {
            throw AgentClientError.socket("\(failure)")
        }
    }
}
