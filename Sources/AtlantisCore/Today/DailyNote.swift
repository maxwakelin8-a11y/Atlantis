import Foundation

/// The machine-owned parts of a LifeOS daily note (`daily/YYYY-MM-DD.md`), as the vault's
/// AGENTS.md defines them:
///
/// - front-matter keys `classes`, `assessments_due`, `notices`, `synced_at`
/// - the lines between `<!-- machine:start` and `<!-- machine:end` markers
///
/// Everything else (other keys, `## Top 3`, `## Notes`, line endings) stays byte for byte.
/// A missing key is added at the end of the front matter; missing markers are left missing (the
/// user removed them), and a note with no front matter keeps none.
public enum DailyNote {
    public static let machineKeys = ["classes", "assessments_due", "notices", "synced_at"]
    public static let startMarker = "<!-- machine:start"
    public static let endMarker = "<!-- machine:end"
    /// Where the vault keeps the daily note template (read only).
    public static let templatePath = "human/[98] System/Templates/journal-template.md"
    /// Longest notice summary kept in the front matter.
    public static let summaryLength = 140

    /// What the sync fills in.
    public struct Content: Equatable, Sendable {
        /// Machine front-matter keys and their YAML (the text after `key:`, starting with a space
        /// or a newline), in `machineKeys` order.
        public var frontMatter: [(key: String, yaml: String)]
        /// The lines that go between the markers (no trailing newline).
        public var block: [String]

        public static func == (a: Content, b: Content) -> Bool {
            a.block == b.block && a.frontMatter.map(\.key) == b.frontMatter.map(\.key)
                && a.frontMatter.map(\.yaml) == b.frontMatter.map(\.yaml)
        }
    }

    // MARK: Building the content

    /// Today's classes (time order), assessments due in the next 14 days (soonest first) and
    /// today's notices, as the vault's AGENTS.md shapes them.
    public static func content(lessons: [Lesson], assessments: [Assessment], notices: [Notice],
                               syncedAt: Date, now: Date, calendar: Calendar = .current) -> Content {
        let today = DayStamp(now, calendar: calendar)
        let classes = lessons.filter { $0.date == today.description }.sorted { ($0.from, $0.id) < ($1.from, $1.id) }
        let lastDay = today.adding(days: TodayModel.assessmentDays, calendar: calendar)
        let due = assessments.filter { item in
            guard let day = DayStamp(item.due) else { return false }
            return day >= today && day <= lastDay && item.status.uppercased() != "MARKS_RELEASED"
        }.sorted { ($0.due, $0.id) < ($1.due, $1.id) }
        let todaysNotices = notices.filter { $0.date == today.description }

        var fm: [(String, String)] = []
        fm.append(("classes", list(classes.map { lesson in
            var pairs: [(String, String)] = [("time", "\(lesson.from)-\(lesson.until)"), ("subject", lesson.subject)]
            if !lesson.room.isEmpty { pairs.append(("room", lesson.room)) }
            if !lesson.teacher.isEmpty { pairs.append(("teacher", lesson.teacher)) }
            if let topic = clean(lesson.topic) { pairs.append(("topic", topic)) }
            if let homework = clean(lesson.homework) { pairs.append(("homework", homework)) }
            return pairs
        })))
        fm.append(("assessments_due", list(due.map { item in
            [("due", item.due), ("title", item.title), ("subject", item.subject), ("status", item.status)]
        })))
        fm.append(("notices", list(todaysNotices.map { notice in
            var pairs: [(String, String)] = [("title", notice.title)]
            if !notice.label.isEmpty { pairs.append(("label", notice.label)) }
            if !notice.staff.isEmpty { pairs.append(("from", notice.staff)) }
            if let summary = clean(notice.contents) { pairs.append(("summary", truncate(summary, summaryLength))) }
            return pairs
        })))
        fm.append(("synced_at", " " + iso(syncedAt, calendar: calendar)))

        var block: [String] = ["### Classes"]
        if classes.isEmpty { block.append("_No classes today._") }
        for lesson in classes {
            var line = "- \(lesson.from)-\(lesson.until) **\(oneLine(lesson.subject))**"
            for part in [lesson.room, lesson.teacher] where !part.isEmpty { line += " · " + oneLine(part) }
            if let topic = clean(lesson.topic) { line += ": _\(topic)_" }
            block.append(line)
            if let homework = clean(lesson.homework) { block.append("  - Homework: \(homework)") }
        }
        block.append("")
        block.append("### Due in the next 14 days")
        if due.isEmpty { block.append("_Nothing due._") }
        for item in due {
            let day = DayStamp(item.due) ?? today
            let label = dayLabel(day, calendar: calendar)
            let countdown = Countdown.text(days: today.days(until: day, calendar: calendar))
            block.append("- \(label): \(oneLine(item.title)) (\(oneLine(item.subject))), \(countdown)")
        }
        block.append("")
        block.append("### Notices")
        if todaysNotices.isEmpty { block.append("_No notices today._") }
        for notice in todaysNotices {
            let from = [notice.label, notice.staff].filter { !$0.isEmpty }.map(oneLine).joined(separator: ", ")
            block.append("- **\(oneLine(notice.title))**" + (from.isEmpty ? "" : " (\(from))"))
        }
        block.append("")
        block.append("_Synced from SEQTA at \(time(syncedAt, calendar: calendar))._")
        return Content(frontMatter: fm, block: block)
    }

