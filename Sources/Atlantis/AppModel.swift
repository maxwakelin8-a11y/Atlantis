import AtlantisCore
import Foundation
import Observation

/// Top-level UI state shared by the window and the menus.
@MainActor @Observable
final class AppModel {
    private static let lastPageKey = "lastPage"

    var page: Page {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: Self.lastPageKey) }
    }

    init(page: Page? = nil) {
        let saved = UserDefaults.standard.string(forKey: Self.lastPageKey).flatMap(Page.init(rawValue:))
        self.page = page ?? saved ?? .today
    }
}
