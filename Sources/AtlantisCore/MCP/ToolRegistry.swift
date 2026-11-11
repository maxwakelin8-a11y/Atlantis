import Foundation

public typealias ToolHandler = @Sendable (_ arguments: JSONValue) async throws -> ToolResult

/// Holds the tools the app offers over MCP and applies the write gate.
///
/// Other milestones register their tools here; the registry decides what runs:
/// - `read`, `write`, `action`: run.
/// - `gatedWrite`: routed by `WriteRoute.for(…)`: run, become an Inbox proposal (the handler does
///   not run), or, for an `ask` bot, become a proposal the run waits on (PRD §7b, §8, F5).
public final class ToolRegistry: ToolBackend, @unchecked Sendable {
    private struct Entry {
        var definition: ToolDefinition
        var handler: ToolHandler
        var describe: (@Sendable (JSONValue) -> String)?
        var proposal: (@Sendable (JSONValue) async throws -> InboxProposal)?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let inbox: any InboxPosting
    private let allowList: any ActionAllowList
    private let approvals: any ApprovalWaiting

    public init(inbox: any InboxPosting, allowList: any ActionAllowList = NoActionsAllowed(),
                approvals: any ApprovalWaiting = NoApprovalWaiting()) {
        self.inbox = inbox
        self.allowList = allowList
        self.approvals = approvals
    }

    /// Adds or replaces a tool. For a gated write, `proposal` builds the Inbox item (validating the
    /// arguments, and throwing `ToolFailure` if they're bad). Without it, `describe` gives a one-line
    /// summary and the proposal just records the tool name and arguments.
    public func register(_ definition: ToolDefinition,
                         describe: (@Sendable (JSONValue) -> String)? = nil,
                         proposal: (@Sendable (JSONValue) async throws -> InboxProposal)? = nil,
                         handler: @escaping ToolHandler) {
        lock.withLock {
            if entries[definition.name] == nil { order.append(definition.name) }
            entries[definition.name] = Entry(definition: definition, handler: handler, describe: describe, proposal: proposal)
        }
    }

    public func listTools() async throws -> [ToolDefinition] {
        lock.withLock { order.compactMap { entries[$0]?.definition } }
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
        let entry = lock.withLock { entries[name] }
        guard let entry else { throw JSONRPCError.invalidParams("Unknown tool: \(name)") }

        if entry.definition.kind == .gatedWrite {
            let route = WriteRoute.for(tool: name, destructive: entry.definition.destructive,
                                       autonomy: MCPCaller.autonomy, allowList: allowList)
            switch route {
            case .run: break
            case .propose: return await propose(entry, arguments: arguments).result
            case .askFirst: return await proposeAndWait(entry, arguments: arguments)
            }
        }
        do {
            return try await entry.handler(arguments)
        } catch let failure as ToolFailure {
            return .error(failure.message)
        } catch {
            return .error("Tool failed: \(error.localizedDescription)")
        }
    }

    private struct Proposed {
        var result: ToolResult
        var receipt: InboxReceipt?
        var proposal: InboxProposal?
    }

    private func propose(_ entry: Entry, arguments: JSONValue) async -> Proposed {
        let name = entry.definition.name
        let proposal: InboxProposal
        if let build = entry.proposal {
            do { proposal = try await build(arguments) } catch let failure as ToolFailure {
                return Proposed(result: .error(failure.message)) // bad input is refused, not parked in the Inbox
            } catch {
                return Proposed(result: .error("\(name) failed: \(error.localizedDescription)"))
            }
        } else {
            let summary = entry.describe?(arguments) ?? "Run \(name)"
            proposal = InboxProposal(
                kind: "mcp.\(name)",
                title: String(summary.prefix(200)),
                body: "An agent asked to run \(name). It hasn't run; accept it in the Inbox to run it.",
                payload: ["tool": .string(name), "arguments": arguments]
            )
        }
        do {
            let receipt = try await inbox.post(proposal)
            return Proposed(result: ToolResult(text: "Not run yet. \(name) needs the user's approval, so it was proposed in the Atlantis Inbox (id \(receipt.id)). Don't retry; the user will decide."),
                            receipt: receipt, proposal: proposal)
        } catch let failure as ToolFailure {
            return Proposed(result: .error("\(name) needs the user's approval but couldn't be proposed: \(failure.message)"))
        } catch {
            return Proposed(result: .error("\(name) needs the user's approval but couldn't be proposed: \(error.localizedDescription)"))
        }
    }

