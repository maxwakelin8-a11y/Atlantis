import Foundation
import Testing
@testable import AtlantisCore

/// Reads the made-up SEQTA answers in `Fixtures/seqta` (never real data: the repo is public).
enum SeqtaFixture {
    static func text(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/seqta/\(name).json")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? { fatalError("missing fixture \(name)") }()
    }

    static func response(_ name: String, status: Int = 200) -> SeqtaResponse {
        SeqtaResponse(status: status, body: text(name))
    }

    /// The unwrapped `payload`, as the decoders receive it.
    static func payload(_ name: String) -> Any {
        try! SeqtaEnvelope.payload(response(name))
    }
}

@Suite struct SeqtaDecodingTests {
    let perth = TimeZone(identifier: "Australia/Perth")!

    @Test func studentIDNeedsAUser() {
        #expect(SeqtaDecoding.studentID(SeqtaFixture.payload("login")) == 4242)
        #expect(SeqtaDecoding.studentID(SeqtaFixture.payload("login-signed-out")) == nil)
    }

    @Test func coloursComeFromPrefsAndSkipBadValues() {
        let colours = SeqtaDecoding.colours(prefs: SeqtaFixture.payload("prefs"))
        #expect(colours.bySubjectCode == ["ENGG9": "#3b82f6", "MATH9": "#f97316"])
        #expect(colours.byTutorID == ["77": "#22c55e"])
    }

    @Test func lessonsAreSortedCleanedAndColoured() {
        let colours = SeqtaDecoding.colours(prefs: SeqtaFixture.payload("prefs"))
        let lessons = SeqtaDecoding.lessons(timetable: SeqtaFixture.payload("timetable"), colours: colours)
        #expect(lessons.map(\.id) == ["2026-11-09T08:30-TUT", "2026-11-09T09:00-ENGG9", "2026-11-09T09:55-MATH9", "2026-11-10T09:00-ENGG9"])
        let tutorial = lessons[0]
        #expect(tutorial.subject == "Tutorial" && tutorial.type == "tutorial" && tutorial.colour == "#22c55e")
        #expect(tutorial.from == "08:30" && tutorial.until == "08:50") // "8:30:00" is padded
        let english = lessons[1]
        #expect(english.subject == "English 9" && english.room == "E12" && english.teacher == "Ms Example")
        #expect(english.colour == "#3b82f6" && english.programme == 3830 && english.metaclass == 29611 && english.period == "1")
        #expect(lessons[2].notes == "Bring a calculator.")
        #expect(english.topic == nil && english.homework == nil)
    }

    @Test func courseLessonsPairSlotsWithContent() {
        let slots = SeqtaDecoding.courseLessons(SeqtaFixture.payload("course-english"))
        #expect(slots.count == 2)
        #expect(slots[0].date == "2026-11-09" && slots[0].start == "09:00")
        #expect(slots[0].topic == "Persuasive writing")
        #expect(slots[0].homework == "Finish the first draft & bring it to class.")
        #expect(slots[1].topic == nil && slots[1].homework == nil) // empty strings become nil
        let maths = SeqtaDecoding.courseLessons(SeqtaFixture.payload("course-maths"))
        #expect(maths[0].homework == "- Exercise 4A\n- Exercise 4B")
    }

    @Test func subjectsOnlyFromActiveTerms() {
        let colours = SeqtaDecoding.colours(prefs: SeqtaFixture.payload("prefs"))
        let subjects = SeqtaDecoding.subjects(SeqtaFixture.payload("subjects"), colours: colours, teachers: ["ENGG9": "Ms Example"])
        #expect(subjects.map(\.code) == ["ENGG9", "MATH9"])
        #expect(subjects[0].name == "English 9" && subjects[0].teacher == "Ms Example" && subjects[0].colour == "#3b82f6")
        #expect(subjects[0].programme == 3830 && subjects[0].metaclass == 29611 && subjects[0].classunit == 31001)
        #expect(subjects[1].teacher == "")
    }

    @Test func upcomingAssessmentsDropCancelled() {
        let list = SeqtaDecoding.upcomingAssessments(SeqtaFixture.payload("upcoming"))
        #expect(list.map(\.id) == [501, 502, 503])
        #expect(list[0].title == "Persuasive speech" && list[0].due == "2026-11-12" && list[0].code == "ENGG9")
        #expect(list[0].subject == "English 9" && list[0].status == "PENDING" && list[0].submitted == false)
        #expect(list[0].programme == 3830 && list[0].metaclass == 29611)
        #expect(list[1].submitted == false) // 0 → false
        #expect(list[0].marks == nil)
    }

    @Test func pastAssessmentsReadMarksFromAllTheUsualPlaces() {
        let past = SeqtaDecoding.pastAssessments(SeqtaFixture.payload("past-english"), programme: 3830, metaclass: 29611)
        #expect(past.map(\.id) == [401, 402, 403])
        #expect(past[0].marks == Mark(grade: "B", percentage: 74, feedback: nil)) // criteria[0].results
        #expect(past[1].marks == Mark(grade: "A", percentage: 81, feedback: nil)) // finalGrade + letterGrade
        #expect(past[2].marks == nil) // overdue, nothing released
        #expect(past[2].programme == 3830 && past[2].metaclass == 29611) // filled from the subject
    }

