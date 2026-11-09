import Foundation

/// Subject colours from the student's SEQTA preferences.
public struct SeqtaColours: Sendable, Equatable {
    public var bySubjectCode: [String: String] = [:]
    public var byTutorID: [String: String] = [:]
    public init() {}
}

/// A lesson's slot in a course page, with what the teacher put in it.
public struct SeqtaCourseLesson: Sendable, Equatable {
    public var date: String
    public var start: String
    public var end: String
    public var period: String?
    public var topic: String?
    public var homework: String?
    public var plan: String?
}

/// Pure decoding of SEQTA's raw `payload` values into Atlantis's models. Every reader is
/// tolerant: a field SEQTA drops or retypes loses that field, not the whole sync. The shapes
/// come from the BetterSEQTA+ and seqta-mcp code that already talks to these endpoints.
public enum SeqtaDecoding {
    // MARK: Login and preferences

    /// The student's id from `/seqta/student/login`. nil means nobody is signed in.
    public static func studentID(_ payload: Any) -> Int? {
        guard let object = payload as? JSONObject else { return nil }
        guard let id = object.int("id", "student"), id > 0 else { return nil }
        return id
    }

    /// `/seqta/student/load/prefs` (`request: "userPrefs", asArray: true`) → subject colours.
    public static func colours(prefs payload: Any) -> SeqtaColours {
        var colours = SeqtaColours()
        for pref in (payload as? [Any])?.objects ?? [] {
            guard let name = pref.string("name"), let value = pref.string("value"), value.hasPrefix("#") else { continue }
            if name.hasPrefix("timetable.subject.colour.") {
                colours.bySubjectCode[String(name.dropFirst("timetable.subject.colour.".count))] = value
            } else if name.hasPrefix("timetable.tutor.") {
                colours.byTutorID[String(name.dropFirst("timetable.tutor.".count))] = value
            }
        }
        return colours
    }

    // MARK: Timetable and courses

    /// `/seqta/student/load/timetable` → lessons, oldest first.
    public static func lessons(timetable payload: Any, colours: SeqtaColours = SeqtaColours()) -> [Lesson] {
        guard let items = (payload as? JSONObject)?.array("items")?.objects else { return [] }
        let lessons: [Lesson] = items.compactMap { item in
            guard let date = item.string("date").map({ String($0.prefix(10)) }), isISODate(date),
                  let from = item.string("from").map(hourMinute) else { return nil }
            let until = item.string("until").map(hourMinute) ?? from
            let type = item.string("type") ?? "class"
            let code = item.string("code") ?? ""
            let subject = type == "tutorial" ? "Tutorial" : (item.string("description") ?? (code.isEmpty ? "Class" : code))
            let colour = type == "tutorial"
                ? item.string("tutorID").flatMap { colours.byTutorID[$0] }
                : colours.bySubjectCode[code]
            let notes = HTMLText.plain(item.string("notes"))
            return Lesson(id: "\(date)T\(from)-\(code)", date: date, from: from, until: until,
                          period: item.string("period"), subject: subject, code: code,
                          room: item.string("room") ?? "", teacher: item.string("staff") ?? "",
                          colour: colour, type: type, notes: notes.isEmpty ? nil : notes,
                          programme: item.int("programmeID", "programme"), metaclass: item.int("metaID", "metaclass"))
        }
        return lessons.sorted { ($0.date, $0.from, $0.code) < ($1.date, $1.from, $1.code) }
    }

    /// `/seqta/student/load/courses` → the lesson slots with topic and homework. Slots are in
    /// `d[].l[]` and their content in `w[term.n][index]`.
    public static func courseLessons(_ payload: Any) -> [SeqtaCourseLesson] {
        guard let course = payload as? JSONObject else { return [] }
        let content = course.array("w") ?? []
        var out: [SeqtaCourseLesson] = []
        for term in course.objects("d") {
            let termContent = term.int("n").flatMap { $0 >= 0 && $0 < content.count ? content[$0] as? [Any] : nil }?.objects ?? []
            for (index, slot) in term.objects("l").enumerated() {
                guard let date = slot.string("d").map({ String($0.prefix(10)) }), isISODate(date),
                      let start = slot.string("s").map(hourMinute) else { continue }
                let lesson = index < termContent.count ? termContent[index] : [:]
                out.append(SeqtaCourseLesson(
                    date: date, start: start, end: slot.string("e").map(hourMinute) ?? start,
                    period: slot.string("p"),
                    topic: nonEmpty(HTMLText.plain(lesson.string("t"))),
                    homework: nonEmpty(HTMLText.plain(lesson.string("h"))),
                    plan: nonEmpty(HTMLText.plain(lesson.string("l")))))
            }
        }
        return out
    }

