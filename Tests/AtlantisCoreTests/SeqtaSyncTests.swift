import Foundation
import Testing
@testable import AtlantisCore

/// A SEQTA that answers from the made-up fixtures.
final class FakeSeqta: SeqtaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [SeqtaRequest] = []
    private var _opened = 0
    private var _closed = 0

    /// Overrides for single paths, e.g. `["/seqta/student/load/notices": SeqtaResponse(status: 500, body: "")]`.
    var overrides: [String: SeqtaResponse] = [:]
    var openError: SeqtaSyncError?
    var loginFixture = "login"

    var requests: [SeqtaRequest] { lock.withLock { _requests } }
    var opened: Int { lock.withLock { _opened } }
    var closed: Int { lock.withLock { _closed } }

    func open() async throws {
        lock.withLock { _opened += 1 }
        if let openError { throw openError }
    }

    func close() async { lock.withLock { _closed += 1 } }

    func send(_ requests: [SeqtaRequest]) async throws -> [SeqtaResponse] {
        lock.withLock { _requests += requests }
        return requests.map(answer)
    }

    private func answer(_ request: SeqtaRequest) -> SeqtaResponse {
        let path = request.path.hasSuffix("?") ? String(request.path.dropLast()) : request.path
        if let override = overrides[path] { return override }
        let body = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any] ?? [:]
        let empty = SeqtaResponse(status: 200, body: #"{"status":"200","payload":{"tasks":[],"pending":[],"d":[],"w":[]}}"#)
        switch path {
        case "/seqta/student/login": return SeqtaFixture.response(loginFixture)
        case "/seqta/student/load/subjects": return SeqtaFixture.response("subjects")
        case "/seqta/student/load/prefs": return SeqtaFixture.response("prefs")
        case "/seqta/student/load/timetable": return SeqtaFixture.response("timetable")
        case "/seqta/student/load/notices": return SeqtaFixture.response("notices")
        case "/seqta/student/assessment/list/upcoming": return SeqtaFixture.response("upcoming")
        case "/seqta/student/load/message": return SeqtaFixture.response("messages")
        case "/seqta/student/load/courses":
            return body["programme"] as? String == "3830" ? SeqtaFixture.response("course-english")
                : body["programme"] as? String == "3831" ? SeqtaFixture.response("course-maths") : empty
        case "/seqta/student/assessment/list/past":
            return body["programme"] as? Int == 3830 ? SeqtaFixture.response("past-english")
                : body["programme"] as? Int == 3831 ? SeqtaFixture.response("past-maths") : empty
        case "/seqta/student/assessment/get":
            switch body["assessment"] as? Int {
            case 501: return SeqtaFixture.response("assessment-501")
            case 401: return SeqtaFixture.response("assessment-401")
            default: return SeqtaFixture.response("assessment-generic")
            }
        default:
            return SeqtaResponse(status: 404, body: "")
        }
    }
}

