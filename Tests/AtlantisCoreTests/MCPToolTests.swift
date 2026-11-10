import Foundation
import Testing
@testable import AtlantisCore

// MARK: - Fixtures

/// Appends proposals to a real `inbox.md` in a temp vault, like the app's Inbox store does.
private final class FileInbox: InboxPosting, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var counter = 0
    init(url: URL) { self.url = url }

    func post(_ proposal: InboxProposal) async throws -> InboxReceipt {
        try lock.withLock {
            var file = InboxFile(text: try TextFile.read(url) ?? "")
            let item = proposal.makeItem()
            counter += 1
            file.append(item)
            _ = try TextFile.write(file.text, to: url)
            return InboxReceipt(id: item.id)
        }
    }
}

/// A temp vault, SEQTA cache and Writer folder with the full tool set registered.
@MainActor
private final class Fixture {
    let root: URL
    let vault: VaultPaths
    let writerRoot: URL
    let cache: SeqtaCache
    let store: TaskStore
    let registry: ToolRegistry
    let inbox: FileInbox
    let counter = Counter()
    final class Counter: @unchecked Sendable { var refreshes = 0; var exports: [(String, URL)] = [] }

    nonisolated static let now = Date(timeIntervalSince1970: 1_794_000_000) // mid Nov 2026

    init(allow: Set<String> = []) throws {
        root = URL(fileURLWithPath: "/tmp/mcptools-\(UUID().uuidString.prefix(8))", isDirectory: true)
        vault = VaultPaths(root: root.appendingPathComponent("vault"))
        writerRoot = root.appendingPathComponent("Writer", isDirectory: true)
        try FileManager.default.createDirectory(at: vault.atlantisDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: writerRoot.appendingPathComponent("Essays"), withIntermediateDirectories: true)
        try Data("# Tasks\n\n- [ ] Essay [due:: 2026-11-12] ^t-00000001\n".utf8).write(to: vault.tasks)
        try Data("# Essay\n\nThe sea is deep.\n".utf8).write(to: writerRoot.appendingPathComponent("Essays/Sea.md"))
        cache = SeqtaCache(root: root.appendingPathComponent("cache"))
        store = TaskStore(vault: vault, now: { Self.now })
        inbox = FileInbox(url: vault.inbox)
        registry = ToolRegistry(inbox: inbox, allowList: StaticAllowList(allow))
        CoreTools.register(in: registry, appVersion: "t", inbox: inbox)
        nonisolated(unsafe) let store = self.store
        let counter = self.counter
        let writer = writerRoot, vault = self.vault
        let context = MCPToolContext(
            vault: { vault }, writerRoot: { writer }, cache: cache, tasks: { store }, inbox: inbox,
            refreshSeqta: { counter.refreshes += 1; return SeqtaRefreshOutcome(ok: true, message: "Synced.") },
            exportDocument: { html, format, target in
                counter.exports.append((format, target))
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(html.utf8).write(to: target)
            },
            now: { Self.now })
        AtlantisTools.register(in: registry, context: context)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func call(_ tool: String, _ args: JSONValue = [:]) async throws -> ToolResult {
        try await registry.callTool(name: tool, arguments: args)
    }

    func inboxItems() throws -> [InboxItem] {
        InboxFile(text: try TextFile.read(vault.inbox) ?? "").items
    }

    var today: String { DayStamp(Self.now).description }
    func day(_ offset: Int) -> String { DayStamp(Self.now).adding(days: offset).description }

    func seedSchoolData() throws {
        try cache.save([
            Lesson(id: "l1", date: today, from: "09:00", until: "10:00", subject: "Maths", code: "9MAT", room: "M3", teacher: "Ms Lee"),
            Lesson(id: "l2", date: day(1), from: "09:00", until: "10:00", subject: "Science", code: "9SCI"),
        ], kind: .lessons, syncedAt: Self.now)
        try cache.save([
            Assessment(id: 7, title: "Algebra test", subject: "Maths", code: "9MAT", due: day(3), status: "OVERDUE"),
            Assessment(id: 8, title: "Old essay", subject: "English", code: "9ENG", due: day(-20), status: "MARKS_RELEASED"),
        ], kind: .assessments, syncedAt: Self.now)
        try cache.save([Notice(id: 1, date: today, title: "Sport carnival", staff: "Office", contents: "Wear house colours.")],
                       kind: .notices, syncedAt: Self.now)
        try cache.save([Subject(code: "9MAT", name: "Maths", teacher: "Ms Lee", programme: 1, metaclass: 2)], kind: .subjects, syncedAt: Self.now)
        try cache.save([MessageSummary(id: 5, sender: "Mr Smith", subject: "Excursion form", read: false)],
                       kind: .messages, syncedAt: Self.now)
    }
}

private func text(_ result: ToolResult) -> String { result.text }
private func parsed(_ result: ToolResult) throws -> JSONValue { try JSONValue.parse(Data(result.text.utf8)) }

// MARK: - Registration

@MainActor
@Suite struct MCPToolRegistrationTests {
    @Test func everyToolInThePRDTableIsRegisteredWithASchemaAndDescription() async throws {
        let f = try Fixture()
        let tools = try await f.registry.listTools()
        let names = Set(tools.map(\.name))
        for name in AtlantisTools.names { #expect(names.contains(name), "missing \(name)") }
        for tool in tools {
            #expect(tool.description.count > 20, "\(tool.name) needs a real description")
            #expect(tool.inputSchema["type"] == "object")
        }
        let gated = Set(tools.filter { $0.kind == .gatedWrite }.map(\.name))
        #expect(gated == Set(GatedAction.allCases.map(\.rawValue)))
    }

    @Test func noToolCanSendASchoolMessage() async throws {
        let f = try Fixture()
        let names = try await f.registry.listTools().map(\.name)
        #expect(!names.contains { $0.contains("send") })
    }
}

// MARK: - Tasks and the gate

@MainActor
@Suite struct MCPTaskToolTests {
    @Test func tasksListFiltersAndShowsIDs() async throws {
        let f = try Fixture()
        let all = try parsed(try await f.call("atlantis_tasks_list"))
        #expect(all["count"] == 1)
        #expect(all["tasks"]?.arrayValue?.first?["id"] == "t-00000001")
        let none = try parsed(try await f.call("atlantis_tasks_list", ["project": "Nope"]))
        #expect(none["count"] == 0)
        let bad = try await f.call("atlantis_tasks_list", ["status": "weird"])
        #expect(bad.isError)
    }

