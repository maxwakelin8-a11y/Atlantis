import Foundation

/// How far a sync reaches (PRD F3).
public struct SeqtaSyncRange: Sendable, Equatable {
    /// Lessons from today to this many days ahead.
    public var lessonDays = 7
    /// Assessments due from today to this many days ahead.
    public var upcomingDays = 14
    /// Past assessments (marks) due this many days back are kept.
    public var pastDays = 30
    /// Newest messages kept in the list.
    public var messageLimit = 25

    public init() {}
}

/// What a sync did: counts per kind (never contents) and what failed.
public struct SeqtaSyncReport: Sendable, Equatable {
    public var counts: [String: Int] = [:]
    public var failures: [String: String] = [:]
    public var newMarkAssessmentIDs: [Int] = []
    public var requestCount = 0

    /// "lessons 12, assessments 5, …" for logs.
    public var summary: String {
        let parts = SeqtaCache.Kind.allCases.compactMap { kind in counts[kind.rawValue].map { "\(kind.rawValue) \($0)" } }
        let failed = failures.isEmpty ? "" : "; failed: " + failures.keys.sorted().joined(separator: ", ")
        return parts.joined(separator: ", ") + failed
    }
}

/// The once-a-day rule (AGENTS.md: at most one automatic sync per morning, no polling).
public enum SeqtaMorningGate {
    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Whether a morning sync may run now: not if an automatic one already reached SEQTA today,
    /// and not if the user already refreshed today (the data is fresh).
    public static func shouldRun(meta: SeqtaMeta, now: Date, calendar: Calendar = .current) -> Bool {
        let today = dayString(now, calendar: calendar)
        if meta.lastAutoSyncDay == today { return false }
        if let last = meta.lastSync, dayString(last, calendar: calendar) == today { return false }
        return true
    }
}

/// One sync: asks SEQTA for the school week through a `SeqtaTransport`, decodes, merges with
/// what's cached and writes the cache. Read-only: every request passes `SeqtaRequest.isAllowed`.
public struct SeqtaSyncRunner: Sendable {
    public let transport: any SeqtaTransport
    public let cache: SeqtaCache
    public var range = SeqtaSyncRange()
    public var calendar: Calendar

    public init(transport: any SeqtaTransport, cache: SeqtaCache = SeqtaCache(), calendar: Calendar = .current) {
        self.transport = transport
        self.cache = cache
        self.calendar = calendar
    }

    @discardableResult
    public func run(reason: SeqtaSyncReason, now: Date = Date()) async throws -> SeqtaSyncReport {
        do {
            let report = try await sync(reason: reason, now: now)
            await transport.close()
            return report
        } catch {
            await transport.close()
            // An automatic sync that got as far as SEQTA uses up the day, even if it found
            // nothing (not signed in, bad answer). One that couldn't connect at all (offline
            // right after wake) doesn't, so the next launch or wake may try again.
            if reason == .morning, !isNetworkFailure(error) {
                let today = SeqtaMorningGate.dayString(now, calendar: calendar)
                try? cache.updateMeta { $0.lastAutoSyncDay = today }
            }
            throw error
        }
    }

    private func isNetworkFailure(_ error: Error) -> Bool {
        if case .network = error as? SeqtaSyncError { return true }
        return false
    }

    // MARK: -

