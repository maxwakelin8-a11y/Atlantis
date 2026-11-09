import Darwin
import Foundation
import Testing
@testable import AtlantisCore

// MARK: - Helpers

private func request(_ method: String, id: Int? = 1, params: JSONValue? = nil) -> Data {
    JSONRPCRequest(id: id.map { .number($0) }, method: method, params: params).encoded()
}

private func json(_ data: Data?) throws -> JSONValue {
    try JSONValue.parse(try #require(data))
}

private func makeRegistry(inbox: any InboxPosting = InMemoryInboxPosting(),
                          allow: Set<String> = []) -> ToolRegistry {
    let registry = ToolRegistry(inbox: inbox, allowList: StaticAllowList(allow))
    CoreTools.register(in: registry, appVersion: "9.9", inbox: inbox)
    return registry
}

/// Short path: unix socket paths top out near 100 bytes.
private func tempSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/atl-\(UUID().uuidString.prefix(8))", isDirectory: true).appendingPathComponent("mcp.sock")
}

// MARK: - JSON and JSON-RPC

@Suite struct JSONRPCTests {
    @Test func jsonValueRoundTrips() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x", 2.5], "c": ["d": "é\n"]]
        #expect(try JSONValue.parse(value.encoded()) == value)
        #expect(!String(decoding: value.encoded(), as: UTF8.self).contains("\n")) // one line
    }

    @Test func parsesRequestsAndNotifications() {
        guard case .request(let r) = JSONRPCIncoming.parse(request("ping", id: 7)) else { Issue.record("not a request"); return }
        #expect(r.method == "ping" && r.id == .number(7) && !r.isNotification)
        guard case .request(let n) = JSONRPCIncoming.parse(request("notifications/initialized", id: nil)) else { Issue.record("not a request"); return }
        #expect(n.isNotification)
        let stringID = Data(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#.utf8)
        guard case .request(let s) = JSONRPCIncoming.parse(stringID) else { Issue.record("not a request"); return }
        #expect(s.id == .string("abc"))
    }

    @Test func rejectsBadMessages() {
        func error(_ text: String) -> (JSONRPCID?, Int)? {
            if case .invalid(let id, let e) = JSONRPCIncoming.parse(Data(text.utf8)) { return (id, e.code) }
            return nil
        }
        #expect(error("{nope")?.1 == JSONRPCError.parseErrorCode)
        #expect(error("[1,2]")?.1 == JSONRPCError.invalidRequestCode)       // batches unsupported
        #expect(error("42")?.1 == JSONRPCError.invalidRequestCode)
        #expect(error(#"{"id":3,"method":"ping"}"#)?.1 == JSONRPCError.invalidRequestCode) // no jsonrpc
        #expect(error(#"{"id":3,"method":"ping"}"#)?.0 == .number(3))        // id kept for the reply
        #expect(error(#"{"jsonrpc":"2.0","id":3}"#)?.1 == JSONRPCError.invalidRequestCode) // no method
        #expect(error(#"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#)?.1 == JSONRPCError.invalidRequestCode)
        #expect(error(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":5}"#)?.1 == JSONRPCError.invalidParamsCode)
    }

    @Test func responsesAreIgnored() {
        #expect(JSONRPCIncoming.parse(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == .response)
    }
}

// MARK: - Framing

@Suite struct FramingTests {
    @Test func bufferSplitsFramesAcrossChunks() throws {
        let a = Data("hello".utf8), b = Data("world!".utf8)
        let wire = Framing.encode(a) + Framing.encode(b)
        var buffer = FrameBuffer()
        buffer.append(wire.prefix(3))                // part of the header
        #expect(try buffer.nextFrame() == nil)
        buffer.append(wire.dropFirst(3).prefix(5))   // header + part of the body
        #expect(try buffer.nextFrame() == nil)
        buffer.append(wire.dropFirst(8))
        #expect(try buffer.nextFrame() == a)
        #expect(try buffer.nextFrame() == b)
        #expect(try buffer.nextFrame() == nil)
    }