    @Test func taskAddIsAnInboxProposalByDefaultAndWritesNothing() async throws {
        let f = try Fixture()
        let before = try String(contentsOf: f.vault.tasks, encoding: .utf8)
        let result = try await f.call("atlantis_task_add", ["title": "Read chapter 3", "due": "2026-11-20", "pri": 2])
        #expect(!result.isError && result.text.contains("Inbox"))
        #expect(try String(contentsOf: f.vault.tasks, encoding: .utf8) == before)
        let item = try #require(try f.inboxItems().first)
        #expect(item.kind == "task.add" && item.title == "Read chapter 3")
        #expect(item.field("due") == "2026-11-20" && item.field("pri") == "2")
        #expect(item.source.hasPrefix("mcp"))
    }

    @Test func taskAddRunsWhenAllowed() async throws {
        let f = try Fixture(allow: ["atlantis_task_add"])
        let result = try await f.call("atlantis_task_add", ["title": "Read chapter 3", "est": "45m", "mode": "school"])
        #expect(!result.isError)
        #expect(try parsed(result)["added"] == true)
        let file = try String(contentsOf: f.vault.tasks, encoding: .utf8)
        #expect(file.contains("Read chapter 3") && file.contains("[est:: 45m]") && file.contains("[source:: mcp"))
        #expect(try f.inboxItems().isEmpty)
    }

