import Foundation
import Security

/// What one bot run may do over MCP. The app issues a grant before a run and revokes it after.
public struct AgentGrant: Sendable, Equatable {
    public var bot: String
    public var tools: Set<String>
    /// Tool calls allowed before the gate refuses ("max steps per run").
    public var maxCalls: Int
    public var autonomy: Autonomy
    public var calls: Int = 0

    public init(bot: String, tools: Set<String>, maxCalls: Int, autonomy: Autonomy) {
        self.bot = bot
        self.tools = tools
        self.maxCalls = maxCalls
        self.autonomy = autonomy
    }
}

/// Grants by token. Tokens are 32 random bytes, live in memory only, and die with the app.
public final class AgentGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [String: AgentGrant] = [:]

    public init() {}

    /// A new token for this grant.
    public func issue(_ grant: AgentGrant) -> String {
        let token = Self.randomToken()
        lock.withLock { grants[token] = grant }
        return token
    }

    public func revoke(_ token: String) {
        lock.withLock { _ = grants.removeValue(forKey: token) }
    }

    public func grant(for token: String) -> AgentGrant? {
        lock.withLock { grants[token] }
    }

    public enum Decision: Equatable, Sendable {
        case allowed(AgentGrant)
        case refused(String)
    }

    /// Checks one call and counts it. Unknown tokens, tools off the list and calls past the limit are refused.
    public func authorize(token: String, tool: String) -> Decision {
        lock.withLock {
            guard var grant = grants[token] else {
                return .refused("This bot run isn't known to Atlantis (it ended or was stopped). No tools are available.")
            }
            guard grant.tools.contains(tool) else {
                return .refused("\(grant.bot) isn't allowed to use \(tool). Only the tools in its file work.")
            }
            guard grant.calls < grant.maxCalls else {
                return .refused("Step limit reached (\(grant.maxCalls) tool calls for this run). Don't call more tools: answer now with what you have, and say what you couldn't check.")
            }
            grant.calls += 1
            grants[token] = grant
            return .allowed(grant)
        }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SecRandom doesn't fail in practice; fall back to two UUIDs rather than a weak token.
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The app's MCP backend: plain MCP clients (Claude Code, OpenMausBot) get every tool as before;
/// a call that carries an agent token gets only that bot's tools (defence in depth on top of the
/// CLI's `--allowedTools`). A token that doesn't check out gets nothing, never full access.
public struct AgentToolGate: ToolBackend {
    public let inner: any ToolBackend
    public let grants: AgentGrants

    public init(inner: any ToolBackend, grants: AgentGrants) {
        self.inner = inner
        self.grants = grants
    }

    public func listTools() async throws -> [ToolDefinition] {
        let all = try await inner.listTools()
        guard let token = MCPCaller.agentToken else { return all }
        guard let grant = grants.grant(for: token) else { return [] }
        return all.filter { grant.tools.contains($0.name) }
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
        guard let token = MCPCaller.agentToken else { return try await inner.callTool(name: name, arguments: arguments) }
        switch grants.authorize(token: token, tool: name) {
        case .refused(let reason):
            return .error(reason)
        case .allowed(let grant):
            let result = try await MCPCaller.$agentName.withValue(grant.bot) {
                try await MCPCaller.$proposalsOnly.withValue(grant.autonomy.proposalsOnly) {
                    try await inner.callTool(name: name, arguments: arguments)
                }
            }
            return ToolResult(text: UntrustedText.wrap(result.text, source: name), isError: result.isError)
        }
    }
}

/// Content a bot reads (SEQTA, docs, tasks, other people's messages) is data, never instructions
/// (PRD §17 "Prompt injection").
///
/// The approach, in layers:
/// 1. **The real protection is what a bot can do**, not what it reads: the CLI only offers the bot's
///    `mcp__atlantis__…` tools (no shell, files or web), the app refuses anything else per token,
///    nothing can send a SEQTA message, and writes become Inbox proposals the user approves.
/// 2. Every tool result a bot gets is wrapped in `<atlantis_data source="…">…</atlantis_data>`, and
///    the bot's system prompt says text inside those tags is data, even if it claims otherwise.
/// 3. Text inside a wrapper can't close it early: the tag names are defused in the content.
public enum UntrustedText {
    public static let tag = "atlantis_data"
    /// Tag names a piece of content must not be able to open or close.
    static let reservedTags = [tag, "thread_history", "user_message"]

    public static func wrap(_ text: String, source: String) -> String {
        let safeSource = source.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return "<\(tag) source=\"\(safeSource)\">\n\(defuse(text))\n</\(tag)>"
    }

    /// Breaks any reserved tag in `text` (`<atlantis_data` → `<atlantis-data`), case-insensitively.
    public static func defuse(_ text: String) -> String {
        var out = text
        for name in reservedTags {
            let dashed = name.replacingOccurrences(of: "_", with: "-")
            out = out.replacingOccurrences(of: name, with: dashed, options: .caseInsensitive)
        }
        return out
    }
}
