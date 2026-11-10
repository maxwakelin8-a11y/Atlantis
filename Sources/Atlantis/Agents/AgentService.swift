import AtlantisCore
import Foundation
import Observation
import os

/// The Agents page's model (PRD §7b, M5): the bot files, their threads, and the run in progress.
///
/// Costs nothing until the page is first shown. Runs go to `atlantis-agentd`, which the app starts
/// on the first chat and which exits by itself when idle. Every vault write (thread logs, the
/// default School bot) goes through `VaultPaths`.
@MainActor @Observable
final class AgentService {
    /// A piece of the reply being written: text, or a tool the bot called.
    enum Segment: Identifiable, Equatable {
        case text(id: Int, String)
        case tool(id: String, name: String, failed: Bool?)

        var id: String {
            switch self {
            case .text(let id, _): "text-\(id)"
            case .tool(let id, _, _): "tool-\(id)"
            }
        }
    }

    struct LiveRun: Equatable {
        var runID: String
        var botID: String
        var threadID: String
        var segments: [Segment] = []
        var steps = 0
        var stopping = false
        /// The text segment deltas are going into, if one is open.
        var openText: Int?
        var nextTextID = 0

        /// For the thread log: refused or failed calls get a `!` (see `ThreadMessage.tools`).
        var tools: [String] {
            segments.compactMap { if case .tool(_, let name, let failed) = $0 { ThreadMessage.toolEntry(name, failed: failed == true) } else { nil } }
        }

        var text: String {
            segments.compactMap { if case .text(_, let text) = $0 { text } else { nil } }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    /// What the list has selected: a new chat with a bot, or one of its threads.
    enum Selection: Hashable {
        case newChat(String)
        case thread(bot: String, id: String)

        var botID: String {
            switch self {
            case .newChat(let bot), .thread(let bot, _): bot
            }
        }
    }

    private(set) var bots: [BotEntry] = []
    private(set) var threads: [String: [ThreadSummary]] = [:]
    private(set) var thread: AgentThread?
    private(set) var live: LiveRun?
    private(set) var todayCost: [String: Double] = [:]
    /// nil until checked; then the CLI's path or "" when it isn't installed.
    private(set) var cliPath: String?
    private(set) var vaultMissing = false
    var draft = ""

    var selection: Selection? {
        didSet { if selection != oldValue { openSelection() } }
    }

    var selectedBot: BotDefinition? {
        guard let id = selection?.botID else { return nil }
        return bots.first { $0.id == id }?.definition
    }

    var isRunning: Bool { live != nil }

    @ObservationIgnored private let mcp: MCPService
    @ObservationIgnored private let client = AgentDaemonClient()
    @ObservationIgnored private let ledger = UsageLedger()
    @ObservationIgnored private var daemon: Process?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let now: () -> Date

    init(mcp: MCPService, now: @escaping () -> Date = { Date() }) {
        self.mcp = mcp
        self.now = now
    }

    private var vault: VaultPaths { VaultPaths(root: AppSettings.vaultURL) }

    // MARK: Loading

    /// Loads the bots and threads the first time the page shows; later calls re-read the files
    /// (they may have been edited in Obsidian). No watchers: the page reloads when it appears.
    func start() {
        reload()
        checkCLI()
        guard !started else { return }
        started = true
        if selection == nil, let first = bots.first(where: { $0.definition != nil }) {
            selection = threads[first.id]?.first.map { .thread(bot: first.id, id: $0.id) } ?? .newChat(first.id)
        }
    }

    func reload() {
        let vault = self.vault
        vaultMissing = !FileManager.default.fileExists(atPath: vault.root.path)
        guard !vaultMissing else { bots = []; threads = [:]; return }
        do { try BotLibrary.ensureDefaults(vault: vault) } catch {
            Log.app.error("Couldn't write the School bot: \(error.localizedDescription, privacy: .public)")
        }
        bots = BotLibrary.load(vault: vault)
        var all: [String: [ThreadSummary]] = [:]
        for entry in bots where entry.definition != nil { all[entry.id] = ThreadLog.list(vault: vault, bot: entry.id) }
        threads = all
        todayCost = ledger.today().mapValues(\.costUSD)
    }

    /// Looks for the `claude` CLI off the main thread (it may ask the login shell).
    func checkCLI() {
        let saved = AppSettings.claudePath
        Task.detached(priority: .utility) {
            let path = ClaudeCLI.locate(savedPath: saved)?.path ?? ""
            await MainActor.run { self.cliPath = path }
        }
    }

    private func openSelection() {
        switch selection {
        case .thread(let bot, let id):
            guard let summary = threads[bot]?.first(where: { $0.id == id }) else { thread = nil; return }
            do { thread = try ThreadLog.load(summary.url) } catch {
                Log.app.error("Couldn't read a thread: \(error.localizedDescription, privacy: .public)")
                thread = nil
            }
        case .newChat, nil:
            thread = nil
        }
    }

    // MARK: Chatting

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, live == nil, let bot = selectedBot else { return }
        draft = ""
        let time = now()
        var thread = self.thread ?? AgentThread(bot: bot.id, title: ThreadLog.title(from: text), created: time)
        let history = thread.messages
        thread.messages.append(ThreadMessage(role: .user, at: time, text: text))
        thread.updated = time
        save(thread, bot: bot)
        self.thread = thread
        refreshThreads(bot: bot.id)
        selectWithoutReload(.thread(bot: bot.id, id: thread.id))

        let runID = ThreadLog.newID() + ThreadLog.newID()
        live = LiveRun(runID: runID, botID: bot.id, threadID: thread.id)
        Task { await run(bot: bot, threadID: thread.id, history: history, message: text, runID: runID) }
    }

