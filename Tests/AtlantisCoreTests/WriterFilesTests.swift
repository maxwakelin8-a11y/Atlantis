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
        try files.write("\(root)/Proj/.writer-record.jsonl", text: "{}\n") // the writing record
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

// MARK: Images and search (M1: pasting images, search across projects)

@Suite struct WriterImageTests {
    let dir: URL
    let files: WriterFiles
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("writerimages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files = WriterFiles(root: dir)
    }

    private var root: String { files.root.path }

    @Test func savesAnImageIntoAProjectAssetsFolder() throws {
        try files.writeImage("\(root)/Essay/assets/image-1.png", data: png)
        #expect(try Data(contentsOf: files.root.appendingPathComponent("Essay/assets/image-1.png")) == png)
        let read = try files.readImage("\(root)/Essay/assets/image-1.png")
        #expect(read.data == png && read.ext == "png")
    }

    @Test func acceptsEachWritableType() throws {
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])
        let gif = Data("GIF89a".utf8)
        let webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8)
        try files.writeImage("\(root)/P/assets/a.jpg", data: jpg)
        try files.writeImage("\(root)/P/assets/b.JPEG", data: jpg)
        try files.writeImage("\(root)/P/assets/c.gif", data: gif)
        try files.writeImage("\(root)/P/assets/d.webp", data: webp)
    }

    @Test func refusesAnythingThatIsNotAnImageInAssets() throws {
        // Not in <project>/assets: the project root, a doc folder, the Writer root, deeper folders.
        #expect(throws: WriterFiles.Failure.badImagePath) { try files.writeImage("\(root)/Essay/Draft/a.png", data: png) }
        #expect(throws: WriterFiles.Failure.badImagePath) { try files.writeImage("\(root)/Essay/a.png", data: png) }
        #expect(throws: WriterFiles.Failure.badImagePath) { try files.writeImage("\(root)/assets/a.png", data: png) }
        #expect(throws: WriterFiles.Failure.badImagePath) { try files.writeImage("\(root)/Essay/assets/deeper/a.png", data: png) }
        #expect(throws: WriterFiles.Failure.badImagePath) { try files.writeImage("\(root)/.hidden/assets/a.png", data: png) }
        #expect(throws: WriterFiles.Failure.badImagePath) { try files.writeImage("\(root)/Essay/assets/.a.png", data: png) }
        // Wrong types, including HEIC (rejected, not converted).
        for ext in ["heic", "svg", "html", "md", "sh", "pdf", ""] {
            #expect(throws: WriterFiles.Failure.notAllowedType(ext)) { try files.writeImage("\(root)/Essay/assets/a.\(ext)", data: png) }
        }
        #expect(!FileManager.default.fileExists(atPath: files.root.appendingPathComponent("Essay").path))
    }

    @Test func refusesBytesThatDontMatchTheExtension() throws {
        #expect(throws: WriterFiles.Failure.notAnImage) { try files.writeImage("\(root)/Essay/assets/a.png", data: Data("<script>".utf8)) }
        #expect(throws: WriterFiles.Failure.notAnImage) { try files.writeImage("\(root)/Essay/assets/a.jpg", data: png) }
        #expect(throws: WriterFiles.Failure.notAnImage) { try files.writeImage("\(root)/Essay/assets/a.png", data: Data()) }
    }

    @Test func refusesOutsideTheFolderAndSymlinks() throws {
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.writeImage("/tmp/Essay/assets/a.png", data: png) }
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.writeImage("\(root)/Essay/assets/../../../a.png", data: png) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files.root.appendingPathComponent("Essay"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: files.root.appendingPathComponent("Essay/assets"), withDestinationURL: outside)
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.writeImage("\(root)/Essay/assets/a.png", data: png) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func capsTheSizeAndNeverOverwrites() throws {
        let big = png + Data(count: WriterFiles.maxImage)
        #expect(throws: WriterFiles.Failure.tooBig) { try files.writeImage("\(root)/Essay/assets/big.png", data: big) }
        try files.writeImage("\(root)/Essay/assets/a.png", data: png)
        #expect(throws: WriterFiles.Failure.alreadyExists) { try files.writeImage("\(root)/Essay/assets/a.png", data: png + Data([1])) }
        #expect(try Data(contentsOf: files.root.appendingPathComponent("Essay/assets/a.png")) == png)
    }

    @Test func readsOnlyImagesInsideTheFolder() throws {
        try files.write("\(root)/Essay/Draft/a.md", text: "# Hi")
        try files.writeImage("\(root)/Essay/assets/a.png", data: png)
        #expect(throws: WriterFiles.Failure.notAllowedType("md")) { try files.readImage("\(root)/Essay/Draft/a.md") }
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.readImage("/etc/hosts") }
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.readImage("\(root)/Essay/assets/../../../x.png") }
        #expect(throws: (any Error).self) { try files.readImage("\(root)/Essay/assets/missing.png") }
        // A symlink to an image outside the folder is refused too.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).png")
        try png.write(to: outside)
        try FileManager.default.createSymbolicLink(at: files.root.appendingPathComponent("Essay/assets/link.png"), withDestinationURL: outside)
        #expect(throws: WriterFiles.Failure.outsideFolder) { try files.readImage("\(root)/Essay/assets/link.png") }
    }
}

