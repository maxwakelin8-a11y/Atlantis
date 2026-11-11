import Foundation

/// Everything the Subjects page shows for one subject, grouped from the flat cache lists.
public struct SubjectDetail: Sendable, Equatable, Identifiable {
    public var subject: Subject
    public var id: String { subject.code }
    /// Due today or later, soonest first.
    public var upcoming: [Assessment]
    /// Due before today, newest first. Marks and feedback show here once released.
    public var past: [Assessment]
    /// Course outline files first, then lesson resources.
    public var files: [SubjectFile]

    /// The next assessment, for the overview card.
    public var next: Assessment? { upcoming.first }
    /// Past assessments with a result.
    public var marked: [Assessment] { past.filter { $0.marks?.isEmpty == false } }
}

public enum SubjectOverview {
    /// One detail per subject, in the subjects list's order. Assessments and files are matched
    /// by subject code; ones for subjects that aren't in the list (an old term) are left out.
    public static func details(subjects: [Subject], assessments: [Assessment], files: [SubjectFile], today: String) -> [SubjectDetail] {
        let byCode = Dictionary(grouping: assessments, by: \.code)
        let filesByCode = Dictionary(grouping: files, by: \.subjectCode)
        return subjects.map { subject in
            let mine = byCode[subject.code] ?? []
            return SubjectDetail(
                subject: subject,
                upcoming: mine.filter { !$0.isPast(today: today) }.sorted { ($0.due, $0.id) < ($1.due, $1.id) },
                past: mine.filter { $0.isPast(today: today) }.sorted { ($0.due, $0.id) > ($1.due, $1.id) },
                files: filesByCode[subject.code] ?? [])
        }
    }

    /// How a mark reads in one line: "B · 74%", "88%", "A".
    public static func markText(_ mark: Mark) -> String? {
        let percent = mark.percentage.map { value -> String in
            value == value.rounded() ? "\(Int(value))%" : String(format: "%.1f%%", value)
        }
        let parts = [mark.grade, percent].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Pages to open in SEQTA itself ("Open in SEQTA" pop-ups). SEQTA Learn routes by hash.
public enum SeqtaPages {
    public static func home(_ base: URL, hash: String) -> URL? {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/"
        parts?.query = nil
        parts?.fragment = hash
        return parts?.url
    }

    public static func course(_ base: URL, programme: Int, metaclass: Int) -> URL? {
        home(base, hash: "?page=/courses/\(programme):\(metaclass)")
    }

    public static func assessment(_ base: URL, programme: Int, metaclass: Int, id: Int) -> URL? {
        home(base, hash: "?page=/assessments/\(programme):\(metaclass)&item=\(id)")
    }

    public static func messages(_ base: URL) -> URL? { home(base, hash: "?page=/messages") }
}
