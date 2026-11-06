import Foundation

/// WebKit content-blocker rules (JSON) that keep web views off the network (PRD §17).
///
/// WebKit's url-filter regex has no `|` (alternation), so every pattern is a separate rule.
public enum ContentRules {
    private static let schemes = ["https?", "wss?"]

    /// Blocks every http(s) and websocket request. Local content (bundled files, `data:`,
    /// `blob:`, custom schemes) still works.
    public static func blockAllNetwork() -> String {
        encode(blockRules)
    }

    /// Blocks the network except the given hosts and their subdomains.
    public static func allowOnly(hosts: [String]) -> String {
        var rules = blockRules
        for host in hosts {
            let escaped = NSRegularExpression.escapedPattern(for: host.lowercased())
            for scheme in schemes {
                // The host itself, then any subdomain of it.
                for prefix in ["", "[^/]*\\."] {
                    rules.append([
                        "trigger": ["url-filter": "^\(scheme)://\(prefix)\(escaped)[:/]"],
                        "action": ["type": "ignore-previous-rules"],
                    ])
                }
            }
        }
        return encode(rules)
    }

    private static var blockRules: [[String: Any]] {
        schemes.map { ["trigger": ["url-filter": "^\($0)://"], "action": ["type": "block"]] }
    }

    private static func encode(_ rules: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
