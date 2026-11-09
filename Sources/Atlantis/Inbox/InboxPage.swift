import AtlantisCore
import SwiftUI

/// How a proposal's `kind` and `source` look in the list.
enum InboxStyle {
    static func icon(for kind: String) -> String {
        switch kind {
        case "task.add": "plus.circle"
        case "task.update": "arrow.triangle.2.circlepath"
        case "message.draft": "envelope"
        case "note": "note.text"
        case "doc.edit": "doc.text"
        default: "tray"
        }
    }

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "task.add": "Add task"
        case "task.update": "Update task"
        case "message.draft": "Message draft"
        case "note": "Note"
        case "doc.edit": "Doc edit"
        case "": "Proposal"
        default: kind
        }
    }

    /// `seqta:assessment:1234` → "SEQTA assessment", `agent:school` → "school agent", `mcp:claude-code` → "claude-code (MCP)".
    static func sourceName(_ source: String) -> String {
        let parts = source.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "seqta": return (["SEQTA"] + parts.dropFirst().prefix(1)).joined(separator: " ")
        case "agent" where parts.count > 1: return "\(parts[1]) agent"
        case "mcp" where parts.count > 1: return "\(parts[1]) (MCP)"
        default: return source
        }
    }
}

struct InboxPage: View {
    let store: InboxStore
    /// Opens a `message.draft` in the Messages compose view (it still needs Send + confirm there).
    var openDraft: (InboxItem) -> Void = { _ in }
    @State private var selection: String?
    @State private var editing: InboxItem?
    @State private var doneExpanded = false
    @FocusState private var listFocused: Bool

    private static let doneLimit = 50

    var body: some View {
        Group {
            if store.pending.isEmpty && store.done.isEmpty {
                EmptyState(title: "Inbox is empty", systemImage: "tray",
                           message: "Proposals from SEQTA, agents and quick captures will land here.")
            } else {
                list
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.danger)
                    .padding(Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface)
            }
        }
        .sheet(item: $editing) { item in
            InboxEditSheet(item: item) { edited in
                perform { try store.edit(edited) }
            }
        }
        .onAppear { listFocused = true }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                if store.pending.isEmpty {
                    Text("Nothing waiting for you.")
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(store.pending) { item in
                    InboxRow(item: item, isAllowed: store.isAllowed(kind: item.kind),
                             accept: { accept(item.id) }, edit: { editing = item }, openDraft: { openDraft(item) },
                             dismiss: { dismiss(item.id) },
                             toggleAllowed: { store.setAllowed(!store.isAllowed(kind: item.kind), kind: item.kind) })
                        .tag(item.id)
                }
            } header: {
                Text("Waiting (\(store.pending.count))")
            }
            if !store.done.isEmpty {
                Section {
                    DisclosureGroup("Done (\(store.done.count))", isExpanded: $doneExpanded) {
                        ForEach(store.done.prefix(Self.doneLimit)) { item in
                            DoneRow(item: item)
                        }
                    }
                }
            }
        }
        .focused($listFocused)
        .onKeyPress("j") { move(by: 1) }
        .onKeyPress("k") { move(by: -1) }
        .onKeyPress(.return) { act { accept($0) } }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in act { dismiss($0) } }
        .animation(Motion.quick, value: store.pending.map(\.id))
    }

    // MARK: Actions

    private func accept(_ id: String) {
        selectNeighbour(of: id)
        Task {
            do { try await store.accept(id: id) } catch { /* shown by store.lastError */ }
        }
    }

    private func dismiss(_ id: String) {
        selectNeighbour(of: id)
        perform { try store.dismiss(id: id) }
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { /* shown by store.lastError */ }
    }

    /// Runs `body` on the selected pending item. Ignores the key if nothing is selected.
    private func act(_ body: (String) -> Void) -> KeyPress.Result {
        guard let selection, store.pending.contains(where: { $0.id == selection }) else { return .ignored }
        body(selection)
        return .handled
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let ids = store.pending.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = selection.flatMap(ids.firstIndex(of:))
        let next = current.map { min(max($0 + offset, 0), ids.count - 1) } ?? (offset > 0 ? 0 : ids.count - 1)
        selection = ids[next]
        return .handled
    }

    /// After an item leaves the list, select the one that takes its place.
    private func selectNeighbour(of id: String) {
        guard selection == id else { return }
        let ids = store.pending.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        selection = ids.indices.contains(index + 1) ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let isAllowed: Bool
    let accept: () -> Void
    let edit: () -> Void
    let openDraft: () -> Void
    let dismiss: () -> Void
    let toggleAllowed: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: InboxStyle.icon(for: item.kind))
                .font(.system(size: Size.iconM))
                .foregroundStyle(Palette.accent)
                .frame(width: Size.avatar)
                .help(InboxStyle.kindName(item.kind))
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(item.title).font(Typo.body)
                HStack(spacing: Space.xs) {
                    ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                        Pill(text: field.value.isEmpty ? field.key : "\(field.key) \(field.value)")
                    }
                    if !item.source.isEmpty {
                        Pill(text: InboxStyle.sourceName(item.source), color: Palette.accent)
                    }
                    if isAllowed {
                        Pill(text: "auto-accepts", color: Palette.success)
                    }
                }
            }
            Spacer(minLength: Space.m)
            HStack(spacing: Space.s) {
                if item.kind == "message.draft" {
                    // A draft is only ever opened for the user to send; accepting it here would
                    // just tick it off without sending anything.
                    Button("Open in Messages", action: openDraft)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Open the draft in Messages. You still press Send and confirm.")
                } else {
                    Button("Accept", action: accept)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Accept (Return)")
                }
                Button(action: edit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Edit")
                    .accessibilityLabel("Edit")
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss (Delete)")
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: Size.listRowMinHeight)
        .contextMenu {
            if item.kind == "message.draft" { Button("Open in Messages", action: openDraft) }
            Button("Accept", action: accept)
            Button("Edit…", action: edit)
            Button("Dismiss", action: dismiss)
            Divider()
            Button(isAllowed ? "Stop always allowing this kind" : "Always allow this kind", action: toggleAllowed)
                .disabled(item.kind.isEmpty)
        }
    }
}

