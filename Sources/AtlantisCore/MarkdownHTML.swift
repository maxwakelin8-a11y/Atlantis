import Foundation

/// A small Markdown → HTML converter for exporting docs from the MCP tool (headings, paragraphs,
/// lists, quotes, code, rules, bold, italic, code spans and links). The Docs editor has its own
/// richer export; this is the headless one. Everything is HTML-escaped, and only http(s) and
/// mailto links are kept.
public enum MarkdownHTML {
    public static func document(markdown: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 11pt; line-height: 1.5; margin: 2cm; }
        h1 { font-size: 22pt; } h2 { font-size: 16pt; } h3 { font-size: 13pt; }
        pre, code { font-family: Menlo, monospace; font-size: 9.5pt; }
        pre { background: #f4f4f4; padding: 8px; white-space: pre-wrap; }
        blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 12px; color: #444; }
        </style></head><body>
        \(body(markdown))
        </body></html>
        """
    }

    /// The Markdown without its leading `---` front matter block.
    public static func stripFrontMatter(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    static func body(_ markdown: String) -> String {
        let lines = stripFrontMatter(markdown).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        var paragraph: [String] = []
        var list: (tag: String, items: [String])?
        var quote: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph = []
        }
        func flushList() {
            guard let current = list else { return }
            out.append("<\(current.tag)>" + current.items.map { "<li>\(inline($0))</li>" }.joined() + "</\(current.tag)>")
            list = nil
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            out.append("<blockquote><p>\(inline(quote.joined(separator: " ")))</p></blockquote>")
            quote = []
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushAll()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                out.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
            } else if trimmed.isEmpty {
                flushAll()
            } else if let (level, text) = heading(trimmed) {
                flushAll()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
            } else if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), Set(trimmed).count == 1 {
                flushAll()
                out.append("<hr>")
            } else if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let item = listItem(trimmed) {
                flushParagraph(); flushQuote()
                if list?.tag != item.tag { flushList(); list = (item.tag, []) }
                list?.items.append(item.text)
            } else {
                flushList(); flushQuote()
                paragraph.append(trimmed)
            }
            i += 1
        }
        flushAll()
        return out.joined(separator: "\n")
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (tag: String, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            var text = String(line.dropFirst(2))
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { text = "☑ " + text.dropFirst(4) }
            return ("ul", text)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("ol", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Code spans, bold, italic and links, on already-escaped text.
    static func inline(_ raw: String) -> String {
        var text = escape(raw)
        var spans: [String] = []
        // Code spans first, held aside so their contents aren't styled.
        text = replace(text, #"`([^`]+)`"#) { match in
            spans.append("<code>\(match[1])</code>")
            return "\u{1}\(spans.count - 1)\u{2}"
        }
        text = replace(text, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { match in
            let url = match[2]
            let ok = url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("mailto:")
            return ok ? "<a href=\"\(url)\">\(match[1])</a>" : match[1]
        }
        text = replace(text, #"\*\*([^*]+)\*\*"#) { "<strong>\($0[1])</strong>" }
        text = replace(text, #"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])"#) { "<em>\($0[1])</em>" }
        text = replace(text, #"(?<![\w_])_([^_\s][^_]*)_(?![\w_])"#) { "<em>\($0[1])</em>" }
        for (index, span) in spans.enumerated() { text = text.replacingOccurrences(of: "\u{1}\(index)\u{2}", with: span) }
        return text
    }

    private static func replace(_ text: String, _ pattern: String, _ make: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
            out += make(groups)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