    @Test func taskUpdateIsGatedAndAcceptedProposalsApply() async throws {
        let f = try Fixture()
        let result = try await f.call("atlantis_task_update", ["id": "t-00000001", "status": "done", "due": "none"])
        #expect(result.text.contains("Inbox"))
        let item = try #require(try f.inboxItems().first)
        #expect(item.kind == "task.update" && item.field("task") == "t-00000001")
        // Accepting it (InboxActions) completes the task.
        try InboxActions(tasks: f.store).apply(item)
        let task = try #require(f.store.tasks.first)
        #expect(task.isDone && task.due == nil)
    }

    @Test func acceptedTaskAddProposalAddsTheTask() async throws {
        let f = try Fixture()
        _ = try await f.call("atlantis_task_add", ["title": "Pack bag", "project": "Camp"])
        let item = try #require(try f.inboxItems().first)
        try InboxActions(tasks: f.store).apply(item)
        let added = try #require(f.store.tasks.first { $0.title == "Pack bag" })
        #expect(added.project == "Camp")
    }

    @Test func taskUpdateRunsWhenAllowedAndRejectsUnknownIDs() async throws {
        let f = try Fixture(allow: ["atlantis_task_update"])
        let ok = try await f.call("atlantis_task_update", ["id": "t-00000001", "title": "Essay v2"])
        #expect(!ok.isError)
        #expect(try String(contentsOf: f.vault.tasks, encoding: .utf8).contains("Essay v2"))
        let missing = try await f.call("atlantis_task_update", ["id": "t-99999999", "status": "done"])
        #expect(missing.isError)
        let empty = try await f.call("atlantis_task_update", ["id": "t-00000001"])
        #expect(empty.isError)
    }

    @Test func gateIsPerAction() async throws {
        let f = try Fixture(allow: ["atlantis_task_add"])
        let update = try await f.call("atlantis_task_update", ["id": "t-00000001", "status": "done"])
        #expect(update.text.contains("Inbox"))
        let docs = try await f.call("atlantis_doc_write", ["path": "Essays/New", "text": "Hi"])
        #expect(docs.text.contains("Inbox"))
        #expect(!FileManager.default.fileExists(atPath: f.writerRoot.appendingPathComponent("Essays/New.md").path))
    }

    @Test func inputsAreValidated() async throws {
        let f = try Fixture(allow: ["atlantis_task_add"])
        for args: JSONValue in [
            [:], ["title": ""], ["title": .string(String(repeating: "x", count: 5_000))],
            ["title": "t", "due": "tomorrow"], ["title": "t", "pri": 9],
            ["title": "t", "est": "lots"], ["title": "t", "mode": "dancing"], ["title": "t", "project": "a]b"],
        ] {
            let result = try await f.call("atlantis_task_add", args)
            #expect(result.isError, "should refuse \(args)")
        }
        #expect(try String(contentsOf: f.vault.tasks, encoding: .utf8).split(separator: "\n").count == 2)
    }

    @Test func todayCombinesLessonsTasksAndAssessments() async throws {
        let f = try Fixture()
        try f.seedSchoolData()
        let today = try parsed(try await f.call("atlantis_today"))
        #expect(today["date"]?.stringValue == f.today)
        #expect(today["schedule"]?.arrayValue?.first?["subject"] == "Maths")
        #expect(today["assessments"]?.arrayValue?.first?["title"] == "Algebra test")
        #expect(today["notices"]?.arrayValue?.count == 1)
        let tomorrow = try parsed(try await f.call("atlantis_today", ["date": .string(f.day(1))]))
        #expect(tomorrow["schedule"]?.arrayValue?.first?["subject"] == "Science")
        #expect(try await f.call("atlantis_today", ["date": "soon"]).isError)
    }
}

// MARK: - Inbox and school

@MainActor
@Suite struct MCPInboxAndSchoolToolTests {
    @Test func inboxPostAndListRoundTrip() async throws {
        let f = try Fixture()
        let posted = try await f.call("atlantis_inbox_post", ["title": "Look at this", "body": "line1\nline2 [x]"])
        #expect(!posted.isError)
        let listed = try parsed(try await f.call("atlantis_inbox_list"))
        #expect(listed["count"] == 1)
        #expect(listed["items"]?.arrayValue?.first?["title"] == "Look at this")
        let dismissed = try parsed(try await f.call("atlantis_inbox_list", ["state": "dismissed"]))
        #expect(dismissed["count"] == 0)
    }

