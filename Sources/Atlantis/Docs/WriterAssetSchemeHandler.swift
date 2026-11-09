import AtlantisCore
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Shows images from the Writer folder in the editor. GenOffice's editor turns a doc's
/// `![](assets/x.png)` into `md-asset:///<absolute path>`; this serves those, and only image files
/// inside the Writer folder (`WriterFiles.readImage` checks the path, symlinks included).
/// Files are read off the main thread (iCloud files can be slow).
@MainActor
final class WriterAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "md-asset"

    private let files: () -> WriterFiles
    /// Requests the page is still waiting for (a task must not be answered after WebKit stops it).
    private var active = Set<ObjectIdentifier>()

    init(files: @escaping () -> WriterFiles) {
        self.files = files
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        // `url.path` is already percent-decoded.
        guard let url = task.request.url, url.scheme == Self.scheme, url.path.hasPrefix("/") else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let path = url.path
        let files = files()
        let id = ObjectIdentifier(task)
        active.insert(id)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try files.readImage(path) } }.value
            guard active.remove(id) != nil else { return }
            switch result {
            case .success(let image):
                let mime = UTType(filenameExtension: image.ext)?.preferredMIMEType ?? "application/octet-stream"
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": mime,
                                                              "Content-Length": "\(image.data.count)",
                                                              "Cache-Control": "no-store"])!
                task.didReceive(response)
                task.didReceive(image.data)
                task.didFinish()
            case .failure:
                task.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }
}
