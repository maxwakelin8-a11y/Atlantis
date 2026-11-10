import Foundation

/// Who is calling a tool, for the Inbox's `source` field (`mcp:claude-code`).
///
/// The name comes from the MCP `initialize` request's `clientInfo`. The stdio helper passes it to
/// the app inside `tools/call`'s `_meta`. It's only a label: the socket is already limited to the
/// same user, so a made-up name can't gain anything.
public enum MCPCaller {
    @TaskLocal public static var clientName: String?
    /// The agent grant token the stdio helper passed in `_meta` (set only while a call is handled).
    @TaskLocal public static var agentToken: String?
    /// The bot making this call, once its token checked out (`AgentToolGate`).
    @TaskLocal public static var agentName: String?
    /// Gated writes must become Inbox proposals whatever the allow list says (bots that only suggest).
    @TaskLocal public static var proposalsOnly = false

    public static let metaKey = "atlantis/client"
    /// `_meta` key for the agent grant token (`ATLANTIS_AGENT_TOKEN` in the helper's environment).
    public static let agentTokenKey = "atlantis/agent-token"
    /// Environment variable the agent daemon sets for `atlantis-mcp`.
    public static let agentTokenEnv = "ATLANTIS_AGENT_TOKEN"

    /// A short label made of letters, digits and `. _ -` (nil if nothing usable is left).
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = raw.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
                || $0 == " "
        }
        let text = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let clipped = String(text.prefix(40))
        return clipped.isEmpty ? nil : clipped
    }

    /// `agent:<bot>` for a bot, else `mcp:<client>`, or plain `mcp` when the client didn't say who it is.
    public static var source: String {
        if let agentName { return "agent:\(agentName)" }
        return clientName.map { "mcp:\($0)" } ?? "mcp"
    }
}

/// What the handler learned from `initialize`. A reference so every message on a connection shares it.
final class MCPClientInfo: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?

    var value: String? { lock.withLock { name } }
    func set(_ newValue: String?) { lock.withLock { name = newValue } }
}
