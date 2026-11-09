import Foundation

/// The text the Settings page shows for connecting Claude Code to Atlantis.
public enum MCPSetup {
    /// Single-quotes a path for a shell when needed.
    public static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:@%")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func claudeCommand(helperPath: String) -> String {
        "claude mcp add atlantis -- \(shellQuoted(helperPath))"
    }

    /// For a `.mcp.json` file or another client's config.
    public static func jsonSnippet(helperPath: String) -> String {
        let value: JSONValue = ["mcpServers": ["atlantis": ["command": .string(helperPath), "args": []]]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
