import AtlantisCore
import SwiftUI

/// Whiteboard: a list of boards on the left, the open board (Excalidraw) on the right.
struct WhiteboardPage: View {
    let board: WhiteboardController
    @State private var renaming: WhiteboardFiles.Board?
    @State private var newName = ""
    @State private var binning: WhiteboardFiles.Board?

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: Size.boardList)
            Divider()
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await board.show() }
        .onDisappear { Task { await board.hide() } }
        .alert("Rename board", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let target = renaming { Task { await board.rename(target.path, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move \"\(binning?.name ?? "")\" to the Bin?",
                            isPresented: Binding(get: { binning != nil }, set: { if !$0 { binning = nil } })) {
            Button("Move to Bin", role: .destructive) {
                if let target = binning { Task { await board.moveToBin(target.path) } }
                binning = nil
            }
        } message: {
            Text("You can get it back from the Bin in Finder.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { board.selected }, set: { path in Task { await board.select(path) } })) {
                ForEach(board.boards) { item in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(item.name).lineLimit(1)
                        if !item.folder.isEmpty {
                            Text(item.folder).font(Typo.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                    }
                    .tag(item.path)
                    .contextMenu {
                        Button("Rename…") { newName = item.name; renaming = item }
                        Button("Show in Finder") { board.reveal(item.path) }
                        Divider()
                        Button("Move to Bin…", role: .destructive) { binning = item }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if board.boards.isEmpty {
                    ContentUnavailableView {
                        Label("No boards yet", systemImage: Page.whiteboard.systemImage)
                    } description: {
                        Text("Make one, or ask an agent to draw one.")
                    }
                }
            }
            Divider()
            HStack {
                Button("New Board", systemImage: "plus") { Task { await board.newBoard() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("New board (⇧⌘N)")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(Space.s)
        }
    }

    @ViewBuilder private var canvas: some View {
        if let problem = board.problem, board.webView == nil {
            ContentUnavailableView("The whiteboard couldn't start", systemImage: Page.whiteboard.systemImage, description: Text(problem))
        } else if board.selected == nil {
            ContentUnavailableView {
                Label("No board open", systemImage: Page.whiteboard.systemImage)
            } description: {
                Text("Boards are Excalidraw files in iCloud Drive ▸ Whiteboards.")
            } actions: {
                Button("New Board") { Task { await board.newBoard() } }
            }
        } else if let webView = board.webView {
            WebViewHost(webView: webView)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
