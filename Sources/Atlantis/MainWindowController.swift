import AppKit
import SwiftUI

/// Owns the single main window. Closing it hides it; the app keeps running.
@MainActor
final class MainWindowController: NSWindowController {
    init(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Atlantis"
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: RootView(model: model))
        hosting.sizingOptions = [] // the window sets its own size; don't shrink to fit SwiftUI
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