    // MARK: Subjects

    /// `/seqta/student/load/subjects` → the subjects of the active term folder(s).
    /// `teachers` maps subject code → teacher (the list has none; the timetable does).
    public static func subjects(_ payload: Any, colours: SeqtaColours = SeqtaColours(), teachers: [String: String] = [:]) -> [Subject] {
        var seen = Set<String>()
        var out: [Subject] = []
        for folder in (payload as? [Any])?.objects ?? [] {
            guard folder.bool("active") == true else { continue }
            for raw in folder.objects("subjects") {
                guard let code = raw.string("code"), let programme = raw.int("programme", "programmeID"),
                      let metaclass = raw.int("metaclass", "metaclassID"), seen.insert(code).inserted else { continue }
                out.append(Subject(code: code, name: raw.string("title", "description") ?? code,
                                   colour: colours.bySubjectCode[code], teacher: teachers[code] ?? "",
                                   programme: programme, metaclass: metaclass, classunit: raw.int("classunit")))
            }
        }
        return out
    }

    // MARK: Assessments

    /// `/seqta/student/assessment/list/upcoming` → assessments (cancelled ones dropped).
    public static func upcomingAssessments(_ payload: Any) -> [Assessment] {
        ((payload as? [Any])?.objects ?? []).compactMap { assessment($0) }
    }

    /// `/seqta/student/assessment/list/past` for one subject: `{tasks: [...], pending: [...]}`.
    public static func pastAssessments(_ payload: Any, programme: Int? = nil, metaclass: Int? = nil) -> [Assessment] {
        guard let object = payload as? JSONObject else { return [] }
        var out: [Assessment] = []
        for raw in object.objects("pending") + object.objects("tasks") {
            guard var item = assessment(raw) else { continue }
            item.programme = item.programme ?? programme
            item.metaclass = item.metaclass ?? metaclass
            out.append(item)
        }
        return out
    }

    /// `/seqta/student/assessment/get` → the task text and any released result with feedback.
    public static func assessmentDetail(_ payload: Any) -> (details: String?, marks: Mark?) {
        guard let object = payload as? JSONObject else { return (nil, nil) }
        var parts: [String] = []
        if let text = nonEmpty(HTMLText.plain(object.string("description", "contents", "details", "task", "instructions"))) {
            parts.append(text)
        }
        let criteria = object.objects("criteria").compactMap { $0.string("title", "name") }
        if !criteria.isEmpty { parts.append("Criteria: " + criteria.joined(separator: "; ")) }
        return (parts.isEmpty ? nil : parts.joined(separator: "\n\n"), mark(object))
    }

    private static func assessment(_ raw: JSONObject) -> Assessment? {
        guard let id = raw.int("id"), let title = raw.string("title"), let due = raw.string("due", "date", "dueDate").map({ String($0.prefix(10)) }),
              isISODate(due) else { return nil }
        let status = raw.string("status") ?? "PENDING"
        if status == "CANCELLED" { return nil }
        let code = raw.string("code", "subject") ?? ""
        return Assessment(id: id, title: title, subject: raw.string("subject", "code") ?? code, code: code, due: due,
                          status: status, submitted: raw.bool("submitted") ?? false, marks: mark(raw),
                          programme: raw.int("programmeID", "programme"), metaclass: raw.int("metaclassID", "metaclass"))
    }

    /// A result from an assessment object: a letter grade and percentage from `finalGrade`,
    /// `letterGrade`, `criteria[0].results` or `results` (the places BetterSEQTA+ looks), and
    /// feedback text if SEQTA sends any.
    static func mark(_ raw: JSONObject) -> Mark? {
        var merged = raw
        for (key, value) in raw.object("extra") ?? [:] where merged[key] == nil { merged[key] = value }
        let firstCriterion = merged.objects("criteria").first?.object("results")
        let results = merged.object("results")
        let grade = merged.string("letterGrade") ?? firstCriterion?.string("grade") ?? results?.string("grade")
        var percentage = merged.double("finalGrade")
        if percentage == nil, merged.string("status").map({ $0 == "MARKS_RELEASED" }) ?? true {
            percentage = firstCriterion?.double("percentage") ?? results?.double("percentage")
        }
        let feedback = nonEmpty(HTMLText.plain(merged.string("feedback", "comment", "comments")
            ?? firstCriterion?.string("comment", "feedback") ?? results?.string("comment", "feedback")))
        let mark = Mark(grade: grade, percentage: percentage, feedback: feedback)
        return mark.isEmpty ? nil : mark
    }

