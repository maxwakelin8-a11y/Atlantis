import Foundation
import Testing
@testable import AtlantisCore

@Suite struct InboxTests {
    static let sample = "- [ ] Add task: Turing essay draft [kind:: task.add] [source:: seqta:assessment:1234] [due:: 2026-11-07] [created:: 2026-11-09] ^i-ab12cd34"

    // MARK: Parsing

    @Test func parsesEveryPart() throws {
        let item = try #require(InboxItem(line: Self.sample))
        #expect(item.id == "i-ab12cd34")
        #expect(item.state == .pending)
        #expect(item.title == "Add task: Turing essay draft")
        #expect(item.kind == "task.add")
        #expect(item.source == "seqta:assessment:1234")
        #expect(item.created == "2026-11-09")
        #expect(item.fields == [.init(key: "due", value: "2026-11-07")])
    }

    @Test func parsesStates() throws {
        for (marker, state) in [(" ", InboxItem.State.pending), ("x", .accepted), ("X", .accepted), ("-", .dismissed)] {
            let item = try #require(InboxItem(line: "- [\(marker)] Thing [kind:: note] ^i-00000001"))
            #expect(item.state == state)
        }
        #expect(InboxItem(line: "- [?] Thing ^i-00000001") == nil)
    }

    @Test func ignoresLinesThatAreNotItems() {
        #expect(InboxItem(line: "# Inbox") == nil)
        #expect(InboxItem(line: "") == nil)
        #expect(InboxItem(line: "- [ ] No id here [kind:: note]") == nil)
        #expect(InboxItem(line: "- [ ] Bad id ^i-xyz") == nil)
        #expect(InboxItem(line: "- [ ] Upper hex ^i-ABCDEF12") == nil)
        #expect(InboxItem(line: "- plain bullet ^i-ab12cd34") == nil)
    }

    @Test func missingFieldsAreEmpty() throws {
        let item = try #require(InboxItem(line: "- [ ] Just a title ^i-0a0b0c0d"))
        #expect(item.kind == "" && item.source == "" && item.created == "" && item.fields.isEmpty)
        #expect(item.line() == "- [ ] Just a title ^i-0a0b0c0d")
    }

    @Test func unknownFieldsAreKeptInOrder() throws {
        let line = "- [ ] Do it [kind:: task.add] [project:: History] [pri:: 2] [weird_key-1:: a b c] [created:: 2026-11-09] ^i-12345678"
        let item = try #require(InboxItem(line: line))
        #expect(item.fields.map(\.key) == ["project", "pri", "weird_key-1"])
        #expect(item.field("weird_key-1") == "a b c")
        #expect(item.line() == line)
    }

    @Test func bracketsAndColonsInTheTitleSurvive() throws {
        let item = try #require(InboxItem(line: "- [ ] Read [chapter 3] now: yes [kind:: note] [due:: 2026-11-10] ^i-aaaaaaaa"))
        #expect(item.title == "Read [chapter 3] now: yes")
        #expect(item.kind == "note")
        #expect(item.field("due") == "2026-11-10")
    }

    @Test func unicodeTitle() throws {
        let line = "- [ ] Écrire l'essai — café ☕ 日本語 [kind:: note] ^i-deadbeef"
        let item = try #require(InboxItem(line: line))
        #expect(item.title == "Écrire l'essai — café ☕ 日本語")
        #expect(item.line() == line)
    }

    @Test func writtenLinesParseBackToTheSameItem() throws {
        let item = InboxItem(kind: "message.draft", title: "Reply to Mr Smith: [urgent]", source: "agent:school",
                             created: "2026-11-09", fields: [.init(key: "to", value: "Mr Smith"), .init(key: "due", value: "tomorrow")])
        let back = try #require(InboxItem(line: item.line()))
        #expect(back == item)
    }

    @Test func sanitisesWhatWouldBreakALine() throws {
        let item = InboxItem(kind: "note", title: "Two\nlines [a:: b]", source: "agent:x",
                             created: "2026-11-09", fields: [.init(key: "my key", value: "has ] bracket\nand newline")])
        let line = item.line()
        #expect(!line.contains("\n"))
        let back = try #require(InboxItem(line: line))
        #expect(back.id == item.id)
        #expect(back.kind == "note")
        #expect(back.fields.count == 1)
        #expect(back.fields[0].key == "mykey")
        #expect(back.fields[0].value == "has ) bracket and newline")
    }