@Suite struct WriterSearchTests {
    let dir: URL
    let files: WriterFiles

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("writersearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files = WriterFiles(root: dir)
        let r = dir.resolvingSymlinksInPath().path
        try files.write("\(r)/Essay/Draft/Intro.md", text: """
        ---
        title: "Why oceans matter"
        synopsis: Hook
        comments: [{"text":"ocean in front matter"}]
        ---

        The ocean is big and blue.

        An Océan again, and a third OCEAN.
        """)
        try files.write("\(r)/Essay/Draft/Plain.md", text: "Nothing here.\n")
        try files.write("\(r)/Essay/Trash/Old.md", text: "ocean in the bin")
        try files.write("\(r)/Essay/Exports/out.md", text: "ocean export")
        try files.write("\(r)/Essay/.snapshots/x.md", text: "ocean snapshot")
        try files.write("\(r)/Essay/.deleted/gone.md", text: "ocean deleted")
        try files.write("\(r)/Speech/Notes/Ocean facts.md", text: "Salt.\n")
        try files.write("\(r)/Speech/Draft/Opening.md", text: "Good morning.\n\nThe OCEAN calls.\n")
        try files.write("\(r)/Speech/Draft/Data.json", text: "{\"ocean\":1}")
    }

    private func names(_ result: WriterFiles.SearchResult) -> [String] {
        result.hits.map { "\($0.project)/\($0.relPath)" }
    }

    @Test func findsTitleAndBodyAcrossProjectsIgnoringHiddenAndTrash() {
        let r = files.search("ocean")
        #expect(names(r) == ["Essay/Draft/Intro.md", "Speech/Draft/Opening.md", "Speech/Notes/Ocean facts.md"])
        #expect(!r.truncated)
        #expect(r.scanned == 4) // Intro, Plain, Opening, Ocean facts (Data.json isn't text; Trash, Exports and hidden folders are skipped)
    }

    @Test func countsAndSnippetsIgnoreFrontMatterAndMarkTheMatch() throws {
        let intro = try #require(files.search("ocean").hits.first)
        #expect(intro.title == "Why oceans matter" && intro.titleMatches)
        #expect(intro.count == 3) // "ocean", "Océan" (accent-insensitive) and "OCEAN"; none from the front matter
        #expect(intro.snippets.map(\.occurrence) == [0, 1, 2])
        #expect(intro.snippets[0].match == "ocean")
        #expect(intro.snippets[0].before == "The ")
        #expect(intro.snippets[0].after == " is big and blue.")
        #expect(intro.snippets[1].match == "Océan") // as written in the file
        #expect(!intro.snippets[1].before.contains("\n"))
    }

    @Test func titleOnlyMatchesHaveNoSnippetsAndTheFileNameIsTheDefaultTitle() throws {
        let facts = try #require(files.search("facts").hits.first)
        #expect(facts.title == "Ocean facts" && facts.titleMatches && facts.count == 0 && facts.snippets.isEmpty)
    }

    @Test func respectsLimitsAndEmptyQueries() {
        let one = files.search("ocean", limit: 1)
        #expect(one.hits.count == 1 && one.truncated)
        #expect(files.search("ocean", maxSnippets: 1).hits[0].snippets.count == 1)
        #expect(files.search("   ").hits.isEmpty)
        #expect(files.search("zzzz-not-there").hits.isEmpty)
    }

    @Test func skipsHugeFilesAndSymlinks() throws {
        let r = files.root.path
        try Data(repeating: UInt8(ascii: "a"), count: WriterFiles.maxSearchDocBytes + 1).write(to: files.root.appendingPathComponent("Essay/Draft/huge.md"))
        try "needle".write(to: files.root.appendingPathComponent("Essay/Draft/huge.md").deletingLastPathComponent().appendingPathComponent("small.md"), atomically: true, encoding: .utf8)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("search-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "needle outside".write(to: outside.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: files.root.appendingPathComponent("Linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: files.root.appendingPathComponent("Essay/Draft/linked-doc.md"), withDestinationURL: outside.appendingPathComponent("o.md"))
        let result = files.search("needle")
        #expect(names(result) == ["Essay/Draft/small.md"])
        _ = r
    }

    @Test func splitsFrontMatterLikeTheWriter() {
        let (front, body) = WriterFiles.splitFrontMatter("\u{FEFF}---\r\ntitle: A\r\n---\r\n\r\nBody")
        #expect(front == "title: A\r\n" && body == "\r\nBody")
        #expect(WriterFiles.splitFrontMatter("No front matter").front == nil)
        #expect(WriterFiles.splitFrontMatter("---\nnever closed\n").front == nil)
        #expect(WriterFiles.frontMatterTitle("title: 'It''s'\nx: 1") == "It's")
        #expect(WriterFiles.frontMatterTitle("title: \"Intro: why\"") == "Intro: why")
        #expect(WriterFiles.frontMatterTitle("synopsis: x") == nil)
    }
}
