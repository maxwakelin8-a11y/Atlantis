import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled editor (index.html, editor.js, …) to the Docs web view from
/// `atlantis-editor://app/…`. Only files inside the editor folder can be read.
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "atlantis-editor"
    static let home = URL(string: "\(scheme)://app/index.html")!

    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The built editor: in the app bundle, or `Resources/DocsEditor` when run from the repo.
    static func editorFolder() -> URL? {
        if let bundled = Bundle.main.url(forResource: "DocsEditor", withExtension: nil) { return bundled }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/DocsEditor")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app" else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let file = root.appendingPathComponent(String(url.path.drop(while: { $0 == "/" })))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
