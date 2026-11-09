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

    /// Where proposals go. The Inbox store replaces `InboxUnavailable` when it is wired in.
    static let inbox: any InboxPosting = InboxUnavailable()

    init(socketURL: URL = AppSupport.sockets.appendingPathComponent("mcp.sock")) {
        let registry = ToolRegistry(inbox: Self.inbox, allowList: NoActionsAllowed())
        CoreTools.register(in: registry, appVersion: Self.appVersion, inbox: Self.inbox)
        self.registry = registry
        server = MCPSocketServer(socketURL: socketURL, handler: MCPProtocolHandler(backend: registry))
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

    var claudeCommand: String? { helperURL.map { MCPSetup.claudeCommand(helperPath: $0.path) } }
    var jsonSnippet: String? { helperURL.map { MCPSetup.jsonSnippet(helperPath: $0.path) } }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
