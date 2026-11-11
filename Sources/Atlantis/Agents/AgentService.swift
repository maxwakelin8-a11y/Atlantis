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
        /// What started it: nil for a chat, else `task:<id>` / `doc:<path>` (AgentOrigin).
        var origin: String?
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
    /// Every run in progress, by run id: chats, assigned tasks and @mentions can run side by side.
    private(set) var runs: [String: LiveRun] = [:]
    /// Writes `ask` bots are waiting on (shown as approve/deny cards in their threads).
    private(set) var approvals: [PendingApproval] = []
    /// Why approving a card failed (by Inbox id), e.g. the task changed meanwhile.
    private(set) var approvalErrors: [String: String] = [:]
    /// The last finished task run per task id (this session); after a relaunch the Inbox is the record.
    private(set) var taskResults: [String: TaskRunResult] = [:]
    private(set) var todayCost: [String: Double] = [:]
    /// Automatic runs (morning, events, hand-offs from Chief) waiting their turn, one at a time (M7).
    private(set) var queue = RunQueue()
    /// Automatic runs that never started today (daily cap, cost cap, switched off).
    private(set) var skipped: [SkippedRun] = []
    /// Threads started today, every bot (Today's Team card). Refreshed when a run starts or ends.
    private(set) var todayThreads: [ThreadSummary] = []
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

    /// The run writing into the open thread, if any.
    var live: LiveRun? {
        guard let id = thread?.id else { return nil }
        return runs.values.first { $0.threadID == id }
    }

    var isRunning: Bool { live != nil }

    func isRunning(thread id: String) -> Bool { runs.values.contains { $0.threadID == id } }

    @ObservationIgnored private let mcp: MCPService
    /// The app's stores, created on first use (results and approvals go through the Inbox).
    @ObservationIgnored private let inbox: @MainActor () -> InboxStore
    @ObservationIgnored private let tasks: @MainActor () -> TaskStore
    @ObservationIgnored private let client = AgentDaemonClient()
    @ObservationIgnored private let ledger = UsageLedger()
    /// What automatic runs happened today (daily cap, morning once a day).
    @ObservationIgnored let triggerLedger: TriggerLedger
    /// Hand-offs per delegating run (`AgentDelegation.maxPerRun`).
    @ObservationIgnored private var delegations: [String: Int] = [:]
    @ObservationIgnored private var daemon: Process?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let now: @Sendable () -> Date

    init(mcp: MCPService, inbox: @escaping @MainActor () -> InboxStore, tasks: @escaping @MainActor () -> TaskStore,
         now: @escaping @Sendable () -> Date = { Date() }, triggerLedger: TriggerLedger? = nil) {
        self.mcp = mcp
        self.inbox = inbox
        self.tasks = tasks
        self.now = now
        self.triggerLedger = triggerLedger ?? TriggerLedger(now: now)
        mcp.approvals.onChange = { [weak self] list in
            Task { @MainActor [weak self] in self?.approvalsChanged(list) }
        }
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
        var thread = self.thread ?? AgentThread(bot: bot.id, title: ThreadLog.title(from: text), created: time, trigger: .chat)
        let history = thread.messages
        thread.messages.append(ThreadMessage(role: .user, at: time, text: text))
        thread.updated = time
        save(thread, bot: bot)
        self.thread = thread
        refreshThreads(bot: bot.id)
        selectWithoutReload(.thread(bot: bot.id, id: thread.id))

        let runID = ThreadLog.newID() + ThreadLog.newID()
        runs[runID] = LiveRun(runID: runID, botID: bot.id, threadID: thread.id)
        let prompt = AgentPrompt.user(message: text, history: history, botName: bot.name)
        Task { await run(bot: bot, threadID: thread.id, prompt: prompt, runID: runID, job: nil) }
    }

    /// Stops the run in the open thread.
    func stop() {
        guard let live else { return }
        stop(runID: live.runID)
    }

    func stop(runID: String) {
        guard var run = runs[runID], !run.stopping else { return }
        run.stopping = true
        runs[runID] = run
        mcp.approvals.cancel(runID: runID) // a call waiting on approval returns now
        let client = self.client
        Task.detached { _ = try? await client.request(AgentRequest(op: .stop, runID: runID)) }
    }

    /// A run started by a task or an @mention: its answer goes to the Inbox, linked by `origin`.
    struct Job {
        var origin: String
        /// Short words for the Inbox title ("Turing essay draft").
        var subject: String
        /// Started by Atlantis (morning, an event, a hand-off): no one is watching its thread, so an
        /// `ask` bot runs as `suggest` (its writes wait in the Inbox instead of blocking the queue).
        var unattended = false
    }

    @discardableResult
    private func run(bot: BotDefinition, threadID: String, prompt: String, runID: String, job: Job?,
                     depth: Int = 0) async -> RunSummary.Status {
        let summary: RunSummary
        if let refusal = ledger.refusal(bot: bot.id, name: bot.name, cap: bot.dailyCostUSD) {
            summary = RunSummary(status: .costLimit, message: refusal, todayCostUSD: ledger.spentToday(bot: bot.id))
        } else if let helper = mcp.helperURL, mcp.helperExists {
            let autonomy = job?.unattended == true ? Autonomy.unattended(bot.autonomy) : bot.autonomy
            let token = mcp.agentGrants.issue(AgentGrant(bot: bot.id, tools: Set(bot.tools), maxCalls: bot.maxSteps,
                                                         autonomy: autonomy, runID: runID, origin: job?.origin,
                                                         depth: depth))
            defer {
                mcp.agentGrants.revoke(token)
                mcp.approvals.cancel(runID: runID)
            }
            let spec = AgentRunSpec(runID: runID, bot: bot.id, botName: bot.name, provider: bot.provider, model: bot.model,
                                    tools: bot.tools, maxSteps: bot.maxSteps, dailyCostUSD: bot.dailyCostUSD,
                                    systemPrompt: AgentPrompt.system(for: bot, now: now(), team: loadedBots),
                                    prompt: prompt,
                                    grantToken: token, mcpHelperPath: helper.path, mcpSocketPath: mcp.socketPath,
                                    claudePath: AppSettings.claudePath)
            summary = await stream(spec)
        } else {
            summary = RunSummary(status: .refused, message: "The atlantis-mcp helper isn't next to this build. Run scripts/build-app.sh.")
        }
        await finish(summary, bot: bot, threadID: threadID, runID: runID, job: job)
        delegations[runID] = nil
        return summary.status
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
        guard var live = runs[runID] else { return }
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
        runs[runID] = live
    }

    private func openTextIndex(_ live: LiveRun) -> Int? {
        guard let open = live.openText else { return nil }
        return live.segments.firstIndex { $0.id == "text-\(open)" }
    }

    private func finish(_ summary: RunSummary, bot: BotDefinition, threadID: String, runID: String, job: Job?) async {
        let liveRun = runs.removeValue(forKey: runID)
        todayCost[bot.id] = summary.todayCostUSD > 0 ? summary.todayCostUSD : ledger.spentToday(bot: bot.id)
        // The thread on screen may have changed; the reply still goes into its own thread's file.
        var target: AgentThread?
        if thread?.id == threadID { target = thread } else if let url = threads[bot.id]?.first(where: { $0.id == threadID })?.url {
            target = try? ThreadLog.load(url)
        }
        let text = summary.text.isEmpty ? (liveRun?.text ?? "") : summary.text
        let note = summary.status == .ok ? nil : (summary.message ?? defaultNote(summary.status))
        if var target {
            let reply = ThreadMessage(role: .bot, at: now(), text: text, tools: liveRun?.tools ?? [],
                                      run: RunInfo(status: summary.status, steps: summary.steps, costUSD: summary.costUSD, note: note))
            target.messages.append(reply)
            target.updated = reply.at
            save(target, bot: bot)
            if thread?.id == threadID { thread = target }
            refreshThreads(bot: bot.id)
        }
        guard let job else { return }
        // The answer goes to the Inbox, linked back to the task or doc.
        let proposal = AgentResultNote.proposal(botID: bot.id, botName: bot.name, origin: job.origin, subject: job.subject,
                                                reply: text, status: summary.status, note: note, threadID: threadID)
        var inboxID: String?
        do { inboxID = try await inbox().post(proposal.makeItem()).id } catch {
            Log.app.error("Couldn't post a bot's answer to the Inbox: \(error.localizedDescription, privacy: .public)")
        }
        if let taskID = AgentOrigin.taskID(job.origin) {
            taskResults[taskID] = TaskRunResult(bot: bot.id, ok: summary.status == .ok, message: note, inboxID: inboxID)
        }
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
        let list = ThreadLog.list(vault: vault, bot: bot)
        threads[bot] = list
        let day = DayStamp(now())
        todayThreads = todayThreads.filter { $0.bot != bot } + list.filter { DayStamp($0.created) == day }
    }

    /// Re-reads today's threads for every bot (Today's Team card, when it appears). Reads only
    /// files whose names start with today's date.
    func refreshToday() {
        let day = DayStamp(now()).description
        let vault = self.vault
        todayThreads = loadedBots.flatMap { ThreadLog.list(vault: vault, bot: $0.id, startedOn: day) }
        todayCost = ledger.today().mapValues(\.costUSD)
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

    /// Assigns the first open task whose title contains `title` to `bot`, waits for the run and
    /// prints what landed in the Inbox (`-debugAgentTask`, for live checks on a made-up vault).
    func debugTask(_ title: String, bot: String) async -> String {
        reload()
        let store = tasks()
        store.start()
        store.reload()
        guard let task = store.tasks.first(where: { $0.isOpen && $0.title.localizedCaseInsensitiveContains(title) }) else {
            return "No open task matching \(title)"
        }
        let (id, problem) = assign(task, to: bot)
        if let problem { return "Refused: \(problem)" }
        await debugWaitForRuns()
        return debugReport(origin: AgentOrigin.task(id))
    }

    /// Prints the Inbox items a task or mention run made (debug).
    func debugReport(origin: String) -> String {
        let store = inbox()
        store.reload()
        let items = AgentResultNote.linked(origin: origin, in: store.items)
        guard !items.isEmpty else { return "Nothing in the Inbox for \(origin)" }
        return items.map { item in
            "Inbox \(item.id) [\(item.kind)] \(item.source): \(item.title)\n" + InboxText.decode(item.field("body") ?? "")
        }.joined(separator: "\n---\n")
    }

    /// Waits for every run to finish (debug only). With `debugAutoApprove`, approves what's asked.
    func debugWaitForRuns() async {
        try? await Task.sleep(for: .milliseconds(300))
        while !runs.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            if debugAutoApprove, let first = approvals.first {
                try? await Task.sleep(for: .seconds(2))
                print("Approving: \(first.title)")
                approve(first)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    @ObservationIgnored var debugAutoApprove = false

    /// Waits until no run is going and nothing is queued (debug only).
    func debugWaitForQueue() async {
        try? await Task.sleep(for: .milliseconds(300))
        while !runs.isEmpty || !queue.all.isEmpty { await debugWaitForRuns() }
    }

    /// Today's runs and what they posted (`-debugMorning`).
    func debugTeamReport() -> String {
        refreshToday()
        let store = inbox()
        store.reload()
        var out = ["Runs today: \(todayThreads.count), skipped: \(skipped.count), automatic runs counted: \(triggerLedger.runsToday)"]
        for thread in todayThreads.sorted(by: { $0.created < $1.created }) {
            out.append("- \(thread.bot) [\(thread.trigger?.raw ?? "chat")] \(thread.status?.rawValue ?? "running"): \(thread.title)")
        }
        for skip in skipped { out.append("- skipped \(skip.bot) [\(skip.trigger.raw)]: \(skip.reason)") }
        let origins = Set(todayThreads.compactMap(\.origin))
        for origin in origins.sorted() { out.append("--- \(origin)\n" + debugReport(origin: origin)) }
        return out.joined(separator: "\n")
    }

    /// Asks Chief, waits for its hand-offs, prints everything (`-debugTeamAsk`).
    func debugTeamAsk(_ text: String) async -> String {
        start()
        guard let chief = loadedBots.first(where: \.isRouter) else { return "No router bot (Chief)" }
        let reply = await debugAsk(text, bot: chief.id)
        guard let thread else { return reply }
        await debugWaitForQueue()
        let handed = handoffs(fromBot: chief.id, threadID: thread.id)
            .map { "- \($0.bot): \($0.title) [\($0.status?.rawValue ?? "?")]" }
        return reply + "\nHand-offs:\n" + (handed.isEmpty ? "(none)" : handed.joined(separator: "\n"))
            + "\n--- Inbox\n" + debugReport(origin: AgentDelegation.origin(fromBot: chief.id, threadID: thread.id))
    }

    /// Selects a bot's latest thread, or a new chat with it (`-debugAgentOpen`).
    func debugOpenLatest(bot id: String) {
        selection = threads[id]?.first.map { .thread(bot: id, id: $0.id) } ?? .newChat(id)
    }

    /// A made-up approval card in the open thread, for screenshots (`-debugApprovalCard`).
    func debugShowApprovalCard() async {
        start()
        // Prefer an `ask` bot's latest thread (the fixture's Coach).
        if let ask = bots.compactMap(\.definition).first(where: { $0.autonomy == .ask }), let latest = threads[ask.id]?.first {
            selection = .thread(bot: ask.id, id: latest.id)
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let thread, let bot = selectedBot else { return }
        let runID = "debug-run"
        var run = LiveRun(runID: runID, botID: bot.id, threadID: thread.id)
        run.segments = [.text(id: 0, "I'll add a study block for the Forces report so it's on your list."),
                        .tool(id: "debug-tool", name: "atlantis_task_add", failed: nil)]
        run.steps = 2
        runs[runID] = run
        approvals = [PendingApproval(id: "i-debug001", runID: runID, bot: bot.id, tool: "atlantis_task_add",
                                     title: "Add task: Start the forces report method",
                                     detail: "Due Thursday · 45 min · Science. Draft the method section before period 3 so you can ask Mr Newton questions.")]
    }

    // MARK: Approvals (`ask` bots)

    private func approvalsChanged(_ list: [PendingApproval]) {
        approvals = list
        approvalErrors = approvalErrors.filter { id, _ in list.contains { $0.id == id } }
    }

    func approvals(forRun runID: String) -> [PendingApproval] { approvals.filter { $0.runID == runID } }

    /// Approve = accept the Inbox item, which applies it; the waiting run hears about it from the Inbox.
    func approve(_ approval: PendingApproval) {
        approvalErrors[approval.id] = nil
        Task {
            do { try await inbox().accept(id: approval.id) } catch {
                approvalErrors[approval.id] = error.localizedDescription
            }
        }
    }

    func deny(_ approval: PendingApproval) {
        do { try inbox().dismiss(id: approval.id) } catch {
            approvalErrors[approval.id] = error.localizedDescription
        }
    }

    // MARK: Assigned tasks

    struct TaskRunResult: Equatable {
        var bot: String
        var ok: Bool
        var message: String?
        var inboxID: String?
    }

    enum TaskStatus: Equatable {
        case working(bot: String)
        case waitingForApproval(bot: String)
        case done(bot: String, inboxID: String?)
        case failed(bot: String, message: String)
    }

    /// Bots that can take tasks (`task` in their triggers).
    var taskBots: [BotDefinition] { loadedBots.filter(\.allowsTask) }
    /// Bots that can be @mentioned in docs (`mention` in their triggers).
    var mentionBots: [BotDefinition] { loadedBots.filter(\.allowsMention) }

    private var loadedBots: [BotDefinition] {
        if bots.isEmpty { reloadBotsOnly() }
        return bots.compactMap(\.definition)
    }

    /// Reads the bot files (no threads), for the Tasks and Docs pickers.
    func reloadBotsOnly() {
        let vault = self.vault
        guard FileManager.default.fileExists(atPath: vault.root.path) else { bots = []; return }
        do { try BotLibrary.ensureDefaults(vault: vault) } catch {
            Log.app.error("Couldn't write the default bots: \(error.localizedDescription, privacy: .public)")
        }
        bots = BotLibrary.load(vault: vault)
    }

    func bot(_ id: String) -> BotDefinition? { loadedBots.first { $0.id == id } }

    /// What the task's latest bot run is doing: in progress here, or the latest answer in the Inbox.
    func taskStatus(_ task: TaskItem) -> TaskStatus? {
        let origin = AgentOrigin.task(task.id)
        if let run = runs.values.first(where: { $0.origin == origin }) {
            return approvals.contains { $0.runID == run.runID } ? .waitingForApproval(bot: run.botID) : .working(bot: run.botID)
        }
        if let result = taskResults[task.id] {
            return result.ok ? .done(bot: result.bot, inboxID: result.inboxID)
                : .failed(bot: result.bot, message: result.message ?? "The run failed.")
        }
        if let note = AgentResultNote.latest(origin: origin, in: inbox().items) {
            let bot = note.source.hasPrefix("agent:") ? String(note.source.dropFirst(6)) : ""
            return AgentResultNote.failed(note) ? .failed(bot: bot, message: "See the Inbox.") : .done(bot: bot, inboxID: note.id)
        }
        return nil
    }

    func isRunning(origin: String) -> Bool { runs.values.contains { $0.origin == origin } }

    /// Sets `[agent:: <bot>]` on the task (nil clears it; only that line changes) and, for a bot
    /// that takes tasks, starts a run. Returns the task's id after the edit (a task gets a `^id`
    /// when first edited) and a problem to show, if any.
    @discardableResult
    func assign(_ task: TaskItem, to botID: String?) -> (taskID: String, problem: String?) {
        let store = tasks()
        let id: String
        do { id = try store.update(id: task.id) { $0.agent = botID } } catch { return (task.id, error.localizedDescription) }
        guard let botID else { return (id, nil) }
        guard let fresh = store.tasks.first(where: { $0.id == id }) else { return (id, "That task changed in the file.") }
        return (id, runTask(fresh, botID: botID))
    }

    /// Starts a run for the task with its bot. One run per task at a time; budgets apply as for chats.
    @discardableResult
    func runTask(_ task: TaskItem, botID: String) -> String? {
        guard let bot = bot(botID) else { return "There's no bot called \(botID) (or its file has a problem)." }
        guard bot.allowsTask else { return "\(bot.name) doesn't take tasks. Add task to the triggers in its file." }
        guard task.blockID != nil else { return "Save the task first." }
        let origin = AgentOrigin.task(task.id)
        guard !isRunning(origin: origin) else { return "\(bot.name) is already working on this task." }
        taskResults[task.id] = nil
        startJob(bot: bot, title: AgentTaskJob.threadTitle(task), userText: AgentTaskJob.threadMessage(task),
                 prompt: AgentTaskJob.prompt(task: task, today: tasks().today),
                 job: Job(origin: origin, subject: task.title), trigger: .task)
        return nil
    }

    // MARK: @mentions in docs

    /// Asks a bot about a doc (Docs bridge `agents.ask`). `path` is the doc's absolute path from the
    /// page; it must be inside the Writer folder. The doc is read from disk (the page saves first).
    func ask(bot botID: String, docPath: String, request: String, writer: WriterFiles) async throws -> String {
        guard let bot = bot(botID) else { throw ToolFailure("There's no bot called \(botID).") }
        guard bot.allowsMention else { throw ToolFailure("\(bot.name) can't be mentioned. Add mention to the triggers in its file.") }
        let clean = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ToolFailure("Write what you'd like \(bot.name) to do after the @mention.") }
        guard clean.count <= AgentMention.maxRequest else { throw ToolFailure("That request is too long.") }
        let relative = try AgentMention.relativeDocPath(docPath, writer: writer)
        let origin = AgentOrigin.doc(relative)
        guard !runs.values.contains(where: { $0.origin == origin && $0.botID == bot.id }) else {
            throw ToolFailure("\(bot.name) is already working on this doc.")
        }
        let text = try await Task.detached(priority: .userInitiated) { try writer.read(docPath) }.value
        let name = ((relative as NSString).lastPathComponent as NSString).deletingPathExtension
        startJob(bot: bot, title: AgentMention.threadTitle(clean), userText: "In “\(name)”: \(clean)",
                 prompt: AgentMention.prompt(request: clean, path: relative, text: text,
                                             canWriteDocs: bot.tools.contains("atlantis_doc_write")),
                 job: Job(origin: origin, subject: "\(name): \(ThreadLog.title(from: clean))"), trigger: .mention)
        return "Asked \(bot.name). The answer will land in your Inbox."
    }

    /// A run with its own new thread (task or mention). Runs in the background; the Agents page
    /// shows it like a chat.
    @discardableResult
    private func startJob(bot: BotDefinition, title: String, userText: String, prompt: String, job: Job,
                          trigger: RunTrigger, depth: Int = 0) -> Task<RunSummary.Status, Never> {
        let time = now()
        var thread = AgentThread(bot: bot.id, title: title, created: time, trigger: trigger, origin: job.origin)
        thread.messages.append(ThreadMessage(role: .user, at: time, text: userText))
        save(thread, bot: bot)
        let runID = ThreadLog.newID() + ThreadLog.newID()
        runs[runID] = LiveRun(runID: runID, botID: bot.id, threadID: thread.id, origin: job.origin)
        refreshThreads(bot: bot.id)
        return Task { await run(bot: bot, threadID: thread.id, prompt: prompt, runID: runID, job: job, depth: depth) }
    }

    // MARK: Automatic runs (M7)

    /// Queues an automatic run (morning, an event, or a hand-off). One runs at a time, first in first
    /// out, under the daily cap; each bot's cost cap applies when it starts.
    @discardableResult
    func enqueue(_ item: QueuedRun) -> RunQueue.Admission {
        let admission = queue.enqueue(item, startedToday: triggerLedger.runsToday, cap: AppSettings.teamSettings.dailyCap)
        switch admission {
        case .queued:
            Log.app.info("Queued \(item.trigger.raw, privacy: .public) run for \(item.bot, privacy: .public)")
            pumpQueue()
        case .refused(let reason):
            if !reason.contains("already") { skip(item, reason: "Daily cap") }
            Log.app.info("Didn't queue \(item.bot, privacy: .public): \(reason, privacy: .public)")
        }
        return admission
    }

    /// Starts the next queued run when nothing queued is running. Called when one is added or ends:
    /// events, never a timer.
    private func pumpQueue() {
        guard let next = queue.startNext() else { return }
        func skipAndContinue(_ reason: String) {
            skip(next, reason: reason)
            queue.finishActive()
            pumpQueue()
        }
        guard let bot = bot(next.bot) else { return skipAndContinue("Bot missing") }
        if case .delegate = next.trigger {} else if !AppSettings.teamSettings.automaticRuns {
            return skipAndContinue("Switched off")
        }
        if ledger.refusal(bot: bot.id, name: bot.name, cap: bot.dailyCostUSD) != nil { return skipAndContinue("Cost cap") }
        guard mcp.helperExists, cliPath != "" else { return skipAndContinue("Not set up") }
        triggerLedger.countRun()
        let task = startJob(bot: bot, title: next.title, userText: next.userText, prompt: next.prompt,
                            job: Job(origin: next.origin, subject: next.subject, unattended: true), trigger: next.trigger,
                            depth: next.depth)
        Task { [weak self] in
            _ = await task.value
            self?.queue.finishActive()
            self?.pumpQueue()
        }
    }

    private func skip(_ item: QueuedRun, reason: String) {
        skipped.append(SkippedRun(bot: item.bot, trigger: item.trigger, title: item.title, reason: reason, at: now()))
        let day = DayStamp(now())
        skipped.removeAll { DayStamp($0.at) != day }
    }

    /// The Settings switch went off: drop the waiting morning and event runs (hand-offs the user asked
    /// for through Chief stay). A run already going finishes.
    func automaticRunsSwitchedOff() {
        queue.removeWaiting { if case .delegate = $0.trigger { false } else { true } }
    }

    /// `atlantis_agent_delegate` from a bot's run: checks the rules and queues the other bot.
    func delegate(caller: AgentDelegation.Caller, bot target: String, request: String) -> Result<String, ToolFailure> {
        reloadBotsOnly()
        let used = caller.runID.flatMap { delegations[$0] } ?? 0
        let checked = AgentDelegation.check(caller: caller, target: target, request: request, bots: bots,
                                            delegationsThisRun: used, spentToday: { [ledger] in ledger.spentToday(bot: $0) })
        let bot: BotDefinition
        switch checked {
        case .failure(let failure): return .failure(failure)
        case .success(let value): bot = value
        }
        let from = caller.bot ?? ""
        let fromName = self.bot(from)?.name ?? from.capitalized
        let clean = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentThread = caller.runID.flatMap { runs[$0]?.threadID } ?? "unknown"
        let item = QueuedRun(bot: bot.id, trigger: .delegate(from: from), title: ThreadLog.title(from: clean),
                             userText: "\(fromName) asked: \(clean)", prompt: AgentDelegation.prompt(request: clean, fromName: fromName),
                             origin: AgentDelegation.origin(fromBot: from, threadID: parentThread),
                             subject: ThreadLog.title(from: clean), depth: caller.depth + 1, parentRunID: caller.runID,
                             queuedAt: now())
        switch enqueue(item) {
        case .queued(let position):
            if let runID = caller.runID { delegations[runID, default: 0] += 1 }
            let when = position == 0 ? "It starts now" : "It's queued behind \(position) other run\(position == 1 ? "" : "s")"
            return .success("Handed to \(bot.name). \(when); its answer goes to the user's Inbox and its own thread. Tell the user you asked \(bot.name).")
        case .refused(let reason):
            return .failure(ToolFailure(reason))
        }
    }

    struct Handoff: Identifiable, Equatable {
        var id: String
        var bot: String
        var title: String
        /// nil while it waits in the queue.
        var threadID: String?
        var running: Bool
        var status: RunSummary.Status?
    }

    /// Runs this thread handed to other bots (Chief → School), queued or done, oldest first.
    func handoffs(fromBot bot: String, threadID: String) -> [Handoff] {
        let origin = AgentDelegation.origin(fromBot: bot, threadID: threadID)
        let started = threads.values.joined().filter { $0.origin == origin }.sorted { $0.created < $1.created }.map { summary in
            Handoff(id: summary.id, bot: summary.bot, title: summary.title, threadID: summary.id,
                    running: isRunning(thread: summary.id), status: summary.status)
        }
        let waiting = queue.waiting.filter { $0.origin == origin }.map {
            Handoff(id: $0.id, bot: $0.bot, title: $0.title, threadID: nil, running: false, status: nil)
        }
        return started + waiting
    }

    /// The Team card's runs in progress.
    var liveForCard: [TeamCard.Live] {
        runs.values.map { run in
            TeamCard.Live(threadID: run.threadID, bot: run.botID, waiting: approvals.contains { $0.runID == run.runID })
        }
    }

    /// The loaded bots (for the Team card's names and avatars).
    /// Doesn't read the files (safe in a view's body); `refreshToday` and `start` load them.
    var definitions: [BotDefinition] { bots.compactMap(\.definition) }

    /// Opens a thread on the Agents page (from Today).
    func open(thread id: String, bot: String) {
        start()
        refreshThreads(bot: bot)
        selection = .thread(bot: bot, id: id)
    }
}
