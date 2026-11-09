import AppKit
import AtlantisCore
import SwiftUI

/// Today (PRD F1): assessments due soon and notices on top; the day's timeline on the left
/// (classes and scheduled tasks); Next up, today's tasks and the Top 3 on the right.
///
/// It reads the stores, so it updates when tasks.md, the SEQTA cache or the daily note change.
/// The only clock is a once-a-minute `TimelineView`, which runs only while the page is visible.
struct TodayPage: View {
    let model: AppModel

    @State private var errorMessage: String?

    private var store: TodayStore { model.today }
    private var tasks: TaskStore { model.tasks }

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let today = store.model(tasks: tasks.tasks)
            let minute = TodayTime.minuteOfDay(model.now())
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    header(today)
                    if let errorMessage {
                        ErrorBanner(message: errorMessage) { self.errorMessage = nil }
                    }
                    if !today.assessments.isEmpty { DueSoonSection(items: today.assessments, colour: store.colour(code:)) }
                    if !today.notices.isEmpty { NoticesSection(notices: today.notices) }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Space.l) {
                            schedule(today, minute: minute).frame(minWidth: Size.pageMinWidth)
                            side(today, minute: minute).frame(width: Size.todaySide)
                        }
                        VStack(alignment: .leading, spacing: Space.l) {
                            side(today, minute: minute)
                            schedule(today, minute: minute)
                        }
                    }
                }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.background)
        .task {
            model.startToday()
            store.reloadDailyNote()
        }
    }

    // MARK: Header

    private func header(_ today: TodayModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(dateTitle(today.day)).font(Typo.pageTitle)
                Text(summary(today)).font(Typo.secondary).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: Space.m)
            SeqtaSyncControl(sync: model.seqtaSync, openSeqta: { model.page = .seqta },
                             openSettings: { model.page = .settings }, now: model.now())
        }
    }

    private func dateTitle(_ day: DayStamp) -> String {
        guard let date = day.date() else { return day.description }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func summary(_ today: TodayModel) -> String {
        let classes = today.blocks.filter { $0.lesson != nil }.count
        var parts: [String] = []
        parts.append(classes == 0 ? "No classes" : classes == 1 ? "1 class" : "\(classes) classes")
        let count = today.openTaskCount
        parts.append(count == 0 ? "no tasks due" : count == 1 ? "1 task" : "\(count) tasks")
        if let first = today.assessments.first {
            parts.append("next assessment \(first.countdown)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Columns

    private func schedule(_ today: TodayModel, minute: Int) -> some View {
        SectionCard(title: "Schedule", systemImage: "calendar") {
            ScheduleList(today: today, minute: minute, neverSynced: model.seqtaSync.lastSync == nil,
                         toggle: toggle(_:))
        }
    }

    private func side(_ today: TodayModel, minute: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            NextUpCard(today: today, minute: minute)
            SectionCard(title: "Tasks", systemImage: "checklist") {
                TodayTaskList(sections: today.taskSections, today: today.day, toggle: toggle(_:),
                              openTasks: { model.page = .tasks })
            }
            SectionCard(title: "Top 3", systemImage: "star") {
                TopThreeList(items: today.topThree, noteURL: store.dailyNoteURL)
            }
        }
    }

    private func toggle(_ task: TaskItem) {
        do {
            if task.isOpen { try tasks.complete(id: task.id) } else { try tasks.reopen(id: task.id) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - SEQTA sync

/// "Last synced 7:42" and a Refresh button, or why it can't sync.
struct SeqtaSyncControl: View {
    let sync: SeqtaSync
    let openSeqta: () -> Void
    let openSettings: () -> Void
    let now: Date

    var body: some View {
        HStack(spacing: Space.s) {
            status
            Button {
                Task { await sync.refresh(reason: .manual) }
            } label: {
                Label("Refresh SEQTA", systemImage: "arrow.clockwise")
            }
            .disabled(sync.isSyncing)
            .help("Refresh SEQTA (⇧⌘R)")
        }
        .controlSize(.small)
    }

    @ViewBuilder private var status: some View {
        switch sync.state {
        case .syncing:
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.mini)
                Text("Syncing…").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
            }
        case .needsSignIn:
            Button("Sign in via the SEQTA tab", systemImage: "person.crop.circle.badge.exclamationmark", action: openSeqta)
                .buttonStyle(.link)
                .font(Typo.secondary)
        case let .failed(message) where AppSettings.seqtaURL == nil:
            Button("Set your SEQTA address in Settings", action: openSettings)
                .buttonStyle(.link)
                .font(Typo.secondary)
                .help(message)
        case let .failed(message):
            Label("Sync failed", systemImage: "exclamationmark.triangle")
                .font(Typo.secondary)
                .foregroundStyle(Palette.warning)
                .help(message)
        case .idle:
            Text(lastSyncText)
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
                .help(sync.partialFailures.isEmpty ? "" : "Didn't load: " + sync.partialFailures.joined(separator: ", "))
        }
    }

    private var lastSyncText: String {
        guard let last = sync.lastSync else { return "Not synced yet" }
        let time = last.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(last, inSameDayAs: now) { return "Last synced \(time)" }
        return "Last synced \(last.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }
}

// MARK: - Due soon and notices

struct DueSoonSection: View {
    let items: [DueAssessment]
    let colour: (String) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Label("Due in the next 14 days", systemImage: "graduationcap").font(Typo.sectionTitle)
                Text("\(items.count)").font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Size.cardMinWidth), spacing: Space.m, alignment: .top)],
                      alignment: .leading, spacing: Space.m) {
                ForEach(items) { item in card(item) }
            }
        }
    }

    private func card(_ item: DueAssessment) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            RoundedRectangle(cornerRadius: Radius.s)
                .fill(Palette.subject(colour(item.assessment.code)))
                .frame(width: Size.subjectBar)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(item.countdown.prefix(1).uppercased() + item.countdown.dropFirst())
                    .font(Typo.caption.weight(.semibold))
                    .foregroundStyle(urgency(item.daysLeft))
                Text(item.assessment.title)
                    .font(Typo.body)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.assessment.subject)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private func urgency(_ days: Int) -> Color {
        if days <= 1 { return Palette.danger }
        if days <= 3 { return Palette.warning }
        return Palette.textSecondary
    }
}