    /// `ask` bots: post the proposal, then hold the call until the user approves (the Inbox applies
    /// it), denies, or the wait runs out (it stays in the Inbox).
    private func proposeAndWait(_ entry: Entry, arguments: JSONValue) async -> ToolResult {
        let posted = await propose(entry, arguments: arguments)
        guard let receipt = posted.receipt, let proposal = posted.proposal else { return posted.result }
        let name = entry.definition.name
        let outcome = await approvals.wait(for: PendingApproval(
            id: receipt.id, runID: MCPCaller.agentRunID ?? "", bot: MCPCaller.agentName ?? "", tool: name,
            title: proposal.title, detail: proposal.body))
        switch outcome {
        case .approved:
            return ToolResult(text: "The user approved this and Atlantis applied it (Inbox id \(receipt.id)).")
        case .denied:
            return .error("The user denied this (Inbox id \(receipt.id)). It wasn't applied. Don't try it again; carry on without it.")
        case .expired:
            return ToolResult(text: "The user hasn't decided yet. It's waiting in the Atlantis Inbox (id \(receipt.id)) and hasn't been applied. Don't retry; carry on.")
        case .cancelled:
            return .error("This run ended before the user decided. It's still waiting in the Atlantis Inbox (id \(receipt.id)).")
        }
    }
}

/// What happens to a gated write (`write*` tools, PRD §8), by who's calling (PRD §7b autonomy):
///
/// | Caller | On the Settings allow list | Not on it |
/// |---|---|---|
/// | MCP client (no bot) | runs | Inbox proposal |
/// | bot, `suggest` | Inbox proposal | Inbox proposal |
/// | bot, `ask` | proposal, run waits for approve/deny | same |
/// | bot, `act` | runs | Inbox proposal |
///
/// Destructive tools never run directly.
public enum WriteRoute: Equatable, Sendable {
    case run
    case propose
    case askFirst

    public static func `for`(tool: String, destructive: Bool, autonomy: Autonomy?,
                             allowList: any ActionAllowList) -> WriteRoute {
        let allowed = !destructive && allowList.isAllowed(tool: tool)
        switch autonomy {
        case nil, .act?: return allowed ? .run : .propose
        case .suggest?: return .propose
        case .ask?: return .askFirst
        }
    }
}

/// Tools that need nothing from other milestones.
public enum CoreTools {
    public static func register(in registry: ToolRegistry, appVersion: String, inbox: any InboxPosting) {
        registry.register(ToolDefinition(
            name: "atlantis_ping",
            description: "Check that Atlantis is running. Returns the app version.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            kind: .read
        )) { _ in
            ToolResult(text: "Atlantis \(appVersion) is running.")
        }

        registry.register(ToolDefinition(
            name: "atlantis_inbox_post",
            description: "Post a proposal or note to the user's Atlantis Inbox for them to accept, edit or dismiss. Always allowed; nothing happens until the user accepts.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "One line the user sees in the Inbox."],
                    "body": ["type": "string", "description": "Optional details, in Markdown."],
                ],
                "required": ["title"],
                "additionalProperties": false,
            ],
            kind: .write
        )) { args in
            let title = try args.requireString("title", maxLength: 500)
            let body = try args.optionalString("body") ?? ""
            let receipt = try await inbox.post(InboxProposal(kind: "note", title: title, body: body))
            return ToolResult(text: "Posted to the Inbox (id \(receipt.id)).")
        }
    }
}
