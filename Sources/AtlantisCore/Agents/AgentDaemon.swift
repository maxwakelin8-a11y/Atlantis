import Darwin
import Foundation
import os

/// `atlantis-agentd`'s server: runs bots for the app over a Unix socket (0600, same-user only).
///
/// Started by the app on the first chat, it exits by itself after `idleExitAfter` seconds with no
/// runs and no requests: one one-shot timer, reset on every request (no repeating timers).
public final class AgentDaemon: @unchecked Sendable {
    public let socketURL: URL
    private let ledger: UsageLedger
    private let providers: [AgentProviderKind: any AgentProvider]
    private let idleExitAfter: Double?
    private let onIdleExit: @Sendable () -> Void
    private let maxConcurrentRuns: Int
    private var server: UnixSocketServer!

    private let lock = NSLock()
    private var runs: [String: RunControl] = [:]
    private var busy = 0
    private var idleWork: DispatchWorkItem?
    private let idleQueue = DispatchQueue(label: "au.lifeos.atlantis.agentd.idle", qos: .utility)
    private let log = Logger(subsystem: "au.lifeos.atlantis", category: "agentd")

    public init(socketURL: URL, ledger: UsageLedger, providers: [AgentProviderKind: any AgentProvider],
                idleExitAfter: Double? = 600, maxConcurrentRuns: Int = 3,
                peerCheck: @escaping @Sendable (Int32) -> Bool = PeerCredentials.isSameUser,
                onIdleExit: @escaping @Sendable () -> Void = { exit(0) }) {
        self.socketURL = socketURL
        self.ledger = ledger
        self.providers = providers
        self.idleExitAfter = idleExitAfter
        self.maxConcurrentRuns = maxConcurrentRuns
        self.onIdleExit = onIdleExit
        server = UnixSocketServer(socketURL: socketURL, label: "agentd", maxConnections: 16, peerCheck: peerCheck) { [weak self] fd in
            self?.serve(fd)
        }
    }

    public func start() throws {
        try server.start()
        scheduleIdleExit()
    }

    /// Stops every run, closes the socket and removes it.
    public func shutdown() {
        let controls = lock.withLock { Array(runs.values) }
        controls.forEach { $0.cancel() }
        lock.withLock { idleWork?.cancel(); idleWork = nil }
        server.stop()
    }

    public var activeRuns: Int { lock.withLock { runs.count } }

    // MARK: Idle exit

    private func begin() {
        lock.withLock {
            busy += 1
            idleWork?.cancel()
            idleWork = nil
        }
    }

    private func end() {
        lock.withLock { busy -= 1 }
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        guard let idleExitAfter else { return }
        lock.withLock {
            idleWork?.cancel()
            guard busy == 0, runs.isEmpty else { idleWork = nil; return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let idle = self.lock.withLock { self.busy == 0 && self.runs.isEmpty }
                guard idle else { return }
                self.log.info("Idle; exiting")
                self.server.stop()
                self.onIdleExit()
            }
            idleWork = work
            idleQueue.asyncAfter(deadline: .now() + idleExitAfter, execute: work)
        }
    }

    // MARK: Requests

    private func serve(_ fd: Int32) {
        begin()
        defer { end() }
        Framing.setTimeouts(fd, seconds: 10)
        guard let frame = try? Framing.readFrame(from: fd),
              let request = try? JSONDecoder().decode(AgentRequest.self, from: frame) else { return }
        switch request.op {
        case .ping:
            reply(AgentReply(ok: true, version: AgentDaemonInfo.version), fd)
        case .usage:
            reply(AgentReply(ok: true, usage: ledger.today().mapValues(\.costUSD)), fd)
        case .stop:
            let control = lock.withLock { request.runID.flatMap { runs[$0] } }
            control?.cancel()
            reply(AgentReply(ok: control != nil, message: control == nil ? "No such run." : nil), fd)
        case .run:
            guard let spec = request.run else { reply(AgentReply(ok: false, message: "run needs a spec"), fd); return }
            // Events can be far apart while a model thinks; only writing is time-limited.
            Framing.setTimeouts(fd, seconds: 30)
            run(spec, fd)
        }
    }

    private func reply(_ reply: AgentReply, _ fd: Int32) {
        guard let data = try? JSONEncoder().encode(reply) else { return }
        try? Framing.writeFrame(data, to: fd)
    }

    private func run(_ spec: AgentRunSpec, _ fd: Int32) {
        let writer = EventWriter(fd: fd)
        func finish(_ summary: RunSummary) {
            var final = summary
            final.todayCostUSD = ledger.spentToday(bot: spec.bot)
            writer.send(.finished(final))
        }

        let problems = spec.problems()
        guard problems.isEmpty else {
            finish(RunSummary(status: .refused, message: "Atlantis refused this run (\(problems.joined(separator: ", ")))."))
            return
        }
        if let refusal = ledger.refusal(bot: spec.bot, name: spec.botName, cap: spec.dailyCostUSD) {
            finish(RunSummary(status: .costLimit, message: refusal))
            return
        }
        guard let provider = providers[spec.provider] else {
            finish(RunSummary(status: .refused, message: "No provider \(spec.provider.rawValue) in this build."))
            return
        }
        let control = RunControl()
        let admitted = lock.withLock { () -> Bool in
            guard runs[spec.runID] == nil, runs.count < maxConcurrentRuns else { return false }
            runs[spec.runID] = control
            return true
        }
        guard admitted else {
            finish(RunSummary(status: .refused, message: "Too many bots are running at once. Try again when one finishes."))
            return
        }
        defer { lock.withLock { _ = runs.removeValue(forKey: spec.runID) } }

        log.info("Run \(spec.runID, privacy: .public) for \(spec.bot, privacy: .public) on \(spec.model, privacy: .public)")
        writer.send(.started(runID: spec.runID))
        let budget = ledger.remaining(bot: spec.bot, cap: spec.dailyCostUSD)
        // If the app goes away mid-run, stop rather than spend for nobody.
        writer.onBroken = { control.cancel() }
        var summary = provider.run(spec, budgetUSD: budget, control: control) { event in writer.send(event) }
        if summary.costUSD > 0 || summary.status != .refused {
            ledger.record(bot: spec.bot, costUSD: summary.costUSD)
        }
        summary.todayCostUSD = ledger.spentToday(bot: spec.bot)
        log.info("Run \(spec.runID, privacy: .public) ended: \(summary.status.rawValue, privacy: .public), \(summary.steps) steps")
        writer.send(.finished(summary))
    }
}

/// Writes events to the app's connection; remembers if it broke.
final class EventWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var broken = false
    var onBroken: (@Sendable () -> Void)?

    init(fd: Int32) { self.fd = fd }

    func send(_ event: AgentEvent) {
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard !broken, let data = try? JSONEncoder().encode(event) else { return nil }
            do { try Framing.writeFrame(data, to: fd); return nil } catch {
                broken = true
                return onBroken
            }
        }
        action?()
    }
}