    @Test func messageDraftOnlyEverBecomesAnInboxDraft() async throws {
        let f = try Fixture(allow: ["atlantis_task_add", "atlantis_task_update", "atlantis_doc_write"])
        let result = try await f.call("atlantis_message_draft", ["to": "Mr Smith", "subject": "Excursion", "body": "Hello,\nCan I hand it in Monday?", "reply_to": 5])
        #expect(!result.isError && result.text.contains("nothing was sent"))
        let item = try #require(try f.inboxItems().first)
        #expect(item.kind == "message.draft" && item.field("reply-to") == "5")
        // The compose view (MessageDraft) must read it back as typed.
        let draft = MessageDraft(inbox: item)
        #expect(draft.subject == "Excursion" && draft.toNames == ["Mr Smith"] && draft.replyTo == 5)
        #expect(draft.body == "Hello,\nCan I hand it in Monday?")
        #expect(try await f.call("atlantis_message_draft", ["subject": "x"]).isError) // no body
    }

    @Test func schoolToolsReadTheCacheOnly() async throws {
        let f = try Fixture()
        // Nothing cached yet: a clear message, not a crash.
        let empty = try await f.call("atlantis_school_timetable")
        #expect(!empty.isError || empty.text.contains("sync") || empty.text.contains("No "))
        try f.seedSchoolData()

        let timetable = try parsed(try await f.call("atlantis_school_timetable", ["from": .string(f.today), "to": .string(f.day(2))]))
        #expect(timetable.encodedString.contains("Maths") && timetable.encodedString.contains("Science"))
        let maths = try parsed(try await f.call("atlantis_school_timetable", ["subject": "maths"]))
        #expect(!maths.encodedString.contains("Science"))

        let upcoming = try parsed(try await f.call("atlantis_school_assessments"))
        #expect(upcoming.encodedString.contains("Algebra test") && !upcoming.encodedString.contains("Old essay"))
        let past = try parsed(try await f.call("atlantis_school_assessments", ["when": "past"]))
        #expect(past.encodedString.contains("Old essay"))
        #expect(try await f.call("atlantis_school_assessments", ["id": 7]).text.contains("Algebra test"))

        try f.cache.save([SubjectFile(subjectCode: "9MAT", name: "Outline.pdf", uuid: "u1", source: "Course outline")],
                         kind: .files, syncedAt: Fixture.now)
        try f.cache.saveMessage(Message(summary: MessageSummary(id: 5, sender: "Mr Smith", subject: "Excursion form"),
                                        recipients: ["Me"], body: "Please return the form."))
        let subjects = try await f.call("atlantis_school_subjects")
        #expect(subjects.text.contains("Maths") && subjects.text.contains("Outline.pdf"))
        #expect(try await f.call("atlantis_school_messages", ["id": 5]).text.contains("Please return the form."))
        #expect(try await f.call("atlantis_school_messages").text.contains("Please return") == false)
        #expect(try await f.call("atlantis_school_notices").text.contains("Sport carnival"))
        #expect(try await f.call("atlantis_school_messages").text.contains("Excursion form"))
        #expect(try await f.call("atlantis_school_messages", ["from": "nobody"]).text.contains("Excursion form") == false)
    }

