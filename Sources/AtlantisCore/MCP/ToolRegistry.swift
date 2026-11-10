import Foundation

public typealias ToolHandler = @Sendable (_ arguments: JSONValue) async throws -> ToolResult

/// Holds the tools the app offers over MCP and applies the write gate.
///
/// Other milestones register their tools here; the registry decides what runs:
/// - `read`, `write`, `action`: run.
/// - `gatedWrite`: run only if the allow list says so (and the tool isn't destructive); otherwise
///   the call becomes an Inbox proposal and the handler does not run (PRD §8, F5).
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

    public init(inbox: any InboxPosting, allowList: any ActionAllowList = NoActionsAllowed()) {
        self.inbox = inbox
        self.allowList = allowList
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

        if entry.definition.kind == .gatedWrite, !isAllowed(entry.definition) {
            return await propose(entry, arguments: arguments)
        }
        do {
            return try await entry.handler(arguments)
        } catch let failure as ToolFailure {
            return .error(failure.message)
        } catch {
            return .error("Tool failed: \(error.localizedDescription)")
        }
    }

    private func isAllowed(_ definition: ToolDefinition) -> Bool {
        !definition.destructive && allowList.isAllowed(tool: definition.name)
    }

    private func propose(_ entry: Entry, arguments: JSONValue) async -> ToolResult {
        let name = entry.definition.name
        let proposal: InboxProposal
        if let build = entry.proposal {
            do { proposal = try await build(arguments) } catch let failure as ToolFailure {
                return .error(failure.message) // bad input is refused, not parked in the Inbox
            } catch {
                return .error("\(name) failed: \(error.localizedDescription)")
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
            return ToolResult(text: "Not run yet. \(name) needs the user's approval, so it was proposed in the Atlantis Inbox (id \(receipt.id)). Don't retry; the user will decide.")
        } catch let failure as ToolFailure {
            return .error("\(name) needs the user's approval but couldn't be proposed: \(failure.message)")
        } catch {
            return .error("\(name) needs the user's approval but couldn't be proposed: \(error.localizedDescription)")
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