private struct DoneRow: View {
    let item: InboxItem

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: item.state == .accepted ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(item.state == .accepted ? Palette.success : Palette.textTertiary)
            Text(item.title)
                .strikethrough(item.state == .dismissed)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            if !item.created.isEmpty {
                Text(item.created).font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
        }
        .font(Typo.secondary)
    }
}

/// Edits a proposal's title and fields.
private struct InboxEditSheet: View {
    @Environment(\.dismiss) private var dismissSheet
    @State private var draft: InboxItem
    @State private var newKey = ""
    @State private var newValue = ""
    let save: (InboxItem) -> Void

    init(item: InboxItem, save: @escaping (InboxItem) -> Void) {
        _draft = State(initialValue: item)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Edit proposal").font(Typo.sectionTitle)
            Form {
                TextField("Title", text: $draft.title)
                ForEach(Array(draft.fields.enumerated()), id: \.offset) { index, field in
                    HStack {
                        TextField(field.key, text: valueBinding(index))
                        Button { removeField(index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(field.key)")
                    }
                }
                HStack {
                    TextField("New field", text: $newKey, prompt: Text("name, e.g. due"))
                    TextField("Value", text: $newValue, prompt: Text("value"))
                    Button("Add", action: addField)
                        .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .formStyle(.columns)
            HStack {
                Text("\(InboxStyle.kindName(draft.kind))\(draft.source.isEmpty ? "" : " · " + InboxStyle.sourceName(draft.source))")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(draft)
                    dismissSheet()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.l)
        .frame(width: Size.readableWidth / 1.5)
    }

    private func valueBinding(_ index: Int) -> Binding<String> {
        Binding(get: { draft.fields.indices.contains(index) ? draft.fields[index].value : "" },
                set: { if draft.fields.indices.contains(index) { draft.fields[index].value = $0 } })
    }

    private func removeField(_ index: Int) {
        if draft.fields.indices.contains(index) { draft.fields.remove(at: index) }
    }

    private func addField() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        draft.fields.append(.init(key: key, value: newValue))
        newKey = ""
        newValue = ""
    }
}
