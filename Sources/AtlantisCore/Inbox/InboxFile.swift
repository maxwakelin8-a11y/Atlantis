import Foundation

/// The text of `inbox.md`, with Inbox items found in it.
///
/// Everything that isn't an item line (headings, notes, blank lines), every line ending and the
/// trailing newline stay byte-for-byte as they were. An edit changes only the edited line.
public struct InboxFile: Equatable, Sendable {
    /// The file split on `\n`. A trailing newline leaves a final empty element, so
    /// `lines.joined("\n")` is always the exact original text. A CRLF file keeps its `\r`s.
    private var lines: [String]

    public init(text: String = "") {
        lines = text.components(separatedBy: "\n")
    }

    public var text: String { lines.joined(separator: "\n") }

    /// Items in file order. Duplicated ids keep only the first.
    public var items: [InboxItem] {
        var seen = Set<String>()
        return itemLines().compactMap { _, item in seen.insert(item.id).inserted ? item : nil }
    }

    public func item(id: String) -> InboxItem? {
        itemLines().first { $0.item.id == id }?.item
    }

    /// Changes the state by swapping only the marker character. Returns false if no such item
    /// (or it already has that state).
    @discardableResult
    public mutating func setState(_ state: InboxItem.State, id: String) -> Bool {
        guard let (index, item) = itemLines().first(where: { $0.item.id == id }), item.state != state else { return false }
        var chars = Array(lines[index])
        chars[3] = state.marker
        lines[index] = String(chars)
        return true
    }

    /// Rewrites the item's line from `item` (keeps the line's own ending). Returns false if
    /// there is no item with that id, or nothing changed.
    @discardableResult
    public mutating func replace(_ item: InboxItem) -> Bool {
        guard let (index, _) = itemLines().first(where: { $0.item.id == item.id }) else { return false }
        let ending = lines[index].hasSuffix("\r") ? "\r" : ""
        let new = item.line() + ending
        guard new != lines[index] else { return false }
        lines[index] = new
        return true
    }

    /// Adds the item after the last item (or at the end, under a `# Inbox` heading in an empty file).
    public mutating func append(_ item: InboxItem) {
        let crlf = lines.contains { $0.hasSuffix("\r") }
        let new = item.line() + (crlf ? "\r" : "")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines = ["# Inbox", "", new, ""]
        } else if let (index, _) = itemLines().last {
            lines.insert(new, at: index + 1)
        } else if lines.last == "" {
            lines.insert(new, at: lines.count - 1)
        } else {
            lines.append(new)
            lines.append("")
        }
    }

    private func itemLines() -> [(index: Int, item: InboxItem)] {
        lines.enumerated().compactMap { index, line in
            InboxItem(line: line).map { (index, $0) }
        }
    }
}