    @Test func emptyFrameIsAllowed() throws {
        var buffer = FrameBuffer()
        buffer.append(Framing.encode(Data()))
        #expect(try buffer.nextFrame() == Data())
    }

    @Test func oversizedFrameIsRefused() {
        var buffer = FrameBuffer()
        var length = UInt32(Framing.maxFrameSize + 1).bigEndian
        buffer.append(Data(bytes: &length, count: 4))
        #expect(throws: Framing.Failure.self) { try buffer.nextFrame() }
    }

    @Test func blockingReadWriteOverASocketPair() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let payload = Data(repeating: 0x61, count: 200_000) // bigger than the socket buffer
        let writeEnd = fds[0]
        let writer = Thread { try? Framing.writeFrame(payload, to: writeEnd) }
        writer.start()
        #expect(try Framing.readFrame(from: fds[1]) == payload)
    }

    @Test func closedPeerIsReported() {
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        close(fds[0]); defer { close(fds[1]) }
        #expect(throws: Framing.Failure.closed) { try Framing.readFrame(from: fds[1]) }
    }
}

// MARK: - Protocol handler

@Suite struct MCPProtocolTests {
    let handler = MCPProtocolHandler(backend: makeRegistry())

    @Test func initializeNegotiatesVersion() async throws {
        let reply = try json(await handler.handle(request("initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])))
        #expect(reply["id"] == 1)
        #expect(reply["result"]?["protocolVersion"] == "2025-06-18")
        #expect(reply["result"]?["serverInfo"]?["name"] == "atlantis")
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)
        let other = try json(await handler.handle(request("initialize", params: ["protocolVersion": "1999-01-01"])))
        #expect(other["result"]?["protocolVersion"] == "2025-06-18") // falls back to ours
    }

    @Test func initializeNeedsParams() async throws {
        let reply = try json(await handler.handle(request("initialize")))
        #expect(reply["error"]?["code"]?.intValue == JSONRPCError.invalidParamsCode)
    }

    @Test func notificationsGetNoReply() async {
        #expect(await handler.handle(request("notifications/initialized", id: nil)) == nil)
        #expect(await handler.handle(request("no/such/thing", id: nil)) == nil) // even unknown ones
    }

    @Test func pingReturnsEmptyObject() async throws {
        let reply = try json(await handler.handle(request("ping", id: 5)))
        #expect(reply["id"] == 5)
        #expect(reply["result"] == [:])
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let reply = try json(await handler.handle(request("resources/list")))
        #expect(reply["error"]?["code"]?.intValue == JSONRPCError.methodNotFoundCode)
    }

    @Test func garbageGetsParseErrorWithNullID() async throws {
        let reply = try json(await handler.handle(Data("not json".utf8)))
        #expect(reply["error"]?["code"]?.intValue == JSONRPCError.parseErrorCode)
        #expect(reply["id"] == .null)
    }

    @Test func listsToolsWithSchemas() async throws {
        let reply = try json(await handler.handle(request("tools/list")))
        let tools = try #require(reply["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names == ["atlantis_ping", "atlantis_inbox_post"])
        #expect(tools[0]["inputSchema"]?["type"] == "object")
        #expect(tools[0]["annotations"]?["readOnlyHint"] == true)
        #expect(tools[1]["annotations"]?["readOnlyHint"] == false)
    }

    @Test func callsATool() async throws {
        let reply = try json(await handler.handle(request("tools/call", params: ["name": "atlantis_ping", "arguments": [:]])))
        #expect(reply["result"]?["isError"] == false)
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"] == "Atlantis 9.9 is running.")
    }

    @Test func callParamsAreValidated() async throws {
        for params: JSONValue? in [nil, [:], ["name": 5], ["name": "atlantis_ping", "arguments": "x"]] {
            let reply = try json(await handler.handle(request("tools/call", params: params)))
            #expect(reply["error"]?["code"]?.intValue == JSONRPCError.invalidParamsCode, "params: \(String(describing: params))")
        }
    }

    @Test func unknownToolIsAProtocolError() async throws {
        let reply = try json(await handler.handle(request("tools/call", params: ["name": "nope"])))
        #expect(reply["error"]?["code"]?.intValue == JSONRPCError.invalidParamsCode)
    }

    @Test func toolFailureIsAnErrorResultNotAProtocolError() async throws {
        let reply = try json(await handler.handle(request("tools/call", params: ["name": "atlantis_inbox_post", "arguments": [:]])))
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["isError"] == true)
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("title") == true)
    }
}

