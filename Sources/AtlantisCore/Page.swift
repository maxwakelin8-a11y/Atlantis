/// A top-level page in the sidebar (PRD F7).
///
/// Pages are added here as their milestone lands. Order in `allCases` is sidebar order.
public enum Page: String, CaseIterable, Identifiable, Sendable {
    case today
    case docs
    case seqta
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "Today"
        case .docs: "Docs"
        case .seqta: "SEQTA"
        case .settings: "Settings"
        }
    }

    /// SF Symbol name.
    public var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .docs: "doc.text"
        case .seqta: "graduationcap"
        case .settings: "gearshape"
        }
    }

    /// Settings sits at the bottom of the sidebar and uses ⌘, instead of a number.
    public var isPinnedToBottom: Bool { self == .settings }

    /// Pages in the main sidebar list, in order.
    public static var main: [Page] { allCases.filter { !$0.isPinnedToBottom } }

    /// Pages pinned to the bottom of the sidebar.
    public static var bottom: [Page] { allCases.filter(\.isPinnedToBottom) }

    /// The ⌘-number shortcut ("1"…"9") for this page, if it has one.
    public var shortcutNumber: String? {
        guard let index = Page.main.firstIndex(of: self), index < 9 else { return nil }
        return String(index + 1)
    }
}
