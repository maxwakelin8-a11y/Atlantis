import AppKit
import AtlantisCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let debug = DebugOptions.fromArguments()
    private lazy var model: AppModel = {
        let model = AppModel(page: debug.page)
        if let seconds = debug.seqtaUnloadAfter { model.seqtaUnloadAfter = .seconds(seconds) }
        return model
    }()
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = debug.appearance { NSApp.appearance = appearance }
        NSApp.mainMenu = makeMenu()

        let controller = MainWindowController(model: model)
        mainWindow = controller
        controller.showWindow(nil)
        NSApp.activate()
        DispatchQueue.main.async { [model] in // after the first frame is laid out
            model.launchSeconds = ProcessStats.secondsSinceLaunch()
            Log.signposter.emitEvent("Window shown")
            Log.app.info("Launched in \(Int((model.launchSeconds ?? 0) * 1000)) ms")
            if ProcessInfo.processInfo.arguments.contains("-debugPrintLaunch") {
                print("launch_ms \(Int((model.launchSeconds ?? 0) * 1000))")
                fflush(stdout)
            }
        }
        if debug.networkCheck { Task { await NetworkCheck.run() } }
        if debug.showHUD { model.showsHUD = true }
        if let doc = debug.openDoc {
            Task { [model] in
                model.page = .docs
                await model.docs.start()
                await model.docs.open(doc)
                if let probe = ProcessInfo.processInfo.environment["ATLANTIS_DOCS_PROBE"], let webView = model.docs.webView {
                    try? await Task.sleep(for: .seconds(2))
                    let result = try? await webView.callAsyncJavaScript(probe, contentWorld: .page)
                    if let path = ProcessInfo.processInfo.environment["ATLANTIS_DOCS_SNAPSHOT"],
                       let image = try? await webView.takeSnapshot(configuration: nil),
                       let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    print("probe: \(String(describing: result)) current=\(model.docs.current?.url.lastPathComponent ?? "nil") ready=\(model.docs.isReady) problem=\(model.docs.problem ?? "-") frame=\(webView.frame) inWindow=\(webView.window != nil) super=\(String(describing: webView.superview.map { type(of: $0) })) hidden=\(webView.isHiddenOrHasHiddenAncestor) alpha=\(webView.alphaValue)")
                    fflush(stdout)
                }
            }
        }
        if !debug.roundTripDirs.isEmpty {
            Task { [model, debug] in await RoundTripCheck.run(debug.roundTripDirs, docs: model.docs) }
        }
        if !debug.pageSequence.isEmpty {
            Task { [model, debug] in
                for (page, seconds) in debug.pageSequence {
                    model.page = page
                    try? await Task.sleep(for: .seconds(seconds))
                    Log.app.notice("Debug: \(page.rawValue, privacy: .public) switch \(model.lastPageSwitchMs ?? -1) ms")
                }
            }
        }

        if let url = debug.snapshotURL, let window = controller.window {
            // Web views don't paint while their window is covered, so bring it forward for the shot.
            window.orderFrontRegardless()
            Task {
                try? await Task.sleep(for: .seconds(self.debug.snapshotDelay)) // one-off, debug only
                do {
                    try await Snapshot.save(window, to: url)
                    Log.app.info("Saved snapshot to \(url.path, privacy: .public)")
                } catch {
                    Log.app.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let docs = model.docsIfStarted, docs.isDirty else { return .terminateNow }
        Task {
            await docs.saveNow() // never lose edits on quit
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.showWindow(nil) }
        return true
    }

    // MARK: - Menu

    @objc private func goToPage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let page = Page(rawValue: id) else { return }
        model.page = page
        mainWindow?.showWindow(nil)
    }

    /// SEQTA commands act only while the SEQTA page is showing and loaded.
    private var visibleSeqta: SeqtaController? {
        guard model.page == .seqta, let seqta = model.seqtaIfStarted, seqta.phase == .ready else { return nil }
        return seqta
    }

    @objc private func seqtaReload() { visibleSeqta?.reload() }
    @objc private func seqtaBack() { visibleSeqta?.goBack() }
    @objc private func seqtaForward() { visibleSeqta?.goForward() }
    @objc private func seqtaHome() { visibleSeqta?.goHome() }
    @objc private func seqtaExtensionSettings() { visibleSeqta?.showExtensionSettings() }
    @objc private func toggleHUD() { model.showsHUD.toggle() }
    @objc private func docsNew() {
        model.page = .docs
        Task { await model.docs.newDoc() }
    }
    @objc private func docsSave() { Task { await model.docsIfStarted?.saveNow() } }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(seqtaReload), #selector(seqtaHome), #selector(seqtaExtensionSettings):
            return visibleSeqta != nil
        case #selector(seqtaBack):
            return visibleSeqta?.canGoBack == true
        case #selector(seqtaForward):
            return visibleSeqta?.canGoForward == true
        case #selector(docsSave):
            return model.page == .docs && model.docsIfStarted?.isDirty == true
        case #selector(toggleHUD):
            menuItem.title = model.showsHUD ? "Hide Performance HUD" : "Show Performance HUD"
            return true
        default:
            return true
        }
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Atlantis", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(pageItem(.settings, title: "Settings…", key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Atlantis", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Atlantis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, "Atlantis", to: main)

        let file = NSMenu()
        let newDoc = commandItem("New Doc", #selector(docsNew), "n")
        newDoc.keyEquivalentModifierMask = [.command, .option]
        file.addItem(newDoc)
        file.addItem(commandItem("Save", #selector(docsSave), "s"))
        add(file, "File", to: main)

        let edit = NSMenu()
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, "Edit", to: main)

        let go = NSMenu()
        for page in Page.main {
            go.addItem(pageItem(page, title: page.title, key: page.shortcutNumber ?? ""))
        }
        add(go, "Go", to: main)

        let view = NSMenu()
        view.addItem(commandItem("Reload", #selector(seqtaReload), "r"))
        view.addItem(commandItem("Back", #selector(seqtaBack), "["))
        view.addItem(commandItem("Forward", #selector(seqtaForward), "]"))
        view.addItem(commandItem("SEQTA Home", #selector(seqtaHome), "H"))
        let extensionSettings = commandItem("BetterSEQTA+ Settings…", #selector(seqtaExtensionSettings), ",")
        extensionSettings.keyEquivalentModifierMask = [.command, .option]
        view.addItem(extensionSettings)
        view.addItem(.separator())
        let hud = commandItem("Show Performance HUD", #selector(toggleHUD), "p")
        hud.keyEquivalentModifierMask = [.command, .option]
        view.addItem(hud)
        let sidebar = view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(view, "View", to: main)

        let window = NSMenu()
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private func commandItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func pageItem(_ page: Page, title: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(goToPage(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = page.rawValue
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, to main: NSMenu) {
        menu.title = title
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }
}
