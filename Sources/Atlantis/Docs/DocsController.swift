import AppKit
import AtlantisCore
import Observation
import WebKit

/// Owns the Docs folder and the one warm editor web view (PRD §17 allows one).
///
/// The bridge is narrow: the page can only say "ready", "dirty" and "save this text". Swift
/// decides which file that text goes to, and `DocFolder` checks every path.
@MainActor @Observable
final class DocsController: NSObject, WKScriptMessageHandler {
    private(set) var files: [URL] = []
    private(set) var current: DocFolder.Snapshot?
    private(set) var isDirty = false
    private(set) var isReady = false
    private(set) var problem: String?

    let folder: DocFolder
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var pendingLoad: DocFolder.Snapshot?
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    init(root: URL = AppSettings.docsURL) {
        folder = DocFolder(root: root)
        super.init()
    }

    /// Creates the web view and the Docs folder the first time Docs is shown.
    func start() async {
        guard webView == nil else { return }
        do {
            try folder.ensureExists()
            refreshList()
            guard let editor = EditorSchemeHandler.editorFolder() else {
                problem = "The editor isn't built. Run `npm run build` in web/docs-editor."
                return
            }
            let config = try await WebViews.configuration(network: .none)
            config.setURLSchemeHandler(EditorSchemeHandler(root: editor), forURLScheme: EditorSchemeHandler.scheme)
            config.userContentController.add(self, contentWorld: .page, name: "docs")
            let webView = WebViews.make(config)
            self.webView = webView
            webView.load(URLRequest(url: EditorSchemeHandler.home))
        } catch {
            problem = "The editor couldn't start: \(error.localizedDescription)"
        }
    }

    func refreshList() {
        files = folder.list()
    }

    /// Opens a doc, saving the current one first if it has edits.
    func open(_ url: URL) async {
        guard url != current?.url else { return }
        await saveNow()
        do {
            let snapshot = try folder.read(url)
            current = snapshot
            isDirty = false
            problem = nil
            if isReady { await load(snapshot) } else { pendingLoad = snapshot }
        } catch {
            problem = message(for: error, url: url)
        }
    }

    func newDoc() async {
        await saveNow()
        do {
            let snapshot = try folder.create()
            refreshList()
            current = nil
            await open(snapshot.url)
        } catch {
            problem = "Couldn't create a doc: \(error.localizedDescription)"
        }
    }

    /// Saves the open doc if it has edits. Writes nothing when the text is unchanged.
    func saveNow() async {
        guard isDirty, let webView, current != nil else { return }
        do {
            let text = try await webView.callAsyncJavaScript("return window.atlantis.takeForSave()",
                                                            contentWorld: .page) as? String
            if let text { write(text) }
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == EditorSchemeHandler.scheme,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
            if let pending = pendingLoad {
                pendingLoad = nil
                Task { await load(pending) }
            }
        case "dirty":
            isDirty = true
        case "save":
            if let text = body["text"] as? String { write(text) }
        default:
            Log.web.error("Docs bridge: unknown message \(type, privacy: .public)")
        }
    }

    private func load(_ snapshot: DocFolder.Snapshot) async {
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript("window.atlantis.load(raw)",
                                                      arguments: ["raw": snapshot.text], contentWorld: .page)
        } catch {
            problem = "Couldn't show this doc: \(error.localizedDescription)"
        }
    }

    private func write(_ text: String) {
        guard let original = current else { return }
        do {
            switch try folder.save(text, over: original) {
            case .unchanged: break
            case .written(let saved): current = saved
            }
            isDirty = false
        } catch DocFolder.Failure.changedOnDisk {
            problem = "This doc was changed in another app. Your edits weren't saved, so nothing was lost there; copy them out, then reopen the doc."
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func message(for error: any Error, url: URL) -> String {
        switch error as? DocFolder.Failure {
        case .notUTF8: "“\(url.lastPathComponent)” isn't UTF-8 text, so Docs won't open it (that could change its bytes)."
        case .outsideFolder: "Docs only opens files inside \(folder.root.path)."
        case .notMarkdown: "Docs only opens .md files."
        default: "Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    // MARK: Round-trip check (debug)

    /// Waits until the editor page has loaded.
    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// Loads each file into the real editor and checks a no-edit save gives the same bytes.
    /// Read-only: nothing is written.
    func roundTripCheck(_ urls: [URL]) async -> (passed: Int, failed: [String], slowestMs: Double) {
        guard let webView else { return (0, ["no web view"], 0) }
        var passed = 0
        var failed: [String] = []
        var slowest = 0.0
        for url in urls {
            guard let snapshot = try? DocFolder.snapshot(of: url) else { failed.append("\(url.path) (unreadable)"); continue }
            let start = ContinuousClock.now
            do {
                let out = try await webView.callAsyncJavaScript(
                    "window.atlantis.load(raw); return [window.atlantis.serialize(), window.atlantis.serializeWithoutShortcut()]",
                    arguments: ["raw": snapshot.text], contentWorld: .page) as? [String]
                let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
                    + Double((ContinuousClock.now - start).components.seconds) * 1000
                slowest = max(slowest, ms)
                if let out, out.count == 2, Data(out[0].utf8) == snapshot.data, Data(out[1].utf8) == snapshot.data {
                    passed += 1
                } else {
                    failed.append(url.path)
                }
            } catch {
                failed.append("\(url.path) (\(error.localizedDescription))")
            }
        }
        return (passed, failed, slowest)
    }
}
