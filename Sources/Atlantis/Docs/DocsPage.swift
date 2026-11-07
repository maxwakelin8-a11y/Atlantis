import AtlantisCore
import SwiftUI

/// Docs: the files in ~/Documents/Docs on the left, the editor on the right.
/// System styling until the design system lands.
struct DocsPage: View {
    let docs: DocsController

    var body: some View {
        HStack(spacing: 0) {
            fileList
                .frame(width: 240)
            Divider()
            editor
        }
        .task { await docs.start() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = docs.problem {
                NoticeBar(text: problem) {}
            }
        }
    }

    private var fileList: some View {
        List(docs.files, id: \.self, selection: Binding(
            get: { docs.current?.url },
            set: { url in if let url { Task { await docs.open(url) } } }
        )) { url in
            Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                .lineLimit(1)
                .tag(url)
        }
        .overlay {
            if docs.files.isEmpty {
                ContentUnavailableView {
                    Label("No docs yet", systemImage: "doc.text")
                } description: {
                    Text("Docs live in ~/Documents/Docs as plain .md files.")
                } actions: {
                    Button("New Doc") { Task { await docs.newDoc() } }
                }
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if let webView = docs.webView {
            WebViewHost(webView: webView)
                .overlay {
                    // A cover, not .opacity: fading a hosted AppKit view can leave it invisible.
                    if docs.current == nil {
                        ContentUnavailableView(docs.files.isEmpty ? "No doc open" : "Pick a doc",
                                               systemImage: "doc.text",
                                               description: Text("Or press ⌥⌘N for a new one."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                    }
                }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DocsToolbar: ToolbarContent {
    let docs: DocsController

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if docs.isDirty {
                Text("Edited").foregroundStyle(.secondary).font(.callout)
            }
            Button("New Doc", systemImage: "square.and.pencil") { Task { await docs.newDoc() } }
                .help("New Doc (⌥⌘N)")
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([docs.current?.url ?? docs.folder.root])
            }
            .help("Show in Finder")
        }
    }
}
