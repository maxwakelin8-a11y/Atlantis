import AppKit
import AtlantisCore
import Observation
import WebKit

/// Docs: the Writer (copied from BetterSEQTA+) in the one warm editor web view (PRD §17).
///
/// The page runs the Writer's own project code; it reaches files only through the "writer"
/// message handler below, and `WriterFiles` refuses any path outside the Writer folder.
@MainActor @Observable
final class DocsController: NSObject, WKScriptMessageHandlerWithReply {
    private(set) var problem: String?
    private(set) var webView: WKWebView?
    @ObservationIgnored private(set) var files = WriterFiles(root: AppSettings.writerURL)

    /// Creates the web view the first time Docs is shown.
    func start() async {
        guard webView == nil else { return }
        do {
            guard let editor = EditorSchemeHandler.editorFolder() else {
                problem = "The editor isn't built. Run `npm run build` in web/docs-editor."
                return
            }
            let config = try await WebViews.configuration(network: .none, storage: .persistent(WebViews.docsStore))
            config.setURLSchemeHandler(EditorSchemeHandler(root: editor), forURLScheme: EditorSchemeHandler.scheme)
            config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "writer")
            let webView = WebViews.make(config)
            self.webView = webView
            webView.load(URLRequest(url: EditorSchemeHandler.home))
        } catch {
            problem = "Docs couldn't start: \(error.localizedDescription)"
        }
    }

    /// Starts the page again (after the Writer folder changes), saving open edits first.
    func reloadPage() {
        Task {
            await flush()
            webView?.load(URLRequest(url: EditorSchemeHandler.home))
        }
    }

    /// Saves every open document now (before quitting).
    /// Gives up after `timeout` so a stuck page can never stop the app quitting.
    func flush(timeout: Duration = .seconds(3)) async {
        guard let webView else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                done.resume()
            }
            Task {
                _ = try? await webView.callAsyncJavaScript("await window.atlantis?.flush?.()", contentWorld: .page)
                finish()
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }

    // MARK: Bridge

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == EditorSchemeHandler.scheme,
              let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return (nil, "Not allowed.")
        }
        do {
            return (try await handle(op, body), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func handle(_ op: String, _ body: [String: Any]) async throws -> Any? {
        let str = { (key: String) in body[key] as? String ?? "" }
        switch op {
        case "writer.dir":
            files = WriterFiles(root: AppSettings.writerURL)
            let files = files
            try await Self.background { try files.ensureRoot() }
            return ["dir": files.root.path]
        case "writer.host":
            return ["author": AppSettings.authorName]
        case "export":
            let target = try files.resolve(str("path"))
            try await DocsExport.export(html: str("html"), format: str("format"), to: target)
            return nil
        case "convert":
            return try await DocsExport.convert(ext: str("ext"), base64: str("data"))
        case "open":
            let url = try files.resolve(str("path"))
            if body["reveal"] as? Bool == true {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
            return nil
        default:
            return try await fileOp(op, body)
        }
    }

    /// Plain file operations, run off the main thread (iCloud files can be slow).
    private func fileOp(_ op: String, _ body: [String: Any]) async throws -> Any? {
        let files = files
        let path = body["path"] as? String ?? ""
        let from = body["from"] as? String ?? ""
        let to = body["to"] as? String ?? ""
        let text = body["text"] as? String ?? ""
        let skip = body["skip"] as? [String] ?? []
        switch op {
        case "fs.list":
            let entries = try await Self.background { try files.list(path) }
            return entries.map { ["name": $0.name, "kind": $0.kind.rawValue] }
        case "fs.read":
            return try await Self.background { try files.read(path) }
        case "fs.write":
            try await Self.background { try files.write(path, text: text) }
        case "fs.mkdir":
            try await Self.background { try files.mkdir(path) }
        case "fs.move":
            try await Self.background { try files.move(from, to: to) }
        case "fs.stat":
            guard let s = try await Self.background({ try files.stat(path) }) else { return nil }
            return ["kind": s.kind.rawValue, "size": s.size, "mtime": s.mtime]
        case "fs.copyDir":
            try await Self.background { try files.copyDir(from, to: to, skip: skip) }
        default:
            Log.web.error("Docs bridge: unknown op \(op, privacy: .public)")
            throw WriterFiles.Failure.outsideFolder
        }
        return nil
    }

    private nonisolated static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    // MARK: Round-trip check (debug)

    /// Waits until the page has set up `window.atlantis`.
    func waitUntilReady() async {
        guard let webView else { return }
        for _ in 0..<200 {
            if (try? await webView.callAsyncJavaScript("return typeof window.atlantis?.roundTrip === 'function'",
                                                      contentWorld: .page)) as? Bool == true { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Loads each file into the real editor and checks a no-edit save gives the same bytes.
    /// Read-only: nothing is written.
    func roundTripCheck(_ urls: [URL]) async -> (passed: Int, failed: [String], slowestMs: Double) {
        guard let webView else { return (0, ["no web view"], 0) }
        var passed = 0
        var failed: [String] = []
        var slowest = 0.0
        for url in urls {
            guard let data = try? Data(contentsOf: url), let text = String(validating: data, as: UTF8.self) else {
                failed.append("\(url.path) (unreadable)")
                continue
            }
            let start = ContinuousClock.now
            do {
                let out = try await webView.callAsyncJavaScript(
                    "const r = window.atlantis.roundTrip(raw); return [r.serialize, r.serializeWithoutShortcut]",
                    arguments: ["raw": text], contentWorld: .page) as? [String]
                let elapsed = ContinuousClock.now - start
                slowest = max(slowest, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                if let out, out.count == 2, Data(out[0].utf8) == data, Data(out[1].utf8) == data {
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
