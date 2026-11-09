import AtlantisCore
import SwiftUI

/// The main window: sidebar on the left, the selected page on the right.
///
/// Uses the plain system look until the design is approved (AGENTS.md "Design").
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(Page.main) { page in
                    Label(page.title, systemImage: page.systemImage).tag(page)
                }
            }
            .safeAreaInset(edge: .bottom) {
                List(selection: selection) {
                    ForEach(Page.bottom) { page in
                        Label(page.title, systemImage: page.systemImage).tag(page)
                    }
                }
                .scrollDisabled(true)
                .frame(height: 44)
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
        case .today: PlaceholderPage(page: .today, note: "Your classes, tasks and assessments will show here (M3).")
        case .tasks: TasksPage(store: model.tasks)
        case .inbox: PlaceholderPage(page: .inbox, note: "Proposals from SEQTA and agents will show here (M4).")
        case .messages: PlaceholderPage(page: .messages, note: "SEQTA messages will show here (M4b).")
        case .subjects: PlaceholderPage(page: .subjects, note: "Marks, feedback and files per subject will show here (M4b).")
        case .agents: PlaceholderPage(page: .agents, note: "Your bot team will show here (M5).")
        case .docs: DocsPage(docs: model.docs)
        case .seqta: SeqtaPage(seqta: model.seqta)
        case .settings: SettingsPage(model: model)
        }
    }

    /// Both lists share one selection; clicking empty space never clears it.
    private var selection: Binding<Page?> {
        Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })
    }
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
