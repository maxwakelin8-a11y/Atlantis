import Foundation
import Testing
@testable import AtlantisCore

@Suite struct SubjectDecodingTests {
    @Test func courseFilesListOutlineThenLessonResourcesOnce() {
        let files = SeqtaDecoding.courseFiles(SeqtaFixture.payload("course-english"), subjectCode: "ENGG9")
        // "no uuid.pdf" can't be downloaded, and the outline repeated in a lesson isn't listed twice.
        #expect(files.map(\.name) == ["English 9 outline.pdf", "Speech rubric.docx"])
        #expect(files[0].source == "Course outline" && files[0].size == 20480 && files[0].mimetype == "application/pdf")
        #expect(files[1].source == "Lesson 2026-11-09 · Persuasive writing")
        #expect(files.allSatisfy { $0.subjectCode == "ENGG9" })
        #expect(files[0].id == "ENGG9:aaaaaaaa-1111-2222-3333-444444444444")
    }

    @Test func peopleAreSortedAndNamedWithFallbacks() {
        let staff = SeqtaDecoding.people(SeqtaFixture.payload("people-staff"), kind: .staff)
        #expect(staff.map(\.name) == ["Mr Sample", "Ms Example", "Pat Placeholder"]) // row without an id is dropped
        #expect(staff.map(\.id) == [247, 246, 250])
        let students = SeqtaDecoding.people(SeqtaFixture.payload("people-student"), kind: .student)
        #expect(students == [SeqtaPerson(id: 246, kind: .student, name: "Robin Madeup", detail: "Year 9 · Roll 9A")])
        #expect(staff[1].key != students[0].key) // same number, different people
    }

    @Test func messageListKeepsTheSenderID() {
        let list = SeqtaDecoding.messageList(SeqtaFixture.payload("messages"))
        #expect(list.first?.senderID == 246)
    }
}

@Suite struct SubjectGroupingTests {
    let english = Subject(code: "ENGG9", name: "English 9", colour: "#3b82f6", teacher: "Ms Example", programme: 1, metaclass: 2)
    let maths = Subject(code: "MATH9", name: "Mathematics 9", programme: 3, metaclass: 4)
    func assessment(_ id: Int, _ code: String, due: String, marks: Mark? = nil) -> Assessment {
        Assessment(id: id, title: "A\(id)", subject: code, code: code, due: due, status: "PENDING", marks: marks)
    }

    @Test func assessmentsSplitIntoUpcomingAndPastPerSubject() {
        let assessments = [
            assessment(1, "ENGG9", due: "2026-11-20"), assessment(2, "ENGG9", due: "2026-11-12"),
            assessment(3, "ENGG9", due: "2026-10-30", marks: Mark(grade: "B", percentage: 74)),
            assessment(4, "ENGG9", due: "2026-11-02"), assessment(5, "MATH9", due: "2026-11-09"),
            assessment(6, "OLDX9", due: "2026-11-10"), // not a current subject
        ]
        let files = [SubjectFile(subjectCode: "MATH9", name: "Sheet.pdf", uuid: "u1", source: "Course outline")]
        let details = SubjectOverview.details(subjects: [english, maths], assessments: assessments, files: files, today: "2026-11-09")
        #expect(details.map(\.id) == ["ENGG9", "MATH9"])
        #expect(details[0].upcoming.map(\.id) == [2, 1]) // soonest first
        #expect(details[0].past.map(\.id) == [4, 3]) // newest first
        #expect(details[0].next?.id == 2)
        #expect(details[0].marked.map(\.id) == [3])
        #expect(details[1].upcoming.map(\.id) == [5]) // due today still counts as upcoming
        #expect(details[1].past.isEmpty && details[1].files.map(\.name) == ["Sheet.pdf"])
        #expect(details[0].files.isEmpty)
    }

    @Test func markTextReadsInOneLine() {
        #expect(SubjectOverview.markText(Mark(grade: "B", percentage: 74)) == "B · 74%")
        #expect(SubjectOverview.markText(Mark(percentage: 88.5)) == "88.5%")
        #expect(SubjectOverview.markText(Mark(grade: "A")) == "A")
        #expect(SubjectOverview.markText(Mark(feedback: "Nice")) == nil)
    }

    @Test func seqtaPagesLinkToCoursesAssessmentsAndMessages() throws {
        let base = try #require(URL(string: "https://learn.example.edu.au/"))
        #expect(SeqtaPages.course(base, programme: 3830, metaclass: 29611)?.absoluteString
                == "https://learn.example.edu.au/#?page=/courses/3830:29611")
        #expect(SeqtaPages.assessment(base, programme: 3830, metaclass: 29611, id: 501)?.absoluteString
                == "https://learn.example.edu.au/#?page=/assessments/3830:29611&item=501")
        #expect(SeqtaPages.messages(base)?.absoluteString == "https://learn.example.edu.au/#?page=/messages")
    }
}

