import AtlantisCore
import Foundation

/// App settings, kept in the app's local defaults (`au.lifeos.atlantis`), never in the repo.
enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    /// SEQTA Learn home page. Falls back to seqta-app's saved address if Atlantis has none yet.
    static var seqtaURL: URL? {
        get {
            let saved = defaults.string(forKey: "seqtaURL")
                ?? UserDefaults(suiteName: "au.lifeos.seqta")?.string(forKey: "seqtaURL")
            return saved.flatMap(SeqtaLinks.homeURL(from:))
        }
        set { defaults.set(newValue?.absoluteString, forKey: "seqtaURL") }
    }

    /// Whether the temporary SEQTA web tab shows in the sidebar (PRD §7d). On until Today, Tasks,
    /// Subjects and Messages cover a school day. Views read it with `@AppStorage(AppSettings.showSeqtaTabKey)`.
    static let showSeqtaTabKey = "showSeqtaTab"
    static var showSeqtaTab: Bool {
        get { defaults.object(forKey: showSeqtaTabKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: showSeqtaTabKey) }
    }

    /// The built BetterSEQTA+ extension (the fork's `npm run build:safari` output).
    static var extensionURL: URL {
        get {
            if let path = defaults.string(forKey: "extensionPath"), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
            return home.appendingPathComponent("Developer/BetterSEQTA-Plus/dist/safari", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "extensionPath") }
    }

    /// The Writer folder Docs works in: one folder per project (same layout as BetterSEQTA+'s
    /// Writer, so its projects open here too). Default: iCloud Drive/Writer.
    static var writerURL: URL {
        get {
            if let path = defaults.string(forKey: "writerPath"), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
            return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Writer", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "writerPath") }
    }

    /// The name Docs puts on title pages when exporting.
    static var authorName: String {
        get { defaults.string(forKey: "authorName") ?? "" }
        set { defaults.set(newValue, forKey: "authorName") }
    }

    /// LifeOS vault (Obsidian, in iCloud Drive).
    static var vaultURL: URL {
        if let path = defaults.string(forKey: "vaultPath"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/LifeOS", isDirectory: true)
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
