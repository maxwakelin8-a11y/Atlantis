import Foundation

/// The whole of `machine/tasks.md`: task lines plus every other line, in file order.
///
/// Reading and writing back an unchanged file gives the same bytes. Editing a task rewrites
/// only that task's lines; adding appends after the last task (PRD F2, §9).
public struct TaskFile: Equatable, Sendable {
    public enum Entry: Equatable, Sendable {
        case other(RawLine)
        case task(TaskItem)
    }

    public private(set) var entries: [Entry]
    /// The file's line ending ("\r\n" if its first ending is CRLF, else "\n").
    public let lineEnding: String

    public init(parsing text: String) {
        var entries: [Entry] = []
        var lines: [RawLine] = []
        var current = ""
        for ch in text {
            if ch == "\n" || ch == "\r\n" {
                lines.append(RawLine(text: current, eol: String(ch)))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { lines.append(RawLine(text: current, eol: "")) }
        let ending = lines.first { !$0.eol.isEmpty }?.eol ?? "\n"

        var inFence = false
        var seen: [String: Int] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let stripped = line.text.drop { $0 == " " || $0 == "\t" }
            if stripped.hasPrefix("```") || stripped.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, var task = TaskItem.parse(line: line.text, eol: line.eol) {
                task.eolStyle = ending
                var j = i + 1
                while j < lines.count, Self.isContinuation(lines[j].text) {
                    task.children.append(lines[j])
                    j += 1
                }
                if task.blockID == nil {
                    let hash = Self.hash(line.text)
                    let n = seen[hash, default: 0]
                    seen[hash] = n + 1
                    task.localID = "~\(hash)-\(n)"
                }
                entries.append(.task(task))
                i = j
            } else {
                entries.append(.other(line))
                i += 1
            }
        }
        self.entries = entries
        self.lineEnding = ending
    }

    /// An indented, non-blank line belongs to the task above it.
    private static func isContinuation(_ text: String) -> Bool {
        guard let first = text.first, first == " " || first == "\t" else { return false }
        return !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// FNV-1a, 32 bit. Only used to tell id-less lines apart.
    private static func hash(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(h, radix: 16)
    }

    public func serialized() -> String {
        var out = ""
        for entry in entries {
            switch entry {
            case let .other(line): out += line.text + line.eol
            case let .task(task): out += task.serialized()
            }
        }
        return out
    }

    public var tasks: [TaskItem] {
        entries.compactMap { if case let .task(t) = $0 { t } else { nil } }
    }

    private func index(of id: String) -> Int? {
        entries.firstIndex { if case let .task(t) = $0 { t.id == id } else { false } }
    }

    public func task(id: String) -> TaskItem? {
        index(of: id).flatMap { if case let .task(t) = entries[$0] { t } else { nil } }
    }

    // MARK: Changes

    /// `t-` plus 8 hex digits, not used by any task in the file.
    public func newID() -> String {
        let used = Set(tasks.compactMap(\.blockID))
        while true {
            let id = "t-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
            if !used.contains(id) { return id }
        }
    }

    /// Appends `item` after the last task (and its continuation lines), or at the end of the
    /// file when there are no tasks. Gives it an id and an `added` date. Returns the new id.
    @discardableResult
    public mutating func add(_ item: TaskItem, today: DayStamp) -> String {
        var item = item
        item.eolStyle = lineEnding
        item.blockID = item.blockID ?? newID()
        if item.added == nil { item.added = today }
        item.original = nil

        let lastTask = entries.lastIndex { if case .task = $0 { true } else { false } }
        let insertAt = lastTask.map { $0 + 1 } ?? entries.count
        var newEOL = lineEnding
        if insertAt == entries.count, let last = entries.indices.last, Self.lastEOL(of: entries[last]).isEmpty {
            // The file had no ending after its last line: the old last line gets one and the
            // new line takes over "no ending at the end of the file".
            setLastEOL(at: last, to: lineEnding)
            newEOL = ""
        }
        item.eol = newEOL
        item.restoreEndings(lastEOL: newEOL)
        entries.insert(.task(item), at: insertAt)
        return item.blockID!
    }

    private static func lastEOL(of entry: Entry) -> String {
        switch entry {
        case let .other(l): l.eol
        case let .task(t): t.lastEOL
        }
    }

    private mutating func setLastEOL(at index: Int, to eol: String) {
        switch entries[index] {
        case var .other(l):
            l.eol = eol
            entries[index] = .other(l)
        case var .task(t):
            if t.children.isEmpty { t.eol = eol } else { t.children[t.children.count - 1].eol = eol }
            entries[index] = .task(t)
        }
    }

    /// Applies `change` to the task with this id. A task with no `^id` gets one if it changed.
    /// Returns the task's id after the change (it differs when an id was just assigned), or
    /// nil if no task has that id.
    @discardableResult
    public mutating func update(id: String, _ change: (inout TaskItem) -> Void) -> String? {
        guard let i = index(of: id), case let .task(old) = entries[i] else { return nil }
        var item = old
        change(&item)
        guard item != old else { return old.id }
        if item.blockID == nil { item.blockID = newID() }
        item.restoreEndings(lastEOL: old.lastEOL)
        entries[i] = .task(item)
        return item.id
    }

    /// Removes the task and its continuation lines.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard let i = index(of: id), case let .task(old) = entries[i] else { return false }
        entries.remove(at: i)
        // If the removed task ended the file without a newline, the new last line takes that.
        if i == entries.count, old.lastEOL.isEmpty, let last = entries.indices.last { setLastEOL(at: last, to: "") }
        return true
    }
}
