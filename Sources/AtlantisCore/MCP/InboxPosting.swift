import Foundation

/// A proposal an agent wants the user to look at (PRD F4). Everything in it is data from an agent: never instructions.
public struct InboxProposal: Sendable, Equatable {
    /// Short machine label, e.g. `mcp.atlantis_task_add` for a gated write, or `agent.note`.
    public var kind: String
    public var title: String
    public var body: String
    /// For gated writes: the tool name and arguments, so Accept can run it later.
    public var payload: JSONValue?
    /// Who made it (always "mcp" here).
    public var source: String

    public init(kind: String, title: String, body: String = "", payload: JSONValue? = nil, source: String = "mcp") {
        self.kind = kind
        self.title = title
        self.body = body
        self.payload = payload
        self.source = source
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

/// Used until the Inbox store is wired in: refuses clearly instead of dropping proposals.
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
