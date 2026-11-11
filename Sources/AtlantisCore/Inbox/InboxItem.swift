import Foundation

/// One proposal in the Inbox (PRD F4). Stored as one line of `machine/atlantis/inbox.md`:
///
///     - [ ] Add task: Turing essay draft [kind:: task.add] [source:: seqta:assessment:1234] [due:: 2026-11-07] [created:: 2026-11-09] ^i-ab12cd34
///
/// `[ ]` is pending, `[x]` accepted, `[-]` dismissed. Fields other than `kind`, `source` and
/// `created` are kept in order in `fields` and written back as they were.
public struct InboxItem: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable, CaseIterable {
        case pending, accepted, dismissed

        /// The character between the brackets.
        public var marker: Character {
            switch self {
            case .pending: " "
            case .accepted: "x"
            case .dismissed: "-"
            }
        }

        init?(marker: Character) {
            switch marker {
            case " ": self = .pending
            case "x", "X": self = .accepted
            case "-": self = .dismissed
            default: return nil
            }
        }
    }

    public struct Field: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var id: String
    public var state: State
    /// e.g. `task.add`, `task.update`, `message.draft`, `note`, `doc.edit`. Empty if the line had none.
    public var kind: String
    public var title: String
    /// e.g. `seqta:assessment:1234`, `agent:school`, `mcp:claude-code`. Empty if none.
    public var source: String
    /// `YYYY-MM-DD`. Empty if the line had none.
    public var created: String
    /// Every other `[key:: value]`, in file order.
    public var fields: [Field]

    public init(id: String = InboxItem.newID(), state: State = .pending, kind: String, title: String,
                source: String = "", created: String = InboxItem.today(), fields: [Field] = []) {
        self.id = id
        self.state = state
        self.kind = kind
        self.title = title
        self.source = source
        self.created = created
        self.fields = fields
    }

    public func field(_ key: String) -> String? {
        fields.first { $0.key == key }?.value
    }

    public mutating func setField(_ key: String, _ value: String?) {
        if let index = fields.firstIndex(where: { $0.key == key }) {
            if let value { fields[index].value = value } else { fields.remove(at: index) }
        } else if let value {
            fields.append(Field(key: key, value: value))
        }
    }

    // MARK: Ids and dates

    /// `i-` and 8 lowercase hex digits.
    public static func newID() -> String {
        "i-" + String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    public static func isValidID(_ id: String) -> Bool {
        guard id.hasPrefix("i-"), id.utf8.count == 10 else { return false }
        return id.dropFirst(2).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Today as `YYYY-MM-DD` in the given calendar's time zone.
    public static func today(now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Line format

    /// The line for this item, without a line ending.
    public func line() -> String {
        var out = "- [\(state.marker)] \(Self.cleanTitle(title))"
        func add(_ key: String, _ value: String) {
            out += " [\(key):: \(Self.cleanValue(value))]"
        }
        if !kind.isEmpty { add("kind", kind) }
        if !source.isEmpty { add("source", source) }
        for field in fields {
            add(Self.cleanKey(field.key), field.value)
        }
        if !created.isEmpty { add("created", created) }
        out += " ^\(id)"
        return out
    }

    /// Parses one line (no line ending). Returns nil if it isn't an Inbox item.
    public init?(line rawLine: String) {
        var line = Substring(rawLine)
        if line.hasSuffix("\r") { line = line.dropLast() }
        guard line.hasPrefix("- ["), line.count >= 6 else { return nil }
        let markerIndex = line.index(line.startIndex, offsetBy: 3)
        guard let state = State(marker: line[markerIndex]) else { return nil }
        let closeIndex = line.index(after: markerIndex)
        guard line[closeIndex] == "]" else { return nil }
        var rest = line[line.index(after: closeIndex)...]
        guard rest.hasPrefix(" ") else { return nil }
        rest = rest.dropFirst()

        // Trailing ` ^i-xxxxxxxx`.
        guard let caret = rest.lastIndex(of: "^"), caret > rest.startIndex,
              rest[rest.index(before: caret)] == " " else { return nil }
        let id = String(rest[rest.index(after: caret)...])
        guard Self.isValidID(id) else { return nil }
        rest = rest[..<rest.index(before: caret)]

        // Trailing ` [key:: value]` fields, taken from the end.
        var parsed: [Field] = []
        while rest.hasSuffix("]") {
            let body = rest.dropLast()
            let segmentStart = body.lastIndex(of: "]").map { body.index(after: $0) } ?? body.startIndex
            let segment = body[segmentStart...]
            guard let match = segment.range(of: #" \[[A-Za-z][A-Za-z0-9_-]*:: "#, options: .regularExpression) else { break }
            let opener = segment[match]
            let key = String(opener.dropFirst(2).dropLast(3))
            let value = String(segment[match.upperBound...])
            parsed.append(Field(key: key, value: value))
            rest = body[..<match.lowerBound]
            if match.lowerBound != segment.startIndex { break } // text before it belongs to the title
        }
        parsed.reverse()

        var kind = "", source = "", created = ""
        var extras: [Field] = []
        for field in parsed {
            switch field.key {
            case "kind" where kind.isEmpty: kind = field.value
            case "source" where source.isEmpty: source = field.value
            case "created" where created.isEmpty: created = field.value
            default: extras.append(field)
            }
        }
        self.init(id: id, state: state, kind: kind, title: String(rest), source: source,
                  created: created, fields: extras)
    }

    // MARK: Sanitising (keeps a written line parseable)

    static func cleanTitle(_ text: String) -> String {
        flatten(text).replacingOccurrences(of: ":: ", with: ": ")
    }

    static func cleanValue(_ text: String) -> String {
        flatten(text).replacingOccurrences(of: "]", with: ")")
    }

    static func cleanKey(_ text: String) -> String {
        let allowed = text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        guard let first = allowed.first, first.isLetter else { return "x" + allowed }
        return allowed
    }

    private static func flatten(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
