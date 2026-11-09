import Foundation

/// What a tool does, from PRD §8. Decides how the gate treats a call.
public enum ToolKind: String, Sendable, Codable {
    /// Reads only. Always allowed.
    case read
    /// Writes, but only by posting to the Inbox (or similar). Always allowed.
    case write
    /// `write*` in the PRD: runs only if the user allowed this action, otherwise becomes an Inbox proposal.
    case gatedWrite = "write-gated"
    /// Does something on request (manual SEQTA sync, export). Not gated.
    case action
}

public struct ToolDefinition: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    /// JSON Schema for the arguments (an object schema).
    public var inputSchema: JSONValue
    public var kind: ToolKind
    /// Destructive tools (deletes) are never auto-allowed, even if on the allow list (PRD §17).
    public var destructive: Bool

    public init(name: String, description: String, inputSchema: JSONValue, kind: ToolKind, destructive: Bool = false) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.kind = kind
        self.destructive = destructive
    }

    private enum CodingKeys: String, CodingKey { case name, description, inputSchema, annotations, meta = "_meta" }

    /// MCP wire shape: `annotations` for generic clients, `_meta` carries Atlantis's own kind.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(inputSchema, forKey: .inputSchema)
        try c.encode(JSONValue.object([
            "readOnlyHint": .bool(kind == .read),
            "destructiveHint": .bool(destructive),
            "openWorldHint": .bool(false),
        ]), forKey: .annotations)
        try c.encode(JSONValue.object(["atlantis/kind": .string(kind.rawValue)]), forKey: .meta)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputSchema = try c.decodeIfPresent(JSONValue.self, forKey: .inputSchema) ?? ["type": "object"]
        let meta = try c.decodeIfPresent(JSONValue.self, forKey: .meta)
        let annotations = try c.decodeIfPresent(JSONValue.self, forKey: .annotations)
        if let raw = meta?["atlantis/kind"]?.stringValue, let kind = ToolKind(rawValue: raw) {
            self.kind = kind
        } else {
            self.kind = annotations?["readOnlyHint"]?.boolValue == true ? .read : .write
        }
        destructive = annotations?["destructiveHint"]?.boolValue ?? false
    }
}

/// What a tool returns: text for the model, plus a flag for "this didn't work" (still a normal reply, per MCP).
public struct ToolResult: Sendable, Equatable, Codable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ text: String) -> ToolResult { .init(text: text, isError: true) }

    private enum CodingKeys: String, CodingKey { case content, isError }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([JSONValue.object(["type": "text", "text": .string(text)])], forKey: .content)
        try c.encode(isError, forKey: .isError)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let blocks = try c.decodeIfPresent([JSONValue].self, forKey: .content) ?? []
        text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

/// A tool failed in a way the caller should see (bad arguments, missing item). Becomes an `isError` result.
public struct ToolFailure: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public extension JSONValue {
    /// A required string argument, or a `ToolFailure` the caller sees.
    func requireString(_ key: String, maxLength: Int = 20_000) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else {
            throw ToolFailure("Missing required argument \"\(key)\" (a non-empty string).")
        }
        guard value.count <= maxLength else { throw ToolFailure("Argument \"\(key)\" is too long (max \(maxLength) characters).") }
        return value
    }

    func optionalString(_ key: String, maxLength: Int = 20_000) throws -> String? {
        guard let raw = self[key], !raw.isNull else { return nil }
        guard let value = raw.stringValue else { throw ToolFailure("Argument \"\(key)\" must be a string.") }
        guard value.count <= maxLength else { throw ToolFailure("Argument \"\(key)\" is too long (max \(maxLength) characters).") }
        return value
    }
}

/// Where tools come from: the app's registry, or (in the stdio helper) the app over the socket.
public protocol ToolBackend: Sendable {
    func listTools() async throws -> [ToolDefinition]
    /// Throws `JSONRPCError` only for protocol-level problems (unknown tool); tool failures are `isError` results.
    func callTool(name: String, arguments: JSONValue) async throws -> ToolResult
}