// MARK: - Write gate

@Suite struct ToolGateTests {
    private func gatedRegistry(inbox: InMemoryInboxPosting, allow: Set<String>, destructive: Bool = false) -> (ToolRegistry, Counter) {
        let ran = Counter()
        let registry = makeRegistry(inbox: inbox, allow: allow)
        registry.register(
            ToolDefinition(name: "atlantis_task_add", description: "Add a task", inputSchema: ["type": "object"],
                           kind: .gatedWrite, destructive: destructive),
            describe: { "Add task: \($0["title"]?.stringValue ?? "?")" }
        ) { _ in
            await ran.increment()
            return ToolResult(text: "added")
        }
        return (registry, ran)
    }

    actor Counter { var value = 0; func increment() { value += 1 } }

    @Test func gatedWriteBecomesAnInboxProposalByDefault() async throws {
        let inbox = InMemoryInboxPosting()
        let (registry, ran) = gatedRegistry(inbox: inbox, allow: [])
        let result = try await registry.callTool(name: "atlantis_task_add", arguments: ["title": "Read chapter 3"])
        #expect(!result.isError)
        #expect(result.text.contains("Inbox"))
        #expect(await ran.value == 0) // the handler did not run
        let proposals = await inbox.proposals
        #expect(proposals.count == 1)
        #expect(proposals[0].kind == "mcp.atlantis_task_add")
        #expect(proposals[0].title == "Add task: Read chapter 3")
        #expect(proposals[0].payload?["tool"] == "atlantis_task_add")
        #expect(proposals[0].payload?["arguments"]?["title"] == "Read chapter 3")
    }

    @Test func allowedGatedWriteRuns() async throws {
        let inbox = InMemoryInboxPosting()
        let (registry, ran) = gatedRegistry(inbox: inbox, allow: ["atlantis_task_add"])
        let result = try await registry.callTool(name: "atlantis_task_add", arguments: [:])
        #expect(result.text == "added")
        #expect(await ran.value == 1)
        #expect(await inbox.proposals.isEmpty)
    }

    @Test func destructiveToolsAreNeverAutoAllowed() async throws {
        let inbox = InMemoryInboxPosting()
        let (registry, ran) = gatedRegistry(inbox: inbox, allow: ["atlantis_task_add"], destructive: true)
        _ = try await registry.callTool(name: "atlantis_task_add", arguments: [:])
        #expect(await ran.value == 0)
        #expect(await inbox.proposals.count == 1)
    }

    @Test func otherKindsAreNotGated() async throws {
        let inbox = InMemoryInboxPosting()
        let registry = makeRegistry(inbox: inbox)
        let ping = try await registry.callTool(name: "atlantis_ping", arguments: [:])
        #expect(!ping.isError)
        let post = try await registry.callTool(name: "atlantis_inbox_post", arguments: ["title": "Look at this", "body": "details"])
        #expect(post.text.contains("mem-1"))
        let proposals = await inbox.proposals
        #expect(proposals.map(\.title) == ["Look at this"])
        #expect(proposals[0].body == "details")
        #expect(proposals[0].kind == "agent.note")
    }

    @Test func failedProposalIsReportedAsAnError() async throws {
        let registry = ToolRegistry(inbox: InboxUnavailable())
        registry.register(ToolDefinition(name: "w", description: "", inputSchema: ["type": "object"], kind: .gatedWrite)) { _ in .init(text: "ran") }
        let result = try await registry.callTool(name: "w", arguments: [:])
        #expect(result.isError)
        #expect(result.text != "ran")
    }

