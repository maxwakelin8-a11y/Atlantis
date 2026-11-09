import AtlantisCore
import SwiftUI

/// Side panel for the selected task. Every control sends only its own field change; the store
/// applies it to the freshly re-read file, so edits made in Obsidian meanwhile are kept.
struct TaskInspector: View {
    let store: TaskStore
    let task: TaskItem
    let edit: ((inout TaskItem) -> Void) -> Void
    let delete: () -> Void
    let close: () -> Void

    @State private var newSubtask = ""
    @State private var confirmDelete = false

    private var calendar: Calendar { store.timeZoneCalendar }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                titleRow
                labelled("Due") { dueRow }
                labelled("Estimate") {
                    CommitTextField(prompt: "e.g. 45m or 1h30m", value: task.estimateMinutes.map(Estimate.format) ?? "") { text in
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { edit { $0.estimateMinutes = nil }; return true }
                        guard let minutes = Estimate.parse(trimmed) else { return false }
                        edit { $0.estimateMinutes = minutes }
                        return true
                    }
                }
                labelled("Priority") { priorityPicker }
                labelled("Project") {
                    nameField(prompt: "None", value: task.project ?? "", options: store.projects) { value in
                        edit { $0.project = value }
                    }
                }
                labelled("Area or mode") {
                    nameField(prompt: "None", value: task.group ?? "", options: areaOptions) { value in
                        edit { $0.group = value }
                    }
                }
                labelled("Notes") {
                    CommitTextEditor(value: task.notes) { text in edit { $0.setNotes(text) } }
                }
                labelled("Subtasks") { subtasks }
                footer
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background)
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete) {
            Button("Delete Task", role: .destructive, action: delete)
        } message: {
            Text("This removes its line (and any subtasks and notes) from tasks.md.")
        }
    }

    private var areaOptions: [String] {
        var seen = Set<String>()
        return (TaskModes.all + store.areas).filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Parts

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Button(action: toggleDone) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Size.iconM))
                    .foregroundStyle(task.isDone ? Palette.success : Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help(task.isDone ? "Reopen" : "Complete")
            CommitTextField(prompt: "Title", value: task.title, axis: .vertical, font: Typo.sectionTitle) { text in
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return false }
                edit { $0.title = clean }
                return true
            }
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("Close (Esc)")
        }
    }

    private func toggleDone() {
        let day = store.today
        edit { task in
            if task.isOpen { task.markDone(on: day) } else { task.reopen() }
        }
    }

    private var dueRow: some View {
        let due = task.due
        let today = store.today
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                DatePicker("Due", selection: Binding(
                    get: { (due ?? today).date(calendar: calendar) ?? Date() },
                    set: { date in edit { $0.due = DayStamp(date, calendar: calendar) } }
                ), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .environment(\.calendar, calendar)
                    .environment(\.timeZone, calendar.timeZone)
                    .opacity(due == nil ? 0.5 : 1)
                Spacer()
            }
            HStack(spacing: Space.s) {
                Button("Today") { edit { $0.due = today } }
                Button("Tomorrow") { edit { $0.due = today.adding(days: 1, calendar: calendar) } }
                Button("Clear") { edit { $0.due = nil } }.disabled(due == nil)
            }
            .buttonStyle(.borderless)
            .font(Typo.secondary)
        }
    }

    private var priorityPicker: some View {
        Picker("Priority", selection: Binding(
            get: { task.priority ?? 0 },
            set: { level in edit { $0.priority = level == 0 ? nil : level } }
        )) {
            Text("None").tag(0)
            Text("1").tag(1)
            Text("2").tag(2)
            Text("3").tag(3)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func nameField(prompt: String, value: String, options: [String], commit: @escaping (String?) -> Void) -> some View {
        HStack(spacing: Space.xs) {
            CommitTextField(prompt: prompt, value: value) { text in
                let clean = text.trimmingCharacters(in: .whitespaces)
                commit(clean.isEmpty ? nil : clean)
                return true
            }
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { commit(option) }
                    }
                    Divider()
                    Button("None") { commit(nil) }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var subtasks: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(task.subtasks) { sub in
                Button { edit { $0.toggleSubtask(sub.id) } } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: sub.isDone ? "checkmark.square.fill" : "square")
                            .foregroundStyle(sub.isDone ? Palette.accent : Palette.textSecondary)
                        Text(sub.title)
                            .strikethrough(sub.isDone)
                            .foregroundStyle(sub.isDone ? Palette.textSecondary : Palette.text)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: Space.s) {
                Image(systemName: "plus").foregroundStyle(Palette.textTertiary)
                TextField("Add a subtask", text: $newSubtask)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let title = newSubtask
                        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        edit { $0.addSubtask(title) }
                        newSubtask = ""
                    }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Divider()
            if let source = task.source { footerLine("Source", source) }
            if let added = task.added { footerLine("Added", added.description) }
            if let done = task.doneDate { footerLine("Done", done.description) }
            Button("Delete Task…", role: .destructive) { confirmDelete = true }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.danger)
                .font(Typo.secondary)
                .padding(.top, Space.xs)
        }
    }

    private func footerLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Typo.caption).foregroundStyle(Palette.textTertiary)
            Text(value).font(Typo.caption).foregroundStyle(Palette.textSecondary).textSelection(.enabled)
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            content()
        }
    }
}

/// A text field that sends its text when you press Return or click away, not on every key.
/// `commit` returns false for text it can't use; the field then goes back to the stored value.
/// If the stored value changes meanwhile (an edit in Obsidian), the field follows unless you
/// are in the middle of typing something different.
struct CommitTextField: View {
    var prompt: String
    let value: String
    var axis: Axis = .horizontal
    var font: Font = Typo.body
    let commit: (String) -> Bool

    @State private var draft = ""
    @State private var committed = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $draft, axis: axis)
            .textFieldStyle(.roundedBorder)
            .font(font)
            .focused($focused)
            .lineLimit(axis == .vertical ? 1...4 : 1...1)
            .onAppear { draft = value; committed = value }
            .onSubmit { send() }
            .onChange(of: focused) { _, isFocused in if !isFocused { send() } }
            .onChange(of: value) { old, new in
                if draft == old || draft == committed { draft = new }
                committed = new
            }
    }

    private func send() {
        guard draft != value else { return }
        committed = draft
        if !commit(draft) { draft = value; committed = value }
    }
}

/// Multi-line version: sends when focus leaves.
struct CommitTextEditor: View {
    let value: String
    let commit: (String) -> Void

    @State private var draft = ""
    @State private var committed = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .font(Typo.body)
            .scrollContentBackground(.hidden)
            .padding(Space.xs)
            .frame(minHeight: Size.listRowMinHeight * 3)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Radius.m).stroke(focused ? Palette.accent : Palette.separator))
            .focused($focused)
            .onAppear { draft = value; committed = value }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused, draft != value else { return }
                committed = draft
                commit(draft)
            }
            .onChange(of: value) { old, new in
                if draft == old || draft == committed { draft = new }
                committed = new
            }
    }
}
