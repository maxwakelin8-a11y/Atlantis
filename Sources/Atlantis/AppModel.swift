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
    let seqtaSync = SeqtaSync()

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
        let store = TaskStore(vault: VaultPaths(root: AppSettings.vaultURL))
        tasksIfStarted = store
        return store
    }

    /// The local MCP server agents talk to (PRD §8). Started at launch, stopped at quit.
    let mcp = MCPService()

    /// How long a hidden SEQTA page stays loaded.
    @ObservationIgnored var seqtaUnloadAfter: Duration = .seconds(600)

    var seqta: SeqtaController {
        if let seqtaIfStarted { return seqtaIfStarted }
        let controller = SeqtaController()
        controller.unloadAfter = seqtaUnloadAfter
        seqtaIfStarted = controller
        return controller
    }

    init(page: Page? = nil) {
        let saved = UserDefaults.standard.string(forKey: Self.lastPageKey).flatMap(Page.init(rawValue:))
        self.page = page ?? saved ?? .today
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