@Suite struct SeqtaSyncTests {
    let perth = TimeZone(identifier: "Australia/Perth")!
    let dir: URL
    let cache: SeqtaCache
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = perth; return c }
    /// Monday 2026-11-09, 8:00 am in Perth.
    let now = ISO8601DateFormatter().date(from: "2026-11-09T00:00:00Z")!

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("seqta-sync-\(UUID().uuidString)")
        cache = SeqtaCache(root: dir)
    }

    private func runner(_ transport: FakeSeqta) -> SeqtaSyncRunner {
        SeqtaSyncRunner(transport: transport, cache: cache, calendar: calendar)
    }

    @Test func fullSyncWritesEveryKind() async throws {
        let seqta = FakeSeqta()
        let report = try await runner(seqta).run(reason: .manual, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(report.failures.isEmpty)
        #expect(report.counts == ["lessons": 4, "assessments": 5, "notices": 2, "subjects": 2, "messages": 2])
        #expect(report.newMarkAssessmentIDs.isEmpty) // first sync: nothing to compare with
        #expect(seqta.opened == 1 && seqta.closed == 1)
        #expect(seqta.requests.allSatisfy { $0.isAllowed })
        #expect(report.summary == "lessons 4, assessments 5, notices 2, subjects 2, messages 2")

        let lessons = try #require(cache.lessons()).items
        #expect(lessons.map(\.id) == ["2026-11-09T08:30-TUT", "2026-11-09T09:00-ENGG9", "2026-11-09T09:55-MATH9", "2026-11-10T09:00-ENGG9"])
        // Topic and homework from the course pages, matched by programme, metaclass, date and time.
        #expect(lessons[1].topic == "Persuasive writing" && lessons[1].homework == "Finish the first draft & bring it to class.")
        #expect(lessons[2].topic == "Linear equations" && lessons[2].homework == "- Exercise 4A\n- Exercise 4B")
        #expect(lessons[3].topic == nil) // slot with empty content
        #expect(lessons[0].topic == nil) // tutorials have no course

        let subjects = try #require(cache.subjects()).items
        #expect(subjects.map(\.code) == ["ENGG9", "MATH9"])
        #expect(subjects[0].teacher == "Ms Example" && subjects[1].teacher == "Mr Sample") // from the timetable
        #expect(subjects[0].colour == "#3b82f6")

        // Upcoming within 14 days + past within 30 days; the far exam and the August essay are out.
        let assessments = try #require(cache.assessments()).items
        #expect(assessments.map(\.id) == [401, 410, 403, 501, 502])
        let speech = try #require(assessments.first { $0.id == 501 })
        #expect(speech.details == "Write and give a 3 minute speech.\nUse three techniques.\n\nCriteria: Ideas; Delivery")
        let review = try #require(assessments.first { $0.id == 401 })
        #expect(review.marks == Mark(grade: "B", percentage: 74, feedback: "Good ideas. Check paragraphing."))
        #expect(review.details == "Review a novel.\n\nCriteria: Ideas")
        #expect(assessments.first { $0.id == 410 }?.marks == Mark(grade: "A", percentage: 88, feedback: nil))

        #expect(try #require(cache.notices()).items.map(\.id) == [9001, 9002])
        #expect(try #require(cache.messages()).items.map(\.id) == [8101, 8100])

        let meta = cache.meta()
        #expect(meta.lastSync == now && meta.lastReason == .manual && meta.lastAutoSyncDay == nil)
        #expect(meta.kinds["lessons"]?.count == 4 && meta.kinds["lessons"]?.syncedAt == now)
        #expect(meta.failures.isEmpty)
    }

    @Test func requestsAreTheExpectedReadsForTheExpectedRange() async throws {
        let seqta = FakeSeqta()
        try await runner(seqta).run(reason: .manual, now: now)
        defer { try? FileManager.default.removeItem(at: dir) }
        let timetable = try #require(seqta.requests.first { $0.path.contains("timetable") })
        #expect(timetable.body == #"{"from":"2026-11-09","student":4242,"until":"2026-11-16"}"#) // today + 7 days
        let notices = try #require(seqta.requests.first { $0.path.contains("notices") })
        #expect(notices.body == #"{"date":"2026-11-09"}"#)
        let messageList = try #require(seqta.requests.first { $0.path.contains("load/message") })
        #expect(messageList.body.contains(#""action":"list""#) && messageList.body.contains(#""limit":25"#))
        // One course per programme/metaclass (not per lesson), one "past" call per active subject.
        #expect(seqta.requests.filter { $0.path.contains("load/courses") }.count == 2)
        #expect(seqta.requests.filter { $0.path.contains("list/past") }.count == 2)
        // Details only for the two upcoming-in-range and the one released mark with no cached copy.
        let detailIDs = seqta.requests.filter { $0.path.contains("assessment/get") }.compactMap { request -> Int? in
            ((try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any])?["assessment"] as? Int
        }.sorted()
        #expect(detailIDs == [401, 410, 501, 502])
        // No sending, saving or submitting anywhere.
        #expect(seqta.requests.allSatisfy { !$0.path.contains("/save/") && !$0.path.contains("submit") })
    }

    @Test func secondSyncReusesDetailsAndSpotsNewMarks() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FakeSeqta()
        try await runner(first).run(reason: .manual, now: now)

        let second = FakeSeqta()
        // The unmarked poem (403) gets a mark.
        let report = try await runnerWithMarkedPoem(second)
        #expect(report.newMarkAssessmentIDs == [403])
        #expect(cache.meta().newMarkAssessmentIDs == [403])
        let detailRequests = second.requests.filter { $0.path.contains("assessment/get") }
        // 501, 401 and 410 are cached with the same status; 502 had generic details cached; only 403 is new.
        #expect(detailRequests.count == 1 && detailRequests[0].body.contains(#""assessment":403"#))
        let assessments = try #require(cache.assessments()).items
        #expect(assessments.first { $0.id == 501 }?.details != nil)
        #expect(assessments.first { $0.id == 401 }?.marks?.feedback == "Good ideas. Check paragraphing.")
        #expect(assessments.first { $0.id == 403 }?.marks?.grade == "C")
    }

    /// Runs with the poem marked: the fixture text is patched in a temp copy of the fake.
    private func runnerWithMarkedPoem(_ seqta: FakeSeqta) async throws -> SeqtaSyncReport {
        let marked = SeqtaFixture.text("past-english").replacingOccurrences(
            of: #""id":403,"title":"Unmarked poem","subject":"English 9","code":"ENGG9","due":"2026-11-03","status":"OVERDUE""#,
            with: #""id":403,"title":"Unmarked poem","subject":"English 9","code":"ENGG9","due":"2026-11-03","status":"MARKS_RELEASED","finalGrade":"65","letterGrade":"C""#)
        #expect(marked != SeqtaFixture.text("past-english"))
        let transport = PatchedPast(base: seqta, marked: marked)
        return try await SeqtaSyncRunner(transport: transport, cache: cache, calendar: calendar).run(reason: .manual, now: now)
    }

    /// Wraps the fake so English's "past" answer is replaced.
    private struct PatchedPast: SeqtaTransport {
        let base: FakeSeqta
        let marked: String
        func open() async throws { try await base.open() }
        func close() async { await base.close() }
        func send(_ requests: [SeqtaRequest]) async throws -> [SeqtaResponse] {
            let answers = try await base.send(requests)
            return zip(requests, answers).map { request, answer in
                request.path.contains("list/past") && request.body.contains("3830")
                    ? SeqtaResponse(status: 200, body: marked) : answer
            }
        }
    }

    @Test func notSignedInIsReportedAndWritesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let seqta = FakeSeqta()
        seqta.loginFixture = "login-signed-out"
        await #expect(throws: SeqtaSyncError.notSignedIn) { try await runner(seqta).run(reason: .manual, now: now) }
        #expect(seqta.closed == 1)
        #expect(cache.lessons() == nil && cache.meta().lastSync == nil)
        #expect(seqta.requests.count == 1) // stopped at the login check
    }

    @Test func aSignInPageOrA401CountsAsNotSignedIn() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = FakeSeqta()
        page.overrides["/seqta/student/login"] = SeqtaResponse(status: 200, body: "<!DOCTYPE html><html><body>Sign in</body></html>")
        await #expect(throws: SeqtaSyncError.notSignedIn) { try await runner(page).run(reason: .manual, now: now) }
        let unauthorised = FakeSeqta()
        unauthorised.overrides["/seqta/student/login"] = SeqtaResponse(status: 401, body: "")
        await #expect(throws: SeqtaSyncError.notSignedIn) { try await runner(unauthorised).run(reason: .manual, now: now) }
        let statusBody = FakeSeqta()
        statusBody.overrides["/seqta/student/load/timetable"] = SeqtaResponse(status: 200, body: #"{"status":"401"}"#)
        await #expect(throws: SeqtaSyncError.notSignedIn) { try await runner(statusBody).run(reason: .manual, now: now) }
        #expect(cache.lessons() == nil) // an expired session mid-sync writes nothing
    }

    @Test func aSessionEndingBetweenStepsIsNotSignedIn() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let seqta = FakeSeqta()
        seqta.overrides["/seqta/student/load/courses"] = SeqtaResponse(status: 401, body: "")
        await #expect(throws: SeqtaSyncError.notSignedIn) { try await runner(seqta).run(reason: .manual, now: now) }
        #expect(cache.lessons() == nil)
    }

    @Test func oneFailingKindKeepsItsOldFileAndTheRest() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try await runner(FakeSeqta()).run(reason: .manual, now: now)
        let oldNotices = try #require(cache.notices())

        let later = now.addingTimeInterval(3600)
        let seqta = FakeSeqta()
        seqta.overrides["/seqta/student/load/notices"] = SeqtaResponse(status: 500, body: "oops")
        let report = try await runner(seqta).run(reason: .manual, now: later)
        #expect(report.counts["notices"] == nil && report.counts["lessons"] == 4)
        #expect(report.failures.keys.sorted() == ["notices"])
        #expect(report.failures["notices"]?.contains("HTTP 500") == true)
        #expect(try #require(cache.notices()).syncedAt == oldNotices.syncedAt) // untouched
        #expect(try #require(cache.lessons()).syncedAt == later)
        #expect(cache.meta().failures.keys.sorted() == ["notices"])
        #expect(cache.meta().kinds["notices"]?.syncedAt == now)
    }

    @Test func aMissingCourseOnlyCostsLessonContent() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let seqta = FakeSeqta()
        seqta.overrides["/seqta/student/load/courses"] = SeqtaResponse(status: 500, body: "")
        let report = try await runner(seqta).run(reason: .manual, now: now)
        #expect(report.failures["lessonContent"] == "2 of 2 courses didn't load")
        #expect(report.counts["lessons"] == 4)
        #expect(try #require(cache.lessons()).items.allSatisfy { $0.topic == nil && $0.homework == nil })
    }

    @Test func everythingFailingIsAnError() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let seqta = FakeSeqta()
        for path in ["subjects", "prefs", "timetable", "notices", "message"] {
            seqta.overrides["/seqta/student/load/\(path)"] = SeqtaResponse(status: 500, body: "")
        }
        seqta.overrides["/seqta/student/assessment/list/upcoming"] = SeqtaResponse(status: 500, body: "")
        await #expect(throws: SeqtaSyncError.self) { try await runner(seqta).run(reason: .manual, now: now) }
        #expect(cache.meta().lastSync == nil)
        #expect(seqta.closed == 1)
    }

    @Test func morningSyncUsesUpTheDayUnlessItCouldNotConnect() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        // Offline: nothing reached SEQTA, so a later launch or wake may try again.
        let offline = FakeSeqta()
        offline.openError = .network("offline")
        await #expect(throws: SeqtaSyncError.network("offline")) { try await runner(offline).run(reason: .morning, now: now) }
        #expect(SeqtaMorningGate.shouldRun(meta: cache.meta(), now: now, calendar: calendar))

        // Not signed in: it did reach SEQTA, so that's the morning's one try.
        let signedOut = FakeSeqta()
        signedOut.loginFixture = "login-signed-out"
        await #expect(throws: SeqtaSyncError.notSignedIn) { try await runner(signedOut).run(reason: .morning, now: now) }
        #expect(cache.meta().lastAutoSyncDay == "2026-11-09")
        #expect(!SeqtaMorningGate.shouldRun(meta: cache.meta(), now: now.addingTimeInterval(3600), calendar: calendar))
        // Tomorrow it may run again.
        #expect(SeqtaMorningGate.shouldRun(meta: cache.meta(), now: now.addingTimeInterval(86_400), calendar: calendar))
    }

    @Test func aManualSyncTodayMeansNoMorningSync() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SeqtaMorningGate.shouldRun(meta: SeqtaMeta(), now: now, calendar: calendar))
        try await runner(FakeSeqta()).run(reason: .manual, now: now)
        #expect(!SeqtaMorningGate.shouldRun(meta: cache.meta(), now: now.addingTimeInterval(60), calendar: calendar))
        #expect(SeqtaMorningGate.shouldRun(meta: cache.meta(), now: now.addingTimeInterval(86_400), calendar: calendar))
    }

    @Test func morningGateUsesTheLocalDayNotUTC() {
        // 2026-11-08T17:00Z is 1 am on the 9th in Perth.
        let lateUTC = ISO8601DateFormatter().date(from: "2026-11-08T17:00:00Z")!
        #expect(SeqtaMorningGate.dayString(lateUTC, calendar: calendar) == "2026-11-09")
        var meta = SeqtaMeta()
        meta.lastAutoSyncDay = "2026-11-08"
        #expect(SeqtaMorningGate.shouldRun(meta: meta, now: lateUTC, calendar: calendar))
    }
}