    // MARK: Applying it to a note

    /// The note with its machine-owned parts replaced. Returns `text` unchanged (same bytes) when
    /// nothing differs.
    public static func apply(_ content: Content, to text: String) -> String {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: "\n") // CR stays on CRLF lines
        func bare(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }
        let cr = eol == "\r\n" ? "\r" : ""

        // Block between the markers.
        if let start = lines.firstIndex(where: { bare($0).trimmingCharacters(in: .whitespaces).hasPrefix(startMarker) }),
           let end = lines[(start + 1)...].firstIndex(where: { bare($0).trimmingCharacters(in: .whitespaces).hasPrefix(endMarker) }) {
            var block = content.block
            // The evening's shutdown lines (M7) live in the block too; a later sync keeps them.
            let old = lines[(start + 1)..<end].map(bare)
            if !block.contains(shutdownHeading), let heading = old.firstIndex(of: shutdownHeading) {
                var kept = Array(old[heading...])
                while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
                if block.last.map({ !$0.isEmpty }) ?? false { block.append("") }
                block += kept
            }
            let new = block.map { $0 + cr }
            if Array(lines[(start + 1)..<end]) != new { lines.replaceSubrange((start + 1)..<end, with: new) }
        }

        // Front matter: `---` on the first line up to the next `---`.
        if bare(lines.first ?? "") == "---",
           let close = lines.dropFirst().firstIndex(where: { bare($0) == "---" }) {
            var fm = Array(lines[1..<close])
            for (key, yaml) in content.frontMatter {
                let new = (key + ":" + yaml).components(separatedBy: "\n").map { $0 + cr }
                if let range = keyRange(key, in: fm.map(bare)) {
                    if Array(fm[range]) != new { fm.replaceSubrange(range, with: new) }
                } else {
                    fm.append(contentsOf: new)
                }
            }
            if fm != Array(lines[1..<close]) { lines.replaceSubrange(1..<close, with: fm) }
        }
        let out = lines.joined(separator: "\n")
        return out == text ? text : out
    }

    /// The lines of a top-level key: its own line plus the indented or `- ` lines under it.
    static func keyRange(_ key: String, in lines: [String]) -> Range<Int>? {
        guard let first = lines.firstIndex(where: { $0 == key + ":" || $0.hasPrefix(key + ":") && ($0.dropFirst(key.count + 1).first == " ") })
        else { return nil }
        var end = first + 1
        while end < lines.count {
            let line = lines[end]
            guard line.hasPrefix(" ") || line.hasPrefix("\t") || line == "-" || line.hasPrefix("- ") else { break }
            end += 1
        }
        return first..<end
    }

    /// A new note from the vault's template (Obsidian's `{{date}}`, `{{title}}`, `{{time}}`).
    public static func fromTemplate(_ template: String, day: DayStamp, now: Date, calendar: Calendar = .current) -> String {
        template.replacingOccurrences(of: "{{date}}", with: day.description)
            .replacingOccurrences(of: "{{title}}", with: day.description)
            .replacingOccurrences(of: "{{time}}", with: time(now, calendar: calendar))
    }

    // MARK: Reading the Top 3

    /// The filled-in items under `## Top 3` (read-only; the section is user-owned).
    public static func topThree(in text: String) -> [String] {
        var inSection = false
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                if inSection { break }
                inSection = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased() == "top 3"
                continue
            }
            guard inSection else { continue }
            if line.hasPrefix(startMarker) { break }
            var item = Substring(line)
            if let dot = item.firstIndex(where: { $0 == "." || $0 == ")" }), item[..<dot].allSatisfy(\.isNumber), dot > item.startIndex {
                item = item[item.index(after: dot)...]
            } else if item.hasPrefix("- ") || item.hasPrefix("* ") || item == "-" {
                item = item.dropFirst()
            } else {
                continue
            }
            var text = item.trimmingCharacters(in: .whitespaces)
            for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) { text = String(text.dropFirst(box.count)) }
            if !text.isEmpty, text != "[ ]" { out.append(text) }
        }
        return out
    }

    // MARK: YAML

    /// A block list of flow maps, one per line, as the vault's AGENTS.md shows them
    /// (`  - { time: "08:55-09:40", subject: History }`), or ` []` when empty.
    static func list(_ maps: [[(String, String)]]) -> String {
        guard !maps.isEmpty else { return " []" }
        return maps.map { map in
            "\n  - { " + map.map { "\($0.0): " + yamlScalar($0.1) }.joined(separator: ", ") + " }"
        }.joined()
    }

    /// Plain when that is safe YAML inside a flow map, else double-quoted.
    static func yamlScalar(_ raw: String) -> String {
        let value = oneLine(raw)
        let plainSafe: Bool = {
            guard let first = value.first, let last = value.last, first != " ", last != " " else { return false }
            if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return false }
            if value.contains(": ") || value.contains(" #") || value.hasSuffix(":") { return false }
            if value.contains(where: { ",[]{}".contains($0) }) { return false } // flow indicators
            if value.contains(":") && value.first!.isNumber { return false } // times like 08:55-09:40
            let lower = value.lowercased()
            if ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(lower) { return false }
            if Double(value) != nil { return false }
            return true
        }()
        if plainSafe { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let flat = oneLine(text)
        return flat.isEmpty ? nil : flat
    }

    /// Collapses whitespace and line breaks to single spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 3)).trimmingCharacters(in: .whitespaces) + "..."
    }

    static func iso(_ date: Date, calendar: Calendar) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = calendar.timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        TodayTime.format(TodayTime.minuteOfDay(date, calendar: calendar))
    }

    /// "Tue 10 Nov"
    static func dayLabel(_ day: DayStamp, calendar: Calendar) -> String {
        guard let date = day.date(calendar: calendar) else { return day.description }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }
}

