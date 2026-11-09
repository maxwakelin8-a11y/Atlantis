import Foundation

/// Full-text search across every Writer project (title + body), run on demand only: nothing is
/// indexed or cached, so idle costs nothing (PRD §17). Read-only, and confined to the Writer folder
/// like every other `WriterFiles` operation (symlinks are never followed).
extension WriterFiles {
    public struct Snippet: Sendable, Equatable {
        /// Text before the match, the match as written in the file, and text after it.
        /// One line each; `before`/`after` carry a leading/trailing "…" when cut.
        public let before: String
        public let match: String
        public let after: String
        /// Which body match this is (0 = first) so the editor can jump to the same one.
        public let occurrence: Int
    }

    public struct SearchHit: Sendable, Equatable {
        /// The project's folder name.
        public let project: String
        /// Absolute path of the document.
        public let path: String
        /// Path inside the project, e.g. `Draft/Intro.md`.
        public let relPath: String
        public let title: String
        public let titleMatches: Bool
        /// Matches in the body (capped at `maxMatchesPerDoc`).
        public let count: Int
        public let snippets: [Snippet]
    }

    public struct SearchResult: Sendable, Equatable {
        public let hits: [SearchHit]
        /// More documents matched than `limit`.
        public let truncated: Bool
        public let scanned: Int
    }

    public static let maxSearchDocBytes = 2_000_000
    public static let maxSearchDocs = 20_000
    public static let maxMatchesPerDoc = 1_000
    static let searchTextExtensions: Set<String> = ["md", "markdown", "txt"]
    /// Folders at the top of a project that hold no documents to search.
    static let searchSkippedTopFolders: Set<String> = ["Exports", "assets", "Trash"]