@Suite struct OnDemandTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seqta-ondemand-\(UUID().uuidString)")
    var cache: SeqtaCache { SeqtaCache(root: dir) }

    @Test func readingAMessageFetchesOnceAndCachesIt() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(SeqtaDecoding.messageList(SeqtaFixture.payload("messages")), kind: .messages, syncedAt: Date())
        let seqta = FakeSeqta()
        let onDemand = SeqtaOnDemand(transport: seqta, cache: cache)
        #expect(!cache.hasMessage(id: 8101))
        let message = try await onDemand.message(id: 8101)
        #expect(message.body == "Hi all,\nPlease return the form by Friday.\nThanks")
        #expect(message.files.map(\.name) == ["form.pdf"])
        #expect(message.summary.senderID == 246) // from the list
        #expect(seqta.requests.count == 1 && seqta.opened == 1 && seqta.closed == 1)
        #expect(seqta.requests.allSatisfy { $0.isAllowed })

        let again = try await onDemand.message(id: 8101)
        #expect(again == message)
        #expect(seqta.requests.count == 1) // served from the cache
        #expect(cache.hasMessage(id: 8101))
    }

    @Test func aMissingMessageFailsAndClosesTheConnection() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let seqta = FakeSeqta()
        await #expect(throws: SeqtaSyncError.self) { try await SeqtaOnDemand(transport: seqta, cache: cache).message(id: 1) }
        #expect(seqta.closed == 1 && !cache.hasMessage(id: 1))
    }

    @Test func peopleComeFromTheAllowListedEndpoint() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let seqta = FakeSeqta()
        let staff = try await SeqtaOnDemand(transport: seqta, cache: cache).people(.staff)
        #expect(staff.count == 3)
        #expect(seqta.requests.map(\.path) == ["/seqta/student/load/message/people"] && seqta.requests[0].isAllowed)
    }

    @Test func filesDownloadThroughAValidatedGetAndAreStoredSafely() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let seqta = FakeSeqta()
        let request = try #require(SeqtaFileRequest(source: .resource, uuid: "AAAAAAAA-1111-2222-3333-444444444444"))
        #expect(request.path == "/seqta/student/load/file?type=resource&file=aaaaaaaa-1111-2222-3333-444444444444")
        let response = try await SeqtaOnDemand(transport: seqta, cache: cache).file(request)
        #expect(response.data == Data("made-up file".utf8) && seqta.closed == 1 && seqta.downloads == [request])

        let files = SeqtaFileCache(root: dir.appendingPathComponent("files"))
        #expect(files.existing(uuid: request.uuid, name: "../../Sheet.pdf") == nil)
        let stored = try files.store(response.data, uuid: request.uuid, name: "../../Sheet.pdf")
        #expect(stored.path.hasPrefix(dir.appendingPathComponent("files").path + "/") && stored.lastPathComponent == "Sheet.pdf")
        #expect(files.existing(uuid: request.uuid, name: "../../Sheet.pdf") == stored)
    }

    @Test func fileRequestsNeedARealUUID() {
        #expect(SeqtaFileRequest(source: .message, uuid: "../../etc/passwd") == nil)
        #expect(SeqtaFileRequest(source: .message, uuid: "1111&type=x") == nil)
        #expect(SeqtaFileRequest(source: .message, uuid: "11111111-2222-3333-4444-555555555555") != nil)
    }

    @Test func fileNamesAreCleaned() {
        #expect(SeqtaFileCache.safeName("../../.ssh/id_rsa") == "id_rsa")
        #expect(SeqtaFileCache.safeName("..hidden.txt") == "hidden.txt")
        #expect(SeqtaFileCache.safeName("   ") == "file")
        #expect(SeqtaFileCache.safeName(String(repeating: "a", count: 300) + ".pdf").count <= 120)
        #expect(SeqtaFileCache.name(fromDisposition: #"attachment; filename="Task sheet.pdf""#) == "Task sheet.pdf")
        #expect(SeqtaFileCache.name(fromDisposition: "attachment; filename*=UTF-8''Task%20sheet.pdf") == "Task sheet.pdf")
        #expect(SeqtaFileCache.name(fromDisposition: "inline") == nil)
    }
}

