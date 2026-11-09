import AtlantisCore
import Foundation
import Observation

/// The SEQTA cache as the pages see it (PRD §7d): subjects, assessments, files and the message
/// list, read from the JSON files the sync writes. Pages read this and never call SEQTA
/// themselves. It reloads when a sync finishes (`reload()`), never on a timer.
@MainActor @Observable
final class SeqtaData {
    private(set) var subjects: [Subject] = []
    private(set) var assessments: [Assessment] = []
    private(set) var files: [SubjectFile] = []
    private(set) var messages: [MessageSummary] = []
    private(set) var syncedAt: Date?
    /// Messages opened on this Mac. SEQTA's own "read" flag is left alone (Atlantis only reads).
    private(set) var openedMessages: Set<Int> = []

    @ObservationIgnored let cache: SeqtaCache

    init(cache: SeqtaCache) {
        self.cache = cache
        reload()
    }

    func reload() {
        subjects = cache.subjects()?.items ?? []
        assessments = cache.assessments()?.items ?? []
        files = cache.files()?.items ?? []
        messages = cache.messages()?.items ?? []
        syncedAt = cache.meta().lastSync
        openedMessages = Set(messages.map(\.id).filter(cache.hasMessage(id:)))
    }

    var hasData: Bool { syncedAt != nil }

    /// Everything per subject, in the subjects list's order.
    var details: [SubjectDetail] {
        SubjectOverview.details(subjects: subjects, assessments: assessments, files: files, today: SeqtaMorningGate.dayString(Date()))
    }

    func detail(code: String) -> SubjectDetail? { details.first { $0.id == code } }

    func markOpened(_ id: Int) { openedMessages.insert(id) }

    func isUnread(_ message: MessageSummary) -> Bool { !message.read && !openedMessages.contains(message.id) }
}
