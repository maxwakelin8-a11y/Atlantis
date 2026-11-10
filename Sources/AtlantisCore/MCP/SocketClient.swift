import Darwin
import Foundation

public enum MCPSocketError: Error, Equatable, CustomStringConvertible {
    /// Nothing is listening: Atlantis isn't running.
    case appNotRunning
    case timeout
    case pathTooLong
    case badReply(String)
    case io(Int32)

    public var description: String {
        switch self {
        case .appNotRunning: "Open Atlantis first."
        case .timeout: "Atlantis didn't answer in time."
        case .pathTooLong: "Socket path is too long."
        case .badReply(let s): "Atlantis sent an unreadable reply: \(s)"
        case .io(let code): "Connection to Atlantis failed: \(String(cString: strerror(code)))."
        }
    }
}

/// Talks to the app's socket: one request per connection.
public struct MCPSocketClient: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    /// The app's socket. `ATLANTIS_MCP_SOCKET` points both the app and the helper somewhere else
    /// (for testing a debug build next to the real app); it's only read at launch.
    public static var defaultPath: String {
        if let override = ProcessInfo.processInfo.environment["ATLANTIS_MCP_SOCKET"], override.hasPrefix("/") { return override }
        return AppSupport.sockets.appendingPathComponent("mcp.sock").path
    }

    /// Sends one JSON message and returns the reply bytes. Nil means the app closed without replying (notification).
    public func send(_ message: Data, timeout: Double = 30) async throws -> Data? {
        let path = self.path
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.roundTrip(message, path: path, timeout: timeout) })
            }
        }
    }

    static func roundTrip(_ message: Data, path: String, timeout: Double) throws -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.io(errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        try connect(fd, to: path)
        Framing.setTimeouts(fd, seconds: timeout)
        do {
            try Framing.writeFrame(message, to: fd)
            return try Framing.readFrame(from: fd)
        } catch Framing.Failure.closed {
            return nil
        } catch Framing.Failure.timeout {
            throw MCPSocketError.timeout
        } catch Framing.Failure.io(let code) {
            throw MCPSocketError.io(code)
        } catch Framing.Failure.tooLarge {
            throw MCPSocketError.badReply("reply too large")
        }
    }

    static func connect(_ fd: Int32, to path: String) throws -> Void {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw MCPSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            switch errno {
            case ENOENT, ECONNREFUSED: throw MCPSocketError.appNotRunning
            default: throw MCPSocketError.io(errno)
            }
        }
    }
}

/// The stdio helper's tool source: forwards `tools/list` and `tools/call` to the running app.
public struct SocketToolBackend: ToolBackend {
    public static let openAtlantisMessage = "Open Atlantis first. The Atlantis app isn't running, so this tool can't reach it. Ask the user to open Atlantis, then try again."

    let client: MCPSocketClient
    let callTimeout: Double

    public init(client: MCPSocketClient = MCPSocketClient(path: MCPSocketClient.defaultPath), callTimeout: Double = 120) {
        self.client = client
        self.callTimeout = callTimeout
    }

    /// With the app closed the list holds just `atlantis_ping`, so the server still looks alive and the reason is clear.
    public func listTools() async throws -> [ToolDefinition] {
        do {
            let result = try await request(method: "tools/list", params: [:], timeout: 10)
            let tools = result["tools"]?.arrayValue ?? []
            return try tools.map { try JSONDecoder().decode(ToolDefinition.self, from: $0.encoded()) }
        } catch MCPSocketError.appNotRunning {
            return [ToolDefinition(
                name: "atlantis_ping",
                description: "Check that Atlantis is running. (The app is closed right now, so this reports that.)",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                kind: .read)]
        }
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
        do {
            var params: JSONValue = ["name": .string(name), "arguments": arguments]
            if let client = MCPCaller.clientName { params = ["name": .string(name), "arguments": arguments, "_meta": [MCPCaller.metaKey: .string(client)]] }
            let result = try await request(method: "tools/call", params: params, timeout: callTimeout)
            return try JSONDecoder().decode(ToolResult.self, from: result.encoded())
        } catch MCPSocketError.appNotRunning {
            return .error(Self.openAtlantisMessage)
        } catch let error as MCPSocketError {
            return .error(error.description)
        }
    }

    private func request(method: String, params: JSONValue, timeout: Double) async throws -> JSONValue {
        let message = JSONRPCRequest(id: .number(1), method: method, params: params).encoded()
        guard let reply = try await client.send(message, timeout: timeout) else {
            throw MCPSocketError.badReply("empty")
        }
        do { return try JSONRPCResponse.parse(reply) }
        catch let error as JSONRPCError { throw error }
        catch { throw MCPSocketError.badReply("not JSON") }
    }
}
