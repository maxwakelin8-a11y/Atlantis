import Foundation
import Testing
@testable import AtlantisCore

@Suite struct DocFolderTests {
    let dir: URL
    let folder: DocFolder

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("docfolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folder = DocFolder(root: dir)
    }

    private func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func readKeepsExactBytesIncludingBOMAndCRLF() throws {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("# Hi\r\n\r\nText".utf8)
        let snap = try folder.read(write("a.md", bytes))
        #expect(snap.data == Data(bytes))
        #expect(Data(snap.text.utf8) == Data(bytes))
    }

    @Test func refusesNonUTF8() throws {
        let url = try write("latin1.md", [0x63, 0x61, 0x66, 0xE9])
        #expect(throws: DocFolder.Failure.notUTF8) { try folder.read(url) }
    }

    @Test func refusesPathsOutsideTheFolder() throws {
        let outside = dir.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).md")
        #expect(throws: DocFolder.Failure.outsideFolder) { try folder.resolve(outside) }
        let sneaky = dir.appendingPathComponent("sub/../../escape.md")
        #expect(throws: DocFolder.Failure.outsideFolder) { try folder.resolve(sneaky) }
    }

    @Test func refusesSymlinksThatLeadOut() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("target-\(UUID().uuidString).md")
        try Data("x".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: DocFolder.Failure.outsideFolder) { try folder.read(link) }
    }

    @Test func refusesNonMarkdown() throws {
        let url = try write("notes.txt", Array("x".utf8))
        #expect(throws: DocFolder.Failure.notMarkdown) { try folder.read(url) }
    }

    @Test func unchangedSaveWritesNothing() throws {
        let url = try write("same.md", Array("# Same\n".utf8))
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let snap = try folder.read(url)
        Thread.sleep(forTimeInterval: 0.02)
        #expect(try folder.save(snap.text, over: snap) == .unchanged)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func savesChangesAndRefusesToOverwriteOutsideEdits() throws {
        let url = try write("edit.md", Array("one\n".utf8))
        let snap = try folder.read(url)
        guard case .written(let saved) = try folder.save("two\n", over: snap) else {
            Issue.record("expected a write"); return
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "two\n")
        try Data("changed in Obsidian\n".utf8).write(to: url)
        #expect(throws: DocFolder.Failure.changedOnDisk) { try folder.save("three\n", over: saved) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "changed in Obsidian\n")
    }

    @Test func listsMarkdownButSkipsAssetsAndHidden() throws {
        _ = try write("a.md", [])
        _ = try write("sub/b.md", [])
        _ = try write("assets/c.md", [])
        _ = try write(".hidden.md", [])
        _ = try write("d.txt", [])
        let names = folder.list().map(\.lastPathComponent).sorted()
        #expect(names == ["a.md", "b.md"])
    }

    @Test func createPicksAFreeName() throws {
        let first = try folder.create()
        let second = try folder.create()
        #expect(first.url.lastPathComponent == "Untitled.md")
        #expect(second.url.lastPathComponent == "Untitled 2.md")
    }
}
