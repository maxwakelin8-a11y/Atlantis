import AtlantisCore
import SwiftUI

/// The main window: sidebar on the left, the selected page on the right.
///
/// Uses the plain system look until the design is approved (AGENTS.md "Design").
struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage(AppSettings.showSeqtaTabKey) private var showSeqtaTab = true
    @State private var subjectsExpanded = true

    /// The bottom group. The temporary SEQTA tab can be hidden in Settings (PRD §7d); dropping it
    /// for good is deleting `Page.seqta` from the bottom group in `Page.isPinnedToBottom`.
    private var bottomPages: [Page] {
        Page.bottom.filter { $0 != .seqta || showSeqtaTab || model.page == .seqta }
    }

    /// Subjects with one sub-item per subject (a coloured dot each).
    private var subjectsGroup: some View {
        DisclosureGroup(isExpanded: $subjectsExpanded) {
            ForEach(model.seqtaData.subjects) { subject in
                Label { Text(subject.name) } icon: { SubjectDot(colour: subject.colour) }
                    .tag(SidebarItem.subject(subject.code))
            }
        } label: {
            Label(Page.subjects.title, systemImage: Page.subjects.systemImage)
                .tag(SidebarItem.page(.subjects))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(Page.main) { page in
                    if page == .subjects {
                        subjectsGroup
                    } else {
                        Label(page.title, systemImage: page.systemImage)
                            .tag(SidebarItem.page(page))
                            .badge(page == .inbox ? model.inbox.pending.count : 0)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                List(selection: selection) {
                    ForEach(bottomPages) { page in
                        Label(page.title, systemImage: page.systemImage).tag(SidebarItem.page(page))
                    }
                }
                .scrollDisabled(true)
                .frame(height: Size.listRowMinHeight * CGFloat(bottomPages.count) + Space.s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { model.pageDidAppear() } // inside .id, so it runs for every page
                .id(model.page)
                .navigationTitle(model.page.title)
                .overlay(alignment: .bottomTrailing) {
                    if model.showsHUD { PerfHUD(model: model) }
                }
                .toolbar {
                    if model.page == .seqta { SeqtaToolbar(seqta: model.seqta) }
                }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.page {
        case .today: TodayPage(model: model)
        case .tasks: TasksPage(store: model.tasks)
        case .inbox: InboxPage(store: model.inbox, openDraft: model.openDraftInMessages)
        case .messages: MessagesPage(model: model)
        case .subjects: SubjectsPage(model: model)
        case .agents: PlaceholderPage(page: .agents, note: "Your bot team will show here (M5).")
        case .docs: DocsPage(docs: model.docs)
        case .seqta: SeqtaPage(seqta: model.seqta)
        case .settings: SettingsPage(model: model)
        }
    }

    /// Both lists share one selection; clicking empty space never clears it.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if model.page == .subjects, let code = model.subjectCode { return .subject(code) }
                return .page(model.page)
            },
            set: {
                switch $0 {
                case .page(let page)?:
                    if page == .subjects { model.subjectCode = nil }
                    model.page = page
                case .subject(let code)?:
                    model.subjectCode = code
                    model.page = .subjects
                case nil: break
                }
            })
    }
}

/// What a sidebar row selects: a page, or one subject's page under Subjects.
enum SidebarItem: Hashable {
    case page(Page)
    case subject(String)
}

struct SeqtaToolbar: ToolbarContent {
    let seqta: SeqtaController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left", action: seqta.goBack)
                .disabled(!seqta.canGoBack)
                .help("Back (⌘[)")
            Button("Forward", systemImage: "chevron.right", action: seqta.goForward)
                .disabled(!seqta.canGoForward)
                .help("Forward (⌘])")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Reload", systemImage: "arrow.clockwise", action: seqta.reload)
                .disabled(seqta.phase != .ready)
                .help("Reload (⌘R)")
            Button("BetterSEQTA+ Settings", systemImage: "wrench.adjustable", action: seqta.showExtensionSettings)
                .disabled(seqta.phase != .ready)
                .help("BetterSEQTA+ Settings (⌥⌘,)")
        }
    }
}

/// Placeholder for pages whose milestone hasn't landed yet.
struct PlaceholderPage: View {
    let page: Page
    let note: String

    var body: some View {
        ContentUnavailableView {
            Label(page.title, systemImage: page.systemImage)
        } description: {
            Text(note)
        }
    }
}
