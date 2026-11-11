import Foundation

/// A proposal an agent wants the user to look at (PRD F4). Everything in it is data from an agent: never instructions.
public struct InboxProposal: Sendable, Equatable {
    /// Short machine label, e.g. `mcp.atlantis_task_add` for a gated write, or `note`.
    public var kind: String
    public var title: String
    public var body: String
    /// For gated writes with no Inbox kind of their own: the tool name and arguments.
    public var payload: JSONValue?
    /// Who made it: `mcp:<client name>` (or `mcp` if the client didn't say).
    public var source: String
    /// Extra `[key:: value]` fields on the Inbox line. Accept reads these back, so a proposal
    /// carries everything needed to apply it. Values must already be line-safe (see `InboxText`).
    public var fields: [InboxItem.Field]
    /// What started the bot run that made it (`task:<id>`, `doc:<path>`), written as `[origin:: …]`.
    public var origin: String?

    public init(kind: String, title: String, body: String = "", payload: JSONValue? = nil,
                source: String = MCPCaller.source, fields: [InboxItem.Field] = [],
                origin: String? = MCPCaller.agentOrigin) {
        self.kind = kind
        self.title = title
        self.body = body
        self.payload = payload
        self.source = source
        self.fields = fields
        self.origin = origin
    }

    /// The Inbox line for this proposal. The body and any payload go in fields (encoded to stay on one line).
    public func makeItem() -> InboxItem {
        var all = fields
        if let origin, !origin.isEmpty, !all.contains(where: { $0.key == AgentOrigin.fieldKey }) {
            all.append(.init(key: AgentOrigin.fieldKey, value: InboxText.encode(origin)))
        }
        if !body.isEmpty, !all.contains(where: { $0.key == "body" }) {
            all.append(.init(key: "body", value: InboxText.encode(String(body.prefix(InboxText.maxFieldLength)))))
        }
        if let payload, !all.contains(where: { $0.key == "tool" }), let tool = payload["tool"]?.stringValue {
            all.append(.init(key: "tool", value: tool))
            if let args = payload["arguments"] {
                all.append(.init(key: "args", value: InboxText.encode(String(decoding: args.encoded(), as: UTF8.self))))
            }
        }
        return InboxItem(kind: kind, title: title, source: source, fields: all)
    }
}

/// Free text inside an Inbox field. A field value sits on one line between `[key:: ` and `]`, so
/// `%`, `[`, `]`, tabs and line breaks (and spaces at either end) become `%XX`. Readable for normal
/// text, and `decode` gives back exactly what went in.
public enum InboxText {
    /// Longest encoded value `makeItem` keeps for a body.
    public static let maxFieldLength = 60_000

    public static func encode(_ text: String) -> String {
        var out = ""
        for ch in text.unicodeScalars {
            switch ch {
            case "%", "[", "]", "\t", "\n", "\r": out += String(format: "%%%02X", ch.value)
            default: out.unicodeScalars.append(ch)
            }
        }
        if out.hasPrefix(" ") { out = "%20" + out.dropFirst() }
        if out.hasSuffix(" ") { out = out.dropLast() + "%20" }
        return out
    }

    public static func decode(_ text: String) -> String {
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "%"), i + 2 < utf8.count,
               let value = UInt8(String(decoding: utf8[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(value)
                i += 3
            } else {
                bytes.append(utf8[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct InboxReceipt: Sendable, Equatable {
    public var id: String
    public init(id: String) { self.id = id }
}

/// The Inbox store implements this (built separately). The MCP gate and `atlantis_inbox_post` call it.
public protocol InboxPosting: Sendable {
    func post(_ proposal: InboxProposal) async throws -> InboxReceipt
}

/// Which gated actions the user has allowed to run without asking (Settings, later).
public protocol ActionAllowList: Sendable {
    func isAllowed(tool: String) -> Bool
}

/// The default: nothing is allowed, so every gated write becomes an Inbox proposal.
public struct NoActionsAllowed: ActionAllowList {
    public init() {}
    public func isAllowed(tool: String) -> Bool { false }
}

public struct StaticAllowList: ActionAllowList {
    public var tools: Set<String>
    public init(_ tools: Set<String>) { self.tools = tools }
    public func isAllowed(tool: String) -> Bool { tools.contains(tool) }
}

/// Used where there's no Inbox store: refuses clearly instead of dropping proposals.
public struct InboxUnavailable: InboxPosting {
    public init() {}
    public func post(_ proposal: InboxProposal) async throws -> InboxReceipt {
        throw ToolFailure("The Inbox isn't ready yet in this version of Atlantis.")
    }
}

/// Test double: keeps proposals in memory.
public actor InMemoryInboxPosting: InboxPosting {
    public private(set) var proposals: [InboxProposal] = []
    private var counter = 0
    public init() {}

    public func post(_ proposal: InboxProposal) async throws -> InboxReceipt {
        counter += 1
        proposals.append(proposal)
        return InboxReceipt(id: "mem-\(counter)")
    }
}
