import AppKit
import AtlantisCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let debug = DebugOptions.fromArguments()
    private lazy var model = AppModel(page: debug.page)
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = debug.appearance { NSApp.appearance = appearance }
        NSApp.mainMenu = makeMenu()

        let controller = MainWindowController(model: model)
        mainWindow = controller
        controller.showWindow(nil)
        NSApp.activate()
        Log.app.info("Launched")

        if let url = debug.snapshotURL, let window = controller.window {
            Task {
                try? await Task.sleep(for: .seconds(1.5)) // one-off, debug only
                do {
                    try Snapshot.save(window, to: url)
                    Log.app.info("Saved snapshot to \(url.path, privacy: .public)")
                } catch {
                    Log.app.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
                }
                NSApp.terminate(nil)
            }
        }
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
