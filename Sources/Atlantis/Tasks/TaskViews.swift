import AtlantisCore
import SwiftUI

/// The quick-add field with a live preview of what it understood.
struct QuickAddBar: View {
    @Binding var text: String
    let store: TaskStore
    var focus: FocusState<Bool>.Binding
    let submit: () -> Void
    let leave: () -> Void

    private var parsed: QuickAddResult {
        QuickAdd.parse(text, now: store.now, calendar: store.timeZoneCalendar,
                       knownProjects: store.projects, knownAreas: store.areas)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Palette.accent)
                    .font(Typo.sectionTitle)
                TextField("Add a task: Turing draft thu 45m #school !1 +turing", text: $text)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .focused(focus)
                    .onSubmit(submit)
                    .onKeyPress(.escape) { leave(); return .handled }
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.m))
            .overlay(RoundedRectangle(cornerRadius: Radius.m).stroke(focus.wrappedValue ? Palette.accent : Palette.separator))

            if !text.trimmingCharacters(in: .whitespaces).isEmpty { preview }
        }
    }

    private var preview: some View {
        let p = parsed
        let day = store.today
        return HStack(spacing: Space.s) {
            Text(p.title.isEmpty ? "Needs a title" : p.title)
                .font(Typo.secondary)
                .foregroundStyle(p.title.isEmpty ? Palette.warning : Palette.textSecondary)
                .lineLimit(1)
            if let due = p.due {
                Pill(text: DayLabel.title(for: due, today: day, calendar: store.timeZoneCalendar), color: Palette.accent)
            }
            if let minutes = p.estimateMinutes { Pill(text: Estimate.format(minutes)) }
            if let pri = p.priority { Pill(text: "!\(pri)", color: Palette.priority(pri)) }
            if let mode = p.mode { Pill(text: "#\(TaskModes.displayName(mode))") }
            if let area = p.area { Pill(text: "#\(area)") }
            if let project = p.project { Pill(text: "+\(project)") }
        }
        .padding(.horizontal, Space.m)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            Text(message).font(Typo.secondary).lineLimit(2)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(Space.s)
        .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m))
    }
}

struct SectionHeader: View {
    let section: TaskSection

    var body: some View {
        HStack(spacing: Space.s) {
            Text(section.title)
                .font(Typo.sectionTitle)
                .foregroundStyle(section.isOverdue ? Palette.danger : Palette.text)
            Text("\(section.tasks.count)")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
        }
        .padding(.top, Space.m)
        .padding(.bottom, Space.xs)
        .background(Palette.background)
    }
}

struct TaskRow: View {
    let task: TaskItem
    let today: DayStamp
    let calendar: Calendar
    let isSelected: Bool
    let toggle: () -> Void
    let select: () -> Void

    private var closed: Bool { !task.isOpen }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Button(action: toggle) {
                Image(systemName: checkSymbol)
                    .font(.system(size: Size.iconM))
                    .foregroundStyle(checkColor)
            }
            .buttonStyle(.plain)
            .help(closed ? "Reopen (Space)" : "Complete (Space)")

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .font(Typo.body)
                    .strikethrough(closed)
                    .foregroundStyle(closed ? Palette.textSecondary : Palette.text)
                    .lineLimit(2)
                meta
            }
            Spacer(minLength: Space.s)
            if let due = task.due, !closed { dueLabel(due) }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .frame(minHeight: Size.listRowMinHeight)
        .background(isSelected ? Palette.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: Radius.m))
        .contentShape(RoundedRectangle(cornerRadius: Radius.m))
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: closed ? "Reopen" : "Complete", toggle)
    }

    private var checkSymbol: String {
        if task.isDone { return "checkmark.circle.fill" }
        if task.isCancelled { return "xmark.circle" }
        return "circle"
    }

    private var checkColor: Color {
        if closed { return Palette.success }
        if let pri = task.priority { return Palette.priority(pri) }
        return Palette.textTertiary
    }

    @ViewBuilder private var meta: some View {
        let subtasks = task.subtasks
        let hasMeta = task.project != nil || task.group != nil || task.estimateMinutes != nil || !subtasks.isEmpty
        if hasMeta {
            HStack(spacing: Space.xs) {
                if let project = task.project { Pill(text: project) }
                if let group = task.group { Pill(text: TaskModes.displayName(group)) }
                if let minutes = task.estimateMinutes { Pill(text: Estimate.format(minutes)) }
                if !subtasks.isEmpty {
                    Pill(text: "\(subtasks.filter(\.isDone).count)/\(subtasks.count)")
                }
            }
        }
    }

    private func dueLabel(_ due: DayStamp) -> some View {
        let color: Color = due < today ? Palette.danger : (due == today ? Palette.accent : Palette.textSecondary)
        return Text(DayLabel.short(for: due, today: today, calendar: calendar))
            .font(Typo.secondary)
            .foregroundStyle(color)
    }
}
