import Foundation

/// JSON-RPC 2.0 pieces for MCP (https://www.jsonrpc.org/specification).
public enum JSONRPCID: Sendable, Hashable {
    case string(String)
    case number(Int)

    var json: JSONValue {
        switch self {
        case .string(let s): .string(s)
        case .number(let n): .int(n)
        }
    }

    init?(json: JSONValue?) {
        switch json {
        case .string(let s): self = .string(s)
        case .int(let n): self = .number(n)
        case .double: if let n = json?.intValue { self = .number(n) } else { return nil }
        default: return nil
        }
    }
}

public struct JSONRPCError: Error, Sendable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let internalErrorCode = -32603

    public static func parseError(_ detail: String = "Parse error") -> JSONRPCError { .init(code: parseErrorCode, message: detail) }
    public static func invalidRequest(_ detail: String = "Invalid request") -> JSONRPCError { .init(code: invalidRequestCode, message: detail) }
    public static func methodNotFound(_ method: String) -> JSONRPCError { .init(code: methodNotFoundCode, message: "Method not found: \(method)") }
    public static func invalidParams(_ detail: String) -> JSONRPCError { .init(code: invalidParamsCode, message: detail) }
    public static func internalError(_ detail: String = "Internal error") -> JSONRPCError { .init(code: internalErrorCode, message: detail) }

    var json: JSONValue {
        var o: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}

public struct JSONRPCRequest: Sendable, Equatable {
    public var id: JSONRPCID?
    public var method: String
    public var params: JSONValue?
    /// Notifications have no id and get no reply.
    public var isNotification: Bool { id == nil }

    public init(id: JSONRPCID?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public func encoded() -> Data {
        var o: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { o["id"] = id.json }
        if let params { o["params"] = params }
        return JSONValue.object(o).encoded()
    }
}

/// What a received message turned out to be.
public enum JSONRPCIncoming: Sendable, Equatable {
    case request(JSONRPCRequest)
    /// A response (result or error) from the other side; servers here never send requests, so they ignore it.
    case response
    /// Unreadable or not a valid request. `id` is set when it could still be read, else the reply uses null.
    case invalid(id: JSONRPCID?, error: JSONRPCError)

    public static func parse(_ data: Data) -> JSONRPCIncoming {
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch {
            return .invalid(id: nil, error: .parseError())
        }
        guard case .object(let o) = value else {
            // MCP 2025-06-18 has no JSON-RPC batching.
            let what = value.arrayValue != nil ? "Batches are not supported" : "A request must be a JSON object"
            return .invalid(id: nil, error: .invalidRequest(what))
        }
        let id = JSONRPCID(json: o["id"])
        if o["id"] != nil, !(o["id"]?.isNull ?? false), id == nil {
            return .invalid(id: nil, error: .invalidRequest("id must be a string or integer"))
        }
        guard o["jsonrpc"]?.stringValue == "2.0" else {
            return .invalid(id: id, error: .invalidRequest("jsonrpc must be \"2.0\""))
        }
        guard let method = o["method"]?.stringValue else {
            if o["result"] != nil || o["error"] != nil { return .response }
            return .invalid(id: id, error: .invalidRequest("Missing method"))
        }
        if let params = o["params"], !(params.objectValue != nil || params.arrayValue != nil) {
            return .invalid(id: id, error: .invalidParams("params must be an object or array"))
        }
        return .request(JSONRPCRequest(id: id, method: method, params: o["params"]))
    }
}

public enum JSONRPCResponse {
    public static func success(id: JSONRPCID, result: JSONValue) -> Data {
        JSONValue.object(["jsonrpc": "2.0", "id": id.json, "result": result]).encoded()
    }

    public static func failure(id: JSONRPCID?, error: JSONRPCError) -> Data {
        JSONValue.object(["jsonrpc": "2.0", "id": id?.json ?? .null, "error": error.json]).encoded()
    }

    /// Splits a response into its result or its error.
    public static func parse(_ data: Data) throws -> JSONValue {
        let value = try JSONValue.parse(data)
        if let error = value["error"] {
            throw JSONRPCError(code: error["code"]?.intValue ?? JSONRPCError.internalErrorCode,
                               message: error["message"]?.stringValue ?? "Error",
                               data: error["data"])
        }
        guard let result = value["result"] else { throw JSONRPCError.invalidRequest("Response has no result") }
        return result
    }
}
