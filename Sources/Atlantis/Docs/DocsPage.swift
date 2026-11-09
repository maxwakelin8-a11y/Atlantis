import SwiftUI

/// Docs: the Writer fills the page (its own project list, binder, editor and inspector).
struct DocsPage: View {
    let docs: DocsController

    var body: some View {
        Group {
            if let webView = docs.webView {
                WebViewHost(webView: webView)
            } else if let problem = docs.problem {
                ContentUnavailableView("Docs couldn't start", systemImage: "doc.text", description: Text(problem))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await docs.start() }
    }
}