    @Test func idsLookRight() {
        for _ in 0..<50 { #expect(InboxItem.isValidID(InboxItem.newID())) }
        #expect(InboxItem.isValidID("i-00ff00ff"))
        #expect(!InboxItem.isValidID("i-00ff00f"))
        #expect(!InboxItem.isValidID("x-00ff00ff"))
    }

    @Test func todayFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Perth")!
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9))!
        #expect(InboxItem.today(now: date, calendar: cal) == "2026-03-07")
    }

    // MARK: File round trip

    static let messy = [
        "---", "title: Inbox", "---", "",
        "# Inbox  ", "",
        "Some note I wrote in Obsidian — keep this, é ☕",
        Self.sample,
        "- [x] Done thing [kind:: task.add] [created:: 2026-11-08] ^i-11111111",
        "",
        "- [-] Nope [kind:: note] ^i-22222222",
        "- a plain bullet that is not an item",
        "## Footer\t",
    ].joined(separator: "\n")

    @Test(arguments: [
        "", "\n", "# Inbox\n", "# Inbox", messy, messy + "\n", messy + "\n\n",
        messy.replacingOccurrences(of: "\n", with: "\r\n"),
        messy.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n",
        "\n\n\n", "no items at all\nreally", sample2,
    ])
    func roundTripIsByteIdentical(text: String) {
        let file = InboxFile(text: text)
        #expect(file.text == text)
        #expect(Data(file.text.utf8) == Data(text.utf8))
    }

    static let sample2 = "- [ ] Only line, no newline ^i-33333333"

    @Test func findsItemsInAMessyFile() {
        let file = InboxFile(text: Self.messy)
        #expect(file.items.map(\.id) == ["i-ab12cd34", "i-11111111", "i-22222222"])
        #expect(file.items.map(\.state) == [.pending, .accepted, .dismissed])
    }

    @Test func crlfItemsParse() {
        let file = InboxFile(text: Self.messy.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(file.items.count == 3)
        #expect(file.item(id: "i-ab12cd34")?.title == "Add task: Turing essay draft")
    }

    // MARK: Changes touch one line

    private func changedLines(_ a: String, _ b: String) -> [Int] {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        #expect(x.count == y.count)
        return zip(x, y).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
    }

    @Test(arguments: [false, true])
    func stateChangeTouchesOnlyOneLine(crlf: Bool) {
        var text = Self.messy
        if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        var file = InboxFile(text: text)
        let changed1 = file.setState(.accepted, id: "i-ab12cd34")
        #expect(changed1)
        #expect(changedLines(text, file.text) == [7])
        let line = file.text.components(separatedBy: "\n")[7]
        #expect(line.hasPrefix("- [x] Add task: Turing essay draft"))
        #expect(line.hasSuffix(crlf ? "^i-ab12cd34\r" : "^i-ab12cd34"))
        #expect(file.item(id: "i-ab12cd34")?.state == .accepted)

        let changed3 = file.setState(.dismissed, id: "i-11111111")

        #expect(changed3)
        #expect(file.item(id: "i-11111111")?.state == .dismissed)
        #expect(file.item(id: "i-22222222")?.state == .dismissed)
    }

    @Test func stateChangeToSameStateOrMissingIdDoesNothing() {
        var file = InboxFile(text: Self.messy)
        let changed5 = file.setState(.pending, id: "i-ab12cd34")
        #expect(!changed5)
        let changed7 = file.setState(.accepted, id: "i-ffffffff")
        #expect(!changed7)
        #expect(file.text == Self.messy)
    }

    @Test func stateChangeKeepsOddFormattingOfTheLine() {
        let odd = "- [ ] Odd  spacing   [zeta:: 1]   [kind:: note] ^i-44444444"
        var file = InboxFile(text: "# Inbox\n\(odd)\n")
        file.setState(.accepted, id: "i-44444444")
        #expect(file.text == "# Inbox\n- [x] Odd  spacing   [zeta:: 1]   [kind:: note] ^i-44444444\n")
    }

    @Test func editRewritesOnlyThatLine() throws {
        var file = InboxFile(text: Self.messy)
        var item = try #require(file.item(id: "i-ab12cd34"))
        item.title = "Add task: Turing essay (final)"
        item.setField("due", "2026-11-12")
        item.setField("project", "History")
        let changed9 = file.replace(item)
        #expect(changed9)
        #expect(changedLines(Self.messy, file.text) == [7])
        let back = try #require(file.item(id: "i-ab12cd34"))
        #expect(back == item)
        #expect(back.fields.map(\.key) == ["due", "project"])
    }

    @Test func editKeepsCRLF() throws {
        let text = "# Inbox\r\n\(Self.sample)\r\n"
        var file = InboxFile(text: text)
        var item = try #require(file.item(id: "i-ab12cd34"))
        item.title = "New title"
        file.replace(item)
        #expect(file.text.hasSuffix("^i-ab12cd34\r\n"))
        #expect(file.text.hasPrefix("# Inbox\r\n- [ ] New title [kind:: task.add]"))
    }

    @Test func editWithNoChangeOrUnknownIdDoesNothing() throws {
        var file = InboxFile(text: Self.messy)
        let item = try #require(file.item(id: "i-ab12cd34"))
        let changed11 = file.replace(item)
        #expect(!changed11)
        var other = item
        other.id = "i-ffffffff"
        let changed13 = file.replace(other)
        #expect(!changed13)
        #expect(file.text == Self.messy)
    }

    // MARK: Append

    private func newItem(_ title: String, id: String = "i-99999999") -> InboxItem {
        InboxItem(id: id, kind: "note", title: title, source: "agent:test", created: "2026-11-09")
    }

    @Test func appendToEmptyFileAddsHeader() {
        var file = InboxFile(text: "")
        file.append(newItem("First"))
        #expect(file.text == "# Inbox\n\n- [ ] First [kind:: note] [source:: agent:test] [created:: 2026-11-09] ^i-99999999\n")
        #expect(file.items.count == 1)
    }

    @Test func appendGoesAfterTheLastItem() {
        var file = InboxFile(text: Self.messy + "\n")
        file.append(newItem("Fresh"))
        var lines = file.text.components(separatedBy: "\n")
        #expect(lines[11].hasPrefix("- [ ] Fresh"))
        #expect(lines[12] == "- a plain bullet that is not an item")
        lines.remove(at: 11)
        #expect(lines.joined(separator: "\n") == Self.messy + "\n")
        #expect(file.items.last?.id == "i-99999999")
    }

    @Test func appendWhenFileEndsWithItemKeepsTrailingNewlineStyle() {
        var withNewline = InboxFile(text: "# Inbox\n\(Self.sample)\n")
        withNewline.append(newItem("B"))
        #expect(withNewline.text.hasSuffix("^i-99999999\n"))
        #expect(withNewline.text.components(separatedBy: "\n").count == 4)

        var without = InboxFile(text: "# Inbox\n\(Self.sample)")
        without.append(newItem("B"))
        #expect(without.text.hasSuffix("^i-99999999"))
        #expect(without.text.hasPrefix("# Inbox\n\(Self.sample)\n- [ ] B"))
    }

    @Test func appendToFileWithoutItemsGoesAtTheEnd() {
        var file = InboxFile(text: "# Inbox\n\nNotes\n")
        file.append(newItem("A"))
        #expect(file.text == "# Inbox\n\nNotes\n- [ ] A [kind:: note] [source:: agent:test] [created:: 2026-11-09] ^i-99999999\n")

        var noNewline = InboxFile(text: "# Inbox")
        noNewline.append(newItem("A"))
        #expect(noNewline.text.hasPrefix("# Inbox\n- [ ] A"))
        #expect(noNewline.text.hasSuffix("^i-99999999\n"))
    }

    @Test func appendUsesCRLFInACRLFFile() {
        var file = InboxFile(text: "# Inbox\r\n\r\n\(Self.sample)\r\n")
        file.append(newItem("A"))
        #expect(file.text.hasSuffix("^i-99999999\r\n"))
        #expect(!file.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(file.items.count == 2)
    }

    @Test func appendLeavesExistingLinesAlone() {
        let before = Self.messy
        var file = InboxFile(text: before)
        file.append(newItem("A"))
        let old = before.components(separatedBy: "\n")
        var new = file.text.components(separatedBy: "\n")
        #expect(new.count == old.count + 1)
        new.remove(at: 11)
        #expect(new == old)
    }

    // MARK: Against the vault path

    @Test func inboxFileLivesWhereVaultPathsSaysAndIsWritable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atl-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultPaths(root: root)
        let target = try vault.writableURL(vault.inbox)
        var file = InboxFile(text: try TextFile.read(target) ?? "")
        file.append(newItem("On disk"))
        #expect(try TextFile.write(file.text, to: target))
        let reread = InboxFile(text: try #require(try TextFile.read(target)))
        #expect(reread.items.map(\.title) == ["On disk"])
        #expect(try TextFile.write(reread.text, to: target) == false) // byte-identical, no write
    }
}