    @Test func inboxPostRejectsOverlongTitle() async throws {
        let registry = makeRegistry()
        let result = try await registry.callTool(name: "atlantis_inbox_post", arguments: ["title": .string(String(repeating: "x", count: 501))])
        #expect(result.isError)
    }
}

// MARK: - Setup text

@Suite struct MCPSetupTests {
    @Test func commandQuotesOnlyWhenNeeded() {
        #expect(MCPSetup.claudeCommand(helperPath: "/Applications/Atlantis.app/Contents/MacOS/atlantis-mcp")
                == "claude mcp add atlantis -- /Applications/Atlantis.app/Contents/MacOS/atlantis-mcp")
        #expect(MCPSetup.claudeCommand(helperPath: "/Users/me/My Apps/it's/atlantis-mcp")
                == #"claude mcp add atlantis -- '/Users/me/My Apps/it'\''s/atlantis-mcp'"#)
    }

    @Test func jsonSnippetIsValid() throws {
        let snippet = MCPSetup.jsonSnippet(helperPath: "/x y/atlantis-mcp")
        let value = try JSONValue.parse(Data(snippet.utf8))
        #expect(value["mcpServers"]?["atlantis"]?["command"] == "/x y/atlantis-mcp")
    }
}

// MARK: - Socket server, end to end

@Suite(.serialized) struct MCPSocketServerTests {
    private func startServer(url: URL = tempSocketURL(),
                             registry: ToolRegistry = makeRegistry(),
                             peerCheck: @escaping @Sendable (Int32) -> Bool = PeerCredentials.isSameUser,
                             maxConnections: Int = 32) throws -> MCPSocketServer {
        let server = MCPSocketServer(socketURL: url, handler: MCPProtocolHandler(backend: registry),
                                     maxConnections: maxConnections, requestTimeout: 2, peerCheck: peerCheck)
        try server.start()
        return server
    }

    private func mode(_ path: String) -> mode_t {
        var st = stat()
        lstat(path, &st)
        return st.st_mode & 0o7777
    }

    private func cleanUp(_ server: MCPSocketServer) {
        server.stop()
        try? FileManager.default.removeItem(at: server.socketURL.deletingLastPathComponent())
    }

    @Test func socketIs0600InA0700Directory() throws {
        let server = try startServer()
        defer { cleanUp(server) }
        #expect(mode(server.socketURL.path) == 0o600)
        #expect(mode(server.socketURL.deletingLastPathComponent().path) == 0o700)
        var st = stat(); lstat(server.socketURL.path, &st)
        #expect((st.st_mode & S_IFMT) == S_IFSOCK)
    }

    @Test func existingLooseDirectoryIsTightened() throws {
        let url = tempSocketURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let server = try startServer(url: url)
        defer { cleanUp(server) }
        #expect(mode(url.deletingLastPathComponent().path) == 0o700)
    }

    @Test func listAndCallRoundTrip() async throws {
        let server = try startServer()
        defer { cleanUp(server) }
        let client = MCPSocketClient(path: server.socketURL.path)

        let list = try json(try await client.send(request("tools/list")))
        #expect(list["result"]?["tools"]?.arrayValue?.count == 2)

        let call = try json(try await client.send(request("tools/call", id: 2, params: ["name": "atlantis_ping"])))
        #expect(call["id"] == 2)
        #expect(call["result"]?["content"]?.arrayValue?.first?["text"] == "Atlantis 9.9 is running.")
    }