    @Test func seqtaRefreshRespectsTheRateLimit() async throws {
        let f = try Fixture()
        let first = try await f.call("atlantis_seqta_refresh")
        #expect(!first.isError)
        #expect(f.counter.refreshes == 1)
        // The sync just wrote the cache (the stub doesn't), so mark it fresh and call again.
        try f.cache.updateMeta { $0.lastSync = Fixture.now.addingTimeInterval(-60) }
        let second = try parsed(try await f.call("atlantis_seqta_refresh"))
        #expect(second["refreshed"] == false)
        #expect(f.counter.refreshes == 1)
    }
}

// MARK: - Docs

@MainActor
@Suite struct MCPDocToolTests {
    @Test func listSearchAndRead() async throws {
        let f = try Fixture()
        let projects = try await f.call("atlantis_docs_list")
        #expect(projects.text.contains("Essays"))
        let docs = try await f.call("atlantis_docs_list", ["project": "Essays"])
        #expect(docs.text.contains("Sea.md"))
        let found = try await f.call("atlantis_docs_search", ["query": "deep"])
        #expect(found.text.contains("Sea"))
        let read = try await f.call("atlantis_doc_read", ["path": "Essays/Sea.md"])
        #expect(read.text.contains("The sea is deep."))
        #expect(try await f.call("atlantis_doc_read", ["path": "Essays/Nope.md"]).isError)
        #expect(try await f.call("atlantis_docs_search", ["query": ""]).isError)
    }

    @Test func pathTraversalIsRefusedOnEveryDocTool() async throws {
        let f = try Fixture(allow: ["atlantis_doc_write"])
        let secret = f.root.appendingPathComponent("secret.md")
        try Data("top secret".utf8).write(to: secret)
        let bad = ["../secret.md", "Essays/../../secret.md", "/etc/passwd", "~/x.md", "Essays//..//..//secret.md", "..", "", "Essays/Sea.md\u{0}.png"]
        for path in bad {
            for tool in ["atlantis_doc_read", "atlantis_doc_export", "atlantis_doc_write"] {
                var args: [String: JSONValue] = ["path": .string(path), "format": "pdf", "text": "owned"]
                if tool == "atlantis_doc_read" { args["format"] = nil; args["text"] = nil }
                let result = try await f.call(tool, .object(args))
                #expect(result.isError, "\(tool) accepted \(path)")
                #expect(!result.text.contains("top secret"))
            }
        }
        #expect(try String(contentsOf: secret, encoding: .utf8) == "top secret")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Writer/../secret2.md").path))
        let docsList = try await f.call("atlantis_docs_list", ["project": "../vault"])
        #expect(docsList.isError)
    }

    @Test func symlinkOutOfTheWriterFolderIsRefused() async throws {
        let f = try Fixture()
        let outside = f.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside text".utf8).write(to: outside.appendingPathComponent("o.md"))
        try FileManager.default.createSymbolicLink(at: f.writerRoot.appendingPathComponent("Essays/link"), withDestinationURL: outside)
        let result = try await f.call("atlantis_doc_read", ["path": "Essays/link/o.md"])
        #expect(result.isError && !result.text.contains("outside text"))
    }

    @Test func docWriteBecomesAProposalWithTheFullText() async throws {
        let f = try Fixture()
        let result = try await f.call("atlantis_doc_write", ["path": "Essays/Reef", "text": "# Reef\n\nCoral [here]."])
        #expect(result.text.contains("Inbox"))
        #expect(!FileManager.default.fileExists(atPath: f.writerRoot.appendingPathComponent("Essays/Reef.md").path))
        let item = try #require(try f.inboxItems().first)
        #expect(item.kind == "doc.edit")
        // Accepting it creates the doc.
        try InboxActions(tasks: f.store, writerRoot: { f.writerRoot }).apply(item)
        #expect(try String(contentsOf: f.writerRoot.appendingPathComponent("Essays/Reef.md"), encoding: .utf8) == "# Reef\n\nCoral [here].")
    }

    @Test func allowedDocWriteCreatesButNeverOverwrites() async throws {
        let f = try Fixture(allow: ["atlantis_doc_write"])
        let created = try await f.call("atlantis_doc_write", ["path": "Essays/Reef.md", "text": "# Reef"])
        #expect(try parsed(created)["created"] == true)
        #expect(try String(contentsOf: f.writerRoot.appendingPathComponent("Essays/Reef.md"), encoding: .utf8) == "# Reef")
        #expect(try f.inboxItems().isEmpty)

        let original = try String(contentsOf: f.writerRoot.appendingPathComponent("Essays/Sea.md"), encoding: .utf8)
        let replace = try await f.call("atlantis_doc_write", ["path": "Essays/Sea.md", "text": "# New"])
        #expect(replace.text.contains("Inbox"))
        #expect(try String(contentsOf: f.writerRoot.appendingPathComponent("Essays/Sea.md"), encoding: .utf8) == original)
        let item = try #require(try f.inboxItems().first)
        #expect(item.kind == "doc.edit" && item.field("mode") == "replace")
    }

