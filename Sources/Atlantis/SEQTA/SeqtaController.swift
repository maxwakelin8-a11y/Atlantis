import AppKit
import AtlantisCore
import Observation
import WebKit

/// The one SEQTA tab, as the extension sees it.
@MainActor
final class SeqtaTab: NSObject, WKWebExtensionTab {
    weak var owner: SeqtaController?

    init(owner: SeqtaController) { self.owner = owner }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { owner?.webView }
    func title(for context: WKWebExtensionContext) -> String? { owner?.webView.title }
    func url(for context: WKWebExtensionContext) -> URL? { owner?.webView.url }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
}

/// SEQTA Learn with BetterSEQTA+ in one web view (from seqta-app's BrowserWindowController).
///
/// Nothing is created until the SEQTA page is first opened. After that the web view stays
/// alive so switching pages is instant and you stay logged in.
@MainActor @Observable
final class SeqtaController: NSObject, WKWebExtensionWindow, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum Phase: Equatable { case idle, starting, ready }

    private(set) var phase: Phase = .idle
    /// Shown above the page when BetterSEQTA+ couldn't load. SEQTA still works without it.
    private(set) var extensionProblem: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private(set) var tab: SeqtaTab!
    @ObservationIgnored private let host = ExtensionHost()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var popups: [NSWindow] = []
    @ObservationIgnored private var keyObserver: NSObjectProtocol?
    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    @ObservationIgnored private var isUnloaded = false

    /// How long SEQTA stays loaded after you leave its page (PRD §17: hidden web views unload).
    @ObservationIgnored var unloadAfter: Duration = .seconds(600)

    override init() {
        // Network: open (WebViews.Network.open). The only such web view, and temporary (PRD §7d).
        let config = WKWebViewConfiguration()
        config.webExtensionController = host.controller
        config.websiteDataStore = .default()
        // Present as Safari so login pages treat the app like a normal browser.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        webView = WebViews.make(config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        tab = SeqtaTab(owner: self)
        host.seqta = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.tabChanged(.title) }
            },
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.tabChanged(.URL) }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.tabChanged(.loading) }
            },
        ]
    }

    /// Loads BetterSEQTA+ and then SEQTA. Safe to call more than once.
    func start() {
        guard phase == .idle, AppSettings.seqtaURL != nil else { return }
        phase = .starting
        Task {
            do {
                try await host.load(from: AppSettings.extensionURL)
            } catch {
                Log.seqta.error("BetterSEQTA+ didn't load: \(error.localizedDescription, privacy: .public)")
                extensionProblem = "BetterSEQTA+ didn't load, so SEQTA is showing without it. "
                    + "Build it with `npm run build:safari` in BetterSEQTA-Plus, or check the path in Settings."
            }
            host.controller.didOpenWindow(self)
            host.controller.didOpenTab(tab)
            host.controller.didFocusWindow(self)
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                let window = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let window,
                          self.webView.window.map(ObjectIdentifier.init) == window else { return }
                    self.host.controller.didFocusWindow(self)
                }
            }
            phase = .ready
            goHome()
        }
    }

    // MARK: Showing and hiding

    /// The SEQTA page appeared: cancel a pending unload, and reload if it was unloaded.
    func pageShown() {
        unloadTask?.cancel()
        unloadTask = nil
        if isUnloaded, phase == .ready {
            isUnloaded = false
            Log.seqta.info("Reloading SEQTA after unload")
            goHome()
        }
    }

    /// The SEQTA page was left: unload it after a while (one-shot, no repeating timer).
    func pageHidden() {
        guard phase == .ready else { return }
        unloadTask?.cancel()
        let delay = unloadAfter
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.webView.load(URLRequest(url: URL(string: "about:blank")!))
            self.isUnloaded = true
            Log.seqta.info("Unloaded hidden SEQTA page")
        }
    }

    // MARK: Commands

    func goHome() {
        guard let url = AppSettings.seqtaURL else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func showExtensionSettings() { host.showSettings() }
    func dismissExtensionProblem() { extensionProblem = nil }

    private func tabChanged(_ properties: WKWebExtension.TabChangedProperties) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if phase == .ready { host.controller.didChangeTabProperties(properties, for: tab) }
    }

    // MARK: WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
    func frame(for context: WKWebExtensionContext) -> CGRect { webView.window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { webView.window?.screen?.frame ?? .null }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        if navigationAction.targetFrame?.isMainFrame == true,
           url.scheme == "http" || url.scheme == "https",
           navigationAction.navigationType == .linkActivated,
           !SeqtaLinks.opensInApp(url, seqtaHost: AppSettings.seqtaURL?.host) {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        if !SeqtaLinks.isWebScheme(url.scheme) {
            NSWorkspace.shared.open(url) // mailto:, msteams:, etc.
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        DownloadPolicy.shouldDownload(navigationResponse) ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadSaver.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadSaver.shared
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https",
           !SeqtaLinks.opensInApp(url, seqtaHost: AppSettings.seqtaURL?.host) {
            NSWorkspace.shared.open(url)
            return nil
        }
        // Login or SEQTA pop-ups: a small window that shares the session.
        return makePopup(configuration: configuration,
                         width: windowFeatures.width?.doubleValue ?? 900,
                         height: windowFeatures.height?.doubleValue ?? 700)
    }

    /// "Open in SEQTA": shows a SEQTA page in the same kind of pop-up window, with the same
    /// session (and BetterSEQTA+, once the SEQTA tab has loaded it). Used by Subjects and Messages
    /// for anything that doesn't have a native page yet (PRD §7d).
    func openInPopup(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https", SeqtaLinks.opensInApp(url, seqtaHost: AppSettings.seqtaURL?.host) else {
            NSWorkspace.shared.open(url)
            return
        }
        makePopup(configuration: webView.configuration, width: 1100, height: 780).load(URLRequest(url: url))
    }

    private func makePopup(configuration: WKWebViewConfiguration, width: Double, height: Double) -> WKWebView {
        let popup = WebViews.make(configuration)
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.contentView = popup
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    /// A pop-up closed with its close button: drop it (and its page) instead of keeping it around.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        popups.removeAll { $0 === window }
        if let popup = window.contentView as? WKWebView { popup.load(URLRequest(url: URL(string: "about:blank")!)) }
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let window = popups.first(where: { $0.contentView === webView }) {
            window.close()
            popups.removeAll { $0 === window }
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let window = webView.window else { return nil }
        return await FileChooser.run(on: window, allowsMultiple: parameters.allowsMultipleSelection,
                                     allowsDirectories: parameters.allowsDirectories)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        await runSheet(alert, for: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await runSheet(alert, for: webView) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await runSheet(alert, for: webView) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @discardableResult
    private func runSheet(_ alert: NSAlert, for webView: WKWebView) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}