    @Test func assessmentDetailGivesTextCriteriaAndFeedback() {
        let released = SeqtaDecoding.assessmentDetail(SeqtaFixture.payload("assessment-401"))
        #expect(released.details == "Review a novel.\n\nCriteria: Ideas")
        #expect(released.marks?.feedback == "Good ideas. Check paragraphing.")
        let upcoming = SeqtaDecoding.assessmentDetail(SeqtaFixture.payload("assessment-501"))
        #expect(upcoming.details == "Write and give a 3 minute speech.\nUse three techniques.\n\nCriteria: Ideas; Delivery")
        #expect(upcoming.marks == nil)
    }

    @Test func noticesBecomePlainText() {
        let notices = SeqtaDecoding.notices(SeqtaFixture.payload("notices"), date: "2026-11-09")
        #expect(notices.map(\.id) == [9001, 9002])
        #expect(notices[0].contents == "Bring shoes.") // <style> dropped
        #expect(notices[0].label == "All Students" && notices[0].staff == "Mr Coach" && notices[0].colour == "#ff5722")
        #expect(notices[0].date == "2026-11-09")
        #expect(notices[1].contents == "Open until 4pm — every day.")
        #expect(notices[1].colour == nil)
    }

    @Test func messageListReadsSummaries() throws {
        let list = SeqtaDecoding.messageList(SeqtaFixture.payload("messages"), timeZone: perth)
        #expect(list.map(\.id) == [8101, 8100]) // the row with no id is skipped
        #expect(list[0].sender == "Ms Example" && list[0].subject == "Excursion form" && list[0].senderType == "staff")
        #expect(list[0].read == false && list[1].read == true)
        #expect(list[0].attachmentCount == 2 && list[1].attachmentCount == 0)
        #expect(list[0].date == ISO8601DateFormatter().date(from: "2026-11-08T04:26:25Z"))
        // No zone given → school time (Perth, UTC+8).
        #expect(list[1].date == ISO8601DateFormatter().date(from: "2026-11-06T14:05:00Z"))
    }

    @Test func wholeMessage() throws {
        let message = try #require(SeqtaDecoding.message(SeqtaFixture.payload("message-8101"), timeZone: perth))
        #expect(message.id == 8101 && message.summary.subject == "Excursion form")
        #expect(message.body == "Hi all,\nPlease return the form by Friday.\nThanks")
        #expect(message.recipients == ["Test Student", "Another Student"])
        #expect(message.files == [MessageFile(name: "form.pdf", uuid: "11111111-2222-3333-4444-555555555555", mimetype: "application/pdf")])
    }

    @Test func datesParseTheShapesSeqtaSends() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let expected = ISO8601DateFormatter().date(from: "2026-04-29T04:26:25Z")
        #expect(SeqtaDecoding.date("2026-04-29 04:26:25.075868+00", defaultTimeZone: perth) == expected)
        #expect(SeqtaDecoding.date("2026-04-29T04:26:25Z", defaultTimeZone: perth) == expected)
        #expect(SeqtaDecoding.date("2026-04-29 12:26:25+08:00", defaultTimeZone: utc) == expected)
        #expect(SeqtaDecoding.date("2026-04-29 04:26:25.0", defaultTimeZone: utc) == expected)
        #expect(SeqtaDecoding.date("2026-04-29 12:26", defaultTimeZone: perth) == ISO8601DateFormatter().date(from: "2026-04-29T04:26:00Z"))
        #expect(SeqtaDecoding.date("yesterday", defaultTimeZone: utc) == nil)
    }

    @Test func missingOrRetypedFieldsLoseOnlyThatField() {
        // Strings for numbers, numbers for strings, nulls, wrong containers: nothing crashes.
        let weird: [String: Any] = ["items": [["date": "2026-11-09", "from": "09:00:00", "code": 5, "programmeID": "3830", "room": NSNull(), "staff": ["x"]]]]
        let lessons = SeqtaDecoding.lessons(timetable: weird)
        #expect(lessons.count == 1)
        #expect(lessons[0].code == "5" && lessons[0].programme == 3830 && lessons[0].room == "" && lessons[0].teacher == "")
        #expect(SeqtaDecoding.lessons(timetable: "nonsense").isEmpty)
        #expect(SeqtaDecoding.subjects(42).isEmpty)
        #expect(SeqtaDecoding.upcomingAssessments(["x": 1]).isEmpty)
        #expect(SeqtaDecoding.messageList([1, 2]).isEmpty)
        #expect(SeqtaDecoding.message([:]) == nil)
    }
}

@Suite struct HTMLTextTests {
    @Test func stripsTagsAndKeepsParagraphs() {
        #expect(HTMLText.plain("<p>One</p><p>Two<br>three</p>") == "One\nTwo\nthree")
        #expect(HTMLText.plain("<ul><li>a</li><li>b</li></ul>") == "- a\n- b")
        #expect(HTMLText.plain(nil) == "" && HTMLText.plain("") == "")
    }

    @Test func decodesEntitiesOnce() {
        #expect(HTMLText.plain("Tom &amp; Jerry &lt;3 &#39;hi&#39; &#x41;") == "Tom & Jerry <3 'hi' A")
        #expect(HTMLText.plain("&amp;lt;") == "&lt;")
        #expect(HTMLText.plain("a&nbsp;&nbsp;b") == "a b")
        #expect(HTMLText.plain("&unknown; stays") == "&unknown; stays")
    }

    @Test func dropsScriptsAndStyles() {
        #expect(HTMLText.plain("Hi<script>alert(1)</script><style>a{}</style> there") == "Hi there")
    }
}
