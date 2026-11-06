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

    /// Created the first time the SEQTA page is shown, so launch stays fast and idle.
    private(set) var seqtaIfStarted: SeqtaController?

    var seqta: SeqtaController {
        if let seqtaIfStarted { return seqtaIfStarted }
        let controller = SeqtaController()
        seqtaIfStarted = controller
        return controller
    }

    init(page: Page? = nil) {
        let saved = UserDefaults.standard.string(forKey: Self.lastPageKey).flatMap(Page.init(rawValue:))
        self.page = page ?? saved ?? .today
    }
}
