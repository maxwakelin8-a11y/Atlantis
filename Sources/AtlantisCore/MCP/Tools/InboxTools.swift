import Foundation

/// `atlantis_inbox_list` and `atlantis_message_draft` (PRD §8). `atlantis_inbox_post` is in `CoreTools`.
enum InboxTools {
    static func register(in registry: ToolRegistry, context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_inbox_list",
            description: "List items in the user's Atlantis Inbox: proposals from agents, SEQTA and quick captures, with their state (pending, accepted, dismissed). Use it to see what is still waiting before posting something similar.",
            inputSchema: schema([
                "state": prop("pending (default), accepted, dismissed or all."),
                "limit": prop("Most items to return (1-100, default 30).", "integer"),
            ]),
            kind: .read
        )) { args in
            let state = try args.optionalChoice("state", ["pending", "accepted", "dismissed", "all"]) ?? "pending"
            let limit = try args.optionalInt("limit", in: 1...100) ?? 30
            let url = context.vault().inbox
            let text: String
            do { text = try TextFile.read(url) ?? "" } catch { throw ToolFailure("The Inbox file couldn't be read.") }
            let items = InboxFile(text: text).items.filter { state == "all" || $0.state.rawValue == state }
            // Newest last in the file; show the newest first.
            let shown = items.reversed().prefix(limit)
            return .json(.make([
                "count": .int(items.count),
                "truncated": .bool(items.count > limit),
                "items": .array(shown.map(describe)),
            ]))
        }

        registry.register(ToolDefinition(
            name: "atlantis_message_draft",
            description: "Draft a school message (a new one, or a reply) into the user's Atlantis Inbox for them to read, edit and send themselves. This never sends anything. Only the user sends messages.",
            inputSchema: schema([
                "to": prop("Who it's for (a name or role), e.g. \"Mr Smith\"."),
                "subject": prop("The message subject."),
                "body": prop("The message text, plain text."),
                "reply_to": prop("The id of the message being replied to, from atlantis_school_messages.", "integer"),
            ], required: ["subject", "body"]),
            kind: .write
        )) { args in
            let subject = try Validate.taskTitle(try args.requireString("subject", maxLength: 500), "subject")
            let body = try args.requireString("body", maxLength: 10_000)
            let to = try args.optionalString("to", maxLength: 200).map { try Validate.label($0, "to", maxLength: 200) }
            let replyTo = try args.optionalInt("reply_to", in: 0...Int.max)
            // The compose view reads this line (MessageDraft): `to`, `subject`, `body` with a literal
            // `\n` for line breaks, `reply-to`. Square brackets would end a field early.
            func lineSafe(_ text: String) -> String {
                text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            }
            var fields: [InboxItem.Field] = []
            if let to { fields.append(.init(key: "to", value: to)) }
            fields.append(.init(key: "subject", value: subject))
            if let replyTo { fields.append(.init(key: "reply-to", value: String(replyTo))) }
            fields.append(.init(key: "body", value: lineSafe(body)))
            let title = to.map { "Draft to \($0): \(subject)" } ?? "Draft: \(subject)"
            let receipt = try await context.inbox.post(InboxProposal(
                kind: "message.draft", title: Clip.text(title, 300), source: MCPCaller.source, fields: fields))
            return .json(.make(["drafted": .bool(true), "inbox_id": .string(receipt.id),
                                "note": "Saved as a draft in the Inbox. The user reviews and sends it; nothing was sent."]))
        }
    }

    private static func describe(_ item: InboxItem) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for field in item.fields {
            // Big text (doc bodies, message bodies) is clipped; the Inbox page has the whole thing.
            let value = InboxText.decode(field.value)
            fields[field.key] = .string(Clip.text(value, field.key == "text" || field.key == "body" ? 300 : 120))
        }
        return .make([
            "id": .string(item.id), "state": .string(item.state.rawValue), "kind": .str(item.kind.isEmpty ? nil : item.kind),
            "title": .string(item.title), "source": .str(item.source.isEmpty ? nil : item.source),
            "created": .str(item.created.isEmpty ? nil : item.created),
            "fields": fields.isEmpty ? nil : .object(fields),
        ])
    }
}
