import Foundation

/// One line of the file with its own line ending, so a file round-trips byte for byte
/// (LF, CRLF, or no ending on the last line).
public struct RawLine: Equatable, Sendable {
    public var text: String
    public var eol: String
    public init(text: String, eol: String) {
        self.text = text
        self.eol = eol
    }
}

/// Everything after a task's title, in file order: Dataview fields and any stray text.
public enum TaskPiece: Equatable, Sendable {
    case field(key: String, value: String)
    case text(String)
}

public struct Subtask: Equatable, Sendable, Identifiable {
    /// Position among the task's subtasks (not among all continuation lines).
    public var id: Int
    public var isDone: Bool
    public var title: String
}

/// A task: one `- [ ] Title [due:: 2026-11-10] … ^t-ab12cd34` line plus its indented
/// continuation lines (subtasks, notes). PRD §9.
///
/// Unknown fields and their order are kept. A line that wasn't changed is written back as
/// the exact bytes that were read, so only edited lines are ever rewritten.
public struct TaskItem: Equatable, Sendable, Identifiable {
    public var bullet: Character = "-"
    /// The character inside the box: " " open, "x" done, "-" cancelled.
    public var status: Character = " "
    public var title: String {
        didSet { title = Self.cleanTitle(title) }
    }
    /// Fields and stray text after the title.
    public var pieces: [TaskPiece] = []
    /// The `^…` block id at the end of the line (`t-` + 8 hex for ids Atlantis makes).
    public var blockID: String?
    /// Indented lines under the task.
    public var children: [RawLine] = []
    public var eol: String = "\n"
    /// The file's line ending, for lines this task adds (not part of equality).
    var eolStyle: String = "\n"

    /// Identity for a line that has no `^id` yet (derived from its text).
    var localID: String = ""
    /// The line as read, and what it rendered to then; used to keep unchanged lines exact.
    var original: (raw: String, render: String)?

    public var id: String { blockID ?? localID }

    public init(title: String) {
        self.title = Self.cleanTitle(title)
        self.localID = "~new-\(UUID().uuidString)"
    }

    public static func == (a: TaskItem, b: TaskItem) -> Bool {
        a.bullet == b.bullet && a.status == b.status && a.title == b.title && a.pieces == b.pieces
            && a.blockID == b.blockID && a.children == b.children && a.eol == b.eol && a.localID == b.localID
    }

    static func cleanTitle(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Status

    public var isDone: Bool { status == "x" || status == "X" }
    public var isCancelled: Bool { status == "-" }
    /// Open means not done and not cancelled.
    public var isOpen: Bool { !isDone && !isCancelled }

    public mutating func markDone(on day: DayStamp) {
        status = "x"
        if doneDate == nil { doneDate = day }
    }

    public mutating func reopen() {
        status = " "
        setField("done", nil)
    }

    // MARK: Fields

    public func field(_ key: String) -> String? {
        for case let .field(k, v) in pieces where k.caseInsensitiveCompare(key) == .orderedSame {
            let trimmed = v.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Sets a field in place (or appends it). Nil or empty removes it.
    public mutating func setField(_ key: String, _ value: String?) {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "]", with: "")
        let index = pieces.firstIndex { piece in
            if case let .field(k, _) = piece { return k.caseInsensitiveCompare(key) == .orderedSame }
            return false
        }
        switch (index, clean) {
        case let (i?, v?) where !v.isEmpty:
            guard case let .field(k, _) = pieces[i] else { return }
            pieces[i] = .field(key: k, value: v)
        case (let i?, _):
            pieces.remove(at: i)
        case (nil, let v?) where !v.isEmpty:
            pieces.append(.field(key: key, value: v))
        default:
            break
        }
    }

    public var due: DayStamp? {
        get { field("due").flatMap { DayStamp($0) } }
        set { setField("due", newValue?.description) }
    }
    /// Day the task is pulled into (`plan::`, used by the SEQTA dashboard).
    public var plan: DayStamp? {
        get { field("plan").flatMap { DayStamp($0) } }
        set { setField("plan", newValue?.description) }
    }
    /// Day of `scheduled::` (the value may carry a time, which is kept).
    public var scheduledDay: DayStamp? { field("scheduled").flatMap { DayStamp($0) } }
    public var added: DayStamp? {
        get { field("added").flatMap { DayStamp($0) } }
        set { setField("added", newValue?.description) }
    }
    public var doneDate: DayStamp? {
        get { field("done").flatMap { DayStamp($0) } }
        set { setField("done", newValue?.description) }
    }
    public var estimateMinutes: Int? {
        get { field("est").flatMap { Estimate.parse($0) } }
        set { setField("est", newValue.map(Estimate.format)) }
    }
    /// Priority 1 (high) to 3 (low).
    public var priority: Int? {
        get { field("pri").flatMap { Int($0.drop { !$0.isNumber }) }.flatMap { (1...3).contains($0) ? $0 : nil } }
        set { setField("pri", newValue.flatMap { (1...3).contains($0) ? String($0) : nil }) }
    }
    public var mode: String? {
        get { field("mode") }
        set { setField("mode", newValue) }
    }
    public var area: String? {
        get { field("area") }
        set { setField("area", newValue) }
    }
    public var project: String? {
        get { field("project") }
        set { setField("project", newValue) }
    }
    /// The bot the task is assigned to (`agent::`, a bot id like `school`), PRD §7b.
    public var agent: String? {
        get { field("agent") }
        set { setField("agent", newValue) }
    }
    /// Where the task came from (`source::` or the older `from::`).
    public var source: String? { field("source") ?? field("from") }

    /// The Area/Mode a task is grouped under.
    public var group: String? {
        get { area ?? mode }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespaces) ?? ""
            if value.isEmpty { area = nil; mode = nil; return }
            if let current = group, current.caseInsensitiveCompare(value) == .orderedSame { return }
            if TaskModes.all.contains(value.lowercased()) { mode = value.lowercased(); area = nil }
            else { area = value; mode = nil }
        }
    }