// MARK: - Writing the note

extension DailyNote {
    public enum WriteResult: Equatable, Sendable {
        case written
        /// The note already had exactly this content.
        case unchanged
        /// No note today and no template to make one from.
        case noTemplate
        /// The vault folder isn't there.
        case noVault
    }

    /// Fills today's note's machine-owned parts. Creates the note from the vault's template first
    /// if it doesn't exist (the vault's AGENTS.md allows that). Atomic, and skips no-op writes.
    @discardableResult
    public static func update(_ content: Content, vault: VaultPaths, now: Date, calendar: Calendar = .current) throws -> WriteResult {
        guard FileManager.default.fileExists(atPath: vault.root.path) else { return .noVault }
        let url = try vault.writableURL(vault.daily(for: now, calendar: calendar))
        let text: String
        if let existing = try TextFile.read(url) {
            text = existing
        } else {
            guard let template = try TextFile.read(vault.root.appendingPathComponent(templatePath)) else { return .noTemplate }
            text = fromTemplate(template, day: DayStamp(now, calendar: calendar), now: now, calendar: calendar)
        }
        return try TextFile.write(apply(content, to: text), to: url) ? .written : .unchanged
    }

    /// The heading of the evening shutdown lines inside the machine block (PRD F6).
    public static let shutdownHeading = "### Shutdown"

    public enum ShutdownResult: Equatable, Sendable {
        case written
        /// The note has no machine markers (the user removed them), so nothing was written.
        case noMarkers
        case noTemplate
        case noVault
    }

    /// `text` with `- <line>` added under `### Shutdown` at the end of the machine block (made if
    /// missing). nil when the note has no markers. Everything outside the markers stays byte for byte.
    public static func appendingShutdown(_ line: String, to text: String) -> String? {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        let cr = eol == "\r\n" ? "\r" : ""
        var lines = text.components(separatedBy: "\n")
        func bare(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }
        guard let start = lines.firstIndex(where: { bare($0).trimmingCharacters(in: .whitespaces).hasPrefix(startMarker) }),
              let end = lines[(start + 1)...].firstIndex(where: { bare($0).trimmingCharacters(in: .whitespaces).hasPrefix(endMarker) })
        else { return nil }
        var block = lines[(start + 1)..<end].map(bare)
        while block.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { block.removeLast() }
        if !block.contains(shutdownHeading) {
            if !block.isEmpty { block.append("") }
            block.append(shutdownHeading)
        }
        block.append("- " + oneLine(line))
        lines.replaceSubrange((start + 1)..<end, with: block.map { $0 + cr })
        return lines.joined(separator: "\n")
    }

    /// Adds one shutdown line to today's note's machine block (creating the note from the vault's
    /// template first, as the sync does). Atomic; never touches anything outside the markers.
    @discardableResult
    public static func appendShutdown(_ line: String, vault: VaultPaths, now: Date, calendar: Calendar = .current) throws -> ShutdownResult {
        guard FileManager.default.fileExists(atPath: vault.root.path) else { return .noVault }
        let url = try vault.writableURL(vault.daily(for: now, calendar: calendar))
        let text: String
        if let existing = try TextFile.read(url) {
            text = existing
        } else {
            guard let template = try TextFile.read(vault.root.appendingPathComponent(templatePath)) else { return .noTemplate }
            text = fromTemplate(template, day: DayStamp(now, calendar: calendar), now: now, calendar: calendar)
        }
        guard let updated = appendingShutdown(line, to: text) else { return .noMarkers }
        try TextFile.write(updated, to: url)
        return .written
    }

    /// Top 3 from today's note, or [] if there's no note.
    public static func topThree(vault: VaultPaths, now: Date, calendar: Calendar = .current) -> [String] {
        guard let text = try? TextFile.read(vault.daily(for: now, calendar: calendar)) else { return [] }
        return topThree(in: text)
    }
}
