import Foundation

/// A parsed JSON object. SEQTA's responses are loosely typed (numbers arrive as strings, flags
/// as 0/1, fields come and go), so decoding goes through these tolerant readers rather than
/// `Codable`.
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    /// The first of `keys` that holds a non-empty string. Numbers are accepted as text.
    func string(_ keys: String...) -> String? {
        for key in keys {
            guard let value = self[key], !(value is NSNull) else { continue }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                return number.stringValue
            }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            guard let value = self[key], !(value is NSNull) else { continue }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
            if let text = value as? String, let int = Int(text.trimmingCharacters(in: .whitespaces)) { return int }
        }
        return nil
    }

    func double(_ keys: String...) -> Double? {
        for key in keys {
            guard let value = self[key], !(value is NSNull) else { continue }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
            if let text = value as? String, let double = Double(text.trimmingCharacters(in: .whitespaces)) { return double }
        }
        return nil
    }

    /// true for `true`, `1`, "1", "true", "yes".
    func bool(_ keys: String...) -> Bool? {
        for key in keys {
            guard let value = self[key], !(value is NSNull) else { continue }
            if let number = value as? NSNumber { return number.intValue != 0 }
            if let text = value as? String {
                switch text.lowercased() {
                case "1", "true", "yes": return true
                case "0", "false", "no", "": return false
                default: continue
                }
            }
        }
        return nil
    }

    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
    func objects(_ key: String) -> [JSONObject] { (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
}

extension Array where Element == Any {
    var objects: [JSONObject] { compactMap { $0 as? JSONObject } }
}

/// Plain text from the HTML SEQTA puts in notices, homework and messages.
public enum HTMLText {
    public static func plain(_ html: String?) -> String {
        guard var text = html, !text.isEmpty else { return "" }
        text = replace(text, #"<(style|script|noscript)\b[^>]*>.*?</\1\s*>"#, with: "", options: [.caseInsensitive, .dotMatchesLineSeparators])
        text = replace(text, #"<br\s*/?>"#, with: "\n", options: .caseInsensitive)
        text = replace(text, #"</(p|div|li|tr|h[1-6]|blockquote|ul|ol|table)\s*>"#, with: "\n", options: .caseInsensitive)
        text = replace(text, #"<li\b[^>]*>"#, with: "- ", options: .caseInsensitive)
        text = replace(text, #"<[^>]*>"#, with: "", options: [])
        text = decodeEntities(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            replace(String(line), #"[ \t\x{00A0}]+"#, with: " ", options: []).trimmingCharacters(in: .whitespaces)
        }
        text = lines.joined(separator: "\n")
        text = replace(text, #"\n{3,}"#, with: "\n\n", options: [])
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ text: String, _ pattern: String, with template: String, options: NSRegularExpression.Options) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "bull": "•", "copy": "©", "deg": "°",
    ]

    /// One pass over the entities, so "&amp;lt;" becomes "&lt;" and not "<".
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"), let regex = try? NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);"#) else { return text }
        var out = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
            out += text[cursor..<whole.lowerBound]
            let name = String(text[inner])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[name.lowercased()]
            }
            out += replacement ?? String(text[whole])
            cursor = whole.upperBound
        }
        out += text[cursor...]
        return out
    }
}