struct NoticesSection: View {
    let notices: [Notice]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Space.m) {
                ForEach(notices) { notice in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(notice.title).font(Typo.body.weight(.medium))
                        let from = [notice.label, notice.staff].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !from.isEmpty {
                            Text(from).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        }
                        if !notice.contents.isEmpty {
                            Text(notice.contents)
                                .font(Typo.secondary)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: Size.readableWidth, alignment: .leading)
                }
            }
            .padding(.top, Space.s)
        } label: {
            HStack(spacing: Space.s) {
                Label("Notices", systemImage: "megaphone").font(Typo.sectionTitle)
                Text("\(notices.count)").font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.quick) { expanded.toggle() } }
        }
        .padding(Space.m)
        .cardStyle()
    }
}

// MARK: - Schedule

struct ScheduleList: View {
    let today: TodayModel
    let minute: Int
    let neverSynced: Bool
    let toggle: (TaskItem) -> Void

    var body: some View {
        if today.blocks.isEmpty && today.anytime.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("No classes today").font(Typo.body).foregroundStyle(Palette.textSecondary)
                if neverSynced {
                    Text("Refresh SEQTA to see your timetable here.")
                        .font(Typo.caption).foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.vertical, Space.s)
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                if !today.anytime.isEmpty {
                    Text("Anytime").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    ForEach(today.anytime) { task in
                        TaskBlockRow(title: task.title, detail: nil, isDone: !task.isOpen) { toggle(task) }
                    }
                    if !today.blocks.isEmpty { Divider().padding(.vertical, Space.xs) }
                }
                ForEach(Array(today.blocks.enumerated()), id: \.element.id) { index, block in
                    if showsNowLine(before: index) { NowLine(minute: minute) }
                    BlockRow(block: block, minute: minute, toggle: toggle)
                }
                if showsNowLine(before: today.blocks.count) { NowLine(minute: minute) }
            }
        }
    }

    /// The now line goes before the first block that starts after now, while the day is on.
    private func showsNowLine(before index: Int) -> Bool {
        guard let first = today.blocks.first, let last = today.blocks.last else { return false }
        guard minute >= first.start, minute < last.end else { return false }
        if today.blocks.contains(where: { $0.contains(minute: minute) }) { return false } // highlighted instead
        let nextIndex = today.blocks.firstIndex { $0.start > minute } ?? today.blocks.count
        return index == nextIndex
    }
}

struct NowLine: View {
    let minute: Int

    var body: some View {
        HStack(spacing: Space.s) {
            Text(TodayTime.format(minute))
                .font(Typo.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.danger)
                .frame(width: Size.timeColumn, alignment: .leading)
            Rectangle().fill(Palette.danger).frame(height: Size.nowLine)
        }
        .padding(.vertical, Space.xxs)
        .accessibilityLabel("Now, \(TodayTime.format(minute))")
    }
}

struct BlockRow: View {
    let block: TodayBlock
    let minute: Int
    let toggle: (TaskItem) -> Void