    // MARK: Notices and messages

    /// `/seqta/student/load/notices` for `date` → notices as plain text.
    public static func notices(_ payload: Any, date: String) -> [Notice] {
        ((payload as? [Any])?.objects ?? []).compactMap { raw in
            guard let id = raw.int("id"), let title = raw.string("title") else { return nil }
            return Notice(id: id, date: date, title: title, label: raw.string("label_title") ?? "",
                          staff: raw.string("staff") ?? "", colour: raw.string("colour"),
                          contents: HTMLText.plain(raw.string("contents")))
        }
    }

    /// `/seqta/student/load/message` with `action: "list"` → summaries, newest first as sent.
    public static func messageList(_ payload: Any, timeZone: TimeZone = .current) -> [MessageSummary] {
        guard let object = payload as? JSONObject else { return [] }
        return object.objects("messages").compactMap { messageSummary($0, timeZone: timeZone) }
    }

    /// `/seqta/student/load/message` with `action: "message"` → one whole message.
    public static func message(_ payload: Any, timeZone: TimeZone = .current) -> Message? {
        guard let object = payload as? JSONObject, let summary = messageSummary(object, timeZone: timeZone) else { return nil }
        let recipients = (object.array("participants") ?? object.array("recipients") ?? []).compactMap { entry -> String? in
            if let text = entry as? String { return text }
            let person = entry as? JSONObject
            return person?.string("name", "xx_display", "display")
        }
        let files = object.objects("files").compactMap { file -> MessageFile? in
            guard let uuid = file.string("uuid") else { return nil }
            return MessageFile(name: file.string("filename", "name") ?? uuid, uuid: uuid, mimetype: file.string("mimetype"))
        }
        return Message(summary: summary, recipients: recipients, body: HTMLText.plain(object.string("contents", "body")), files: files)
    }

    private static func messageSummary(_ raw: JSONObject, timeZone: TimeZone) -> MessageSummary? {
        guard let id = raw.int("id"), let subject = raw.string("subject") else { return nil }
        let attachments = raw.int("attachmentCount") ?? ((raw.bool("attachments") ?? false) ? 1 : 0)
        return MessageSummary(id: id, date: raw.string("date").flatMap { date($0, defaultTimeZone: timeZone) },
                              sender: raw.string("sender") ?? "", senderType: raw.string("sender_type") ?? "",
                              subject: subject, read: raw.bool("read") ?? false, attachmentCount: attachments)
    }

    // MARK: Helpers

    /// SEQTA timestamps: "2026-04-29 04:26:25.075868+00", "2026-11-09 09:30:00.0" or ISO 8601.
    /// With no zone given they're in the school's time zone.
    public static func date(_ text: String, defaultTimeZone: TimeZone = .current) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        var zone = defaultTimeZone
        if let tz = group(7) {
            if tz == "Z" {
                zone = TimeZone(secondsFromGMT: 0)!
            } else {
                let sign = tz.hasPrefix("-") ? -1 : 1
                let digits = tz.dropFirst().replacingOccurrences(of: ":", with: "")
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = digits.count > 2 ? Int(digits.dropFirst(2)) ?? 0 : 0
                zone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)) ?? zone
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: Int(group(1)!), month: Int(group(2)!), day: Int(group(3)!),
                                   hour: Int(group(4)!), minute: Int(group(5)!), second: group(6).flatMap { Int($0) } ?? 0)
        return calendar.date(from: parts)
    }

    static func isISODate(_ text: String) -> Bool {
        text.count == 10 && text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// "09:00:00" → "09:00", "9:05" → "09:05".
    static func hourMinute(_ text: String) -> String {
        guard let range = text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) else { return String(text.prefix(5)) }
        let time = String(text[range])
        return time.count == 4 ? "0" + time : time
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }
}