    // MARK: Continuation lines

    private static func parseChild(_ text: String) -> (done: Bool, title: String)? {
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        let c = Array(trimmed.prefix(6))
        guard c.count >= 5, "-*+".contains(c[0]), c[1] == " ", c[2] == "[", c[4] == "]" else { return nil }
        if c.count > 5, c[5] != " " { return nil }
        return (c[3] == "x" || c[3] == "X", String(trimmed.dropFirst(6)))
    }

    public var subtasks: [Subtask] {
        var out: [Subtask] = []
        for child in children {
            if let s = Self.parseChild(child.text) { out.append(Subtask(id: out.count, isDone: s.done, title: s.title)) }
        }
        return out
    }

    /// Indented text lines that aren't subtasks, with their common indent removed.
    public var notes: String {
        let lines = children.map(\.text).filter { Self.parseChild($0) == nil }
        let indent = lines.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(indent)) }.joined(separator: "\n")
    }

    /// Replaces the note lines (subtask lines stay put). Notes sit right under the task line.
    /// Blank lines are dropped: a blank line would end the task's block in the file.
    public mutating func setNotes(_ text: String) {
        let kept = children.filter { Self.parseChild($0.text) != nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        children = lines.map { RawLine(text: "  " + $0, eol: eolStyle) } + kept
    }

    /// Flips one subtask's box, changing only that character.
    public mutating func toggleSubtask(_ index: Int) {
        var seen = 0
        for i in children.indices {
            guard Self.parseChild(children[i].text) != nil else { continue }
            defer { seen += 1 }
            guard seen == index else { continue }
            var chars = Array(children[i].text)
            if let open = chars.firstIndex(of: "["), open + 1 < chars.count {
                chars[open + 1] = (chars[open + 1] == " ") ? "x" : " "
                children[i].text = String(chars)
            }
            return
        }
    }

    public mutating func addSubtask(_ title: String) {
        let clean = Self.cleanTitle(title)
        guard !clean.isEmpty else { return }
        children.append(RawLine(text: "  - [ ] " + clean, eol: eolStyle))
    }

    /// Line ending of the last line of this task (its last continuation line, or its own).
    var lastEOL: String { children.last?.eol ?? eol }

    /// After an edit: every line but the file's last has an ending, and the last line keeps
    /// whatever ending the old last line had (including none at the end of a file).
    mutating func restoreEndings(lastEOL: String) {
        if children.isEmpty { eol = lastEOL; return }
        if eol.isEmpty { eol = eolStyle }
        for i in children.indices.dropLast() where children[i].eol.isEmpty { children[i].eol = eolStyle }
        children[children.count - 1].eol = lastEOL
    }

    // MARK: Text

    func render() -> String {
        var parts = ["\(bullet) [\(status)]"]
        if !title.isEmpty { parts.append(title) }
        for piece in pieces {
            switch piece {
            case let .field(k, v): parts.append("[\(k):: \(v)]")
            case let .text(t): parts.append(t)
            }
        }
        if let blockID { parts.append("^\(blockID)") }
        return parts.joined(separator: " ")
    }

    /// The task's own line: the original bytes if nothing changed, else a fresh render.
    public var lineText: String {
        let fresh = render()
        if let original, original.render == fresh { return original.raw }
        return fresh
    }

    /// Main line and continuation lines, as they go in the file.
    func serialized() -> String {
        var out = lineText + eol
        for child in children { out += child.text + child.eol }
        return out
    }

    // MARK: Parsing

    /// Parses `- [ ] …`. Returns nil if the line isn't a top-level task line.
    static func parse(line: String, eol: String) -> TaskItem? {
        let c = Array(line.prefix(6))
        guard c.count >= 5, "-*+".contains(c[0]), c[1] == " ", c[2] == "[", c[4] == "]",
              c[3] != "[", c[3] != "]" else { return nil }
        if c.count > 5, c[5] != " " { return nil }
        var body = String(line.dropFirst(min(6, line.count))).trimmingCharacters(in: .whitespaces)

        var blockID: String?
        if let caret = body.lastIndex(of: "^"),
           body[caret...].dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
           body.index(after: caret) < body.endIndex,
           caret == body.startIndex || body[body.index(before: caret)] == " " {
            blockID = String(body[body.index(after: caret)...])
            body = String(body[..<caret]).trimmingCharacters(in: .whitespaces)
        }

        let (title, pieces) = scan(body)
        var item = TaskItem(title: title)
        item.bullet = c[0]
        item.status = c[3]
        item.pieces = pieces
        item.blockID = blockID
        item.eol = eol
        item.localID = ""
        item.original = (line, item.render())
        return item
    }

    /// Splits a task body into its title and the fields/text that follow.
    static func scan(_ body: String) -> (String, [TaskPiece]) {
        let chars = Array(body)
        var title: String?
        var pieces: [TaskPiece] = []
        var buffer = ""
        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespaces)
            buffer = ""
            guard !text.isEmpty else { return }
            if title == nil && pieces.isEmpty { title = text } else { pieces.append(.text(text)) }
        }
        var i = 0
        while i < chars.count {
            if chars[i] == "[", let (key, value, end) = matchField(chars, i) {
                flush()
                pieces.append(.field(key: key, value: value))
                i = end
                continue
            }
            buffer.append(chars[i])
            i += 1
        }
        flush()
        return (title ?? "", pieces)
    }

    /// Matches `[key:: value]` at `start`. Returns the key, value and the index after `]`.
    private static func matchField(_ c: [Character], _ start: Int) -> (String, String, Int)? {
        var i = start + 1
        guard i < c.count, c[i].isASCII, c[i].isLetter else { return nil }
        var key = ""
        while i < c.count, c[i].isASCII, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "-" {
            key.append(c[i]); i += 1
        }
        guard i + 1 < c.count, c[i] == ":", c[i + 1] == ":" else { return nil }
        i += 2
        var value = ""
        while i < c.count, c[i] != "]", c[i] != "[" { value.append(c[i]); i += 1 }
        guard i < c.count, c[i] == "]" else { return nil }
        return (key, value.trimmingCharacters(in: .whitespaces), i + 1)
    }
}