    private var isNow: Bool { block.contains(minute: minute) }
    private var isPast: Bool { block.end <= minute }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(block.startText).font(Typo.caption.monospacedDigit().weight(.medium))
                Text(block.endText).font(Typo.caption.monospacedDigit()).foregroundStyle(Palette.textTertiary)
            }
            .frame(width: Size.timeColumn, alignment: .leading)
            switch block.kind {
            case let .lesson(lesson): lessonBody(lesson)
            case let .task(task):
                TaskBlockRow(title: block.title, detail: task.estimateMinutes.map { "Scheduled · " + Estimate.format($0) } ?? "Scheduled",
                             isDone: !task.isOpen) { toggle(task) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.xs)
        .background(isNow ? Palette.accent.opacity(Palette.highlightOpacity) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.m))
        .opacity(isPast ? Palette.pastOpacity : 1)
        .accessibilityElement(children: .combine)
    }

    private func lessonBody(_ lesson: Lesson) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            RoundedRectangle(cornerRadius: Radius.s)
                .fill(Palette.subject(lesson.colour))
                .frame(width: Size.subjectBar)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Text(lesson.subject).font(Typo.body.weight(.semibold))
                    if isNow { Pill(text: "Now", color: Palette.accent) }
                }
                let place = [lesson.room, lesson.teacher].filter { !$0.isEmpty }.joined(separator: " · ")
                if !place.isEmpty {
                    Text(place).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
                if let topic = lesson.topic, !topic.isEmpty {
                    Text(topic).font(Typo.secondary).foregroundStyle(Palette.text).lineLimit(2)
                }
                if let homework = lesson.homework, !homework.isEmpty {
                    Label(homework, systemImage: "book.closed")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct TaskBlockRow: View {
    let title: String
    let detail: String?
    let isDone: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Button(action: toggle) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Size.iconS))
                    .foregroundStyle(isDone ? Palette.success : Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help(isDone ? "Reopen" : "Complete")
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Typo.body).strikethrough(isDone)
                if let detail { Text(detail).font(Typo.caption).foregroundStyle(Palette.textSecondary) }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Right column

struct NextUpCard: View {
    let today: TodayModel
    let minute: Int

    var body: some View {
        SectionCard(title: "Next up", systemImage: "arrow.forward.circle") {
            let current = today.current(at: minute)
            let next = today.next(after: minute)
            if current == nil && next == nil {
                Text(today.blocks.isEmpty ? "Nothing on the timeline today." : "That's everything on today's timeline.")
                    .font(Typo.secondary).foregroundStyle(Palette.textSecondary)
            }
            if let current {
                entry(label: "Now", block: current, detail: "until \(current.endText)")
            }
            if let next {
                entry(label: "Next", block: next,
                      detail: "\(next.startText) · \(Countdown.text(minutes: next.start - minute))")
            }
        }
    }

    private func entry(label: String, block: TodayBlock, detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            RoundedRectangle(cornerRadius: Radius.s)
                .fill(block.lesson.map { Palette.subject($0.colour) } ?? Palette.accent)
                .frame(width: Size.subjectBar)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(label.uppercased()).font(Typo.caption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                Text(block.title).font(Typo.body.weight(.semibold))
                let room = block.lesson?.room ?? ""
                Text(room.isEmpty ? detail : "\(detail) · \(room)")
                    .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

struct TodayTaskList: View {
    let sections: [TaskSection]
    let today: DayStamp
    let toggle: (TaskItem) -> Void
    let openTasks: () -> Void

    var body: some View {
        if sections.isEmpty {
            Text("Nothing due today.").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(sections) { section in
                    if sections.count > 1 || section.isOverdue {
                        Text(section.title)
                            .font(Typo.caption.weight(.semibold))
                            .foregroundStyle(section.isOverdue ? Palette.danger : Palette.textTertiary)
                            .padding(.top, Space.xs)
                    }
                    ForEach(section.tasks) { task in
                        TaskRow(task: task, today: today, calendar: .current, isSelected: false,
                                toggle: { toggle(task) }, select: openTasks)
                    }
                }
            }
        }
    }
}

struct TopThreeList: View {
    let items: [String]
    let noteURL: URL

    var body: some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("No Top 3 yet. Add them in today's daily note.")
                    .font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                if FileManager.default.fileExists(atPath: noteURL.path) {
                    Button("Open daily note") { NSWorkspace.shared.open(noteURL) }
                        .buttonStyle(.link)
                        .font(Typo.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text("\(index + 1)")
                            .font(Typo.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Palette.accent)
                        Text(item).font(Typo.body)
                    }
                }
            }
        }
    }
}