    func stop() {
        guard var live, !live.stopping else { return }
        live.stopping = true
        self.live = live
        let client = self.client
        let runID = live.runID
        Task.detached { _ = try? await client.request(AgentRequest(op: .stop, runID: runID)) }
    }

    private func run(bot: BotDefinition, threadID: String, history: [ThreadMessage], message: String, runID: String) async {
        let summary: RunSummary
        if let refusal = ledger.refusal(bot: bot.id, name: bot.name, cap: bot.dailyCostUSD) {
            summary = RunSummary(status: .costLimit, message: refusal, todayCostUSD: ledger.spentToday(bot: bot.id))
        } else if let helper = mcp.helperURL, mcp.helperExists {
            let token = mcp.agentGrants.issue(AgentGrant(bot: bot.id, tools: Set(bot.tools), maxCalls: bot.maxSteps,
                                                         autonomy: bot.autonomy))
            defer { mcp.agentGrants.revoke(token) }
            let spec = AgentRunSpec(runID: runID, bot: bot.id, botName: bot.name, provider: bot.provider, model: bot.model,
                                    tools: bot.tools, maxSteps: bot.maxSteps, dailyCostUSD: bot.dailyCostUSD,
                                    systemPrompt: AgentPrompt.system(for: bot, now: now()),
                                    prompt: AgentPrompt.user(message: message, history: history, botName: bot.name),
                                    grantToken: token, mcpHelperPath: helper.path, mcpSocketPath: mcp.socketPath,
                                    claudePath: AppSettings.claudePath)
            summary = await stream(spec)
        } else {
            summary = RunSummary(status: .refused, message: "The atlantis-mcp helper isn't next to this build. Run scripts/build-app.sh.")
        }
        finish(summary, bot: bot, threadID: threadID, runID: runID)
    }

