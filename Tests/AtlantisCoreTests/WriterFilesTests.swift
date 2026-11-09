import Foundation
import Testing
@testable import AtlantisCore

@Suite struct WriterFilesTests {
    let dir: URL
    let files: WriterFiles

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("writerfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files = WriterFiles(root: dir)
    }

    private var root: String { files.root.path }

    @Test func readKeepsExactTextIncludingBOMAndCRLF() throws {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("# Hi\r\n\r\nText".utf8)
        try Data(bytes).write(to: files.root.appendingPathComponent("a.md"))
        #expect(Data(try files.read("\(root)/a.md").utf8) == Data(bytes))
    }

    @Test func refusesNonUTF8() throws {
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: files.root.appendingPathComponent("latin1.md"))
        #expect(throws: WriterFiles.Failure.notText) { try files.read("\(root)/latin1.md") }
    }

    @Test func refusesPathsOutsideTheFolder() throws {
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.resolve("\(root)/../escape.md") }
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.resolve("\(root)/new/../../escape.md") }
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.resolve("relative.md") }
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.write("/tmp/x.md", text: "x") }
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.move("\(root)/a.md", to: "/tmp/a.md") }
    }

    @Test func refusesSymlinksThatLeaveTheFolder() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: files.root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.write("\(root)/link/evil.md", text: "x") }
        #expect(try files.list(root).isEmpty) // the symlink isn't listed
    }

    @Test func writesOnlyTextTypesAtomicallyAndSkipsNoOps() throws {
        #expect(throws: WriterFiles.Failure.notAllowedType("sh")) { try files.write("\(root)/run.sh", text: "x") }
        try files.write("\(root)/Proj/Draft/One.md", text: "Hello\n")
        let url = files.root.appendingPathComponent("Proj/Draft/One.md")
        let before = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        Thread.sleep(forTimeInterval: 0.02)
        try files.write("\(root)/Proj/Draft/One.md", text: "Hello\n")
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
        #expect(try files.read("\(root)/Proj/Draft/One.md") == "Hello\n")
    }

    @Test func listStatMoveAndCopy() throws {
        try files.write("\(root)/P/Draft/A.md", text: "a")
        try files.write("\(root)/P/Exports/x.html", text: "<p>")
        #expect(try files.list("\(root)/P") == [.init(name: "Draft", kind: .dir), .init(name: "Exports", kind: .dir)])
        #expect(try files.stat("\(root)/P/Draft/A.md")?.kind == .file)
        #expect(try files.stat("\(root)/P/nope.md") == nil)
        try files.move("\(root)/P/Draft/A.md", to: "\(root)/P/Trash/A.md")
        #expect(throws: WriterFiles.Failure.alreadyExists) { try files.copyDir("\(root)/P", to: "\(root)/P", skip: []) }
        try files.copyDir("\(root)/P", to: "\(root)/P copy", skip: ["Exports"])
        #expect(try files.read("\(root)/P copy/Trash/A.md") == "a")
        #expect(try files.stat("\(root)/P copy/Exports") == nil)
    }
}