    private func sync(reason: SeqtaSyncReason, now: Date) async throws -> SeqtaSyncReport {
        var report = SeqtaSyncReport()
        let today = SeqtaMorningGate.dayString(now, calendar: calendar)
        let lastDay = SeqtaMorningGate.dayString(addDays(now, range.lessonDays), calendar: calendar)
        func send(_ requests: [SeqtaRequest]) async throws -> [SeqtaResponse] {
            for request in requests where !request.isAllowed { throw SeqtaSyncError.blockedRequest(request.path) }
            report.requestCount += requests.count
            let responses = try await transport.send(requests)
            guard responses.count == requests.count else { throw SeqtaSyncError.badResponse("missing answers") }
            return responses
        }

        try await transport.open()

        // 1. Who is signed in. No user means no session.
        let loginRequest = SeqtaRequest(path: "/seqta/student/login",
                                        body: ["mode": "normal", "query": NSNull(), "redirect_url": ""])
        let login = try await send([loginRequest])[0]
        guard let studentID = SeqtaDecoding.studentID(try SeqtaEnvelope.payload(login)) else { throw SeqtaSyncError.notSignedIn }

        // 2. The independent lists, in one go.
        let first = try await send([
            SeqtaRequest(path: "/seqta/student/load/subjects?"),
            SeqtaRequest(path: "/seqta/student/load/prefs?", body: ["request": "userPrefs", "asArray": true, "user": studentID]),
            SeqtaRequest(path: "/seqta/student/load/timetable?", body: ["from": today, "until": lastDay, "student": studentID]),
            SeqtaRequest(path: "/seqta/student/load/notices?", body: ["date": today]),
            SeqtaRequest(path: "/seqta/student/assessment/list/upcoming?", body: ["student": studentID]),
            SeqtaRequest(path: "/seqta/student/load/message", body: [
                "action": "list", "label": "inbox", "searchValue": "", "sortBy": "date", "sortOrder": "desc",
                "offset": 0, "limit": range.messageLimit,
            ]),
        ])
        let payloads = first.map { response in Result { try SeqtaEnvelope.payload(response) } }
        // A session that ends mid-sync (401 on later requests) is "not signed in", not a failure.
        for case .failure(let error) in payloads where (error as? SeqtaSyncError) == .notSignedIn { throw error }
        func value(_ index: Int, _ kind: String) -> Any? {
            switch payloads[index] {
            case .success(let payload): return payload
            case .failure(let error):
                report.failures[kind] = (error as? SeqtaSyncError)?.message ?? error.localizedDescription
                return nil
            }
        }
        let prefs = value(1, "prefs")
        let colours = prefs.map { SeqtaDecoding.colours(prefs: $0) } ?? SeqtaColours()
        let timetable = value(2, "lessons")
        let subjectsPayload = value(0, "subjects")
        let noticesPayload = value(3, "notices")
        let upcomingPayload = value(4, "assessments")
        let messagesPayload = value(5, "messages")

        var lessons = timetable.map { SeqtaDecoding.lessons(timetable: $0, colours: colours) }
        var teachers: [String: String] = [:]
        for lesson in lessons ?? [] where !lesson.teacher.isEmpty && teachers[lesson.code] == nil { teachers[lesson.code] = lesson.teacher }
        let previousSubjects = cache.subjects()?.items ?? []
        for subject in previousSubjects where !subject.teacher.isEmpty && teachers[subject.code] == nil { teachers[subject.code] = subject.teacher }
        let subjects = subjectsPayload.map { SeqtaDecoding.subjects($0, colours: colours, teachers: teachers) }

        // 3. Per-subject calls: the course page of every lesson's class and every subject (lesson
        // content and the file list), past assessments for each active subject.
        var courseRequests: [SeqtaRequest] = []
        var courseKeys: [String] = []
        func addCourse(programme: Int?, metaclass: Int?) {
            guard let programme, let metaclass, programme > 0, metaclass > 0,
                  !courseKeys.contains("\(programme):\(metaclass)") else { return }
            courseKeys.append("\(programme):\(metaclass)")
            courseRequests.append(SeqtaRequest(path: "/seqta/student/load/courses",
                                               body: ["programme": String(programme), "metaclass": String(metaclass)]))
        }
        for lesson in lessons ?? [] { addCourse(programme: lesson.programme, metaclass: lesson.metaclass) }
        for subject in subjects ?? [] { addCourse(programme: subject.programme, metaclass: subject.metaclass) }
        let pastSubjects = subjects ?? []
        let pastRequests = pastSubjects.map {
            SeqtaRequest(path: "/seqta/student/assessment/list/past?",
                         body: ["programme": $0.programme, "metaclass": $0.metaclass, "student": studentID])
        }
        let second = try await send(courseRequests + pastRequests)
        for response in second where (try? SeqtaEnvelope.payload(response)) == nil {
            if response.status == 401 || response.status == 403 { throw SeqtaSyncError.notSignedIn }
        }

        var content: [String: SeqtaCourseLesson] = [:] // "programme:metaclass|date|from"
        var courseFiles: [SubjectFile] = []
        var failedCourses = 0
        let codeByCourse = Dictionary((subjects ?? []).map { ("\($0.programme):\($0.metaclass)", $0.code) }, uniquingKeysWith: { first, _ in first })
        for (index, key) in courseKeys.enumerated() {
            guard let payload = try? SeqtaEnvelope.payload(second[index]) else { failedCourses += 1; continue }
            for slot in SeqtaDecoding.courseLessons(payload) { content["\(key)|\(slot.date)|\(slot.start)"] = slot }
            if let code = codeByCourse[key] { courseFiles += SeqtaDecoding.courseFiles(payload, subjectCode: code) }
        }
        if lessons != nil {
            lessons = lessons?.map { lesson in
                var lesson = lesson
                guard let programme = lesson.programme, let metaclass = lesson.metaclass,
                      let slot = content["\(programme):\(metaclass)|\(lesson.date)|\(lesson.from)"] else { return lesson }
                lesson.topic = slot.topic
                lesson.homework = slot.homework
                return lesson
            }
        }
        if failedCourses > 0 { report.failures["lessonContent"] = "\(failedCourses) of \(courseKeys.count) courses didn't load" }
        // The file list is replaced only when every course loaded, so a bad day never empties it.
        let files: [SubjectFile]? = subjects != nil && failedCourses == 0 ? courseFiles : nil

        // 4. Assessments: upcoming + recent past, merged, then details where they changed.
        var assessments: [Assessment]?
        if let upcomingPayload {
            var byID: [Int: Assessment] = [:]
            var pastFailures = 0
            for (offset, subject) in pastSubjects.enumerated() {
                guard let payload = try? SeqtaEnvelope.payload(second[courseRequests.count + offset]) else { pastFailures += 1; continue }
                for item in SeqtaDecoding.pastAssessments(payload, programme: subject.programme, metaclass: subject.metaclass) {
                    byID[item.id] = item
                }
            }
            for item in SeqtaDecoding.upcomingAssessments(upcomingPayload) {
                var merged = item
                if merged.marks == nil { merged.marks = byID[item.id]?.marks }
                merged.programme = merged.programme ?? byID[item.id]?.programme
                merged.metaclass = merged.metaclass ?? byID[item.id]?.metaclass
                byID[item.id] = merged
            }
            if pastFailures > 0 { report.failures["pastAssessments"] = "\(pastFailures) of \(pastSubjects.count) subjects didn't load" }
            let earliest = SeqtaMorningGate.dayString(addDays(now, -range.pastDays), calendar: calendar)
            let latest = SeqtaMorningGate.dayString(addDays(now, range.upcomingDays), calendar: calendar)
            assessments = byID.values.filter { $0.due >= earliest && $0.due <= latest }
                .sorted { ($0.due, $0.id) < ($1.due, $1.id) }
        }

        let previousAssessments = cache.assessments()?.items
        if var current = assessments {
            let before = Dictionary((previousAssessments ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Details (task text, feedback) are fetched for upcoming work and released marks,
            // and reused from the cache until the status changes.
            var needed: [Int] = []
            for index in current.indices {
                let item = current[index]
                if let old = before[item.id], old.status == item.status, old.details != nil || old.marks?.feedback != nil {
                    current[index].details = old.details
                    if var marks = item.marks {
                        marks.feedback = marks.feedback ?? old.marks?.feedback
                        current[index].marks = marks
                    }
                    continue
                }
                guard item.metaclass != nil, item.due >= today || item.marks != nil else { continue }
                needed.append(index)
            }
            if !needed.isEmpty {
                let detailResponses = try await send(needed.map { index in
                    SeqtaRequest(path: "/seqta/student/assessment/get?",
                                 body: ["assessment": current[index].id, "metaclass": current[index].metaclass ?? 0, "student": studentID])
                })
                var failed = 0
                for (position, index) in needed.enumerated() {
                    guard let payload = try? SeqtaEnvelope.payload(detailResponses[position]) else {
                        if detailResponses[position].status == 401 || detailResponses[position].status == 403 { throw SeqtaSyncError.notSignedIn }
                        failed += 1
                        continue
                    }
                    let detail = SeqtaDecoding.assessmentDetail(payload)
                    current[index].details = detail.details
                    if let mark = detail.marks {
                        current[index].marks = Mark(grade: current[index].marks?.grade ?? mark.grade,
                                                    percentage: current[index].marks?.percentage ?? mark.percentage,
                                                    feedback: mark.feedback ?? current[index].marks?.feedback)
                    }
                }
                if failed > 0 { report.failures["assessmentDetails"] = "\(failed) of \(needed.count) didn't load" }
            }
            assessments = current
            // New marks: released now, not before. The very first sync has nothing to compare.
            if previousAssessments != nil {
                report.newMarkAssessmentIDs = current.filter { item in
                    guard item.marks?.grade != nil || item.marks?.percentage != nil else { return false }
                    guard let old = before[item.id] else { return false }
                    return old.marks?.grade == nil && old.marks?.percentage == nil
                }.map(\.id)
            }
        }

        let notices = noticesPayload.map { SeqtaDecoding.notices($0, date: today) }
        let messages = messagesPayload.map { Array(SeqtaDecoding.messageList($0).prefix(range.messageLimit)) }

        // 5. Write what we got. A kind that failed keeps its old file.
        let written = now
        var counts: [String: Int] = [:]
        func save<Item: Codable & Sendable>(_ items: [Item]?, _ kind: SeqtaCache.Kind) throws {
            guard let items else { return }
            try cache.save(items, kind: kind, syncedAt: written)
            counts[kind.rawValue] = items.count
        }
        try save(lessons, .lessons)
        try save(assessments, .assessments)
        try save(notices, .notices)
        try save(subjects, .subjects)
        try save(messages, .messages)
        try save(files, .files)
        report.counts = counts
        if counts.isEmpty { throw SeqtaSyncError.nothingSynced(report.failures) }

        try cache.updateMeta { meta in
            meta.lastSync = written
            meta.lastReason = reason
            if reason == .morning { meta.lastAutoSyncDay = today }
            for (kind, count) in counts { meta.kinds[kind] = .init(syncedAt: written, count: count) }
            meta.failures = report.failures
            meta.newMarkAssessmentIDs = report.newMarkAssessmentIDs
        }
        return report
    }

    private func addDays(_ date: Date, _ days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
}