    @Test func stdioBackendTalksToTheServer() async throws {
        let inbox = InMemoryInboxPosting()
        let server = try startServer(registry: makeRegistry(inbox: inbox))
        defer { cleanUp(server) }
        let backend = SocketToolBackend(client: MCPSocketClient(path: server.socketURL.path))
        let tools = try await backend.listTools()
        #expect(tools.map(\.name) == ["atlantis_ping", "atlantis_inbox_post"])
        #expect(tools[1].kind == .write)
        let result = try await backend.callTool(name: "atlantis_inbox_post", arguments: ["title": "Hi"])
        #expect(!result.isError)
        #expect(await inbox.proposals.count == 1)
        await #expect(throws: JSONRPCError.self) { try await backend.callTool(name: "missing", arguments: [:]) }
    }

    @Test func manyShortConnectionsAtOnce() async throws {
        let server = try startServer()
        defer { cleanUp(server) }
        let path = server.socketURL.path
        // 100 connections in waves of 20 (the server's cap on simultaneous ones is 32).
        var ok = 0
        for wave in 0..<5 {
            ok += await withTaskGroup(of: Bool.self) { group in
                for i in 0..<20 {
                    let id = wave * 20 + i
                    group.addTask {
                        let reply = try? await MCPSocketClient(path: path).send(request("ping", id: id))
                        return (try? json(reply))?["id"] == .int(id)
                    }
                }
                var count = 0
                for await good in group where good { count += 1 }
                return count
            }
        }
        #expect(ok == 100)
    }

    @Test func connectionsFromOtherUsersAreDropped() async throws {
        let server = try startServer(peerCheck: { _ in false })
        defer { cleanUp(server) }
        let reply = try? await MCPSocketClient(path: server.socketURL.path).send(request("ping"), timeout: 2)
        #expect(reply == nil) // hung up with no answer (or refused outright)
    }

    @Test func peerCheckAcceptsTheSameUser() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(PeerCredentials.isSameUser(fds[0]))
        #expect(!PeerCredentials.isSameUser(-1))
    }

    @Test func oversizedRequestIsDropped() async throws {
        let server = try startServer()
        defer { cleanUp(server) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        try MCPSocketClient.connect(fd, to: server.socketURL.path)
        var length = UInt32(Framing.maxFrameSize + 1).bigEndian
        _ = withUnsafeBytes(of: &length) { write(fd, $0.baseAddress, 4) }
        Framing.setTimeouts(fd, seconds: 2)
        #expect(throws: Framing.Failure.self) { try Framing.readFrame(from: fd) } // closed, no reply
        let still = try json(try await MCPSocketClient(path: server.socketURL.path).send(request("ping")))
        #expect(still["result"] == [:]) // the server survived
    }

    @Test func connectionLimitIsEnforced() async throws {
        let server = try startServer(maxConnections: 2)
        defer { cleanUp(server) }
        // Two idle connections hold both slots.
        var held: [Int32] = []
        for _ in 0..<2 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            try MCPSocketClient.connect(fd, to: server.socketURL.path)
            held.append(fd)
        }
        defer { held.forEach { close($0) } }
        try await Task.sleep(for: .milliseconds(200))
        let third = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(third) }
        try MCPSocketClient.connect(third, to: server.socketURL.path)
        Framing.setTimeouts(third, seconds: 2)
        #expect(throws: Framing.Failure.self) { try Framing.readFrame(from: third) } // dropped, not served
    }

    @Test func staleSocketIsReplaced() throws {
        let url = tempSocketURL()
        let first = try startServer(url: url)
        // Simulate a crash: the socket file stays behind with nobody listening.
        first.stop()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(raw) // a socket file with no listener
        #expect(FileManager.default.fileExists(atPath: url.path))
        let second = try startServer(url: url)
        defer { cleanUp(second) }
        #expect(second.isRunning)
    }

    @Test func secondServerOnALivePathIsRefused() throws {
        let first = try startServer()
        defer { cleanUp(first) }
        let second = MCPSocketServer(socketURL: first.socketURL, handler: MCPProtocolHandler(backend: makeRegistry()))
        #expect(throws: MCPSocketServer.StartError.alreadyRunning) { try second.start() }
        #expect(first.isRunning)
    }

    @Test func nonSocketFilesAreLeftAlone() throws {
        let url = tempSocketURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = MCPSocketServer(socketURL: url, handler: MCPProtocolHandler(backend: makeRegistry()))
        #expect(throws: MCPSocketServer.StartError.notASocket(url.path)) { try server.start() }
        #expect(try Data(contentsOf: url) == Data("precious".utf8))
    }

    @Test func overlongPathIsRefused() {
        let url = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 120) + "/mcp.sock")
        let server = MCPSocketServer(socketURL: url, handler: MCPProtocolHandler(backend: makeRegistry()))
        #expect(throws: (any Error).self) { try server.start() }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func stopRemovesTheSocketAndRefusesNewConnections() async throws {
        let server = try startServer()
        let url = server.socketURL
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: MCPSocketError.appNotRunning) { _ = try await MCPSocketClient(path: url.path).send(request("ping")) }
        server.stop() // twice is fine
        try server.start() // and it can start again
        #expect(server.isRunning)
        server.stop()
    }

    @Test func clientReportsAppNotRunning() async {
        let client = MCPSocketClient(path: "/tmp/atl-none-\(UUID().uuidString.prefix(6))/mcp.sock")
        await #expect(throws: MCPSocketError.appNotRunning) { _ = try await client.send(request("ping")) }
    }

    @Test func helperBackendSaysOpenAtlantisWhenTheAppIsClosed() async throws {
        let backend = SocketToolBackend(client: MCPSocketClient(path: "/tmp/atl-none-\(UUID().uuidString.prefix(6))/mcp.sock"))
        let result = try await backend.callTool(name: "atlantis_ping", arguments: [:])
        #expect(result.isError)
        #expect(result.text.contains("Open Atlantis first"))
        let tools = try await backend.listTools()
        #expect(tools.map(\.name) == ["atlantis_ping"]) // still answers, with one tool
    }

    @Test func fullHelperChainWithTheAppClosed() async throws {
        let backend = SocketToolBackend(client: MCPSocketClient(path: "/tmp/atl-none-\(UUID().uuidString.prefix(6))/mcp.sock"))
        let handler = MCPProtocolHandler(backend: backend)
        let reply = try json(await handler.handle(request("tools/call", params: ["name": "atlantis_inbox_post", "arguments": ["title": "x"]])))
        #expect(reply["result"]?["isError"] == true)
        #expect(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.hasPrefix("Open Atlantis first") == true)
    }
}

