import Foundation

// SENDING A SEQTA MESSAGE (PRD §7d, AGENTS.md hard rule).
//
// This file is the *only* place that knows how to send. Messages are sent by the user alone: from
// the Messages compose view, with an explicit Send click and then a confirm sheet that lists the
// recipients and subject. Nothing else may reach this code:
//
// - `SeqtaRequest.isAllowed` (the read-only allow-list the sync and every read path use) rejects
//   `SeqtaSend.path`, and `SeqtaSendRequest` is a different type that `SeqtaTransport.send`
//   cannot take.
// - The MCP server, `atlantis-mcp`, the sync runner and the Inbox never reference this file; a
//   test (`SeqtaSendIsolationTests`) scans the sources and fails if they do, or if anything but
//   the compose view creates a `Confirmation`.
// - `send` needs a `Confirmation` that matches the message word for word, so what the user
//   confirmed is what goes out.
//
// Bots can only draft into the Inbox (`message.draft`); opening a draft in Messages still needs
// the same Send + confirm.

public struct SeqtaSendRequest: Sendable, Equatable {
    public let path: String
    public let body: String
}

public enum SeqtaSend {
    public static let path = "/seqta/student/save/message"

    /// The most SEQTA's own composer accepts.
    public static let maxSubject = 200
    public static let maxBody = 10_000

    /// A message as the user wrote it.
    public struct Outgoing: Sendable, Equatable {
        public var recipients: [SeqtaPerson]
        public var subject: String
        /// Plain text; blank lines become paragraphs.
        public var body: String
        /// Hide recipients from each other.
        public var blind: Bool

        public init(recipients: [SeqtaPerson], subject: String, body: String, blind: Bool = false) {
            self.recipients = recipients; self.subject = subject; self.body = body; self.blind = blind
        }
    }

    public enum Problem: Error, Equatable, Sendable {
        case noRecipients, noSubject, noBody, subjectTooLong, bodyTooLong
        /// What the confirm sheet showed isn't what is being sent.
        case notConfirmed
        /// SEQTA refused it, or never answered.
        case rejected(String)

        public var message: String {
            switch self {
            case .noRecipients: "Add at least one recipient."
            case .noSubject: "Add a subject."
            case .noBody: "Write a message."
            case .subjectTooLong: "The subject is too long (\(SeqtaSend.maxSubject) characters at most)."
            case .bodyTooLong: "The message is too long (\(SeqtaSend.maxBody) characters at most)."
            case .notConfirmed: "The message changed after you confirmed it. Check it and send again."
            case .rejected(let why): "SEQTA didn't send it: \(why)"
            }
        }
    }

    /// Proof that the user saw this exact message in the confirm sheet and said yes. Only the
    /// compose view's confirm sheet creates one (checked by a test).
    public struct Confirmation: Sendable, Equatable {
        let message: Outgoing
        public init(confirming message: Outgoing) { self.message = message }
    }

    public static func validate(_ message: Outgoing) -> Problem? {
        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.recipients.isEmpty { return .noRecipients }
        if subject.isEmpty { return .noSubject }
        if subject.count > maxSubject { return .subjectTooLong }
        if body.isEmpty { return .noBody }
        if body.count > maxBody { return .bodyTooLong }
        return nil
    }

    /// The request SEQTA's own composer makes (`save/message`), without attachments.
    public static func request(for message: Outgoing) throws -> SeqtaSendRequest {
        if let problem = validate(message) { throw problem }
        let participants: [[String: Any]] = message.recipients.map { person in
            [person.kind.rawValue: true, "id": person.id]
        }
        let payload: [String: Any] = [
            "subject": message.subject.trimmingCharacters(in: .whitespacesAndNewlines),
            "contents": html(fromPlain: message.body),
            "participants": participants,
            "blind": message.blind,
            "files": [Int](),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return SeqtaSendRequest(path: path, body: String(decoding: data, as: UTF8.self))
    }

    /// Plain text → paragraphs, as SEQTA's composer produces.
    public static func html(fromPlain text: String) -> String {
        let normal = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return normal.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { paragraph in
            let escaped = paragraph
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            return "<p>" + escaped.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        }.joined()
    }

    /// Whether SEQTA accepted the message (HTTP ok and a status of 200, or none).
    public static func check(_ response: SeqtaResponse) throws {
        if response.status == 0 { throw SeqtaSyncError.network("no answer") }
        if response.status == 401 || response.status == 403 { throw SeqtaSyncError.notSignedIn }
        guard (200..<300).contains(response.status) else { throw Problem.rejected("HTTP \(response.status)") }
        if let object = (try? JSONSerialization.jsonObject(with: Data(response.body.utf8))) as? JSONObject,
           let status = object.string("status"), status != "200" {
            if status == "401" || status == "403" { throw SeqtaSyncError.notSignedIn }
            throw Problem.rejected("status \(status)")
        }
    }

    /// Sends one message through `transport`: one request, then the connection is closed. The
    /// confirmation must be for this very message.
    public static func send(_ message: Outgoing, confirmed: Confirmation, via transport: any SeqtaSendTransport) async throws {
        guard confirmed.message == message else { throw Problem.notConfirmed }
        let request = try request(for: message)
        let response: SeqtaResponse
        do {
            try await transport.open()
            response = try await transport.post(request)
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
        try check(response)
    }
}

/// A connection that can post one send request. Kept apart from `SeqtaTransport.send`, which
/// refuses anything that isn't on the read-only allow-list.
public protocol SeqtaSendTransport: SeqtaTransport {
    func post(_ request: SeqtaSendRequest) async throws -> SeqtaResponse
}
