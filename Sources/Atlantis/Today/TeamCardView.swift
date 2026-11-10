import AtlantisCore
import SwiftUI

// MARK: - Team card (M7)

/// Today's "Team" card: what the bots did today, approvals waiting, and the morning plan's first
/// lines. Built from the stores it observes (`TeamCard.build`); no timers of its own.
struct TeamCardView: View {
    let card: TeamCard
    let openThread: (_ bot: String, _ id: String) -> Void
    let openInbox: () -> Void
    let openAgents: () -> Void

    var body: some View {
        SectionCard(title: "Team", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: Space.s) {
                if let morning = card.morning { MorningNoteView(note: morning, openInbox: openInbox) }
                if card.pendingApprovals > 0 {
                    Button(action: openInbox) {
                        Label(card.pendingApprovals == 1 ? "1 bot suggestion waiting" : "\(card.pendingApprovals) bot suggestions waiting",
                              systemImage: "tray")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .help("Open the Inbox")
                }
                if card.runs.isEmpty {
                    Text(card.automaticRuns ? "No bot runs yet today." : "No bot runs today. Bots only run when you ask them (Settings ▸ Bots on Their Own).")
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(card.runs) { run in
                            TeamRunRow(run: run) {
                                if let id = run.threadID { openThread(run.bot, id) } else { openAgents() }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MorningNoteView: View {
    let note: TeamCard.Note
    let openInbox: () -> Void

    var body: some View {
        Button(action: openInbox) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Morning plan").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                ForEach(Array(note.lines.enumerated()), id: \.offset) { index, line in
                    Text(Self.inline(line))
                        .font(index == 0 ? Typo.body : Typo.secondary)
                        .foregroundStyle(index == 0 ? Palette.text : Palette.textSecondary)
                        .lineLimit(index == 0 ? 3 : 2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accent.opacity(Palette.highlightOpacity), in: RoundedRectangle(cornerRadius: Radius.m))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the morning plan in the Inbox")
    }

    /// Bold and italics from the bot's Markdown, on one line.
    static func inline(_ text: String) -> AttributedString {
        let clean = text.hasPrefix("- ") || text.hasPrefix("* ") ? String(text.dropFirst(2)) : text
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: clean, options: options)) ?? AttributedString(clean)
    }
}

private struct TeamRunRow: View {
    let run: TeamCard.Run
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s) {
                Text(run.avatar)
                    .frame(width: Size.avatar, height: Size.avatar)
                    .background(Palette.background, in: Circle())
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(run.title).lineLimit(1)
                    Text("\(run.botName) · \(run.trigger) · \(run.at.formatted(date: .omitted, time: .shortened))")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.s)
                status
            }
            .padding(.vertical, Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(run.threadID == nil ? "Open the Agents page" : "Open this run's thread")
    }

    @ViewBuilder private var status: some View {
        switch run.status {
        case .queued:
            Pill(text: "Waiting")
        case .running:
            ProgressView().controlSize(.small)
        case .waitingForApproval:
            Image(systemName: "hand.raised.fill").foregroundStyle(Palette.warning).help("Waiting for your approval")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success).help("Done")
        case .failed(let why):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).help(why)
        case .skipped(let why):
            Pill(text: why)
        }
    }
}

// MARK: - End of day (PRD F6)

/// The evening shutdown: go through today's open tasks (done, tomorrow, drop or keep), then add one
/// line to the daily note's machine block. Nothing changes until "Finish day".
struct EndOfDaySheet: View {
    let model: AppModel
    let tasks: [TaskItem]
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String: ShutdownChoice] = [:]
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("End of Day").font(Typo.pageTitle)
                Text(tasks.isEmpty ? "Nothing open for today. Nice work." : "What happens to what's left? Tasks you don't touch stay as they are.")
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
            }
            if !tasks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ForEach(tasks) { task in
                            HStack(spacing: Space.m) {
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(task.title.isEmpty ? "Untitled" : task.title).lineLimit(2)
                                    if let detail = detail(task) {
                                        Text(detail).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                                    }
                                }
                                Spacer(minLength: Space.m)
                                Picker("", selection: binding(task.id)) {
                                    ForEach(ShutdownChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                            .padding(.vertical, Space.xxs)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: Size.sheetListMaxHeight)
            }
            if let errorMessage {
                ErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }
            HStack {
                Text(preview).font(Typo.caption).foregroundStyle(Palette.textSecondary).lineLimit(2)
                Spacer(minLength: Space.m)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Finish Day", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: Size.sheetWidth)
    }

    private func binding(_ id: String) -> Binding<ShutdownChoice> {
        Binding { choices[id] ?? .keep } set: { choices[id] = $0 }
    }

    private func detail(_ task: TaskItem) -> String? {
        var parts: [String] = []
        let today = model.tasks.today
        if let due = task.due {
            parts.append(due < today ? "Overdue since \(Self.short(due))" : due == today ? "Due today" : "Due \(Self.short(due))")
        }
        if let estimate = task.estimateMinutes { parts.append(Estimate.format(estimate)) }
        if let project = task.project { parts.append(project) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "8 Nov".
    private static func short(_ day: DayStamp) -> String {
        day.date().map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? day.description
    }

    private var line: String {
        let tally = Shutdown.tally(tasks, choices: choices)
        let time = TodayTime.format(TodayTime.minuteOfDay(model.now()))
        return Shutdown.line(time: time, done: tally.done, moved: tally.moved, dropped: tally.dropped, kept: tally.kept)
    }

    private var preview: String { "Adds to today's note: \(line)" }

    private func finish() {
        let store = model.tasks
        let today = store.today
        let summary = line
        do {
            for task in tasks {
                switch choices[task.id] ?? .keep {
                case .keep: continue
                case .done: try store.complete(id: task.id)
                case .tomorrow: try store.update(id: task.id) { Shutdown.moveToTomorrow(&$0, today: today) }
                case .drop: try store.update(id: task.id) { Shutdown.drop(&$0) }
                }
            }
            switch try model.today.appendShutdown(summary) {
            case .written: dismiss()
            case .noMarkers:
                errorMessage = "Tasks updated, but today's note has no Atlantis block, so the summary wasn't added."
            case .noTemplate, .noVault:
                errorMessage = "Tasks updated, but there's no daily note or template to add the summary to."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
