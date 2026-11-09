import Foundation

// The shapes Atlantis keeps from SEQTA (PRD §7d). These are *our* models, decoded from SEQTA's
// loosely-typed responses by `SeqtaDecoding`, and saved as JSON by `SeqtaCache`. Pages and the
// MCP read tools (PRD §8) read them from the cache and never talk to SEQTA themselves.
//
// Dates are plain "YYYY-MM-DD" strings and times "HH:mm" in the school's local time, exactly as
// SEQTA reports them (a lesson is "09:00 on 2026-11-09", not an instant). Only things that are
// real instants (messages, sync times) are `Date`.

/// One timetable lesson.
public struct Lesson: Codable, Sendable, Equatable, Identifiable {
    /// `date` + start time + code. Stable between syncs.
    public var id: String
    public var date: String
    public var from: String
    public var until: String
    public var period: String?
    public var subject: String
    public var code: String
    public var room: String
    public var teacher: String
    /// `#rrggbb` from the student's SEQTA colour preferences, or nil.
    public var colour: String?
    /// "class", "tutorial", …
    public var type: String
    /// Lesson topic and homework come from the subject's course page, so they're nil when SEQTA
    /// has nothing set (or that course couldn't be loaded).
    public var topic: String?
    public var homework: String?
    public var notes: String?
    /// Needed to match the lesson to its course and assessments.
    public var programme: Int?
    public var metaclass: Int?

    public init(id: String, date: String, from: String, until: String, period: String? = nil,
                subject: String, code: String, room: String = "", teacher: String = "",
                colour: String? = nil, type: String = "class", topic: String? = nil,
                homework: String? = nil, notes: String? = nil, programme: Int? = nil, metaclass: Int? = nil) {
        self.id = id; self.date = date; self.from = from; self.until = until; self.period = period
        self.subject = subject; self.code = code; self.room = room; self.teacher = teacher
        self.colour = colour; self.type = type; self.topic = topic; self.homework = homework
        self.notes = notes; self.programme = programme; self.metaclass = metaclass
    }
}

/// A result for one assessment: a letter grade and/or a percentage, plus teacher feedback.
public struct Mark: Codable, Sendable, Equatable {
    public var grade: String?
    public var percentage: Double?
    public var feedback: String?

    public init(grade: String? = nil, percentage: Double? = nil, feedback: String? = nil) {
        self.grade = grade; self.percentage = percentage; self.feedback = feedback
    }

    public var isEmpty: Bool { grade == nil && percentage == nil && feedback == nil }
}

public struct Assessment: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var subject: String
    public var code: String
    /// "YYYY-MM-DD"
    public var due: String
    /// SEQTA's status: "PENDING", "OVERDUE", "MARKS_RELEASED", …
    public var status: String
    public var submitted: Bool
    /// Filled once marks are released.
    public var marks: Mark?
    /// Task description and criteria, as plain text (from the assessment's own page).
    public var details: String?
    public var programme: Int?
    public var metaclass: Int?

    public init(id: Int, title: String, subject: String, code: String, due: String, status: String,
                submitted: Bool = false, marks: Mark? = nil, details: String? = nil,
                programme: Int? = nil, metaclass: Int? = nil) {
        self.id = id; self.title = title; self.subject = subject; self.code = code; self.due = due
        self.status = status; self.submitted = submitted; self.marks = marks; self.details = details
        self.programme = programme; self.metaclass = metaclass
    }

    /// Whether the assessment is already past its due date today (compares "YYYY-MM-DD" strings).
    public func isPast(today: String) -> Bool { due < today }
}

public struct Notice: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    /// The day the notice was fetched for ("YYYY-MM-DD").
    public var date: String
    public var title: String
    public var label: String
    public var staff: String
    public var colour: String?
    /// Plain text.
    public var contents: String

    public init(id: Int, date: String, title: String, label: String = "", staff: String = "",
                colour: String? = nil, contents: String = "") {
        self.id = id; self.date = date; self.title = title; self.label = label; self.staff = staff
        self.colour = colour; self.contents = contents
    }
}

public struct Subject: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }
    public var code: String
    public var name: String
    public var colour: String?
    /// From the timetable (the subjects list itself has no teacher), so it can be empty.
    public var teacher: String
    public var programme: Int
    public var metaclass: Int
    public var classunit: Int?

    public init(code: String, name: String, colour: String? = nil, teacher: String = "",
                programme: Int, metaclass: Int, classunit: Int? = nil) {
        self.code = code; self.name = name; self.colour = colour; self.teacher = teacher
        self.programme = programme; self.metaclass = metaclass; self.classunit = classunit
    }
}

public struct MessageSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var date: Date?
    public var sender: String
    public var senderType: String
    public var subject: String
    public var read: Bool
    public var attachmentCount: Int

    public init(id: Int, date: Date? = nil, sender: String, senderType: String = "", subject: String,
                read: Bool = false, attachmentCount: Int = 0) {
        self.id = id; self.date = date; self.sender = sender; self.senderType = senderType
        self.subject = subject; self.read = read; self.attachmentCount = attachmentCount
    }
}

public struct MessageFile: Codable, Sendable, Equatable {
    public var name: String
    public var uuid: String
    public var mimetype: String?

    public init(name: String, uuid: String, mimetype: String? = nil) {
        self.name = name; self.uuid = uuid; self.mimetype = mimetype
    }
}

/// A whole message. The sync only saves the list (`MessageSummary`); full messages are read on
/// demand by the Messages page (M4b), which uses `SeqtaDecoding.message(_:)`.
public struct Message: Codable, Sendable, Equatable, Identifiable {
    public var summary: MessageSummary
    public var id: Int { summary.id }
    public var recipients: [String]
    /// Plain text.
    public var body: String
    public var files: [MessageFile]

    public init(summary: MessageSummary, recipients: [String] = [], body: String = "", files: [MessageFile] = []) {
        self.summary = summary; self.recipients = recipients; self.body = body; self.files = files
    }
}
