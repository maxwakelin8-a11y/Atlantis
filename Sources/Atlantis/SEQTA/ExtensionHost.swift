import AppKit
import AtlantisCore
import WebKit

/// Loads the BetterSEQTA+ build into WebKit's web-extension runtime and answers its
/// questions about windows and tabs. (From seqta-app.)
@MainActor
final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    let controller = WKWebExtensionController(configuration: .default())
    private(set) var context: WKWebExtensionContext?
    weak var seqta: SeqtaController?
    private var popupPanel: NSPanel?

    override init() {
        super.init()
        controller.delegate = self
    }

    func load(from url: URL) async throws {
        let ext = try await WKWebExtension(resourceBaseURL: ExtensionStaging.prepare(url))
        let ctx = WKWebExtensionContext(for: ext)
        // Fixed id so extension storage (settings, themes) survives relaunches.
        ctx.uniqueIdentifier = "au.lifeos.atlantis.betterseqta"
        #if DEBUG
        ctx.isInspectable = true
        #endif
        for permission in ext.requestedPermissions {
            ctx.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            ctx.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(ctx)
        context = ctx
        for error in ext.errors {
            Log.seqta.error("BetterSEQTA+ manifest: \(error.localizedDescription, privacy: .public)")
        }
        await loadBackground(ctx)
    }

    /// Starts the extension's background before any SEQTA page opens, so it's ready for the
    /// content script's first message. Gives up after 10 s so SEQTA still opens.
    private func loadBackground(_ ctx: WKWebExtensionContext) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish = { (note: String) in
                guard !finished else { return }
                finished = true
                Log.seqta.info("BetterSEQTA+ background: \(note, privacy: .public)")
                done.resume()
            }
            ctx.loadBackgroundContent { error in
                MainActor.assumeIsolated { finish(error.map { String(describing: $0) } ?? "loaded") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { // one-shot timeout, not a timer
                MainActor.assumeIsolated { finish("timed out") }
            }
        }
    }

    /// Opens the BetterSEQTA+ settings popup.
    func showSettings() {
        guard let tab = seqta?.tab else { return }
        context?.performAction(for: tab)
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        seqta.map { [$0] } ?? []
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        seqta
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        if let url = configuration.url {
            if url.scheme == "http" || url.scheme == "https",
               !SeqtaLinks.opensInApp(url, seqtaHost: AppSettings.seqtaURL?.host) {
                NSWorkspace.shared.open(url)
            } else {
                seqta?.webView.load(URLRequest(url: url))
            }
        }
        completionHandler(nil, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popup = action.popupWebView else { completionHandler(nil); return }
        popupPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "BetterSEQTA+ Settings"
        panel.contentView = popup
        panel.isReleasedWhenClosed = false
        if let main = seqta?.webView.window {
            let frame = main.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 440, y: frame.maxY - 60))
        }
        panel.makeKeyAndOrderFront(nil)
        popupPanel = panel
        completionHandler(nil)
    }
}
