import Foundation

/// The MCP-level behaviour (initialize, ping, tools/list, tools/call) on top of a `ToolBackend`.
/// Takes one JSON-RPC message and returns the reply bytes (nil for notifications).
public struct MCPProtocolHandler: Sendable {
    public static let protocolVersion = "2025-06-18"
    /// Older versions we also speak (same tool messages).
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let backend: any ToolBackend
    public let serverName: String
    public let serverVersion: String

    public init(backend: any ToolBackend, serverName: String = "atlantis", serverVersion: String = MCPInfo.version) {
        self.backend = backend
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    public func handle(_ message: Data) async -> Data? {
        switch JSONRPCIncoming.parse(message) {
        case .response:
            return nil
        case .invalid(let id, let error):
            return JSONRPCResponse.failure(id: id, error: error)
        case .request(let request):
            return await handle(request)
        }
    }

    func handle(_ request: JSONRPCRequest) async -> Data? {
        do {
            let result = try await result(for: request)
            guard let id = request.id else { return nil }
            return JSONRPCResponse.success(id: id, result: result)
        } catch let error as JSONRPCError {
            guard request.id != nil else { return nil } // never answer a notification
            return JSONRPCResponse.failure(id: request.id, error: error)
        } catch {
            guard request.id != nil else { return nil }
            return JSONRPCResponse.failure(id: request.id, error: .internalError())
        }
    }

    private func result(for request: JSONRPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            guard let params = request.params?.objectValue, let requested = params["protocolVersion"]?.stringValue else {
                throw JSONRPCError.invalidParams("initialize needs params.protocolVersion")
            }
            let version = Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(serverName), "version": .string(serverVersion)],
                "instructions": "Atlantis is the user's planner and docs app. Writes may become Inbox proposals the user approves; say so rather than retrying.",
            ]
        case "ping":
            return [:]
        case "tools/list":
            let tools = try await backend.listTools()
            let encoded = try tools.map { try JSONValue.parse(JSONEncoder().encode($0)) }
            return ["tools": .array(encoded)]
        case "tools/call":
            guard let params = request.params?.objectValue else {
                throw JSONRPCError.invalidParams("tools/call needs params")
            }
            guard let name = params["name"]?.stringValue, !name.isEmpty else {
                throw JSONRPCError.invalidParams("tools/call needs params.name")
            }
            let arguments = params["arguments"] ?? [:]
            guard arguments.objectValue != nil || arguments.isNull else {
                throw JSONRPCError.invalidParams("params.arguments must be an object")
            }
            let result = try await backend.callTool(name: name, arguments: arguments.isNull ? [:] : arguments)
            return try JSONValue.parse(JSONEncoder().encode(result))
        default:
            if request.method.hasPrefix("notifications/") { return .null } // acknowledged silently
            throw JSONRPCError.methodNotFound(request.method)
        }
    }
}

public enum MCPInfo {
    public static let version = "0.1.0"
}