/// A transport that records what is posted to it, for the send tests.
final class FakeSender: SeqtaSendTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _posted: [SeqtaSendRequest] = []
    private var _closed = 0
    var answer = SeqtaResponse(status: 200, body: #"{"status":"200","payload":{}}"#)
    var posted: [SeqtaSendRequest] { lock.withLock { _posted } }
    var closed: Int { lock.withLock { _closed } }
    func open() async throws {}
    func send(_ requests: [SeqtaRequest]) async throws -> [SeqtaResponse] { [] }
    func close() async { lock.withLock { _closed += 1 } }
    func post(_ request: SeqtaSendRequest) async throws -> SeqtaResponse {
        lock.withLock { _posted.append(request) }
        return answer
    }
}

@Suite struct SeqtaSendTests {
    let staff = SeqtaPerson(id: 246, kind: .staff, name: "Ms Example")
    let student = SeqtaPerson(id: 9, kind: .student, name: "Robin Madeup")
    func message(_ recipients: [SeqtaPerson]? = nil, subject: String = "Excursion form", body: String = "Hello,\n\nHere it is <3 & more.") -> SeqtaSend.Outgoing {
        SeqtaSend.Outgoing(recipients: recipients ?? [staff, student], subject: subject, body: body)
    }

    @Test func theRequestMatchesSeqtasComposer() throws {
        let request = try SeqtaSend.request(for: message())
        #expect(request.path == "/seqta/student/save/message")
        let object = try #require(JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
        #expect(object["subject"] as? String == "Excursion form")
        #expect(object["contents"] as? String == "<p>Hello,</p><p>Here it is &lt;3 &amp; more.</p>")
        #expect(object["blind"] as? Bool == false)
        #expect((object["files"] as? [Int]) == [])
        let people = try #require(object["participants"] as? [[String: Any]])
        #expect(people.count == 2 && people[0]["staff"] as? Bool == true && people[0]["id"] as? Int == 246)
        #expect(people[1]["student"] as? Bool == true && people[1]["staff"] == nil)
    }

    @Test func incompleteMessagesAreRefused() {
        #expect(SeqtaSend.validate(message([])) == .noRecipients)
        #expect(SeqtaSend.validate(message(subject: "  ")) == .noSubject)
        #expect(SeqtaSend.validate(message(body: "\n ")) == .noBody)
        #expect(SeqtaSend.validate(message(subject: String(repeating: "s", count: 201))) == .subjectTooLong)
        #expect(SeqtaSend.validate(message(body: String(repeating: "b", count: 10_001))) == .bodyTooLong)
        #expect(SeqtaSend.validate(message()) == nil)
        #expect(throws: SeqtaSend.Problem.noRecipients) { try SeqtaSend.request(for: message([])) }
    }

    @Test func sendsOneRequestAfterAMatchingConfirmation() async throws {
        let sender = FakeSender()
        let outgoing = message()
        try await SeqtaSend.send(outgoing, confirmed: .init(confirming: outgoing), via: sender)
        #expect(sender.posted.count == 1 && sender.closed == 1)
    }

    @Test func aMessageEditedAfterConfirmingIsNotSent() async {
        let sender = FakeSender()
        let confirmed = SeqtaSend.Confirmation(confirming: message())
        for changed in [message([staff]), message(subject: "Different"), message(body: "Different")] {
            await #expect(throws: SeqtaSend.Problem.notConfirmed) { try await SeqtaSend.send(changed, confirmed: confirmed, via: sender) }
        }
        #expect(sender.posted.isEmpty)
    }

    @Test func seqtaSayingNoIsAnError() async {
        let sender = FakeSender()
        sender.answer = SeqtaResponse(status: 200, body: #"{"status":"500"}"#)
        let outgoing = message()
        await #expect(throws: SeqtaSend.Problem.rejected("status 500")) {
            try await SeqtaSend.send(outgoing, confirmed: .init(confirming: outgoing), via: sender)
        }
        sender.answer = SeqtaResponse(status: 401, body: "")
        await #expect(throws: SeqtaSyncError.notSignedIn) {
            try await SeqtaSend.send(outgoing, confirmed: .init(confirming: outgoing), via: sender)
        }
        #expect(sender.closed == 2)
    }
}

/// The send path must stay out of reach of everything that reads, syncs or belongs to an agent.
@Suite struct SeqtaSendIsolationTests {
    /// The repo's `Sources` folder, found from this file.
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")