    @Test func acceptingAReplaceRefusesIfTheDocChangedMeanwhile() async throws {
        let f = try Fixture()
        _ = try await f.call("atlantis_doc_write", ["path": "Essays/Sea.md", "text": "# Rewritten"])
        let item = try #require(try f.inboxItems().first)
        try Data("# Edited by the user meanwhile".utf8).write(to: f.writerRoot.appendingPathComponent("Essays/Sea.md"))
        #expect(throws: (any Error).self) { try InboxActions(tasks: f.store, writerRoot: { f.writerRoot }).apply(item) }
        #expect(try String(contentsOf: f.writerRoot.appendingPathComponent("Essays/Sea.md"), encoding: .utf8) == "# Edited by the user meanwhile")
    }

    @Test func docWriteInputsAreValidated() async throws {
        let f = try Fixture(allow: ["atlantis_doc_write"])
        let big = String(repeating: "x", count: 60_000)
        for args: JSONValue in [
            ["path": "Essays/A", "text": .string(big)], ["path": "Essays/A", "text": "nul\u{0}"],
            ["path": "Essays/A"], ["text": "x"], ["path": "NoSuchProject/A", "text": "x"],
            ["path": "Essays/bad.exe", "text": "x"],
        ] {
            #expect(try await f.call("atlantis_doc_write", args).isError, "should refuse \(args)")
        }
    }

    @Test func exportSavesIntoTheProjectsExportsFolder() async throws {
        let f = try Fixture()
        let result = try parsed(try await f.call("atlantis_doc_export", ["path": "Essays/Sea.md", "format": "docx"]))
        #expect(result["exported"] == true)
        #expect(f.counter.exports.count == 1)
        let target = f.counter.exports[0].1
        #expect(target.path.hasPrefix(f.writerRoot.resolvingSymlinksInPath().path) || target.path.hasPrefix(f.writerRoot.path))
        #expect(target.path.contains("/Essays/Exports/"))
        #expect(try await f.call("atlantis_doc_export", ["path": "Essays/Sea.md", "format": "exe"]).isError)
    }
}

// MARK: - End to end over the socket

@MainActor
@Suite(.serialized) struct MCPEndToEndTests {
    @Test func taskAddOverTheSocketLandsInInboxMd() async throws {
        let f = try Fixture()
        let dir = URL(fileURLWithPath: "/tmp/atl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let server = MCPSocketServer(socketURL: dir.appendingPathComponent("mcp.sock"),
                                     handler: MCPProtocolHandler(backend: f.registry),
                                     maxConnections: 8, requestTimeout: 5)
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        let client = MCPSocketClient(path: server.socketURL.path)

        let initialize = JSONRPCRequest(id: .number(1), method: "initialize", params: [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "e2e-test", "version": "1"],
        ]).encoded()
        _ = try await client.send(initialize)
        let call = JSONRPCRequest(id: .number(2), method: "tools/call", params: [
            "name": "atlantis_task_add", "arguments": ["title": "Over the socket", "due": "2026-11-30"],
        ]).encoded()
        let reply = try JSONValue.parse(try #require(try await client.send(call)))
        #expect(reply["result"]?["isError"] != true)
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("Inbox") == true)

        let item = try #require(try f.inboxItems().first)
        #expect(item.source == "mcp:e2e-test")
        #expect(item.kind == "task.add" && item.title == "Over the socket" && item.field("due") == "2026-11-30")
        #expect(!(try String(contentsOf: f.vault.tasks, encoding: .utf8)).contains("Over the socket"))
    }
}

private extension JSONValue {
    var encodedString: String { String(decoding: encoded(), as: UTF8.self) }
}
