import AtlantisCore
import Foundation
import Observation
import os

/// Top-level UI state shared by the window and the menus.
@MainActor @Observable
final class AppModel {
    private static let lastPageKey = "lastPage"

    var page: Page {
        didSet {
            guard page != oldValue else { return }
            UserDefaults.standard.set(page.rawValue, forKey: Self.lastPageKey)
            beginPageSwitch()
        }
    }

    /// Debug performance overlay (View ▸ Show Performance HUD).
    var showsHUD = false
    /// Process start → main window on screen, in seconds.
    var launchSeconds: Double?
    /// How long the last page switch took to show, in milliseconds.
    private(set) var lastPageSwitchMs: Double?

    @ObservationIgnored private var pageSwitch: (state: OSSignpostIntervalState, start: ContinuousClock.Instant)?

    /// Created the first time the SEQTA page is shown, so launch stays fast and idle.
    private(set) var seqtaIfStarted: SeqtaController?

    /// The SEQTA sync engine (PRD §7d). Cheap until a sync runs: it only reads `meta.json`.
    let seqtaSync: SeqtaSync

    /// Today's SEQTA data, Top 3 and plan (PRD F1).
    let today: TodayStore

    /// The clock pages use. Real time, shifted by `-debugNow` for screenshots.
    @ObservationIgnored let clockOffset: TimeInterval
    func now() -> Date { Date().addingTimeInterval(clockOffset) }

    private var vault: VaultPaths { VaultPaths(root: AppSettings.vaultURL) }

    /// The SEQTA cache as the Subjects and Messages pages read it.
    let seqtaData: SeqtaData

    /// The subject whose page shows under Subjects (nil: the overview of all subjects).
    var subjectCode: String?

    /// Created the first time Messages is shown or something opens a draft in it.
    @ObservationIgnored private var messagesStorage: MessagesModel?

    var messages: MessagesModel {
        if let messagesStorage { return messagesStorage }
        let model = MessagesModel(sync: seqtaSync, data: seqtaData)
        model.onDraftSent = { [weak self] inboxID in
            guard let self, let inboxID else { return }
            Task { try? await self.inbox.accept(id: inboxID) }
        }
        messagesStorage = model
        return model
    }

    /// Opens an agent's `message.draft` in the Messages compose view. It still needs Send + confirm.
    func openDraftInMessages(_ item: InboxItem) {
        messages.startCompose(MessageDraft(inbox: item), inboxItemID: item.id)
        page = .messages
    }

    /// Shows a SEQTA page in the pop-up window ("Open in SEQTA").
    func openInSeqta(_ url: URL?) {
        guard let url else { return }
        seqta.openInPopup(url)
    }

    /// The SEQTA address's page for `make`, for the buttons that open SEQTA.
    func seqtaPage(_ make: (URL) -> URL?) -> URL? { AppSettings.seqtaURL.flatMap(make) }

    /// Created the first time Docs is shown, then kept warm (the one warm Docs editor, PRD §17).
    private(set) var docsIfStarted: DocsController?

    var docs: DocsController {
        if let docsIfStarted { return docsIfStarted }
        let controller = DocsController()
        docsIfStarted = controller
        return controller
    }

    /// Created the first time Tasks is shown (or anything else needs tasks); then it watches
    /// `machine/tasks.md` for edits made elsewhere.
    private(set) var tasksIfStarted: TaskStore?

    var tasks: TaskStore {
        if let tasksIfStarted { return tasksIfStarted }
        let offset = clockOffset
        let store = TaskStore(vault: vault, now: { Date().addingTimeInterval(offset) })
        tasksIfStarted = store
        return store
    }

    @ObservationIgnored private var inboxStorage: InboxStore?

    /// Created the first time it's needed (the sidebar badge or the Inbox page), then kept.
    var inbox: InboxStore {
        if let inboxStorage { return inboxStorage }
        let store = InboxStore(vault: vault)
        // Accepting a task or doc proposal applies it (see InboxActions in AtlantisCore).
        store.onAccept = { [weak self] item in
            guard let self else { return }
            try InboxActions(tasks: self.tasks, writerRoot: { AppSettings.writerURL }).apply(item)
        }
        store.start()
        inboxStorage = store
        return store
    }

