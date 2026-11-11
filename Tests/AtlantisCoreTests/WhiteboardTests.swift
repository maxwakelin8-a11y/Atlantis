import Foundation
import Testing
@testable import AtlantisCore

// MARK: - Fixture

private final class BoardInbox: InboxPosting, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    func post(_ proposal: InboxProposal) async throws -> InboxReceipt {
        try lock.withLock {
            var file = InboxFile(text: try TextFile.read(url) ?? "")
            let item = proposal.makeItem()
            file.append(item)
            _ = try TextFile.write(file.text, to: url)
            return InboxReceipt(id: item.id)
        }
    }
}

@MainActor
private final class BoardFixture {
    let root: URL
    let boards: URL
    let vault: VaultPaths
    let inbox: BoardInbox
    let registry: ToolRegistry
    let events = Events()
    final class Events: @unchecked Sendable { var changed: [String] = []; var opened: [String] = [] }

    init(allow: Set<String> = []) throws {
        root = URL(fileURLWithPath: "/tmp/boards-\(UUID().uuidString.prefix(8))", isDirectory: true)
        boards = root.appendingPathComponent("Whiteboards", isDirectory: true)
        vault = VaultPaths(root: root.appendingPathComponent("vault"))
        try FileManager.default.createDirectory(at: vault.atlantisDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        try Data("# Tasks\n".utf8).write(to: vault.tasks)
        inbox = BoardInbox(url: vault.inbox)
        registry = ToolRegistry(inbox: inbox, allowList: StaticAllowList(allow))
        let store = TaskStore(vault: vault)
        nonisolated(unsafe) let tasks = store
        let boards = self.boards, vault = self.vault, events = self.events
        let context = MCPToolContext(
            vault: { vault }, writerRoot: { vault.root }, cache: SeqtaCache(root: root.appendingPathComponent("cache")),
            tasks: { tasks }, inbox: inbox,
            refreshSeqta: { SeqtaRefreshOutcome(ok: true, message: "") },
            exportDocument: { _, _, _ in },
            whiteboardRoot: { boards },
            boardChanged: { events.changed.append($0) },
            openBoard: { events.opened.append($0) })
        AtlantisTools.register(in: registry, context: context)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var files: WhiteboardFiles { WhiteboardFiles(root: boards) }

    func call(_ tool: String, _ args: JSONValue = [:]) async throws -> ToolResult {
        try await registry.callTool(name: tool, arguments: args)
    }

    func board(_ path: String) throws -> JSONValue {
        try WhiteboardScene.parse(try files.read(path))
    }
}

private func parsed(_ result: ToolResult) throws -> JSONValue { try JSONValue.parse(Data(result.text.utf8)) }
private func elements(_ board: JSONValue) -> [JSONValue] { board["elements"]?.arrayValue ?? [] }
private func element(_ board: JSONValue, _ id: String) -> JSONValue? { elements(board).first { $0["id"]?.stringValue == id } }

// MARK: - Files

@Suite struct WhiteboardFilesTests {
    let root = URL(fileURLWithPath: "/tmp/wbfiles-\(UUID().uuidString.prefix(8))", isDirectory: true)

    @Test func pathsStayInsideTheFolder() throws {
        #expect(try WhiteboardFiles.validate("Plan", addExtension: true) == "Plan.excalidraw")
        #expect(try WhiteboardFiles.validate("Science/Cells.excalidraw") == "Science/Cells.excalidraw")
        for bad in ["../x.excalidraw", "/etc/x.excalidraw", "~/x.excalidraw", "a/../../x.excalidraw", ".hidden.excalidraw",
                    "a/.b/x.excalidraw", "x.md", "", "a//b.excalidraw", "a\\b.excalidraw", "a/b/c/d/e.excalidraw", "x\u{0}.excalidraw"] {
            #expect(throws: WhiteboardFiles.Failure.badPath, "accepted \(bad)") { try WhiteboardFiles.validate(bad) }
        }
    }

    @Test func symlinksCantLeadOut() throws {
        let files = WhiteboardFiles(root: root)
        try files.ensureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: outside)
        #expect(throws: WhiteboardFiles.Failure.badPath) { try files.url("Link/x.excalidraw") }
        #expect(files.list().isEmpty)
    }

    @Test func createListRenameTrash() throws {
        let files = WhiteboardFiles(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try files.create()
        let second = try files.create()
        #expect(first == "Untitled board.excalidraw" && second == "Untitled board 2.excalidraw")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Science"), withIntermediateDirectories: true)
        let nested = try files.create(named: "Cells", in: "Science")
        #expect(Set(files.list().map(\.path)) == [first, second, nested])
        #expect(files.list().first { $0.path == nested }?.folder == "Science")
        #expect(try WhiteboardScene.parse(try files.read(first))["elements"] == [])

        let renamed = try files.rename(first, to: "Plan/../ideas")
        #expect(renamed == "Plan-..-ideas.excalidraw")
        #expect(throws: WhiteboardFiles.Failure.alreadyExists) { try files.rename(second, to: "Plan-..-ideas") }
        try files.trash(second)
        #expect(!files.exists(second))
    }

    @Test func saveRefusesWhenTheFileChangedSinceThePageSawIt() throws {
        let files = WhiteboardFiles(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try files.create()
        let original = try files.read(path)
        let seen = WhiteboardFiles.hash(original)

        #expect(try files.save(path, text: "{\"type\":\"excalidraw\",\"elements\":[1]}", expected: seen)
                == .saved(hash: WhiteboardFiles.hash("{\"type\":\"excalidraw\",\"elements\":[1]}")))
        // The page still thinks the file is `original`: refused, and it gets the file back to merge.
        let result = try files.save(path, text: "{\"elements\":[2]}", expected: seen)
        guard case .conflict(let text, _) = result else { Issue.record("expected a conflict"); return }
        #expect(text.contains("[1]"))
        #expect(try files.read(path).contains("[1]"))
        // Saving exactly what's there is never a conflict.
        #expect(try files.save(path, text: text, expected: "stale") == .saved(hash: WhiteboardFiles.hash(text)))
    }
}

// MARK: - Drawing

@Suite struct WhiteboardDrawTests {
    private func draw(_ elements: JSONValue, on current: String? = nil, position: String = "auto") throws -> JSONValue {
        let request = try WhiteboardDraw(arguments: ["board": "Test", "elements": elements, "position": .string(position)])
        return try WhiteboardScene.parse(try request.apply(to: current).text)
    }

    @Test func shapesGetBoundLabelsAndArrowsBindBothEnds() throws {
        let board = try draw([
            ["type": "rectangle", "id": "idea", "x": 0, "y": 0, "label": "Idea", "backgroundColor": "yellow"],
            ["type": "ellipse", "id": "test", "x": 300, "y": 0, "label": "Test it"],
            ["type": "arrow", "id": "go", "from": "idea", "to": "test", "label": "then"],
        ])
        let idea = try #require(element(board, "idea"))
        #expect(idea["backgroundColor"] == "#ffec99")
        #expect(idea["customData"]?[WhiteboardScene.layoutMark] == true)
        let labelRef = try #require(idea["boundElements"]?.arrayValue?.first { $0["type"] == "text" })
        let label = try #require(element(board, labelRef["id"]!.stringValue!))
        #expect(label["containerId"] == "idea" && label["text"] == "Idea" && label["fontFamily"] == 5)
        #expect(idea["boundElements"]?.arrayValue?.contains { $0["id"] == "go" && $0["type"] == "arrow" } == true)
        #expect(element(board, "test")?["boundElements"]?.arrayValue?.contains { $0["id"] == "go" } == true)

        let arrow = try #require(element(board, "go"))
        #expect(arrow["startBinding"]?["elementId"] == "idea" && arrow["endBinding"]?["elementId"] == "test")
        #expect(arrow["endArrowhead"] == "arrow" && arrow["startArrowhead"] == .null)
        // Starts at the box's right edge (x = 160) and ends at the ellipse's left edge (x = 300), plus gaps.
        let startX = try #require(arrow["x"]?.doubleValue)
        let dx = try #require(arrow["points"]?.arrayValue?.last?.arrayValue?.first?.doubleValue)
        #expect(abs(startX - 164) < 0.5 && abs(startX + dx - 296) < 0.5)
        // The label of the arrow, centred on it.
        #expect(elements(board).contains { $0["containerId"] == "go" && $0["text"] == "then" })
        // Labels come right after their shape (Excalidraw draws in array order).
        let ids = elements(board).compactMap { $0["id"]?.stringValue }
        #expect(ids.firstIndex(of: "idea")! + 1 == ids.firstIndex(of: labelRef["id"]!.stringValue!)!)
        #expect(board["type"] == "excalidraw")
    }

    @Test func newDrawingsGoNextToWhatsThereAndNothingOldChanges() throws {
        let first = try WhiteboardDraw(arguments: ["board": "Test", "elements": [["type": "rectangle", "id": "mine", "x": 0, "y": 50, "width": 200, "height": 100]]])
        let before = try first.apply(to: nil).text
        let board = try draw([["type": "rectangle", "id": "new", "x": 0, "y": 0]], on: before)
        #expect(element(board, "new")?["x"]?.doubleValue == 320) // 200 + 120 gap
        #expect(element(board, "new")?["y"]?.doubleValue == 50)
        #expect(element(board, "mine") == element(try WhiteboardScene.parse(before), "mine"))

        let absolute = try draw([["type": "rectangle", "id": "new", "x": 0, "y": 0]], on: before, position: "absolute")
        #expect(element(absolute, "new")?["x"]?.doubleValue == 0)
    }

    @Test func connectingToAnExistingShapeUpdatesOnlyItsBindings() throws {
        let before = try WhiteboardDraw(arguments: ["board": "T", "elements": [["type": "diamond", "id": "q", "x": 0, "y": 0, "width": 100, "height": 100]]])
            .apply(to: nil).text
        let old = try #require(element(try WhiteboardScene.parse(before), "q"))
        let board = try draw([["type": "text", "id": "note", "x": 300, "y": 40, "text": "Yes"],
                              ["type": "arrow", "from": "q", "to": "note"]], on: before)
        let q = try #require(element(board, "q"))
        #expect(q["version"]?.intValue == (old["version"]?.intValue ?? 0) + 1)
        #expect(q["x"] == old["x"] && q["width"] == old["width"])
        #expect(q["boundElements"]?.arrayValue?.count == 1)
        // Connected to existing shapes: placed where asked, not moved aside.
        #expect(element(board, "note")?["x"]?.doubleValue == 300)
    }

    @Test func freeLinesUsePoints() throws {
        let board = try draw([["type": "line", "id": "l", "x": 10, "y": 20, "points": [[0, 0], [100, 50], [200, 0]], "strokeStyle": "dashed"]])
        let line = try #require(element(board, "l"))
        #expect(line["points"]?.arrayValue?.count == 3)
        #expect(line["width"]?.doubleValue == 200 && line["height"]?.doubleValue == 50)
        #expect(line["endArrowhead"] == .null && line["strokeStyle"] == "dashed")
    }

    @Test func badSpecsAreRefusedWithAReason() throws {
        let cases: [JSONValue] = [
            [["type": "star", "x": 0, "y": 0]],
            [["type": "rectangle"]],
            [["type": "text", "x": 0, "y": 0]],
            [["type": "arrow", "from": "nope"]],
            [["type": "arrow", "from": "a", "to": "b"]],
            [["type": "rectangle", "x": 0, "y": 0, "id": "a b"]],
            [["type": "rectangle", "x": 0, "y": 0, "id": "a"], ["type": "ellipse", "x": 0, "y": 0, "id": "a"]],
            [["type": "rectangle", "x": 0, "y": 0, "strokeColor": "rainbow"]],
            [["type": "rectangle", "x": .double(.infinity), "y": 0]],
            [["type": "rectangle", "x": 0, "y": 0, "width": 0]],
            [],
        ]
        for spec in cases {
            #expect(throws: ToolFailure.self, "accepted \(spec)") { _ = try draw(spec) }
        }
        let many = JSONValue.array(Array(repeating: ["type": "rectangle", "x": 0, "y": 0], count: 301))
        #expect(throws: ToolFailure.self) { _ = try draw(many) }
    }

    @Test func summaryFoldsLabelsAndShowsConnections() throws {
        let board = try draw([
            ["type": "rectangle", "id": "a", "x": 0, "y": 0, "label": "Start"],
            ["type": "rectangle", "id": "b", "x": 300, "y": 0, "label": "End"],
            ["type": "arrow", "id": "ab", "from": "a", "to": "b"],
            ["type": "text", "id": "t", "x": 0, "y": 200, "text": "Note"],
        ])
        let summary = WhiteboardScene.summary(board)
        let items = summary["elements"]?.arrayValue ?? []
        #expect(items.count == 4) // labels are folded into their shapes
        #expect(items.first { $0["id"] == "a" }?["label"] == "Start")
        #expect(items.first { $0["id"] == "ab" }?["from"] == "a" && items.first { $0["id"] == "ab" }?["to"] == "b")
        #expect(items.first { $0["id"] == "t" }?["text"] == "Note")
        #expect(summary["bounds"]?["x"] == 0)
    }

    @Test func roughTextSizeGrowsWithText() {
        let short = WhiteboardBuilder.textSize("Hi", fontSize: 20)
        let long = WhiteboardBuilder.textSize("Hello there\nsecond line", fontSize: 20)
        #expect(long.width > short.width && long.height == 50)
    }
}

// MARK: - Tools

@MainActor
@Suite struct WhiteboardToolTests {
    let spec: JSONValue = [["type": "rectangle", "id": "a", "x": 0, "y": 0, "label": "A"],
                           ["type": "rectangle", "id": "b", "x": 300, "y": 0, "label": "B"],
                           ["type": "arrow", "from": "a", "to": "b"]]

    @Test func drawingWaitsInTheInboxUntilAllowedThenAcceptApplies() async throws {
        let f = try BoardFixture()
        let result = try await f.call("atlantis_whiteboard_draw", ["board": "Science/Flow", "elements": spec])
        #expect(!result.isError && result.text.contains("Inbox"))
        #expect(!f.files.exists("Science/Flow.excalidraw"))
        let item = try #require(InboxFile(text: try TextFile.read(f.vault.inbox) ?? "").items.first)
        #expect(item.kind == "whiteboard.draw" && item.title.contains("New board"))

        var changed: [String] = []
        try InboxActions(tasks: TaskStore(vault: f.vault), whiteboardRoot: { f.boards }, boardChanged: { changed.append($0) }).apply(item)
        #expect(changed == ["Science/Flow.excalidraw"])
        #expect(elements(try f.board("Science/Flow.excalidraw")).count == 5) // 2 boxes, 2 labels, 1 arrow
    }

    @Test func allowedDrawingWritesAndTellsTheApp() async throws {
        let f = try BoardFixture(allow: ["atlantis_whiteboard_draw"])
        let out = try parsed(try await f.call("atlantis_whiteboard_draw", ["board": "Plan", "elements": spec]))
        #expect(out["created_board"] == true && out["added"] == 3)
        #expect(f.events.changed == ["Plan.excalidraw"])
        // Drawing again adds; the first drawing is still there.
        _ = try await f.call("atlantis_whiteboard_draw", ["board": "Plan.excalidraw", "elements": [["type": "text", "x": 0, "y": 0, "text": "More"]]])
        #expect(elements(try f.board("Plan.excalidraw")).count == 6)

        let read = try parsed(try await f.call("atlantis_whiteboard_read", ["board": "Plan"]))
        #expect(read["count"] == 4)
        #expect(read["elements"]?.arrayValue?.contains { $0["label"] == "A" } == true)
        let raw = try parsed(try await f.call("atlantis_whiteboard_read", ["board": "Plan.excalidraw", "raw": true]))
        #expect(raw["json"]?.stringValue?.contains("\"excalidraw\"") == true)

        let list = try parsed(try await f.call("atlantis_whiteboards_list"))
        #expect(list["boards"]?.arrayValue?.first?["board"] == "Plan.excalidraw")

        let open = try await f.call("atlantis_whiteboard_open", ["board": "Plan"])
        #expect(!open.isError && f.events.opened == ["Plan.excalidraw"])
        #expect(try await f.call("atlantis_whiteboard_open", ["board": "Nope"]).isError)
    }

    @Test func badRequestsFailBeforeTheInbox() async throws {
        let f = try BoardFixture()
        let bad = try await f.call("atlantis_whiteboard_draw", ["board": "Plan", "elements": [["type": "arrow", "from": "x"]]])
        #expect(bad.isError)
        let ghost = try await f.call("atlantis_whiteboard_draw", ["board": "Plan", "elements": [["type": "arrow", "from": "ghost", "to": "boo"]]])
        #expect(ghost.isError && ghost.text.contains("ghost"))
        #expect((try TextFile.read(f.vault.inbox) ?? "").isEmpty)
    }

    @Test func pathTraversalIsRefusedOnEveryBoardTool() async throws {
        let f = try BoardFixture(allow: ["atlantis_whiteboard_draw"])
        let secret = f.root.appendingPathComponent("secret.excalidraw")
        try Data("{\"type\":\"excalidraw\",\"elements\":[],\"secret\":\"top secret\"}".utf8).write(to: secret)
        for path in ["../secret.excalidraw", "/tmp/x.excalidraw", "a/../../secret", "~/x", ".x"] {
            for tool in ["atlantis_whiteboard_read", "atlantis_whiteboard_draw", "atlantis_whiteboard_open"] {
                let result = try await f.call(tool, ["board": .string(path), "elements": spec])
                #expect(result.isError, "\(tool) accepted \(path)")
                #expect(!result.text.contains("top secret"))
            }
        }
        #expect(try String(contentsOf: secret, encoding: .utf8).contains("top secret"))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("x.excalidraw").path))
    }
}
