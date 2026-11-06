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

    /// LifeOS vault (Obsidian, in iCloud Drive).
    static var vaultURL: URL {
        if let path = defaults.string(forKey: "vaultPath"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/LifeOS", isDirectory: true)
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
