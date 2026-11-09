import AtlantisCore
import Foundation
import Observation

/// What the compose view is editing. Plain text; recipients are people picked from SEQTA's lists.
@MainActor @Observable
final class ComposeState: Identifiable {
    let id = UUID()
    var recipients: [SeqtaPerson] = []
    var subject: String
    var body: String
    var blind = false
    /// Names an agent's draft was addressed to. They aren't SEQTA ids, so the user picks people;
    /// these show as hints until they have.
    var hintNames: [String]
    /// The Inbox proposal this started from, marked accepted once the message is sent.
    let inboxItemID: String?
    let replyTo: Int?

    var sending = false
    var error: String?

    init(draft: MessageDraft, recipients: [SeqtaPerson] = [], inboxItemID: String? = nil) {
        subject = draft.subject
        body = draft.body
        hintNames = draft.toNames
        replyTo = draft.replyTo
        self.recipients = recipients
        self.inboxItemID = inboxItemID
    }

    /// The message as it is now, for the confirm sheet and for sending.
    var outgoing: SeqtaSend.Outgoing {
        .init(recipients: recipients, subject: subject, body: body, blind: blind)
    }

    /// Why Send is disabled, or nil when the message is complete.
    var problem: SeqtaSend.Problem? { SeqtaSend.validate(outgoing) }
}

/// The Messages page's state: the list (from the cache), the open message, and the compose view.
///
/// It reads the cache and asks SEQTA only when the user does something (open a message, search
/// for people, Send). The one send is `send(confirmed:)`, called from the confirm sheet.
@MainActor @Observable
final class MessagesModel {
    private(set) var selectedID: Int?
    /// The open message's whole body (nil until it has loaded).
    private(set) var open: Message?
    private(set) var opening = false
    private(set) var openError: String?

    /// The compose view, when it's open.
    var compose: ComposeState?

    private(set) var staff: [SeqtaPerson] = []
    private(set) var students: [SeqtaPerson] = []
    private(set) var loadingPeople: Set<SeqtaPerson.Kind> = []
    private(set) var peopleError: String?

    /// Called with the Inbox proposal's id after a message that came from one was sent.
    @ObservationIgnored var onDraftSent: ((String?) -> Void)?

    @ObservationIgnored private let sync: SeqtaSync
    @ObservationIgnored private let data: SeqtaData
    @ObservationIgnored private var openTask: Task<Void, Never>?

    init(sync: SeqtaSync, data: SeqtaData) {
        self.sync = sync
        self.data = data
    }

    // MARK: Reading

    func select(_ id: Int?) {
        guard id != selectedID else { return }
        openTask?.cancel()
        selectedID = id
        open = nil
        openError = nil
        guard let id else { opening = false; return }
        if let cached = data.cache.message(id: id) {
            open = cached
            opening = false
            data.markOpened(id)
            return
        }
        opening = true
        openTask = Task { [weak self] in await self?.fetch(id) }
    }

    func retryOpen() {
        guard let id = selectedID else { return }
        selectedID = nil
        select(id)
    }

    private func fetch(_ id: Int) async {
        do {
            let message = try await sync.readMessage(id: id)
            guard selectedID == id, !Task.isCancelled else { return }
            open = message
            data.markOpened(id)
        } catch let error as SeqtaSyncError {
            guard selectedID == id else { return }
            openError = error.message
        } catch {
            guard selectedID == id else { return }
            openError = error.localizedDescription
        }
        if selectedID == id { opening = false }
    }

    // MARK: Composing

    func startCompose(_ draft: MessageDraft = MessageDraft(), inboxItemID: String? = nil) {
        compose = ComposeState(draft: draft, inboxItemID: inboxItemID)
        Task { await loadPeople(.staff) }
    }

    /// A reply to the open message, addressed to its sender.
    func startReply(to message: Message) {
        let summary = message.summary
        var recipients: [SeqtaPerson] = []
        var hints: [String] = []
        if let senderID = summary.senderID, let kind = SeqtaPerson.Kind(rawValue: summary.senderType) {
            recipients = [SeqtaPerson(id: senderID, kind: kind, name: summary.sender)]
        } else {
            hints = [summary.sender]
        }
        let quoted = Self.quote(message)
        compose = ComposeState(
            draft: MessageDraft(subject: MessageDraft.replySubject(summary.subject), body: quoted, toNames: hints, replyTo: summary.id),
            recipients: recipients)
        Task { await loadPeople(.staff) }
    }

    /// The reply starts with a blank line above the quoted message.
    private static func quote(_ message: Message) -> String {
        let who = message.summary.sender.isEmpty ? "them" : message.summary.sender
        let lines = message.body.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }
        return "\n\nOn \(message.summary.date?.formatted(date: .abbreviated, time: .shortened) ?? "an earlier day"), \(who) wrote:\n" + lines.joined(separator: "\n")
    }

    func closeCompose() { compose = nil }

    /// One request per list, kept for as long as the app runs (the lists are big).
    func loadPeople(_ kind: SeqtaPerson.Kind) async {
        guard (kind == .staff ? staff : students).isEmpty, !loadingPeople.contains(kind) else { return }
        loadingPeople.insert(kind)
        peopleError = nil
        defer { loadingPeople.remove(kind) }
        do {
            let people = try await sync.people(kind)
            if kind == .staff { staff = people } else { students = people }
        } catch let error as SeqtaSyncError {
            peopleError = error.message
        } catch {
            peopleError = error.localizedDescription
        }
    }

    func people(_ kind: SeqtaPerson.Kind) -> [SeqtaPerson] { kind == .staff ? staff : students }

    // MARK: Sending

    /// Sends what the confirm sheet showed. Closes the compose view when SEQTA accepts it.
    func send(_ state: ComposeState, confirmed: SeqtaSend.Confirmation) async {
        guard !state.sending else { return }
        state.sending = true
        state.error = nil
        defer { state.sending = false }
        do {
            try await sync.send(state.outgoing, confirmed: confirmed)
            compose = nil
            onDraftSent?(state.inboxItemID)
        } catch let error as SeqtaSend.Problem {
            state.error = error.message
        } catch let error as SeqtaSyncError {
            state.error = error.message
        } catch {
            state.error = error.localizedDescription
        }
    }
}