    /// The local MCP server agents talk to (PRD §8). Started at launch, stopped at quit.
    let mcp = MCPService()

    /// Created the first time the Agents page is shown (PRD §7b). Nothing runs until a chat starts.
    private(set) var agentsIfStarted: AgentService?

    var agents: AgentService {
        if let agentsIfStarted { return agentsIfStarted }
        let offset = clockOffset
        let service = AgentService(mcp: mcp, now: { Date().addingTimeInterval(offset) })
        agentsIfStarted = service
        return service
    }

    /// How long a hidden SEQTA page stays loaded.
    @ObservationIgnored var seqtaUnloadAfter: Duration = .seconds(600)

    var seqta: SeqtaController {
        if let seqtaIfStarted { return seqtaIfStarted }
        let controller = SeqtaController()
        controller.unloadAfter = seqtaUnloadAfter
        seqtaIfStarted = controller
        return controller
    }

    init(page: Page? = nil, seqtaCache: SeqtaCache = SeqtaCache(), planURL: URL = PlanFile.defaultURL,
         clockOffset: TimeInterval = 0) {
        let saved = UserDefaults.standard.string(forKey: Self.lastPageKey).flatMap(Page.init(rawValue:))
        self.page = page ?? saved ?? .today
        self.clockOffset = clockOffset
        seqtaSync = SeqtaSync(cache: seqtaCache)
        seqtaData = SeqtaData(cache: seqtaCache)
        today = TodayStore(cache: seqtaCache, vault: VaultPaths(root: AppSettings.vaultURL), planURL: planURL,
                           now: { Date().addingTimeInterval(clockOffset) })
        seqtaSync.onSynced = { [weak self] _ in await self?.didSync() }
    }

    // MARK: Today wiring

    /// Starts Today's stores and keeps `plan.json` current. Called once, after the first frame.
    func startToday() {
        today.start()
        tasks.start()
        writePlanAndObserve()
    }

    /// Writes the plan now and again whenever tasks or the cache change (observation, no timers).
    private func writePlanAndObserve() {
        withObservationTracking {
            today.writePlan(tasks: tasks.tasks)
            _ = tasks.revision
            _ = today.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.writePlanAndObserve() }
        }
    }

    /// After a sync wrote the cache: reload Today, fill the daily note, propose new homework and
    /// assessments in the Inbox (PRD F3: never added silently).
    /// Debug (`-debugAfterSync YES`): runs the after-sync work on the cache as it is, with no
    /// network, then prints what it did.
    func debugRunAfterSync() async {
        startToday()
        await didSync()
    }

    private func didSync() async {
        today.reloadCache()
        seqtaData.reload()
        today.writeDailyNote(syncedAt: seqtaSync.lastSync ?? now())
        await proposeFromSeqta()
    }

    private func proposeFromSeqta() async {
        guard FileManager.default.fileExists(atPath: vault.root.path) else { return }
        let inbox = self.inbox
        inbox.reload()
        tasks.start()
        tasks.reload()
        let proposals = SeqtaProposals.make(lessons: today.lessons, assessments: today.assessments,
                                            inbox: inbox.items, tasks: tasks.tasks, now: now())
        for item in proposals {
            do { try await inbox.post(item) } catch {
                Log.app.error("Couldn't post a SEQTA proposal: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        if !proposals.isEmpty { Log.app.info("Posted \(proposals.count) SEQTA proposals to the Inbox") }
    }

    private func beginPageSwitch() {
        if let pageSwitch { Log.signposter.endInterval("Page switch", pageSwitch.state) }
        let state = Log.signposter.beginInterval("Page switch", id: Log.signposter.makeSignpostID(),
                                                 "\(self.page.rawValue, privacy: .public)")
        pageSwitch = (state, .now)
    }

    /// Called when the new page's view has appeared.
    func pageDidAppear() {
        guard let pageSwitch else { return }
        Log.signposter.endInterval("Page switch", pageSwitch.state)
        let elapsed = ContinuousClock.now - pageSwitch.start
        lastPageSwitchMs = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        self.pageSwitch = nil
    }
}
