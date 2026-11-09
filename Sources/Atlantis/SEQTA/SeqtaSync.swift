import AppKit
import AtlantisCore
import Observation
import WebKit

/// The SEQTA sync engine's app side (PRD §7d).
///
/// A hidden web view with the SEQTA tab's logged-in session loads SEQTA's origin only while a
/// sync runs, fetches the JSON endpoints in that page, and is released when the sync ends, so
/// idle costs nothing. There are no timers: a sync starts from the Refresh button or menu, or
/// once a day from app launch or wake (`morningSyncIfNeeded`). It only reads; nothing here can
/// send a message (the request allow-list in `SeqtaRequest` has no write endpoint); the one send
/// is `SeqtaSend`, reached only from the Messages compose view.
///
/// What a sync fetches and decodes is `SeqtaSyncRunner` in AtlantisCore, which has the tests.
@MainActor @Observable
final class SeqtaSync {
    enum State: Equatable {
        case idle
        case syncing
        case failed(String)
        /// The session has ended. The UI tells the user to sign in via the SEQTA tab.
        case needsSignIn
    }

    typealias Reason = SeqtaSyncReason

    private(set) var state: State = .idle
    /// When the cache was last written (manual or morning). nil: never synced.
    private(set) var lastSync: Date?
    /// Parts that didn't load in the last sync, e.g. ["notices"]. Empty when it all worked.
    private(set) var partialFailures: [String] = []

    @ObservationIgnored let cache: SeqtaCache
    @ObservationIgnored private var current: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Replaceable so tests of the app side could run without a web view.
    @ObservationIgnored var makeTransport: @MainActor () -> any SeqtaTransport = { SeqtaWebTransport() }
    /// The connection a message send uses. Only `send(_:confirmed:)` below makes one.
    @ObservationIgnored var makeSendTransport: @MainActor () -> any SeqtaSendTransport = { SeqtaWebTransport() }

    /// Called after a sync wrote the cache, so the pages reload it (no timers, only this event).
    @ObservationIgnored var onSynced: (() -> Void)?

    init(cache: SeqtaCache = SeqtaCache()) {
        self.cache = cache
        let meta = cache.meta()
        lastSync = meta.lastSync
        partialFailures = meta.failures.keys.sorted()
    }

    var isSyncing: Bool { state == .syncing }

    // MARK: Starting a sync

    /// Syncs now. A sync already running is joined, not repeated. `.morning` obeys the
    /// once-a-day rule itself, so no caller can break it.
    func refresh(reason: Reason) async {
        if let current {
            await current.value
            return
        }
        if reason == .morning, !SeqtaMorningGate.shouldRun(meta: cache.meta(), now: Date()) { return }
        guard AppSettings.seqtaURL != nil else {
            if reason == .manual { state = .failed(SeqtaSyncError.notConfigured.message) }
            return
        }
        let task = Task { await perform(reason) }
        current = task
        await task.value
        current = nil
    }

    /// The automatic sync: once per local day, the first time the app launches or the Mac wakes.
    func morningSyncIfNeeded() {
        Task { await refresh(reason: .morning) }
    }

