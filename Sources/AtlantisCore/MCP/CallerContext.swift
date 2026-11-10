import Foundation

/// Who is calling a tool, for the Inbox's `source` field (`mcp:claude-code`).
///
/// The name comes from the MCP `initialize` request's `clientInfo`. The stdio helper passes it to
/// the app inside `tools/call`'s `_meta`. It's only a label: the socket is already limited to the
/// same user, so a made-up name can't gain anything.
public enum MCPCaller {
    @TaskLocal public static var clientName: String?

    public static let metaKey = "atlantis/client"

    /// A short label made of letters, digits and `. _ -` (nil if nothing usable is left).
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = raw.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
                || $0 == " "
        }
        let text = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let clipped = String(text.prefix(40))
        return clipped.isEmpty ? nil : clipped
    }

    /// `mcp:<client>`, or plain `mcp` when the client didn't say who it is.
    public static var source: String {
        clientName.map { "mcp:\($0)" } ?? "mcp"
    }
}

/// What the handler learned from `initialize`. A reference so every message on a connection shares it.
final class MCPClientInfo: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?

    var value: String? { lock.withLock { name } }
    func set(_ newValue: String?) { lock.withLock { name = newValue } }
}
