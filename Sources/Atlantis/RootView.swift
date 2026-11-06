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
            PageView(page: model.page)
                .navigationTitle(model.page.title)
        }
    }

    /// Both lists share one selection; clicking empty space never clears it.
    private var selection: Binding<Page?> {
        Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })
    }
}

/// Placeholder for pages whose milestone hasn't landed yet.
struct PageView: View {
    let page: Page

    var body: some View {
        ContentUnavailableView {
            Label(page.title, systemImage: page.systemImage)
        } description: {
            Text(note)
        }
    }

    private var note: String {
        switch page {
        case .today: "Your classes, tasks and assessments will show here (M3)."
        case .seqta: "SEQTA with BetterSEQTA+ moves in next (M0)."
        case .settings: "Settings will show here."
        }
    }
}
