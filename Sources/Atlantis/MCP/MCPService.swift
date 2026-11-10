import AtlantisCore
import Foundation
import Observation
import os

/// Runs the local MCP socket server and owns the tool registry other milestones add tools to.
///
/// The server starts at launch on a background queue and costs nothing while idle (PRD §17).
/// Agents reach it through the bundled `atlantis-mcp` helper (PRD §8).
@MainActor @Observable
final class MCPService {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .stopped

    /// Other milestones register their tools here.
    @ObservationIgnored let registry: ToolRegistry
    @ObservationIgnored private let server: MCPSocketServer

    /// Where proposals go: the app's Inbox store, once `configure(model:)` has connected it.
    @ObservationIgnored let inbox = InboxBridge()
    /// Which `write*` actions run without asking (Settings ▸ Agents & MCP).
    let allowList = DefaultsActionAllowList()
    /// Per-run tool grants for Atlantis's own bots (M5): a call carrying a bot's token only gets that bot's tools.
    @ObservationIgnored let agentGrants = AgentGrants()
    /// Writes `ask` bots are waiting on (M6): decided in the thread or the Inbox.
    @ObservationIgnored let approvals = ApprovalCenter()

    init(socketURL: URL = URL(fileURLWithPath: MCPSocketClient.defaultPath)) {
        let registry = ToolRegistry(inbox: inbox, allowList: allowList, approvals: approvals)
        CoreTools.register(in: registry, appVersion: Self.appVersion, inbox: inbox)
        self.registry = registry
        let gate = AgentToolGate(inner: registry, grants: agentGrants)
        server = MCPSocketServer(socketURL: socketURL, handler: MCPProtocolHandler(backend: gate))
    }

    /// Connects the tools to the app's stores. Call once, before `start()`.
    func configure(model: AppModel) {
        inbox.provider = { @MainActor in model.inbox }
        let context = MCPToolContext(
            vault: { VaultPaths(root: AppSettings.vaultURL) },
            writerRoot: { AppSettings.writerURL },
            cache: model.seqtaSync.cache,
            tasks: { model.tasks },
            inbox: inbox,
            refreshSeqta: {
                let sync = model.seqtaSync
                await sync.refresh(reason: .manual)
                switch await sync.state {
                case .idle: return SeqtaRefreshOutcome(ok: true, message: "Synced. " + (await sync.lastReportSummary ?? "Saved data is up to date."))
                case .needsSignIn: return SeqtaRefreshOutcome(ok: false, message: "The user isn't signed in to SEQTA. They need to sign in from Atlantis, then try again.")
                case .failed(let reason): return SeqtaRefreshOutcome(ok: false, message: "Sync failed: \(reason)")
                case .syncing: return SeqtaRefreshOutcome(ok: true, message: "A sync is still running. Read again in a minute.")
                }
            },
            exportDocument: { html, format, target in
                try await DocsExport.export(html: html, format: format, to: target)
            },
            delegate: { caller, bot, request in
                await model.agents.delegate(caller: caller, bot: bot, request: request)
            },
            whiteboardRoot: { AppSettings.whiteboardsURL },
            boardChanged: { path in
                await model.whiteboardIfStarted?.boardChanged(path)
            },
            openBoard: { path in
                await model.openBoard(path)
            })
        AtlantisTools.register(in: registry, context: context)
    }

    var socketPath: String { server.socketURL.path }

    func start() {
        switch state {
        case .stopped, .failed: break
        case .starting, .running: return
        }
        state = .starting
        let server = server
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: State
            do {
                try server.start()
                result = .running
                Log.app.info("MCP server listening")
            } catch {
                result = .failed(String(describing: error))
                Log.app.error("MCP server failed to start: \(String(describing: error), privacy: .public)")
            }
            DispatchQueue.main.async { self?.state = result }
        }
    }

    /// Stops the server and removes the socket file (called at quit).
    func stop() {
        server.stop()
        state = .stopped
    }

    // MARK: Setup text for Settings

    /// The bundled helper, next to the app's own executable.
    var helperURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("atlantis-mcp")
    }

    var helperExists: Bool {
        helperURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }

    /// The bundled agent daemon, beside the helper.
    var agentDaemonURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("atlantis-agentd")
    }

    var claudeCommand: String? { helperURL.map { MCPSetup.claudeCommand(helperPath: $0.path) } }
    var jsonSnippet: String? { helperURL.map { MCPSetup.jsonSnippet(helperPath: $0.path) } }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// Hands proposals to the Inbox store, which lives on the main actor and is created on first use.
final class InboxBridge: InboxPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (@MainActor @Sendable () -> InboxStore)?

    var provider: (@MainActor @Sendable () -> InboxStore)? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func post(_ proposal: InboxProposal) async throws -> InboxReceipt {
        guard let provider else { throw ToolFailure("The Inbox isn't ready yet.") }
        let item = proposal.makeItem()
        let posted = try await MainActor.run { provider() }.post(item)
        return InboxReceipt(id: posted.id)
    }
}
