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
    /// `-debugRoundTrip "dir1:dir2"`: load every .md file there into the real editor, check a
    /// no-edit save gives identical bytes, print a summary and quit. Read-only.
    var roundTripDirs: [URL] = []
    /// `-debugSeqtaSync YES`: run one manual SEQTA sync at launch and log what it saved (counts only).
    var seqtaSync = false
    /// `-debugSeqtaCache /path`: read (and write) the SEQTA cache there instead of Application
    /// Support, and skip the automatic sync, so screenshots use made-up data.
    var seqtaCache: URL?
    /// `-debugSubject ENGG9`: open the Subjects page on that subject.
    var subject: String?
    /// `-debugMessage 8101`: open the Messages page on that message.
    var message: Int?
    /// `-debugCompose YES`: open the Messages compose view with a made-up draft.
    var compose = false
    /// `-debugHUD YES`: start with the performance HUD showing.
    var showHUD = false
    /// `-debugPageSequence "seqta:15,today:10"`: show each page for that many seconds, in order.
    var pageSequence: [(Page, Double)] = []

    /// `-debugTasksView upcoming`: which Tasks view to open (today, upcoming, project, area, done).
    var tasksView: TaskListKind?
    /// `-debugTaskSelect 2`: select the nth task (1-based) of that view, so its side panel shows.
    var taskSelect: Int?

    /// `-debugSeqtaCache /path`: read (and sync into) this SEQTA cache folder instead of the real
    /// one, and skip the automatic morning sync. For screenshots on made-up data
    /// (`scripts/today-fixture.sh` makes one).
    var seqtaCacheURL: URL?
    /// `-debugPlanPath /path/plan.json`: write plan.json here instead of the shared folder.
    var planURL: URL?
    /// `-debugAfterSync YES`: run the after-sync work (Inbox proposals, daily note, plan) on
    /// the cache without syncing, print a line and quit. Use it with `-debugSeqtaCache`.
    var afterSync = false
    /// `-debugAcceptInbox YES`: shortly after launch, accept every pending Inbox item (as clicking
    /// Accept would), print a line and quit. For the MCP end-to-end check.
    var acceptInbox = false
    /// `-debugNow 10:05`: pretend it is this time today (the Today page's now line, Next up).
    var clockOffset: TimeInterval = 0
    /// `-debugAgentAsk "What's due?"`: send this to a bot in a new thread, print the outcome and quit.
    /// Use it with `-vaultPath` on a made-up vault. Real runs cost real usage.
    var agentAsk: String?
    /// `-debugAgentBot school`: which bot `-debugAgentAsk` / `-debugAgentTask` / `-debugAgentMention` uses.
    var agentBot = "school"
    /// `-debugAgentTask "Turing"`: assign the first open task with this in its title to the bot, wait
    /// for the run, print what landed in the Inbox and quit. Real runs cost real usage.
    var agentTask: String?
    /// `-debugAgentMention /abs/Writer/Project/Doc.md -debugAgentRequest "…"`: send an @mention
    /// through the Docs page's bridge (`agents.ask`), wait, print the Inbox items and quit.
    var agentMention: String?
    var agentRequest = "Give me one tip to improve this."
    /// `-debugAutoApprove YES`: approve each `ask` approval a couple of seconds after it appears
    /// (as clicking Approve would). For the live check of `ask` bots.
    var autoApprove = false
    /// `-debugApprovalCard YES`: show a made-up approval card in the open thread (screenshots).
    var approvalCard = false

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
        options.seqtaSync = (args["debugSeqtaSync"] as? String).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
        options.roundTripDirs = ((args["debugRoundTrip"] as? String) ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
        if let path = args["debugSeqtaCache"] as? String {
            options.seqtaCache = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        options.subject = args["debugSubject"] as? String
        options.message = (args["debugMessage"] as? String).flatMap(Int.init)
        options.compose = (args["debugCompose"] as? String).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
        options.tasksView = (args["debugTasksView"] as? String).flatMap(TaskListKind.init(rawValue:))
        options.taskSelect = (args["debugTaskSelect"] as? String).flatMap(Int.init)
        func path(_ key: String) -> URL? {
            (args[key] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        options.seqtaCacheURL = options.seqtaCache
        options.acceptInbox = (args["debugAcceptInbox"] as? String).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
        options.afterSync = (args["debugAfterSync"] as? String).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
        options.planURL = path("debugPlanPath")
        if let text = args["debugNow"] as? String, let minutes = TodayTime.minutes(text) {
            options.clockOffset = TimeInterval(minutes - TodayTime.minuteOfDay(Date())) * 60
        }
        options.agentAsk = args["debugAgentAsk"] as? String
        if let bot = args["debugAgentBot"] as? String { options.agentBot = bot }
        options.agentTask = args["debugAgentTask"] as? String
        options.agentMention = args["debugAgentMention"] as? String
        if let request = args["debugAgentRequest"] as? String { options.agentRequest = request }
        options.autoApprove = (args["debugAutoApprove"] as? String).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
        options.approvalCard = (args["debugApprovalCard"] as? String).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
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
    /// (`cacheDisplay` can't draw those). Uses `screencapture`, which may need the Screen
    /// Recording permission for whatever launched the app. Web views don't paint while their
    /// window is covered, so each one's own WebKit snapshot is drawn on top at its frame.
    static func save(_ window: NSWindow, to url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        guard let contentView = window.contentView else { throw CocoaError(.fileWriteUnknown) }
        guard process.terminationStatus == 0, let captured = NSImage(contentsOf: url),
              let base = captured.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // The screen is asleep or locked, so the window can't be captured. Draw the view
            // itself instead (no sidebar material, but layout and colours are right).
            try drawContentView(contentView, to: url)
            return
        }
        let webViews = allWebViews(in: contentView).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        guard !webViews.isEmpty else { return }

        let scale = CGFloat(base.width) / window.frame.width
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for webView in webViews {
            guard let image = try? await webView.takeSnapshot(configuration: nil),
                  let snap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            // Window coordinates and CG pixels both start bottom-left.
            let frame = webView.convert(webView.bounds, to: nil)
            context.draw(snap, in: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                          width: frame.width * scale, height: frame.height * scale))
        }
        guard let combined = context.makeImage() else { return }
        try NSBitmapImageRep(cgImage: combined).representation(using: .png, properties: [:])?
            .write(to: url, options: .atomic)
    }

    private static func drawContentView(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The window draws its own background, so the content view's capture is see-through:
        // put it on the window background colour (in the window's light or dark appearance).
        guard let content = rep.cgImage,
              let context = CGContext(data: nil, width: content.width, height: content.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            try rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
            return
        }
        var background = NSColor.windowBackgroundColor.cgColor
        (view.window?.effectiveAppearance ?? view.effectiveAppearance).performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        let rect = CGRect(x: 0, y: 0, width: content.width, height: content.height)
        context.setFillColor(background)
        context.fill(rect)
        context.draw(content, in: rect)
        guard let combined = context.makeImage() else { return }
        try NSBitmapImageRep(cgImage: combined).representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    private static func allWebViews(in view: NSView) -> [WKWebView] {
        if let webView = view as? WKWebView { return [webView] }
        return view.subviews.flatMap(allWebViews(in:))
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

enum RoundTripCheck {
    /// Every .md file under `dirs`, skipping hidden folders, node_modules and build output.
    static func markdownFiles(in dirs: [URL]) -> [URL] {
        var out: [URL] = []
        for dir in dirs {
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if ["node_modules", "vendor", ".build", "build"].contains(url.lastPathComponent) {
                    walker.skipDescendants(); continue
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if url.pathExtension == "md", size < 2_000_000 { out.append(url) }
            }
        }
        return out
    }

    @MainActor
    static func run(_ dirs: [URL], docs: DocsController) async {
        await docs.start()
        await docs.waitUntilReady()
        let files = markdownFiles(in: dirs)
        let result = await docs.roundTripCheck(files)
        print("Round trip (real WebKit): \(result.passed)/\(files.count) byte-identical, slowest \(Int(result.slowestMs)) ms")
        for failure in result.failed { print("  FAIL \(failure)") }
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