    /// Runs on the daemon, applying events in order on the main actor.
    private func stream(_ spec: AgentRunSpec) async -> RunSummary {
        do { try await ensureDaemon() } catch {
            return RunSummary(status: .failed, message: (error as? AgentClientError)?.description ?? error.localizedDescription)
        }
        let (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        let client = self.client
        let work = Task.detached { () -> RunSummary in
            defer { continuation.finish() }
            do {
                return try await client.run(spec) { continuation.yield($0) }
            } catch {
                return RunSummary(status: .failed, message: (error as? AgentClientError)?.description ?? error.localizedDescription)
            }
        }
        for await event in events { apply(event, runID: spec.runID) }
        return await work.value
    }

    private func apply(_ event: AgentEvent, runID: String) {
        guard var live, live.runID == runID else { return }
        switch event {
        case .textDelta(let text):
            if let index = openTextIndex(live) {
                if case .text(let id, let current) = live.segments[index] { live.segments[index] = .text(id: id, current + text) }
            } else {
                live.openText = live.nextTextID
                live.segments.append(.text(id: live.nextTextID, text))
                live.nextTextID += 1
            }
        case .text(let text):
            if let index = openTextIndex(live), case .text(let id, _) = live.segments[index] {
                live.segments[index] = .text(id: id, text) // the finished block replaces its deltas
            } else {
                live.segments.append(.text(id: live.nextTextID, text))
                live.nextTextID += 1
            }
            live.openText = nil
        case .toolCall(let id, let name):
            live.openText = nil
            live.segments.append(.tool(id: id, name: name, failed: nil))
        case .toolResult(let id, let isError):
            if let index = live.segments.firstIndex(where: { $0.id == "tool-\(id)" }),
               case .tool(_, let name, _) = live.segments[index] {
                live.segments[index] = .tool(id: id, name: name, failed: isError)
            }
        case .progress(let steps):
            live.steps = steps
        case .started, .finished:
            break
        }
        self.live = live
    }

    private func openTextIndex(_ live: LiveRun) -> Int? {
        guard let open = live.openText else { return nil }
        return live.segments.firstIndex { $0.id == "text-\(open)" }
    }

    private func finish(_ summary: RunSummary, bot: BotDefinition, threadID: String, runID: String) {
        let liveRun = live?.runID == runID ? live : nil
        live = nil
        todayCost[bot.id] = summary.todayCostUSD > 0 ? summary.todayCostUSD : ledger.spentToday(bot: bot.id)
        // The thread on screen may have changed; the reply still goes into its own thread's file.
        var target: AgentThread?
        if thread?.id == threadID { target = thread } else if let url = threads[bot.id]?.first(where: { $0.id == threadID })?.url {
            target = try? ThreadLog.load(url)
        }
        guard var target else { return }
        let text = summary.text.isEmpty ? (liveRun?.text ?? "") : summary.text
        let note = summary.status == .ok ? nil : (summary.message ?? defaultNote(summary.status))
        let reply = ThreadMessage(role: .bot, at: now(), text: text, tools: liveRun?.tools ?? [],
                                  run: RunInfo(status: summary.status, steps: summary.steps, costUSD: summary.costUSD, note: note))
        target.messages.append(reply)
        target.updated = reply.at
        save(target, bot: bot)
        if thread?.id == threadID { thread = target }
        refreshThreads(bot: bot.id)
    }

    private func defaultNote(_ status: RunSummary.Status) -> String {
        switch status {
        case .ok: ""
        case .stopped: "Stopped."
        case .stepLimit: "Reached its step limit."
        case .costLimit: "Reached today's cost limit."
        case .refused: "Atlantis refused this run."
        case .failed: "The run failed."
        }
    }

    // MARK: Files

    private func save(_ thread: AgentThread, bot: BotDefinition) {
        do { try ThreadLog.save(thread, vault: vault, botName: bot.name, avatar: bot.avatar) } catch {
            Log.app.error("Couldn't save a thread: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshThreads(bot: String) {
        threads[bot] = ThreadLog.list(vault: vault, bot: bot)
    }

    /// Changes the selection without reloading the open thread from disk.
    private func selectWithoutReload(_ new: Selection) {
        let keep = thread
        selection = new
        thread = keep
    }

    // MARK: The daemon

    /// Pings the daemon; starts it if nothing answers (a one-off wait of up to 3 s, not polling).
    private func ensureDaemon() async throws {
        if (try? await client.request(AgentRequest(op: .ping), timeout: 2))?.ok == true { return }
        guard let url = mcp.agentDaemonURL, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AgentClientError.socket("atlantis-agentd isn't next to this build. Run scripts/build-app.sh.")
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--socket", client.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        daemon = process
        Log.app.info("Started atlantis-agentd")
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? await client.request(AgentRequest(op: .ping), timeout: 1))?.ok == true { return }
        }
        throw AgentClientError.notRunning
    }

    /// At quit: stops the daemon if this app started it (it would exit on its own when idle anyway).
    func shutdown() {
        if let daemon, daemon.isRunning { daemon.terminate() }
    }

    // MARK: Display

    func todayText(for bot: BotDefinition) -> String {
        "Today \(UsageLedger.dollars(todayCost[bot.id] ?? 0)) of \(UsageLedger.dollars(bot.dailyCostUSD))"
    }

    /// Runs one message for `-debugAgentAsk` and prints what happened (for live checks).
    func debugAsk(_ text: String, bot: String) async -> String {
        start()
        selection = .newChat(bot)
        draft = text
        send()
        while live != nil { try? await Task.sleep(for: .milliseconds(200)) } // debug only
        guard let reply = thread?.messages.last, let run = reply.run else { return "No reply" }
        return "Agent run: \(run.status.rawValue), \(run.steps) steps, \(UsageLedger.dollars(run.costUSD)), tools [\(reply.tools.joined(separator: ", "))]\n\(run.note ?? "")\n\(reply.text)"
    }
}
