import AppKit
import AtlantisCore

/// Launch arguments for testing and screenshots, e.g.
/// `Atlantis -debugAppearance dark -debugPage seqta -debugSnapshot /tmp/shot.png -debugSnapshotDelay 8`.
/// They are read from the launch arguments only and never saved.
struct DebugOptions {
    var appearance: NSAppearance?
    var page: Page?
    var snapshotURL: URL?
    var snapshotDelay: Double = 1.5

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