    /// Documents matching `query` (case and accent insensitive). At most `limit` documents are
    /// returned, each with up to `maxSnippets` snippets.
    public func search(_ query: String, limit: Int = 200, maxSnippets: Int = 3) -> SearchResult {
        let q = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !q.isEmpty else { return SearchResult(hits: [], truncated: false, scanned: 0) }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let keySet = Set(keys)

        var hits: [SearchHit] = []
        var truncated = false
        var scanned = 0

        func children(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        func visit(_ dir: URL, project: String, rel: String, depth: Int) {
            for item in children(dir) {
                if truncated || scanned >= Self.maxSearchDocs { return }
                guard let v = try? item.resourceValues(forKeys: keySet), v.isSymbolicLink != true else { continue }
                let name = item.lastPathComponent
                if v.isDirectory == true {
                    if depth == 0, Self.searchSkippedTopFolders.contains(name) { continue }
                    if depth < 12 { visit(item, project: project, rel: rel.isEmpty ? name : "\(rel)/\(name)", depth: depth + 1) }
                } else if v.isRegularFile == true, Self.searchTextExtensions.contains(item.pathExtension.lowercased()),
                          let size = v.fileSize, size <= Self.maxSearchDocBytes {
                    scanned += 1
                    guard let data = try? Data(contentsOf: item), let text = String(validating: data, as: UTF8.self),
                          let hit = Self.match(text, query: q, maxSnippets: maxSnippets, project: project,
                                               path: item.path, relPath: rel.isEmpty ? name : "\(rel)/\(name)") else { continue }
                    if hits.count >= limit { truncated = true; return }
                    hits.append(hit)
                }
            }
        }

        for project in children(root) {
            guard let v = try? project.resourceValues(forKeys: keySet), v.isDirectory == true, v.isSymbolicLink != true else { continue }
            visit(project, project: project.lastPathComponent, rel: "", depth: 0)
            if truncated { break }
        }
        return SearchResult(hits: hits, truncated: truncated, scanned: scanned)
    }

    // MARK: Matching one document

    static func match(_ raw: String, query: String, maxSnippets: Int,
                      project: String, path: String, relPath: String) -> SearchHit? {
        let (front, body) = splitFrontMatter(raw)
        let stem = ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let title = frontMatterTitle(front).flatMap { $0.isEmpty ? nil : $0 } ?? stem

        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let titleMatches = title.range(of: query, options: options) != nil
        let ns = body as NSString
        var count = 0
        var snippets: [Snippet] = []
        var at = 0
        while at < ns.length, count < maxMatchesPerDoc {
            let r = ns.range(of: query, options: options, range: NSRange(location: at, length: ns.length - at))
            if r.location == NSNotFound { break }
            if snippets.count < maxSnippets { snippets.append(snippet(ns, r, occurrence: count)) }
            count += 1
            at = r.location + max(r.length, 1)
        }
        guard titleMatches || count > 0 else { return nil }
        return SearchHit(project: project, path: path, relPath: relPath, title: title,
                         titleMatches: titleMatches, count: count, snippets: snippets)
    }

    /// A one-line excerpt around `r`: up to 48 characters before and 80 after, kept inside the
    /// paragraph, with runs of whitespace collapsed.
    private static func snippet(_ ns: NSString, _ r: NSRange, occurrence: Int) -> Snippet {
        let lead = 48, trail = 80
        var start = max(0, r.location - lead)
        var end = min(ns.length, r.location + r.length + trail)
        // Stay on the match's own line.
        let lineBefore = ns.range(of: "\n", options: .backwards, range: NSRange(location: start, length: r.location - start))
        if lineBefore.location != NSNotFound { start = lineBefore.location + 1 }
        let afterFrom = r.location + r.length
        let lineAfter = ns.range(of: "\n", options: [], range: NSRange(location: afterFrom, length: end - afterFrom))
        if lineAfter.location != NSNotFound { end = lineAfter.location }
        // Don't cut a character in half (only where the cut was arbitrary, not at a line break).
        if lineBefore.location == NSNotFound, start < ns.length { start = ns.rangeOfComposedCharacterSequence(at: start).location }
        if lineAfter.location == NSNotFound, end < ns.length { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end)) }
        end = max(end, afterFrom)

        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        var before = clean(ns.substring(with: NSRange(location: start, length: r.location - start)))
        var after = clean(ns.substring(with: NSRange(location: afterFrom, length: end - afterFrom)))
        if start > 0 && lineBefore.location == NSNotFound { before = "…" + String(before.drop(while: { $0 == " " })) }
        while after.last == " " { after.removeLast() }
        if end < ns.length && lineAfter.location == NSNotFound { after += "…" }
        return Snippet(before: before, match: clean(ns.substring(with: r)), after: after, occurrence: occurrence)
    }

    /// Splits `raw` into its front matter text (between the `---` lines) and the body.
    /// Works on "\n" separated lines, because Swift treats "\r\n" as one Character.
    static func splitFrontMatter(_ raw: String) -> (front: String?, body: String) {
        var text = raw
        if raw.unicodeScalars.first == "\u{FEFF}" { text = String(String.UnicodeScalarView(raw.unicodeScalars.dropFirst())) }
        let lines = text.components(separatedBy: "\n")
        let blank = CharacterSet(charactersIn: " \t\r")
        guard lines.count > 1, lines[0].trimmingCharacters(in: blank) == "---",
              let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: blank) == "---" }) else {
            return (nil, text)
        }
        return (lines[1..<close].joined(separator: "\n") + "\n", lines[(close + 1)...].joined(separator: "\n"))
    }

    /// The `title:` field of a Writer front matter block (plain, "double" or 'single' quoted).
    static func frontMatterTitle(_ front: String?) -> String? {
        guard let front else { return nil }
        for line in front.split(whereSeparator: \.isNewline) where line.hasPrefix("title:") {
            let value = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let data = value.data(using: .utf8),
               let s = try? JSONDecoder().decode(String.self, from: data) { return s }
            if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            return value
        }
        return nil
    }
}
