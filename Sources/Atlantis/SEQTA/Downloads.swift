import AppKit
import WebKit

/// Saves web downloads (from SEQTA or Google) to ~/Downloads without overwriting.
@MainActor
final class DownloadSaver: NSObject, WKDownloadDelegate {
    static let shared = DownloadSaver()

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return Self.uniqueURL(in: downloads, name: suggestedFilename)
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    nonisolated static func uniqueURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return url
    }
}

/// Shared rules for when a response should become a download.
@MainActor
enum DownloadPolicy {
    static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        if !response.canShowMIMEType { return true }
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return true
        }
        return false
    }
}
