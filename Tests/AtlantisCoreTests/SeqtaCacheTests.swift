import Foundation
import Testing
@testable import AtlantisCore

@Suite struct SeqtaCacheTests {
    let dir: URL
    let cache: SeqtaCache
    let when = ISO8601DateFormatter().date(from: "2026-11-09T00:00:00Z")!

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("seqta-cache-\(UUID().uuidString)")
        cache = SeqtaCache(root: dir)
    }

    @Test func missingCacheReadsAsNeverSynced() {
        #expect(cache.lessons() == nil && cache.assessments() == nil && cache.messages() == nil)
        #expect(cache.meta() == SeqtaMeta() && cache.meta().lastSync == nil)
    }

    @Test func roundTripsEveryKind() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let lesson = Lesson(id: "2026-11-09T09:00-ENGG9", date: "2026-11-09", from: "09:00", until: "09:50", subject: "English 9",
                            code: "ENGG9", room: "E12", teacher: "Ms Example", colour: "#3b82f6", topic: "Writing", homework: "Draft")
        let assessment = Assessment(id: 1, title: "Speech", subject: "English 9", code: "ENGG9", due: "2026-11-12", status: "MARKS_RELEASED",
                                    marks: Mark(grade: "A", percentage: 90.5, feedback: "Great"), details: "Do it", programme: 1, metaclass: 2)
        let notice = Notice(id: 5, date: "2026-11-09", title: "Sport", label: "All", staff: "Coach", colour: "#fff000", contents: "Bring shoes")
        let subject = Subject(code: "ENGG9", name: "English 9", colour: "#3b82f6", teacher: "Ms Example", programme: 3830, metaclass: 29611, classunit: 5)
        let message = MessageSummary(id: 9, date: when, sender: "Ms Example", senderType: "staff", subject: "Hi", read: true, attachmentCount: 1)

        try cache.save([lesson], kind: .lessons, syncedAt: when)
        try cache.save([assessment], kind: .assessments, syncedAt: when)
        try cache.save([notice], kind: .notices, syncedAt: when)
        try cache.save([subject], kind: .subjects, syncedAt: when)
        try cache.save([message], kind: .messages, syncedAt: when)

        #expect(cache.lessons()?.items == [lesson] && cache.lessons()?.syncedAt == when)
        #expect(cache.assessments()?.items == [assessment])
        #expect(cache.notices()?.items == [notice])
        #expect(cache.subjects()?.items == [subject])
        #expect(cache.messages()?.items == [message])
        // One file per kind, named for it.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["assessments.json", "lessons.json", "messages.json", "notices.json", "subjects.json"])
    }

    @Test func filesAreReadableJSONForAgents() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save([Notice(id: 1, date: "2026-11-09", title: "T")], kind: .notices, syncedAt: when)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("notices.json"))) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["syncedAt"] as? String == "2026-11-09T00:00:00Z")
        #expect((json["items"] as? [[String: Any]])?.first?["title"] as? String == "T")
    }

    @Test func metaRoundTripsAndUpdates() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.updateMeta { meta in
            meta.lastSync = when
            meta.lastReason = .morning
            meta.lastAutoSyncDay = "2026-11-09"
            meta.kinds["lessons"] = .init(syncedAt: when, count: 4)
            meta.failures = ["notices": "HTTP 500"]
            meta.newMarkAssessmentIDs = [3]
        }
        try cache.updateMeta { $0.lastReason = .manual } // keeps the rest
        let meta = cache.meta()
        #expect(meta.lastSync == when && meta.lastReason == .manual && meta.lastAutoSyncDay == "2026-11-09")
        #expect(meta.kinds["lessons"] == .init(syncedAt: when, count: 4))
        #expect(meta.failures == ["notices": "HTTP 500"] && meta.newMarkAssessmentIDs == [3])
    }

    @Test func overwritesAreAtomicAndPrivate() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save([Notice(id: 1, date: "d", title: "first")], kind: .notices, syncedAt: when)
        try cache.save([Notice(id: 2, date: "d", title: "second")], kind: .notices, syncedAt: when)
        #expect(cache.notices()?.items.map(\.title) == ["second"])
        let file = dir.appendingPathComponent("notices.json").path
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        // No leftover temp files from the atomic write.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["notices.json"])
    }

    @Test func unchangedBytesAreNotRewritten() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.saveMeta(SeqtaMeta())
        let url = dir.appendingPathComponent("meta.json")
        let first = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        Thread.sleep(forTimeInterval: 0.05)
        try cache.saveMeta(SeqtaMeta())
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == first)
    }

    @Test func corruptFilesReadAsMissing() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("lessons.json"))
        try Data("{".utf8).write(to: dir.appendingPathComponent("meta.json"))
        #expect(cache.lessons() == nil)
        #expect(cache.meta() == SeqtaMeta())
    }

    @Test func clearRemovesEverything() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save([Notice(id: 1, date: "d", title: "t")], kind: .notices, syncedAt: when)
        try cache.updateMeta { $0.lastSync = when }
        try cache.clear()
        #expect(cache.notices() == nil && cache.meta().lastSync == nil)
    }

    @Test func defaultRootIsTheAppSupportSeqtaFolder() {
        #expect(SeqtaCache().root == AppSupport.seqtaCache)
        #expect(AppSupport.seqtaCache.path.hasSuffix("/Atlantis/seqta"))
    }
}
