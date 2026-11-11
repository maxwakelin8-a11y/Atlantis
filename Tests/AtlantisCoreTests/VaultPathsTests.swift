import Foundation
import Testing
@testable import AtlantisCore

@Suite struct VaultPathsTests {
    let vault = VaultPaths(root: URL(fileURLWithPath: "/tmp/atlantis-vault-test", isDirectory: true))

    @Test func knownFilesAreInTheRightPlaces() {
        #expect(vault.tasks.path == "/tmp/atlantis-vault-test/machine/tasks.md")
        #expect(vault.inbox.path == "/tmp/atlantis-vault-test/machine/atlantis/inbox.md")
    }

    @Test func dailyNoteName() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Perth")!
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9))!
        #expect(vault.daily(for: date, calendar: cal).lastPathComponent == "2026-03-07.md")
    }

    @Test func refusesHumanFolderAndOutside() {
        #expect(throws: VaultPaths.Failure.self) { try vault.writableURL(vault.root.appendingPathComponent("human/x.md")) }
        #expect(throws: VaultPaths.Failure.self) { try vault.writableURL(vault.root.appendingPathComponent("machine/../human/x.md")) }
        #expect(throws: VaultPaths.Failure.self) { try vault.writableURL(URL(fileURLWithPath: "/tmp/elsewhere.md")) }
        #expect(throws: Never.self) { try vault.writableURL(vault.tasks) }
    }

    @Test func textFileSkipsNoOpWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("atl-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TextFile.write("a\n", to: url))
        #expect(try !TextFile.write("a\n", to: url))
        #expect(try TextFile.read(url) == "a\n")
    }
}
