import Foundation

/// A small YAML subset for the front matter of Atlantis's own markdown files (bot definitions,
/// thread logs). Enough for what we write and what a person types by hand:
///
/// ```
/// name: School
/// tools: [a, b]          # inline list
/// triggers:              # block list
///   - chat
/// budget:                # one level of nesting
///   max_steps: 12
/// ```
///
/// Strings may be bare, "double quoted" (with `\"`, `\\`, `\n` escapes) or 'single quoted'.
/// Anything else (anchors, multi-line strings, deeper nesting) is a parse error, not a guess.
public enum FrontMatter {
    public indirect enum Value: Equatable, Sendable {
        case string(String)
        case list([String])
        case map([String: Value])

        public var string: String? { if case .string(let s) = self { return s }; return nil }
        public var list: [String]? {
            switch self {
            case .list(let items): items
            case .string(let s) where s.isEmpty: []
            default: nil
            }
        }
        public var map: [String: Value]? { if case .map(let m) = self { return m }; return nil }
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { "Front matter line \(line): \(message)" }
    }

    /// Splits `---\n…\n---\n` off the top of a file. Nil when the file has no front matter.
    public static func split(_ text: String) -> (yaml: String, body: String)? {
        let normalized = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard normalized.hasPrefix("---\n") || normalized.hasPrefix("---\r\n") else { return nil }
        var lines = normalized.components(separatedBy: "\n")
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" || $0 == "---\r" }) else { return nil }
        let yaml = lines[..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (yaml, body)
    }

    /// Parses the YAML subset into a map.
    public static func parse(_ yaml: String) throws -> [String: Value] {
        var result: [String: Value] = [:]
        // (key, indent) of the parent whose block is open, and what it has collected so far.
        var parent: (key: String, indent: Int)?
        var childMap: [String: Value] = [:]
        var childList: [String] = []
        var nested: (key: String, indent: Int, list: [String])? // a list inside a nested map

        func closeNested() {
            if let n = nested { childMap[n.key] = .list(n.list); nested = nil }
        }
        func closeParent() {
            closeNested()
            guard let p = parent else { return }
            if !childList.isEmpty { result[p.key] = .list(childList) }
            else if !childMap.isEmpty { result[p.key] = .map(childMap) }
            else { result[p.key] = .string("") }
            parent = nil
            childMap = [:]
            childList = []
        }

        let lines = yaml.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            let line = stripComment(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.contains("\t") { throw ParseError(line: number, message: "use spaces, not tabs") }
            let indent = line.prefix(while: { $0 == " " }).count
            let content = String(line.dropFirst(indent))

            if indent == 0 {
                closeParent()
                let (key, rest) = try keyValue(content, line: number)
                if rest.isEmpty {
                    parent = (key, 0)
                } else {
                    result[key] = try scalarOrInline(rest, line: number)
                }
                continue
            }

            guard parent != nil else { throw ParseError(line: number, message: "unexpected indent") }
            if content.hasPrefix("- ") || content == "-" {
                let item = try scalar(String(content.dropFirst()).trimmingCharacters(in: .whitespaces), line: number)
                if var n = nested, indent > n.indent {
                    n.list.append(item)
                    nested = n
                } else if nested == nil, childMap.isEmpty {
                    childList.append(item)
                } else {
                    throw ParseError(line: number, message: "a list item where a key was expected")
                }
                continue
            }
            guard childList.isEmpty else { throw ParseError(line: number, message: "a key inside a list") }
            if let n = nested, indent > n.indent {
                throw ParseError(line: number, message: "too deeply nested")
            }
            closeNested()
            let (key, rest) = try keyValue(content, line: number)
            if rest.isEmpty {
                nested = (key, indent, [])
            } else {
                childMap[key] = try scalarOrInline(rest, line: number)
            }
        }
        closeParent()
        return result
    }

    // MARK: Writing

    /// A scalar as YAML: bare when that reads back the same, otherwise double-quoted.
    public static func quoted(_ value: String) -> String {
        let plainSafe = !value.isEmpty
            && value.trimmingCharacters(in: .whitespaces) == value
            && !value.contains(where: { "#:[]{},\"'\n\r\t&*!|>%@`".contains($0) })
            && !value.hasPrefix("-") && !value.hasPrefix("?")
        if plainSafe { return value }
        var out = "\""
        for ch in value {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    // MARK: Pieces

    private static func stripComment(_ line: String) -> String {
        // A `#` starts a comment at the line start or after a space, outside quotes.
        var inDouble = false, inSingle = false
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" && !inSingle && previous != "\\" { inDouble.toggle() }
            else if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "#" && !inDouble && !inSingle && (previous == " " || index == line.startIndex) {
                return String(line[..<index]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            previous = ch
            index = line.index(after: index)
        }
        return line
    }

    private static func keyValue(_ content: String, line: Int) throws -> (String, String) {
        guard let colon = content.firstIndex(of: ":") else { throw ParseError(line: line, message: "expected `key: value`") }
        let key = content[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw ParseError(line: line, message: "bad key \"\(key)\"")
        }
        let rest = content[content.index(after: colon)...]
        if let first = rest.first, first != " " { throw ParseError(line: line, message: "expected a space after `:`") }
        return (key, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func scalarOrInline(_ text: String, line: Int) throws -> Value {
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw ParseError(line: line, message: "unclosed `[`") }
            let inner = text.dropFirst().dropLast()
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .list([]) }
            return .list(try splitInline(String(inner), line: line).map { try scalar($0, line: line) })
        }
        if text.hasPrefix("{") { throw ParseError(line: line, message: "inline maps aren't supported") }
        return .string(try scalar(text, line: line))
    }

    private static func splitInline(_ text: String, line: Int) throws -> [String] {
        var items: [String] = []
        var current = ""
        var inDouble = false, inSingle = false
        var previous: Character = " "
        for ch in text {
            if ch == "\"" && !inSingle && previous != "\\" { inDouble.toggle() }
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "," && !inDouble && !inSingle {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        items.append(current.trimmingCharacters(in: .whitespaces))
        if inDouble || inSingle { throw ParseError(line: line, message: "unclosed quote") }
        return items
    }

    static func scalar(_ text: String, line: Int) throws -> String {
        if text.hasPrefix("\"") {
            guard text.count >= 2, text.hasSuffix("\""), !text.hasSuffix("\\\"") || text.hasSuffix("\\\\\"") else {
                throw ParseError(line: line, message: "unclosed quote")
            }
            var out = ""
            var escaping = false
            for ch in text.dropFirst().dropLast() {
                if escaping {
                    switch ch {
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if text.hasPrefix("'") {
            guard text.count >= 2, text.hasSuffix("'") else { throw ParseError(line: line, message: "unclosed quote") }
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if text.hasPrefix("&") || text.hasPrefix("*") || text.hasPrefix("|") || text.hasPrefix(">") {
            throw ParseError(line: line, message: "YAML anchors and block strings aren't supported")
        }
        return text
    }
}
