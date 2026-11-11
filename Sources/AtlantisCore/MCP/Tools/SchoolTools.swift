import Foundation

/// `atlantis_seqta_refresh` and the `atlantis_school_*` read tools (PRD §8, §7d).
///
/// The read tools only read the SEQTA cache. They never reach SEQTA: only the sync does, and only
/// when the user (or the once-a-morning rule) starts one.
enum SchoolTools {
    static func register(in registry: ToolRegistry, context: MCPToolContext) {
        registerRefresh(registry, context)
        registerTimetable(registry, context)
        registerAssessments(registry, context)
        registerSubjects(registry, context)
        registerNotices(registry, context)
        registerMessages(registry, context)
    }

    private static let notSynced = "No SEQTA data is saved yet. The user needs to sign in to SEQTA in Atlantis and refresh; you can then call atlantis_seqta_refresh."

    private static func stamp(_ date: Date?) -> JSONValue? {
        date.map { .string(ISO8601DateFormatter().string(from: $0)) }
    }

    // MARK: Refresh

    private static func registerRefresh(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_seqta_refresh",
            description: "Ask Atlantis to sync SEQTA now (timetable, assessments, notices, subjects, messages list), then read the result with the atlantis_school_* tools. Syncs at most once every 5 minutes, so don't call it in a loop; if the data is fresh the reply says so and nothing is fetched.",
            inputSchema: schema(),
            kind: .action
        )) { _ in
            let last = context.cache.meta().lastSync
            if let last, context.now().timeIntervalSince(last) < context.minRefreshInterval {
                let minutes = Int(context.now().timeIntervalSince(last) / 60)
                return .json(.make(["refreshed": .bool(false), "synced_at": stamp(last),
                                    "message": .string("SEQTA was synced \(minutes) min ago, so it wasn't synced again. The saved data is current.")]))
            }
            let outcome = await context.refreshSeqta()
            return .json(.make(["refreshed": .bool(outcome.ok), "synced_at": stamp(context.cache.meta().lastSync),
                                "message": .string(outcome.message)]))
        }
    }

    // MARK: Timetable

    private static func registerTimetable(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_school_timetable",
            description: "The user's lessons for a date range from the saved SEQTA data, with each lesson's topic, notes and homework when SEQTA has them. Default: today to 6 days ahead. Max 31 days.",
            inputSchema: schema([
                "from": prop("First day, YYYY-MM-DD. Default: today."),
                "to": prop("Last day, YYYY-MM-DD. Default: 6 days after from."),
                "subject": prop("Only lessons whose subject name or code contains this text."),
            ]),
            kind: .read
        )) { args in
            guard let cached = context.cache.lessons() else { return ToolResult(text: notSynced) }
            let from = try args.optionalDay("from") ?? context.today
            let to = try args.optionalDay("to") ?? from.adding(days: 6, calendar: context.calendar)
            guard from <= to else { throw ToolFailure("\"from\" must be on or before \"to\".") }
            guard from.days(until: to, calendar: context.calendar) <= 30 else { throw ToolFailure("The range is limited to 31 days.") }
            let subject = try args.optionalString("subject", maxLength: 100)?.lowercased()
            let lessons = cached.items.filter { lesson in
                lesson.date >= from.description && lesson.date <= to.description
                    && (subject.map { lesson.subject.lowercased().contains($0) || lesson.code.lowercased().contains($0) } ?? true)
            }.sorted { ($0.date, $0.from) < ($1.date, $1.from) }
            let shown = lessons.prefix(200)
            return .json(.make([
                "notice": .string(schoolDataNotice), "synced_at": stamp(cached.syncedAt),
                "from": .string(from.description), "to": .string(to.description),
                "count": .int(lessons.count), "truncated": .bool(lessons.count > 200),
                "lessons": .array(shown.map { lesson in
                    .make(["date": .string(lesson.date), "from": .string(lesson.from), "until": .string(lesson.until),
                           "subject": .string(lesson.subject), "code": .string(lesson.code),
                           "room": .str(lesson.room.isEmpty ? nil : lesson.room),
                           "teacher": .str(lesson.teacher.isEmpty ? nil : lesson.teacher),
                           "type": .str(lesson.type == "class" ? nil : lesson.type),
                           "topic": .str(Clip.optional(lesson.topic, 300)),
                           "homework": .str(Clip.optional(lesson.homework, 1_000)),
                           "notes": .str(Clip.optional(lesson.notes, 1_000))])
                }),
            ]))
        }
    }

    // MARK: Assessments

    private static func registerAssessments(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_school_assessments",
            description: "The user's assessments from the saved SEQTA data: upcoming (default), past, or all, with status, whether it was submitted, and marks and feedback once released. Pass an id for one assessment's full task description.",
            inputSchema: schema([
                "when": prop("upcoming (default), past or all. Judged by the due date against today."),
                "subject": prop("Only assessments whose subject name or code contains this text."),
                "id": prop("One assessment's id: returns its full details.", "integer"),
                "limit": prop("Most assessments to return (1-100, default 30).", "integer"),
            ]),
            kind: .read
        )) { args in
            guard let cached = context.cache.assessments() else { return ToolResult(text: notSynced) }
            let todayKey = context.today.description
            func detail(_ a: Assessment, full: Bool) -> JSONValue {
                .make(["id": .int(a.id), "title": .string(a.title), "subject": .string(a.subject), "code": .string(a.code),
                       "due": .string(a.due), "status": .string(a.status), "submitted": .bool(a.submitted),
                       "grade": .str(a.marks?.grade), "percentage": a.marks?.percentage.map(JSONValue.double),
                       "feedback": .str(Clip.optional(a.marks?.feedback, full ? 5_000 : 400)),
                       "details": .str(Clip.optional(a.details, full ? 20_000 : 600))])
            }
            if let id = try args.optionalInt("id", in: 0...Int.max) {
                guard let found = cached.items.first(where: { $0.id == id }) else { throw ToolFailure("No saved assessment with id \(id).") }
                return .json(.make(["notice": .string(schoolDataNotice), "synced_at": stamp(cached.syncedAt), "assessment": detail(found, full: true)]))
            }
            let when = try args.optionalChoice("when", ["upcoming", "past", "all"]) ?? "upcoming"
            let subject = try args.optionalString("subject", maxLength: 100)?.lowercased()
            let limit = try args.optionalInt("limit", in: 1...100) ?? 30
            var items = cached.items.filter { a in
                switch when {
                case "upcoming": a.due >= todayKey
                case "past": a.due < todayKey
                default: true
                }
            }
            if let subject { items = items.filter { $0.subject.lowercased().contains(subject) || $0.code.lowercased().contains(subject) } }
            // Soonest first for upcoming; most recent first otherwise.
            items.sort { when == "upcoming" ? ($0.due, $0.id) < ($1.due, $1.id) : ($0.due, $0.id) > ($1.due, $1.id) }
            return .json(.make([
                "notice": .string(schoolDataNotice), "synced_at": stamp(cached.syncedAt),
                "count": .int(items.count), "truncated": .bool(items.count > limit),
                "assessments": .array(items.prefix(limit).map { detail($0, full: false) }),
            ]))
        }
    }

    // MARK: Subjects

    private static func registerSubjects(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_school_subjects",
            description: "The user's subjects from the saved SEQTA data: name, code, teacher, and for each subject the released marks and feedback and how many assessments are still to come. Also the names of each subject's saved course files (the files themselves aren't available here).",
            inputSchema: schema(["subject": prop("Only subjects whose name or code contains this text.")]),
            kind: .read
        )) { args in
            guard let cached = context.cache.subjects() else { return ToolResult(text: notSynced) }
            let filter = try args.optionalString("subject", maxLength: 100)?.lowercased()
            let assessments = context.cache.assessments()?.items ?? []
            let files = context.cache.files()?.items ?? []
            let todayKey = context.today.description
            let subjects = cached.items.filter { subject in
                filter.map { subject.name.lowercased().contains($0) || subject.code.lowercased().contains($0) } ?? true
            }
            return .json(.make([
                "notice": .string(schoolDataNotice), "synced_at": stamp(cached.syncedAt),
                "count": .int(subjects.count),
                "subjects": .array(subjects.map { subject in
                    let mine = assessments.filter { $0.code == subject.code }
                    let courseFiles = files.filter { $0.subjectCode == subject.code }
                    let marked = mine.filter { !($0.marks?.isEmpty ?? true) }.sorted { $0.due > $1.due }
                    return .make([
                        "code": .string(subject.code), "name": .string(subject.name),
                        "teacher": .str(subject.teacher.isEmpty ? nil : subject.teacher),
                        "upcoming_assessments": .int(mine.filter { $0.due >= todayKey && ($0.marks?.isEmpty ?? true) }.count),
                        "files": .array(courseFiles.prefix(40).map { f in
                            .make(["name": .string(Clip.text(f.name, 200)), "from": .string(Clip.text(f.source, 120))])
                        }),
                        "marks": .array(marked.prefix(20).map { a in
                            .make(["assessment": .string(a.title), "due": .string(a.due), "grade": .str(a.marks?.grade),
                                   "percentage": a.marks?.percentage.map(JSONValue.double),
                                   "feedback": .str(Clip.optional(a.marks?.feedback, 400))])
                        }),
                    ])
                }),
            ]))
        }
    }

    // MARK: Notices

    private static func registerNotices(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_school_notices",
            description: "School notices for a day from the saved SEQTA data. Default: today. Only days the last sync fetched are available.",
            inputSchema: schema(["date": prop("The day, YYYY-MM-DD. Default: today.")]),
            kind: .read
        )) { args in
            guard let cached = context.cache.notices() else { return ToolResult(text: notSynced) }
            let date = try args.optionalDay("date") ?? context.today
            let notices = cached.items.filter { $0.date == date.description }
            let have = Set(cached.items.map(\.date)).sorted()
            return .json(.make([
                "notice": .string(schoolDataNotice), "synced_at": stamp(cached.syncedAt),
                "date": .string(date.description), "count": .int(notices.count),
                "days_saved": .array(have.suffix(7).map(JSONValue.string)),
                "notices": .array(notices.prefix(50).map { n in
                    .make(["id": .int(n.id), "title": .string(n.title), "label": .str(n.label.isEmpty ? nil : n.label),
                           "from": .str(n.staff.isEmpty ? nil : n.staff), "text": .str(Clip.optional(n.contents, 1_500))])
                }),
            ]))
        }
    }

    // MARK: Messages

    private static func registerMessages(_ registry: ToolRegistry, _ context: MCPToolContext) {
        registry.register(ToolDefinition(
            name: "atlantis_school_messages",
            description: "The user's SEQTA message list from the saved data (newest first): sender, subject, date, whether it's been read. Pass an id to get the full text of a message the user has already opened in Atlantis (others only have the list entry; this tool never fetches from SEQTA). To reply, use atlantis_message_draft (it never sends).",
            inputSchema: schema([
                "unread_only": prop("Only unread messages.", "boolean"),
                "from": prop("Only messages whose sender contains this text."),
                "id": prop("One message's id.", "integer"),
                "limit": prop("Most messages to return (1-100, default 20).", "integer"),
            ]),
            kind: .read
        )) { args in
            guard let cached = context.cache.messages() else { return ToolResult(text: notSynced) }
            let id = try args.optionalInt("id", in: 0...Int.max)
            let unreadOnly = try args.optionalBool("unread_only") ?? false
            let sender = try args.optionalString("from", maxLength: 100)?.lowercased()
            let limit = try args.optionalInt("limit", in: 1...100) ?? 20
            var items = cached.items
            if let id { items = items.filter { $0.id == id } }
            if unreadOnly { items = items.filter { !$0.read } }
            if let sender { items = items.filter { $0.sender.lowercased().contains(sender) } }
            items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return .json(.make([
                "notice": .string(schoolDataNotice), "synced_at": stamp(cached.syncedAt),
                "count": .int(items.count), "truncated": .bool(items.count > limit),
                "messages": .array(items.prefix(limit).map { m in
                    // Full text only for one message, and only if the user already opened it in Atlantis.
                    let full = id == m.id ? context.cache.message(id: m.id) : nil
                    return .make(["id": .int(m.id), "date": stamp(m.date), "from": .string(m.sender), "subject": .string(Clip.text(m.subject, 300)),
                           "read": .bool(m.read), "attachments": m.attachmentCount > 0 ? .int(m.attachmentCount) : nil,
                           "to": full.map { .array($0.recipients.prefix(30).map(JSONValue.string)) },
                           "text": .str(full.map { Clip.text($0.body, 8_000) })])
                }),
            ]))
        }
    }
}
