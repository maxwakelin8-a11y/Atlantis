import Foundation

/// A write an `ask` bot wants to make, waiting for the user (PRD §7b "ask: approve before applying").
///
/// The write is posted to the Inbox as a normal proposal first; this is the same proposal, shown
/// as an approve/deny card in the bot's thread too. Approving accepts the Inbox item (which applies
/// it through `InboxActions`), denying dismisses it. Deciding in either place resolves the wait.
public struct PendingApproval: Sendable, Equatable, Identifiable {
    /// The Inbox item's id.
    public var id: String
    /// The run that asked (the card shows in that run's thread).
    public var runID: String
    public var bot: String
    public var tool: String
    public var title: String
    public var detail: String

    public init(id: String, runID: String, bot: String, tool: String, title: String, detail: String = "") {
        self.id = id
        self.runID = runID
        self.bot = bot
        self.tool = tool
        self.title = title
        self.detail = detail
    }
}

public enum ApprovalOutcome: Sendable, Equatable {
    /// The user approved and the Inbox applied it.
    case approved
    /// The user said no.
    case denied
    /// No decision in time: it stays in the Inbox as a normal proposal.
    case expired
    /// The run ended (stopped, finished, killed) while waiting.
    case cancelled
}

/// Waits for the user's decision on an `ask` bot's write.
public protocol ApprovalWaiting: Sendable {
    func wait(for approval: PendingApproval) async -> ApprovalOutcome
}

/// For places with nobody to ask (tests, plain MCP setups): the proposal just stays in the Inbox.
public struct NoApprovalWaiting: ApprovalWaiting {
    public init() {}
    public func wait(for approval: PendingApproval) async -> ApprovalOutcome { .expired }
}

/// Test double: answers every request with a fixed outcome and remembers what was asked.
public final class FixedApprovals: ApprovalWaiting, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [PendingApproval] = []
    public let outcome: ApprovalOutcome

    public init(_ outcome: ApprovalOutcome) { self.outcome = outcome }
    public var requests: [PendingApproval] { lock.withLock { asked } }

    public func wait(for approval: PendingApproval) async -> ApprovalOutcome {
        lock.withLock { asked.append(approval) }
        return outcome
    }
}

/// The app's approvals: holds each waiting write until the user decides, the run ends, or the
/// wait times out. One one-shot timer per waiting approval, only while a run is waiting (no idle work).
public final class ApprovalCenter: ApprovalWaiting, @unchecked Sendable {
    private struct Waiter {
        var approval: PendingApproval
        var continuation: CheckedContinuation<ApprovalOutcome, Never>
        var timer: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var waiters: [String: Waiter] = [:]
    private let timeout: Duration
    private var changed: (@Sendable ([PendingApproval]) -> Void)?

    /// `timeout` must stay under the MCP helper's agent call timeout (`SocketToolBackend.agentCallTimeout`).
    public init(timeout: Duration = .seconds(240)) {
        self.timeout = timeout
    }

    /// Called (on any thread) whenever the waiting list changes.
    public var onChange: (@Sendable ([PendingApproval]) -> Void)? {
        get { lock.withLock { changed } }
        set { lock.withLock { changed = newValue } }
    }

    public var pending: [PendingApproval] {
        lock.withLock { waiters.values.map(\.approval).sorted { $0.id < $1.id } }
    }

    public func wait(for approval: PendingApproval) async -> ApprovalOutcome {
        let outcome: ApprovalOutcome = await withCheckedContinuation { continuation in
            lock.withLock { waiters[approval.id] = Waiter(approval: approval, continuation: continuation, timer: nil) }
            let timeout = self.timeout
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.resolve(id: approval.id, .expired)
            }
            lock.withLock { waiters[approval.id]?.timer = timer }
            notify()
        }
        return outcome
    }

    /// Resolves one waiting approval. Returns false if nothing was waiting on that id.
    @discardableResult
    public func resolve(id: String, _ outcome: ApprovalOutcome) -> Bool {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        guard let waiter else { return false }
        waiter.timer?.cancel()
        waiter.continuation.resume(returning: outcome)
        notify()
        return true
    }

    /// The Inbox changed: any waiting item that's no longer pending is decided.
    public func inboxDecided(_ decisions: [String: InboxItem.State]) {
        let ids = lock.withLock { Array(waiters.keys) }
        for id in ids {
            switch decisions[id] {
            case .accepted?: resolve(id: id, .approved)
            case .dismissed?: resolve(id: id, .denied)
            default: break
            }
        }
    }

    /// The run ended: everything it was waiting on is cancelled (the Inbox items stay pending).
    public func cancel(runID: String) {
        let ids = lock.withLock { waiters.values.filter { $0.approval.runID == runID }.map(\.approval.id) }
        for id in ids { resolve(id: id, .cancelled) }
    }

    private func notify() {
        let (callback, list) = lock.withLock { (changed, waiters.values.map(\.approval).sorted { $0.id < $1.id }) }
        callback?(list)
    }
}
