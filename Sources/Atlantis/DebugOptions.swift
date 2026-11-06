import AppKit
import AtlantisCore
import WebKit

/// Launch arguments for testing and screenshots, e.g.
/// `Atlantis -debugAppearance dark -debugPage seqta -debugSnapshot /tmp/shot.png -debugSnapshotDelay 8`.
/// They are read from the launch arguments only and never saved.
struct DebugOptions {
    var appearance: NSAppearance?
    var page: Page?
    var snapshotURL: URL?
    var snapshotDelay: Double = 1.5
    /// `-debugNetworkCheck YES`: checks that locked-down web views really can't reach the web.
    var networkCheck = false
    /// `-debugSeqtaUnloadAfter 5`: unload the hidden SEQTA page after this many seconds.
    var seqtaUnloadAfter: Double?
    /// `-debugHUD YES`: start with the performance HUD showing.
    var showHUD = false
    /// `-debugPageSequence "seqta:15,today:10"`: show each page for that many seconds, in order.
    var pageSequence: [(Page, Double)] = []

    static func fromArguments(_ defaults: UserDefaults = .standard) -> DebugOptions {
        let args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var options = DebugOptions()
        switch args["debugAppearance"] as? String {
        case "dark": options.appearance = NSAppearance(named: .darkAqua)
        case "light": options.appearance = NSAppearance(named: .aqua)
        default: break
        }
        options.page = (args["debugPage"] as? String).flatMap(Page.init(rawValue:))
        if let path = args["debugSnapshot"] as? String {
            options.snapshotURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let delay = args["debugSnapshotDelay"] as? String, let seconds = Double(delay) {
            options.snapshotDelay = seconds
        }
        options.networkCheck = (args["debugNetworkCheck"] as? String).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
        options.seqtaUnloadAfter = (args["debugSeqtaUnloadAfter"] as? String).flatMap(Double.init)
        options.showHUD = (args["debugHUD"] as? String).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
        options.pageSequence = ((args["debugPageSequence"] as? String) ?? "")
            .split(separator: ",")
            .compactMap { step in
                let parts = step.split(separator: ":")
                guard parts.count == 2, let page = Page(rawValue: String(parts[0])),
                      let seconds = Double(parts[1]) else { return nil }
                return (page, seconds)
            }
        return options
    }
}

@MainActor
enum Snapshot {
    /// Saves a PNG of the window as it appears on screen, including sidebar materials
    /// (`cacheDisplay` can't draw those). Uses `screencapture`, which may need the
    /// Screen Recording permission for whatever launched the app.
    static func save(_ window: NSWindow, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Loads a real web page in a `.none` web view and logs whether it was blocked.
@MainActor
enum NetworkCheck {
    static func run() async {
        do {
            let webView = WebViews.make(try await WebViews.configuration(network: .none))
            let probe = Probe()
            webView.navigationDelegate = probe
            webView.load(URLRequest(url: URL(string: "https://example.com/")!))
            let blocked = await probe.result()
            let message = blocked ? "PASS: blocked" : "FAIL: example.com loaded"
            Log.web.notice("Network check \(message, privacy: .public)")
            print("Network check \(message)")
        } catch {
            print("Network check error: \(error)")
        }
    }

    private final class Probe: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var done = false

        func result() async -> Bool {
            await withCheckedContinuation { continuation = $0 }
        }

        private func finish(_ blocked: Bool) {
            guard !done else { return }
            done = true
            continuation?.resume(returning: blocked)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(false) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(true) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(true) }
    }
}
