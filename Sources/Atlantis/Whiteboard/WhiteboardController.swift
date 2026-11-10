import AppKit
import AtlantisCore
import Observation
import UniformTypeIdentifiers
import WebKit

/// Whiteboard: Excalidraw (web/whiteboard) in a web view, one board at a time.
///
/// The page never names files. This controller decides which board is open, hands its text to
/// the page, and writes what the page saves back to that board only ("board" message handler).
/// A save is refused when the file changed on disk since the page last saw it (an agent drew on
/// it, iCloud brought a newer copy); the page merges the newer file in and saves again.
///
/// The web view lives only while the page is visible (PRD §17); the board list is native.
@MainActor @Observable
final class WhiteboardController: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let scheme = "atlantis-board"
    private static let home = URL(string: "\(scheme)://app/index.html")!
    private static let lastBoardKey = "whiteboardLastBoard"

    private(set) var boards: [WhiteboardFiles.Board] = []
    private(set) var selected: String?
    private(set) var webView: WKWebView?
    private(set) var problem: String?

    var files: WhiteboardFiles { WhiteboardFiles(root: AppSettings.whiteboardsURL) }

    /// Changes each time a board is opened, so a late save from the previous one is refused.
    @ObservationIgnored private var token = ""
    /// Hash of the open board as the page last saw it.
    @ObservationIgnored private var knownHash: String?
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var visible = false

    override init() {
        selected = UserDefaults.standard.string(forKey: Self.lastBoardKey)
        super.init()
    }

    // MARK: Page lifecycle

    /// The page appeared: list boards, start the web view, watch the folder.
    func show() async {
        visible = true
        let files = files
        try? await Self.background { try files.ensureRoot() }
        await reloadList()
        if selected == nil || !boards.contains(where: { $0.path == selected }) { selected = boards.first?.path }
        startWatching()
        guard webView == nil else { return }
        do {
            guard let folder = Self.bundleFolder() else {
                problem = "The whiteboard isn't built. Run `npm run build` in web/whiteboard."
                return
            }
            let config = try await WebViews.configuration(network: .none)
            config.setURLSchemeHandler(EditorSchemeHandler(root: folder), forURLScheme: Self.scheme)
            config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "board")
            let webView = WebViews.make(config)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.underPageBackgroundColor = .windowBackgroundColor
            self.webView = webView
            pageReady = false
            webView.load(URLRequest(url: Self.home))
        } catch {
            problem = "The whiteboard couldn't start: \(error.localizedDescription)"
        }
    }

    /// The page went away: save, then let the web view go (idle = zero work).
    func hide() async {
        visible = false
        watcher?.stop()
        watcher = nil
        await flush()
        guard !visible, let webView else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "board", contentWorld: .page)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        self.webView = nil
        pageReady = false
        token = ""
    }

    /// Saves the open board now (switching boards, quitting). Gives up after `timeout`.
    func flush(timeout: Duration = .seconds(3)) async {
        guard let webView, pageReady else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                done.resume()
            }
            Task {
                _ = try? await webView.callAsyncJavaScript("await window.atlantisBoard?.flush?.()", contentWorld: .page)
                finish()
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }

    // MARK: Boards

    func reloadList() async {
        let files = files
        let list = await Task.detached(priority: .userInitiated) { files.list() }.value
        boards = list.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Opens a board in the page (saving the one that was open).
    func select(_ path: String?) async {
        guard path != selected || token.isEmpty else { return }
        await flush()
        selected = path
        UserDefaults.standard.set(path, forKey: Self.lastBoardKey)
        await pushSelected()
    }

    /// Makes a new board and opens it.
    func newBoard() async {
        let files = files
        do {
            let path = try await Self.background { try files.create() }
            await reloadList()
            await select(path)
        } catch {
            problem = error.localizedDescription
        }
    }

    func rename(_ path: String, to name: String) async {
        let files = files
        do {
            await flush()
            let renamed = try await Self.background { try files.rename(path, to: name) }
            await reloadList()
            if selected == path {
                selected = renamed
                UserDefaults.standard.set(renamed, forKey: Self.lastBoardKey)
                await pushSelected()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func moveToBin(_ path: String) async {
        let files = files
        do {
            if selected == path { await flush() }
            try await Self.background { try files.trash(path) }
            await reloadList()
            if selected == path {
                selected = boards.first?.path
                await pushSelected()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func reveal(_ path: String) {
        guard let url = try? files.url(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Called when an agent (MCP tool or an accepted Inbox drawing) changed a board.
    func boardChanged(_ path: String) async {
        if visible { await reloadList() }
        if path == selected { await pushUpdate() }
    }

    /// Shows a board on the page (MCP `atlantis_whiteboard_open`).
    func open(_ path: String) async {
        await reloadList()
        await select(path)
    }

    // MARK: Swift → page

    private func pushSelected() async {
        guard pageReady, let webView else { return }
        token = UUID().uuidString
        let currentToken = token
        guard let path = selected else {
            knownHash = nil
            _ = try? await webView.callAsyncJavaScript("await window.atlantisBoard.open(null)", contentWorld: .page)
            return
        }
        let files = files
        let text: String
        do {
            text = try await Self.background { try files.read(path) }
        } catch {
            problem = error.localizedDescription
            return
        }
        guard currentToken == token else { return }
        problem = nil
        knownHash = WhiteboardFiles.hash(text)
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        _ = try? await webView.callAsyncJavaScript(
            "await window.atlantisBoard.open(board)",
            arguments: ["board": ["token": currentToken, "name": name, "text": text]], contentWorld: .page)
    }

    /// The open board's file changed on disk: hand the page the new text to merge. `knownHash`
    /// stays as it was, so a save the page already sent still hits a conflict and merges.
    private func pushUpdate() async {
        guard pageReady, let webView, let path = selected else { return }
        let files = files
        guard let text = try? await Self.background({ try files.read(path) }),
              WhiteboardFiles.hash(text) != knownHash else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.atlantisBoard.merge(update)",
            arguments: ["update": ["token": token, "name": "", "text": text]], contentWorld: .page)
    }

    /// FSEvents on the Whiteboards folder while the page shows (no polling): new boards from
    /// Finder or iCloud appear, and the open board picks up outside edits.
    private func startWatching() {
        watcher?.stop()
        let root = files.root
        watcher = FileWatcher(folder: root, anyFile: true) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.visible else { return }
                await self.reloadList()
                await self.pushUpdate()
            }
        }
    }

    // MARK: Page → Swift ("board" handler)

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == Self.scheme,
              let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return (nil, "Not allowed.")
        }
        switch op {
        case "ready":
            pageReady = true
            token = ""
            await pushSelected()
            return (nil, nil)
        case "save":
            guard let path = selected, !token.isEmpty, body["token"] as? String == token,
                  let text = body["text"] as? String else { return (nil, "This board isn't open any more.") }
            let files = files
            let expected = knownHash
            do {
                let result = try await Self.background { try files.save(path, text: text, expected: expected) }
                switch result {
                case .saved(let hash):
                    knownHash = hash
                    return (["ok": true], nil)
                case .conflict(let current, let hash):
                    knownHash = hash
                    return (["conflict": true, "text": current], nil)
                }
            } catch {
                return (nil, error.localizedDescription)
            }
        case "log":
            let text = String((body["message"] as? String ?? "").prefix(2_000))
            Log.web.error("Whiteboard page: \(text, privacy: .public)")
            return (nil, nil)
        case "openLink":
            // Links on a board open in the user's browser; nothing loads inside Atlantis.
            if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return (nil, nil)
        default:
            return (nil, "Not allowed.")
        }
    }

    // MARK: Navigation, new windows, downloads ("Save as image")

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url else { return .cancel }
        if url.scheme == Self.scheme || url.scheme == "blob" || url.absoluteString == "about:blank" { return .allow }
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Help links and similar open in the user's browser, never in a new web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        if let ext = (suggestedFilename as NSString).pathExtension.nilIfEmpty, let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try? FileManager.default.removeItem(at: url) // the panel already asked about replacing it
        return url
    }

    func webView(_ webView: WKWebView, webContentProcessDidTerminate: WKWebView) {
        pageReady = false
        token = ""
        if visible { webView.load(URLRequest(url: Self.home)) }
    }

    // MARK: Helpers

    /// The built whiteboard: in the app bundle, or `Resources/Whiteboard` when run from the repo.
    static func bundleFolder() -> URL? {
        if let bundled = Bundle.main.url(forResource: "Whiteboard", withExtension: nil) { return bundled }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Whiteboard")
        return FileManager.default.fileExists(atPath: repo.appendingPathComponent("index.html").path) ? repo : nil
    }

    private nonisolated static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