@Suite struct SeqtaRequestTests {
    @Test func readEndpointsAreAllowed() {
        for path in ["/seqta/student/load/timetable?", "/seqta/student/load/notices?", "/seqta/student/load/subjects?",
                     "/seqta/student/load/courses", "/seqta/student/load/prefs?", "/seqta/student/assessment/list/upcoming?",
                     "/seqta/student/assessment/list/past?", "/seqta/student/assessment/get?"] {
            #expect(SeqtaRequest(path: path).isAllowed, "\(path)")
        }
        #expect(SeqtaRequest(path: "/seqta/student/login", body: ["mode": "normal"]).isAllowed)
    }

    @Test func messagesAllowReadingButNeverSending() {
        #expect(SeqtaRequest(path: "/seqta/student/load/message", body: ["action": "list"]).isAllowed)
        #expect(SeqtaRequest(path: "/seqta/student/load/message", body: ["action": "message", "id": 1]).isAllowed)
        #expect(!SeqtaRequest(path: "/seqta/student/load/message", body: ["action": "send"]).isAllowed)
        #expect(!SeqtaRequest(path: "/seqta/student/load/message", body: ["action": "delete"]).isAllowed)
        #expect(!SeqtaRequest(path: "/seqta/student/load/message").isAllowed)
        #expect(!SeqtaRequest(path: "/seqta/student/save/message", body: ["action": "list"]).isAllowed)
    }

