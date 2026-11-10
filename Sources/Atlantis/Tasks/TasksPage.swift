import AtlantisCore
import SwiftUI

/// Tasks (PRD F2): quick add on top, a list per view, and a side panel to edit the selected task.
/// Keys: ⌘N quick add · J/K or ↑/↓ move · Space complete (or reopen) · Esc leave a field / deselect.
struct TasksPage: View {
    let store: TaskStore
    /// Bots that take tasks (M6): the inspector's "Assign to bot".
    let agents: AgentService
    var openInbox: () -> Void = {}

    @State private var kind: TaskListKind = .today
    @State private var selection: String?
    @State private var quickText = ""
    @State private var errorMessage: String?
    @State private var debugApplied = false
    @FocusState private var quickAddFocused: Bool
    @FocusState private var listFocused: Bool

    private var today: DayStamp { store.today }
    private var calendar: Calendar { store.timeZoneCalendar }

    private var sections: [TaskSection] {
        TaskLists.sections(kind, tasks: store.tasks, today: today, calendar: calendar)
    }
    private var flat: [TaskItem] { sections.flatMap(\.tasks) }
    private var selected: TaskItem? { selection.flatMap { store.task(id: $0) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .frame(minWidth: Size.pageMinWidth, maxWidth: .infinity)
            if let task = selected {
                Divider()
                TaskInspector(store: store, task: task, edit: edit(_:), delete: delete, close: { selection = nil },
                              agents: agents, assign: assign(_:), openInbox: openInbox)
                    .id(task.id)
                    .frame(width: Size.sidePanel)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Palette.background)
        .animation(Motion.quick, value: selected == nil)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Task", systemImage: "plus") { quickAddFocused = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New task (⌘N)")
            }
        }
        .task {
            store.start()
            applyDebugOptions()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            QuickAddBar(text: $quickText, store: store, focus: $quickAddFocused, submit: addFromQuickAdd, leave: leaveQuickAdd)
            HStack {
                Picker("View", selection: $kind) {
                    ForEach(TaskListKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            if let errorMessage {
                ErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }
        }
        .padding(Space.l)
    }

    // MARK: List

    @ViewBuilder private var content: some View {
        if let problem = store.problem, store.tasks.isEmpty {
            EmptyState(title: "Tasks can't be read", systemImage: "exclamationmark.triangle", message: problem)
        } else if !store.isLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xs, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.tasks) { task in
                                TaskRow(task: task, today: today, calendar: calendar, isSelected: task.id == selection,
                                        toggle: { toggle(task) }, select: { select(task) })
                                    .id(task.id)
                            }
                        } header: {
                            SectionHeader(section: section)
                        }
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.l)
                .frame(maxWidth: Size.readableWidth * 1.4, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(phases: .down) { press in handleKey(press) }
            .onChange(of: selection) { _, id in
                if let id { withAnimation(Motion.quick) { proxy.scrollTo(id) } }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch kind {
        case .today: EmptyState(title: "Nothing due today", systemImage: "sun.max", message: "Add a task above, or see Upcoming.")
        case .upcoming: EmptyState(title: "Nothing coming up", systemImage: "calendar", message: "Tasks with a later due date show here.")
        case .project: EmptyState(title: "No open tasks", systemImage: "folder", message: "Type +project when you add a task to group it.")
        case .area: EmptyState(title: "No open tasks", systemImage: "square.grid.2x2", message: "Type #school (or any #area) when you add a task.")
        case .done: EmptyState(title: "Nothing done yet", systemImage: "checkmark.circle", message: "Finished tasks show here.")
        }
    }

    // MARK: Actions

    private func run<T>(_ action: () throws -> T) -> T? {
        do {
            let value = try action()
            errorMessage = nil
            return value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func addFromQuickAdd() {
        let parsed = QuickAdd.parse(quickText, now: store.now, calendar: calendar,
                                    knownProjects: store.projects, knownAreas: store.areas)
        guard !parsed.title.isEmpty else { return }
        if run({ try store.add(parsed.makeTask()) }) != nil {
            withAnimation(Motion.quick) { quickText = "" }
        }
    }

    private func leaveQuickAdd() {
        quickAddFocused = false
        listFocused = true
    }

    private func select(_ task: TaskItem) {
        selection = task.id
        listFocused = true
    }

    private func toggle(_ task: TaskItem) {
        // Move the selection on first, since a completed task usually leaves the view.
        let next = task.id == selection ? neighbour(of: task.id) : selection
        let done = task.isDone || task.isCancelled
        let result: String? = withAnimation(Motion.quick) {
            run { done ? try store.reopen(id: task.id) : try store.complete(id: task.id) }
        }
        if result != nil, task.id == selection { selection = next }
    }

    /// The task after (else before) this one in the current view.
    private func neighbour(of id: String) -> String? {
        let ids = flat.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return nil }
        if i + 1 < ids.count { return ids[i + 1] }
        return i > 0 ? ids[i - 1] : nil
    }

    private func edit(_ change: (inout TaskItem) -> Void) {
        guard let id = selection else { return }
        if let newID = run({ try store.update(id: id, change) }), newID != id { selection = newID }
    }

    /// Assigns the selected task to a bot (or clears it) and starts its run.
    private func assign(_ bot: String?) -> String? {
        guard let task = selected else { return nil }
        let (id, problem) = agents.assign(task, to: bot)
        if id != selection { selection = id }
        return problem
    }

    private func delete() {
        guard let id = selection else { return }
        let next = neighbour(of: id)
        if run({ try store.delete(id: id) }) != nil { withAnimation(Motion.quick) { selection = next } }
    }

    private func move(_ step: Int) {
        let ids = flat.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection.flatMap({ ids.firstIndex(of: $0) }) else {
            selection = step > 0 ? ids.first : ids.last
            return
        }
        selection = ids[min(max(current + step, 0), ids.count - 1)]
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        switch press.key {
        case .upArrow: move(-1)
        case .downArrow: move(1)
        case .space:
            guard let task = selected else { return .ignored }
            toggle(task)
        case .escape:
            guard selection != nil else { return .ignored }
            selection = nil
        default:
            switch press.characters {
            case "j": move(1)
            case "k": move(-1)
            default: return .ignored
            }
        }
        return .handled
    }

    /// Debug launch options (`-debugTasksView`, `-debugTaskSelect`) for screenshots.
    private func applyDebugOptions() {
        guard !debugApplied else { return }
        debugApplied = true
        let debug = DebugOptions.fromArguments()
        if let view = debug.tasksView { kind = view }
        if let n = debug.taskSelect, n >= 1, n <= flat.count { selection = flat[n - 1].id }
    }
}