    /// Hooks the morning sync to app launch (now) and to the Mac waking from sleep. Both are
    /// events, not timers: between them the engine does no work.
    func startAutoSync() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.morningSyncIfNeeded() }
        }
        morningSyncIfNeeded()
    }

    // MARK: Running

    private func perform(_ reason: Reason) async {
        state = .syncing
        let signpost = Log.signposter.beginInterval("SEQTA sync", id: Log.signposter.makeSignpostID(),
                                                    "\(reason.rawValue, privacy: .public)")
        defer { Log.signposter.endInterval("SEQTA sync", signpost) }
        let runner = SeqtaSyncRunner(transport: makeTransport(), cache: cache)
        do {
            let report = try await runner.run(reason: reason)
            lastSync = cache.meta().lastSync
            partialFailures = report.failures.keys.sorted()
            state = .idle
            Log.seqta.info("SEQTA sync (\(reason.rawValue, privacy: .public)): \(report.summary, privacy: .public); \(report.requestCount) requests")
            lastReportSummary = report.summary
            onSynced?()
        } catch let error as SeqtaSyncError {
            state = error == .notSignedIn ? .needsSignIn : .failed(error.message)
            Log.seqta.error("SEQTA sync (\(reason.rawValue, privacy: .public)) stopped: \(error.message, privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
            Log.seqta.error("SEQTA sync (\(reason.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: On demand (the Messages and Subjects pages)

    /// Each of these opens the hidden SEQTA page for its one request and unloads it again.
    /// They only read, except `send`, which is the compose view's confirmed Send.

    /// The whole message, from the cache if it was read before.
    func readMessage(id: Int) async throws -> Message {
        try await SeqtaOnDemand(transport: makeTransport(), cache: cache).message(id: id)
    }

    func people(_ kind: SeqtaPerson.Kind) async throws -> [SeqtaPerson] {
        try await SeqtaOnDemand(transport: makeTransport(), cache: cache).people(kind)
    }

    /// A downloaded copy of a SEQTA file on this Mac (downloaded now if it isn't yet).
    func localFile(uuid: String, name: String, source: SeqtaFileRequest.Source) async throws -> URL {
        let files = SeqtaFileCache()
        if let existing = files.existing(uuid: uuid, name: name) { return existing }
        guard let request = SeqtaFileRequest(source: source, uuid: uuid) else { throw SeqtaSyncError.badResponse("file id") }
        let response = try await SeqtaOnDemand(transport: makeTransport(), cache: cache).file(request)
        let named = SeqtaFileCache.name(fromDisposition: response.disposition)
        return try files.store(response.data, uuid: uuid, name: name.isEmpty ? (named ?? "file") : name)
    }

    /// Sends a message the user wrote and confirmed. The one place the app sends anything.
    func send(_ message: SeqtaSend.Outgoing, confirmed: SeqtaSend.Confirmation) async throws {
        try await SeqtaSend.send(message, confirmed: confirmed, via: makeSendTransport())
    }

    /// Counts only (never contents) from the last good sync, for logs and the debug flag.
    private(set) var lastReportSummary: String?
}

/// The hidden web view a sync talks through. One per sync: made in `open()`, released in
/// `close()`. It shares the SEQTA tab's website data store (the login) but may only reach the
/// SEQTA host, so a sign-in redirect to anywhere else ends the sync as "not signed in".
@MainActor
final class SeqtaWebTransport: NSObject, SeqtaSendTransport, WKNavigationDelegate {
    private var webView: WKWebView?
    private var seqtaHost = ""
    private var navigation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    /// How long SEQTA's page may take to load.
    private let loadTimeout: Duration = .seconds(30)

    func open() async throws {
        guard let url = AppSettings.seqtaURL, let host = url.host?.lowercased() else { throw SeqtaSyncError.notConfigured }
        seqtaHost = host
        let config: WKWebViewConfiguration
        do {
            config = try await WebViews.configuration(network: .only([host]), storage: .sharedSession)
        } catch {
            throw SeqtaSyncError.network("couldn't set up the sync page")
        }
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15" // as the SEQTA tab does
        let webView = WebViews.make(config)
        webView.navigationDelegate = self
        self.webView = webView
        try await load(url)
    }

    func send(_ requests: [SeqtaRequest]) async throws -> [SeqtaResponse] {
        for request in requests where !request.isAllowed { throw SeqtaSyncError.blockedRequest(request.path) }
        return try await run(requests.map { (path: $0.path, body: $0.body) })
    }

    /// The message send (`SeqtaSend`): one POST, to the save endpoint and nothing else.
    func post(_ request: SeqtaSendRequest) async throws -> SeqtaResponse {
        guard request.path == SeqtaSend.path else { throw SeqtaSyncError.blockedRequest(request.path) }
        return try await run([(path: request.path, body: request.body)])[0]
    }

    private func run(_ requests: [(path: String, body: String)]) async throws -> [SeqtaResponse] {
        guard let webView else { throw SeqtaSyncError.network("SEQTA isn't loaded") }
        let list = requests.map { ["path": $0.path, "body": $0.body] }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { throw SeqtaSyncError.badResponse("requests") }
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(Self.script, arguments: ["requests": String(decoding: data, as: UTF8.self)],
                                                           in: nil, contentWorld: .page)
        } catch {
            throw SeqtaSyncError.network("the SEQTA page stopped answering")
        }
        guard let text = result as? String,
              let answers = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]],
              answers.count == requests.count else { throw SeqtaSyncError.badResponse("page script") }
        return answers.map { SeqtaResponse(status: ($0["status"] as? Int) ?? 0, body: $0["body"] as? String ?? "") }
    }

    /// One file, as a read-only GET with the session's cookies (at most 25 MB).
    func download(_ request: SeqtaFileRequest) async throws -> SeqtaFileResponse {
        guard let webView else { throw SeqtaSyncError.network("SEQTA isn't loaded") }
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(Self.downloadScript, arguments: ["path": request.path],
                                                           in: nil, contentWorld: .page)
        } catch {
            throw SeqtaSyncError.network("the SEQTA page stopped answering")
        }
        guard let text = result as? String,
              let answer = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw SeqtaSyncError.badResponse("page script")
        }
        let data = (answer["base64"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        return SeqtaFileResponse(status: (answer["status"] as? Int) ?? 0, data: data, disposition: answer["disposition"] as? String ?? "")
    }

    func close() async {
        timeout?.cancel()
        timeout = nil
        finishNavigation(.failure(CancellationError()))
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil // releasing it ends the page and its web content process
    }

    /// POSTs each request to its path on SEQTA's origin with the session's cookies, a few at a
    /// time, and returns `[{status, body}]` as JSON text. Only `/seqta/student/` paths run.
    private static let script = """
    const reqs = JSON.parse(requests);
    const out = new Array(reqs.length);
    let next = 0;
    async function worker() {
      while (true) {
        const i = next++;
        if (i >= reqs.length) return;
        const r = reqs[i];
        if (typeof r.path !== 'string' || !r.path.startsWith('/seqta/student/')) { out[i] = { status: 0, body: '' }; continue; }
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 25000);
        try {
          const res = await fetch(location.origin + r.path, {
            method: 'POST', credentials: 'include', signal: controller.signal,
            headers: { 'Content-Type': 'application/json; charset=utf-8' }, body: r.body });
          out[i] = { status: res.status, body: await res.text() };
        } catch (e) {
          out[i] = { status: 0, body: '' };
        } finally { clearTimeout(timer); }
      }
    }
    await Promise.all(Array.from({ length: Math.min(4, reqs.length) }, worker));
    return JSON.stringify(out);
    """

    private static let downloadScript = """
    if (typeof path !== 'string' || !path.startsWith('/seqta/student/load/file?')) return JSON.stringify({ status: 0 });
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 60000);
    try {
      const res = await fetch(location.origin + path, { credentials: 'include', signal: controller.signal });
      const buffer = await res.arrayBuffer();
      if (buffer.byteLength > 26214400) return JSON.stringify({ status: 413 });
      const bytes = new Uint8Array(buffer);
      let binary = '';
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      return JSON.stringify({ status: res.status, disposition: res.headers.get('content-disposition') || '', base64: btoa(binary) });
    } catch (e) {
      return JSON.stringify({ status: 0 });
    } finally { clearTimeout(timer); }
    """

    // MARK: Loading

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            // One-shot give-up, not a repeating timer.
            timeout = Task { [weak self, loadTimeout] in
                try? await Task.sleep(for: loadTimeout)
                guard !Task.isCancelled else { return }
                self?.finishNavigation(.failure(SeqtaSyncError.network("loading SEQTA took too long")))
            }
            webView?.load(URLRequest(url: url))
        }
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        guard let continuation = navigation else { return }
        navigation = nil
        continuation.resume(with: result)
    }

    private func isSeqtaHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == seqtaHost || host.hasSuffix("." + seqtaHost)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // A redirect off SEQTA's address is the sign-in page: the session has ended.
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https",
           !isSeqtaHost(url.host) {
            finishNavigation(.failure(SeqtaSyncError.notSignedIn))
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(isSeqtaHost(webView.url?.host) ? .success(()) : .failure(SeqtaSyncError.notSignedIn))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishNavigation(.failure(SeqtaSyncError.network((error as NSError).localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishNavigation(.failure(SeqtaSyncError.network((error as NSError).localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(SeqtaSyncError.network("the sync page crashed")))
    }
}