    @Test func nothingThatChangesSeqtaIsAllowed() {
        for path in ["/seqta/student/save/message", "/seqta/student/save/assessment/submission", "/seqta/student/file/upload/xhr2",
                     "/seqta/student/save/prefs", "/seqta/student/load/settings", "/seqta/parent/load/timetable",
                     "https://evil.example/seqta/student/load/timetable", "/seqta/student/load/timetable/../../save/message",
                     "/seqta/student/login/other"] {
            #expect(!SeqtaRequest(path: path, body: ["action": "list", "mode": "normal"]).isAllowed, "\(path)")
        }
        #expect(!SeqtaRequest(path: "/seqta/student/login", body: ["mode": "sso"]).isAllowed)
    }

    @Test func requestBodiesAreStableJSON() {
        let request = SeqtaRequest(path: "/x", body: ["b": 2, "a": "1", "n": NSNull()])
        #expect(request.body == #"{"a":"1","b":2,"n":null}"#)
    }

    @Test func envelopeUnwrapsAndClassifiesAnswers() throws {
        #expect(try SeqtaEnvelope.payload(SeqtaResponse(status: 200, body: #"{"status":"200","payload":[1,2]}"#)) as? [Int] == [1, 2])
        #expect(throws: SeqtaSyncError.notSignedIn) { try SeqtaEnvelope.payload(SeqtaResponse(status: 403, body: "")) }
        #expect(throws: SeqtaSyncError.notSignedIn) { try SeqtaEnvelope.payload(SeqtaResponse(status: 200, body: #"{"status":"401"}"#)) }
        #expect(throws: SeqtaSyncError.network("no answer")) { try SeqtaEnvelope.payload(SeqtaResponse(status: 0, body: "")) }
        #expect(throws: SeqtaSyncError.badResponse("HTTP 502")) { try SeqtaEnvelope.payload(SeqtaResponse(status: 502, body: "")) }
        #expect(throws: SeqtaSyncError.badResponse("not JSON")) { try SeqtaEnvelope.payload(SeqtaResponse(status: 200, body: "garbage")) }
        #expect(throws: SeqtaSyncError.badResponse("no payload")) { try SeqtaEnvelope.payload(SeqtaResponse(status: 200, body: "{}")) }
    }
}