public enum TaskModes {
    /// Modes shared with the AI Dock (PRD §10).
    public static let all: [String] = ["school", "building", "bjj", "social"]

    /// "school" → "School", "bjj" → "BJJ"; other names just get a capital first letter.
    public static func displayName(_ name: String) -> String {
        if name.lowercased() == "bjj" { return "BJJ" }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Estimates are stored as `45m`, `1h`, `1h30m`.
public enum Estimate {
    public static func format(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h\(m)m"
    }

    /// `45m`, `45 min`, `1h`, `1.5h`, `1h30m`, `90min`. Needs a unit. Returns minutes (1…1440).
    public static func parse(_ raw: String) -> Int? {
        let s = raw.lowercased().filter { !$0.isWhitespace }
        guard !s.isEmpty else { return nil }
        // Split into number+unit pairs: "1h30m" → [(1,h),(30,m)]
        var total = 0.0
        var digits = ""
        var unit = ""
        var pairs = 0
        func commit() -> Bool {
            guard let value = Double(digits), !unit.isEmpty else { return false }
            switch unit {
            case "m", "min", "mins", "minute", "minutes": total += value
            case "h", "hr", "hrs", "hour", "hours": total += value * 60
            default: return false
            }
            pairs += 1
            digits = ""; unit = ""
            return true
        }
        for ch in s {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty { guard commit() else { return nil } }
                digits.append(ch)
            } else if ch.isLetter {
                guard !digits.isEmpty else { return nil }
                unit.append(ch)
            } else { return nil }
        }
        guard commit(), pairs <= 2 else { return nil }
        let minutes = Int(total.rounded())
        return (1...1440).contains(minutes) ? minutes : nil
    }
}
