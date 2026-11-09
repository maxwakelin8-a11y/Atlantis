import Foundation
import Testing
@testable import AtlantisCore

@MainActor
@Suite struct TaskStoreTests {
    let root: URL
    let vault: VaultPaths
    let store: TaskStore
    nonisolated static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }()
    nonisolated static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 10))!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("taskstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("machine"), withIntermediateDirectories: true)
        vault = VaultPaths(root: root)
        store = TaskStore(vault: vault, now: { Self.now }, calendar: Self.calendar)
    }

    private func write(_ text: String) throws { try Data(text.utf8).write(to: vault.tasks) }
    private func read() throws -> String { try String(contentsOf: vault.tasks, encoding: .utf8) }

    private let seed = """
    # Tasks

    - [ ] Overdue one [due:: 2026-11-05] ^t-00000001
    - [ ] Due today [due:: 2026-11-09] ^t-00000002
    - [ ] Due tomorrow [due:: 2026-11-10] [pri:: 2] ^t-00000003
    - [ ] Pulled in [plan:: 2026-11-09] ^t-00000004
    - [x] Finished [due:: 2026-11-01] [done:: 2026-11-02] ^t-00000005

    """

    @Test func loadsAndQueries() throws {
        try write(seed)
        store.start()
        defer { store.stop() }
        #expect(store.isLoaded && store.problem == nil)
        #expect(store.tasks.count == 5)
        #expect(store.overdue.map(\.id) == ["t-00000001", "t-00000005"].filter { $0 == "t-00000001" })
        #expect(store.tasks(dueOn: DayStamp(year: 2026, month: 11, day: 9)).map(\.id) == ["t-00000002"])
        #expect(Set(store.forToday.map(\.id)) == ["t-00000001", "t-00000002", "t-00000004"])
    }

    @Test func missingVaultIsAProblemNotACrash() {
        let missing = TaskStore(vault: VaultPaths(root: root.appendingPathComponent("nope")))
        missing.start()
        defer { missing.stop() }
        #expect(missing.problem != nil)
        #expect(missing.tasks.isEmpty)
        #expect(throws: TaskStore.Failure.self) { try missing.add(TaskItem(title: "x")) }
    }

    @Test func missingFileLoadsEmptyAndAddCreatesIt() throws {
        store.start()
        defer { store.stop() }
        #expect(store.isLoaded && store.tasks.isEmpty && store.problem == nil)
        let id = try store.add(TaskItem(title: "First"))
        let text = try read()
        #expect(text == "# Tasks\n\n- [ ] First [added:: 2026-11-09] ^\(id)\n")
        #expect(store.tasks.map(\.id) == [id])
    }

    @Test func addUpdateCompleteReopenDelete() throws {
        try write(seed)
        store.start()
        defer { store.stop() }
        var item = TaskItem(title: "Write tests")
        item.priority = 1
        let id = try store.add(item)
        #expect(try read().hasSuffix("- [ ] Write tests [pri:: 1] [added:: 2026-11-09] ^\(id)\n"))

        try store.update(id: id) { $0.title = "Write more tests"; $0.estimateMinutes = 30 }
        #expect(try read().contains("- [ ] Write more tests [pri:: 1] [added:: 2026-11-09] [est:: 30m] ^\(id)\n"))

        try store.complete(id: id)
        #expect(try read().contains("- [x] Write more tests [pri:: 1] [added:: 2026-11-09] [est:: 30m] [done:: 2026-11-09] ^\(id)\n"))
        #expect(store.task(id: id)?.isDone == true)

        try store.reopen(id: id)
        #expect(try read().contains("- [ ] Write more tests [pri:: 1] [added:: 2026-11-09] [est:: 30m] ^\(id)\n"))

        try store.delete(id: id)
        #expect(try read() == seed)
    }

    @Test func otherLinesAreUntouchedByEdits() throws {
        try write(seed)
        store.start()
        defer { store.stop() }
        try store.complete(id: "t-00000002")
        let expected = seed.replacingOccurrences(of: "- [ ] Due today [due:: 2026-11-09] ^t-00000002",
                                                 with: "- [x] Due today [due:: 2026-11-09] [done:: 2026-11-09] ^t-00000002")
        #expect(try read() == expected)
    }

    @Test func writeRereadsTheFileFirst() throws {
        try write(seed)
        store.start()
        defer { store.stop() }
        // Someone else edits the file after we loaded it (we haven't reloaded yet).
        try write(seed.replacingOccurrences(of: "Due tomorrow", with: "Edited in Obsidian")
                  + "- [ ] Added in Obsidian ^t-00000006\n")
        try store.complete(id: "t-00000002")
        let text = try read()
        #expect(text.contains("Edited in Obsidian"))
        #expect(text.contains("Added in Obsidian"))
        #expect(text.contains("- [x] Due today"))
        #expect(store.tasks.count == 6)
    }

    @Test func editingATaskThatVanishedFailsAndShowsTheFile() throws {
        try write(seed)
        store.start()
        defer { store.stop() }
        try write(seed.replacingOccurrences(of: "- [ ] Due today [due:: 2026-11-09] ^t-00000002\n", with: ""))
        #expect(throws: TaskStore.Failure.taskNotFound) { try store.complete(id: "t-00000002") }
        #expect(store.task(id: "t-00000002") == nil)
        #expect(store.tasks.count == 4)
    }

    @Test func fieldLevelChangesKeepOtherToolsEdits() throws {
        try write(seed)
        store.start()
        defer { store.stop() }
        // Obsidian changes the due date; we change only the priority.
        try write(seed.replacingOccurrences(of: "[due:: 2026-11-10] [pri:: 2]", with: "[due:: 2026-11-20] [pri:: 2]"))
        try store.update(id: "t-00000003") { $0.priority = 1 }
        #expect(try read().contains("Due tomorrow [due:: 2026-11-20] [pri:: 1] ^t-00000003"))
    }

    @Test func reloadPicksUpExternalEditsAndIgnoresNoOps() throws {
        try write(seed)
        store.start()
        defer { store.stop() }
        let revision = store.revision
        store.reload()
        #expect(store.revision == revision)
        try write(seed + "- [ ] New ^t-00000007\n")
        store.reload()
        #expect(store.revision == revision + 1)
        #expect(store.task(id: "t-00000007")?.title == "New")
    }

    @Test func editingAnIdLessTaskReturnsItsNewId() throws {
        try write("- [ ] No id\n")
        store.start()
        defer { store.stop() }
        let oldID = try #require(store.tasks.first?.id)
        let newID = try store.update(id: oldID) { $0.priority = 2 }
        #expect(newID != oldID && newID.hasPrefix("t-"))
        #expect(try read() == "- [ ] No id [pri:: 2] ^\(newID)\n")
    }

    @Test func neverWritesOutsideTheVaultOrHuman() throws {
        // writableURL is what guards this; the store uses it for its single write path.
        #expect(throws: VaultPaths.Failure.self) { try vault.writableURL(root.appendingPathComponent("human/tasks.md")) }
    }

    @Test func watcherNoticesExternalEditsWithoutPolling() async throws {
        try write(seed)
        store.start()
        defer { store.stop() }
        #expect(store.tasks.count == 5)
        try write(seed + "- [ ] From Obsidian ^t-0000000a\n") // in-place style write
        try await waitUntil { store.tasks.count == 6 }
        // An atomic replace (rename over the file), as iCloud and many editors do.
        let tmp = root.appendingPathComponent("machine/.tmp-\(UUID().uuidString)")
        try Data((seed + "- [ ] A ^t-0000000b\n- [ ] B ^t-0000000c\n").utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(vault.tasks, withItemAt: tmp)
        try await waitUntil { store.tasks.count == 7 }
        // Our own writes echo back and change nothing further.
        try store.complete(id: "t-00000002")
        let revision = store.revision
        try await Task.sleep(for: .milliseconds(700))
        #expect(store.revision == revision)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("timed out waiting for the file watcher"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
