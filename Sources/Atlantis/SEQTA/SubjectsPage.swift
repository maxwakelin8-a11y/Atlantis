import AtlantisCore
import QuickLook
import SwiftUI

/// A coloured dot for a subject (sidebar sub-items, page headers).
struct SubjectDot: View {
    let colour: String?
    var body: some View {
        Circle().fill(Palette.subject(colour)).frame(width: Space.s + Space.xxs, height: Space.s + Space.xxs)
    }
}

/// Subjects (PRD F7, §7d): one overview of every subject, and one page per subject with its
/// teacher, assessments, marks and feedback, and course files. All from the SEQTA cache; a file is
/// downloaded only when it's clicked.
struct SubjectsPage: View {
    let model: AppModel
    @State private var files: SeqtaFileOpener

    init(model: AppModel) {
        self.model = model
        _files = State(initialValue: SeqtaFileOpener(sync: model.seqtaSync))
    }

    private var data: SeqtaData { model.seqtaData }

    var body: some View {
        Group {
            if data.subjects.isEmpty {
                EmptyState(title: "No subjects yet", systemImage: "books.vertical",
                           message: data.hasData ? "SEQTA didn't list any subjects." : "Refresh in Settings to load your subjects, marks and files.")
            } else if let code = model.subjectCode, let detail = data.detail(code: code) {
                SubjectDetailView(detail: detail, files: files, model: model)
            } else {
                overview
            }
        }
        .quickLookPreview(Bindable(files).preview)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let subject = model.subjectCode.flatMap({ data.detail(code: $0)?.subject }) {
                    Button("Open in SEQTA", systemImage: "arrow.up.forward.app") {
                        model.openInSeqta(model.seqtaPage { SeqtaPages.course($0, programme: subject.programme, metaclass: subject.metaclass) })
                    }
                    .help("Open \(subject.name) in a SEQTA window")
                }
            }
        }
    }

    private var overview: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Size.sidePanel), spacing: Space.m)], spacing: Space.m) {
                ForEach(data.details) { detail in
                    Button {
                        model.subjectCode = detail.id
                    } label: {
                        SubjectCard(detail: detail)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Space.l)
        }
    }
}

private struct SubjectCard: View {
    let detail: SubjectDetail

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                SubjectDot(colour: detail.subject.colour)
                Text(detail.subject.name).font(Typo.sectionTitle).lineLimit(1)
                Spacer()
            }
            if !detail.subject.teacher.isEmpty {
                Text(detail.subject.teacher).font(Typo.secondary).foregroundStyle(Palette.textSecondary)
            }
            Divider()
            if let next = detail.next {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Next up").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    Text(next.title).font(Typo.secondary).lineLimit(1)
                    Text(SubjectFormat.due(next.due)).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
            } else {
                Text("Nothing due").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
            }
            HStack(spacing: Space.xs) {
                if !detail.upcoming.isEmpty { Pill(text: "\(detail.upcoming.count) upcoming") }
                if !detail.marked.isEmpty { Pill(text: "\(detail.marked.count) marked", color: Palette.success) }
                if !detail.files.isEmpty { Pill(text: detail.files.count == 1 ? "1 file" : "\(detail.files.count) files") }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.l))
        .contentShape(RoundedRectangle(cornerRadius: Radius.l))
    }
}

enum SubjectFormat {
    /// "Mon 16 Nov" for a "YYYY-MM-DD" day, or the text as it was if it isn't one.
    static func due(_ day: String) -> String {
        guard let date = parse(day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func parse(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func status(_ assessment: Assessment) -> (text: String, colour: Color)? {
        switch assessment.status.uppercased() {
        case "OVERDUE": ("Overdue", Palette.danger)
        case "MARKS_RELEASED": ("Marked", Palette.success)
        case "PENDING": assessment.submitted ? ("Submitted", Palette.success) : nil
        default: assessment.submitted ? ("Submitted", Palette.success) : nil
        }
    }
}

// MARK: One subject

private struct SubjectDetailView: View {
    let detail: SubjectDetail
    let files: SeqtaFileOpener
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header
                SectionCard(title: "Upcoming", systemImage: "calendar") {
                    if detail.upcoming.isEmpty {
                        Text("Nothing due.").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(detail.upcoming) { assessment in
                        AssessmentRow(assessment: assessment, open: { open(assessment) })
                    }
                }
                SectionCard(title: "Marks and feedback", systemImage: "checkmark.seal") {
                    if detail.past.isEmpty {
                        Text("No past assessments yet.").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(detail.past) { assessment in
                        AssessmentRow(assessment: assessment, open: { open(assessment) })
                    }
                }
                SectionCard(title: "Files", systemImage: "doc") {
                    if detail.files.isEmpty {
                        Text("No files on this course.").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(detail.files) { file in
                        FileRow(file: file, busy: files.busy.contains(file.uuid)) {
                            files.open(uuid: file.uuid, name: file.name, source: .resource)
                        }
                    }
                    if let error = files.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Typo.secondary).foregroundStyle(Palette.danger)
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: Size.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            SubjectDot(colour: detail.subject.colour)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(detail.subject.name).font(Typo.pageTitle)
                HStack(spacing: Space.s) {
                    Text(detail.subject.code).font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                    if !detail.subject.teacher.isEmpty {
                        Label(detail.subject.teacher, systemImage: "person").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            Spacer()
            Button("All subjects", systemImage: "square.grid.2x2") { model.subjectCode = nil }
                .buttonStyle(.borderless)
        }
    }

    private func open(_ assessment: Assessment) {
        let programme = assessment.programme ?? detail.subject.programme
        let metaclass = assessment.metaclass ?? detail.subject.metaclass
        model.openInSeqta(model.seqtaPage { SeqtaPages.assessment($0, programme: programme, metaclass: metaclass, id: assessment.id) })
    }
}

private struct AssessmentRow: View {
    let assessment: Assessment
    let open: () -> Void
    @State private var expanded = false

    private var mark: String? { assessment.marks.flatMap(SubjectOverview.markText) }
    private var feedback: String? {
        assessment.marks?.feedback.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(assessment.title).font(Typo.body)
                    Text("Due \(SubjectFormat.due(assessment.due))").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: Space.s)
                if let status = SubjectFormat.status(assessment), mark == nil {
                    Pill(text: status.text, color: status.colour)
                }
                if let mark {
                    Text(mark).font(Typo.number.weight(.semibold)).foregroundStyle(Palette.success)
                }
                if feedback != nil || assessment.details != nil {
                    Button { withAnimation(Motion.quick) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? "Hide details" : "Show details")
                }
                Button(action: open) { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
                    .help("Open in SEQTA")
                    .accessibilityLabel("Open in SEQTA")
            }
            if expanded {
                VStack(alignment: .leading, spacing: Space.s) {
                    if let feedback {
                        Text("Feedback").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        Text(verbatim: feedback).font(Typo.secondary).textSelection(.enabled)
                    }
                    if let details = assessment.details, !details.isEmpty {
                        Text("Task").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        Text(verbatim: details).font(Typo.secondary).textSelection(.enabled)
                    }
                }
                .padding(Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: Radius.m))
            }
        }
        .padding(.vertical, Space.xxs)
    }
}

private struct FileRow: View {
    let file: SubjectFile
    let busy: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.s) {
                Image(systemName: "doc").foregroundStyle(Palette.textSecondary)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(file.name).font(Typo.body).lineLimit(1)
                    Text([file.source, fileSizeText(file.size)].compactMap { $0 }.joined(separator: " · "))
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) } else {
                    Image(systemName: "eye").foregroundStyle(Palette.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Download and preview")
    }
}