    static func swiftFiles(_ subpath: String) -> [URL] {
        let root = sources.appendingPathComponent(subpath)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    static func mentions(_ file: URL, _ needles: [String]) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return true }
        return needles.contains { text.contains($0) }
    }

    static let needles = ["SeqtaSend", "save/message"]

    @Test func theReadAllowListRejectsTheSendEndpoint() {
        #expect(!SeqtaRequest(path: SeqtaSend.path).isAllowed)
        #expect(!SeqtaRequest(path: SeqtaSend.path + "?").isAllowed)
        #expect(!SeqtaRequest(path: SeqtaSend.path, body: ["action": "list", "mode": "normal"]).isAllowed)
        #expect(!SeqtaRequest(path: "/seqta/student/save/message/draft").isAllowed)
        for action in ["send", "save", "delete", "star", "markRead", ""] {
            #expect(!SeqtaRequest(path: "/seqta/student/load/message", body: ["action": action]).isAllowed)
        }
        #expect(!SeqtaRequest(path: "/seqta/student/load/message/people", body: ["mode": "everyone"]).isAllowed)
        #expect(SeqtaRequest(path: "/seqta/student/load/message", body: ["action": "message", "id": 1]).isAllowed)
    }

    @Test func aTransportCannotSendThroughTheReadPath() async throws {
        // `SeqtaRunner`-style callers pass `SeqtaRequest`s; the send request is another type.
        let request = try SeqtaSend.request(for: .init(recipients: [SeqtaPerson(id: 1, kind: .staff, name: "A")], subject: "s", body: "b"))
        #expect(!SeqtaRequest(path: request.path, body: [:]).isAllowed)
    }

    @Test func sourceFilesFoundTheSourcesFolder() {
        #expect(Self.swiftFiles("AtlantisCore").count > 20)
        #expect(Self.swiftFiles("Atlantis").count > 20)
        #expect(!Self.swiftFiles("AtlantisMCP").isEmpty)
    }

    @Test func noReadOrAgentCodeMentionsTheSendPath() {
        // AtlantisCore: only SeqtaSend.swift itself. MCP helper, MCP server and Inbox: never.
        let core = Self.swiftFiles("AtlantisCore").filter { $0.lastPathComponent != "SeqtaSend.swift" }
        let others = Self.swiftFiles("AtlantisMCP") + Self.swiftFiles("Atlantis/MCP") + Self.swiftFiles("Atlantis/Inbox")
        for file in core + others {
            #expect(!Self.mentions(file, Self.needles), "\(file.lastPathComponent) must not reference the send path")
        }
    }

    @Test func onlyTheMessagesPageAndTheSyncEngineReachSend() {
        let allowed: Set<String> = ["SeqtaSync.swift", "SendConfirmSheet.swift", "ComposeView.swift", "MessagesModel.swift"]
        for file in Self.swiftFiles("Atlantis") where Self.mentions(file, Self.needles) {
            #expect(allowed.contains(file.lastPathComponent), "\(file.lastPathComponent) must not reference the send path")
        }
    }

    @Test func onlyTheConfirmSheetCreatesAConfirmation() {
        for file in Self.swiftFiles("Atlantis") + Self.swiftFiles("AtlantisCore") where Self.mentions(file, ["Confirmation(confirming"]) {
            #expect(["SendConfirmSheet.swift", "SeqtaSend.swift"].contains(file.lastPathComponent),
                    "\(file.lastPathComponent) must not make send confirmations")
        }
    }
}

@Suite struct MessageDraftTests {
    @Test func aDraftProposalOpensWithItsFields() {
        let item = InboxItem(kind: "message.draft", title: "Reply to Ms Example", source: "agent:school", fields: [
            .init(key: "to", value: "Ms Example, Mr Sample"), .init(key: "subject", value: "Excursion form"),
            .init(key: "body", value: "Hi,\\n\\nYes, I'll bring it."), .init(key: "reply-to", value: "8101"),
        ])
        let draft = MessageDraft(inbox: item)
        #expect(draft == MessageDraft(subject: "Excursion form", body: "Hi,\n\nYes, I'll bring it.",
                                      toNames: ["Ms Example", "Mr Sample"], replyTo: 8101))
    }

    @Test func aBareDraftFallsBackToItsTitle() {
        let draft = MessageDraft(inbox: InboxItem(kind: "message.draft", title: "Ask about the due date"))
        #expect(draft == MessageDraft(subject: "Ask about the due date"))
    }

    @Test func repliesGetOneRe() {
        #expect(MessageDraft.replySubject("Test results") == "Re: Test results")
        #expect(MessageDraft.replySubject("Re: Test results") == "Re: Test results")
        #expect(MessageDraft.replySubject("RE: x") == "RE: x")
    }
}