// MARK: - Stdio

@Suite struct StdioTransportTests {
    @Test func linesInRepliesOut() async throws {
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        #expect(pipe(&input) == 0 && pipe(&output) == 0)
        let handler = MCPProtocolHandler(backend: makeRegistry())
        let script = [
            String(decoding: request("initialize", id: 1, params: ["protocolVersion": "2025-06-18"]), as: UTF8.self),
            String(decoding: request("notifications/initialized", id: nil), as: UTF8.self),
            "",
            "garbage",
            String(decoding: request("tools/list", id: 2), as: UTF8.self),
        ].joined(separator: "\n") + "\n"
        _ = script.withCString { write(input[1], $0, strlen($0)) }
        close(input[1]) // end of input

        await StdioTransport.run(input: input[0], output: output[1], handler: handler)
        close(output[1]); close(input[0])

        var text = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(output[0], &chunk, chunk.count)
            if n <= 0 { break }
            text.append(contentsOf: chunk[0..<n])
        }
        close(output[0])
        let replies = try String(decoding: text, as: UTF8.self).split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
        #expect(replies.count == 3) // initialize, the parse error, tools/list. Nothing for the notification or blank line.
        #expect(replies.contains { $0["id"] == 1 && $0["result"]?["serverInfo"] != nil })
        #expect(replies.contains { $0["id"] == .null && $0["error"]?["code"]?.intValue == JSONRPCError.parseErrorCode })
        #expect(replies.contains { $0["id"] == 2 && $0["result"]?["tools"]?.arrayValue?.count == 2 })
    }
}
