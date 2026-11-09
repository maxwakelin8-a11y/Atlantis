import Foundation

/// What the compose view starts from: a reply, or a `message.draft` proposal that an agent left
/// in the Inbox (PRD §7b). A draft is only ever *opened* in the compose view; sending still takes
/// the user's Send click and the confirm.
///
/// Inbox line: `- [ ] Reply to Ms Example [kind:: message.draft] [to:: Ms Example, Mr Sample]
/// [subject:: Excursion form] [body:: Hi Ms Example,\n\nYes, I'll bring it.] [reply-to:: 8101]`.
/// Inbox values are single-line, so `\n` in `body` means a line break.
public struct MessageDraft: Sendable, Equatable {
    public var subject: String
    public var body: String
    /// Names the draft is addressed to. They aren't SEQTA ids, so the user picks the people.
    public var toNames: [String]
    /// The message being replied to.
    public var replyTo: Int?

    public init(subject: String = "", body: String = "", toNames: [String] = [], replyTo: Int? = nil) {
        self.subject = subject; self.body = body; self.toNames = toNames; self.replyTo = replyTo
    }

    public init(inbox item: InboxItem) {
        let names = (item.field("to") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body = (item.field("body") ?? "").replacingOccurrences(of: "\\n", with: "\n")
        self.init(subject: item.field("subject") ?? item.title, body: body, toNames: names,
                  replyTo: item.field("reply-to").flatMap { Int($0) })
    }

    /// "Re: " once, however many times it's been replied to.
    public static func replySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("re:") ? trimmed : "Re: " + trimmed
    }
}
