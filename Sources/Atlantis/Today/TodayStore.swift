import AtlantisCore
import Foundation
import Observation

/// What Today needs besides tasks: the SEQTA cache (re-read after each sync) and the Top 3 from
/// today's daily note (re-read when the note changes, via FSEvents). No timers.
///
/// It also does the after-sync work that writes files: today's daily note machine block, and
/// `plan.json` whenever the plan changes.
@MainActor @Observable
final class TodayStore {
    private(set) var lessons: [Lesson] = []
    private(set) var assessments: [Assessment] = []
    private(set) var notices: [Notice] = []
    /// For subject colours (by code) where a lesson has none.
    private(set) var subjects: [Subject] = []
    private(set) var topThree: [String] = []
    /// Bumped whenever any of the above changes.
    private(set) var revision = 0

    @ObservationIgnored let cache: SeqtaCache
    @ObservationIgnored let vault: VaultPaths
    @ObservationIgnored let planURL: URL
    @ObservationIgnored let now: @MainActor () -> Date
    @ObservationIgnored private var dailyWatcher: FileWatcher?
    @ObservationIgnored private var watchedDay: DayStamp?
    @ObservationIgnored private var started = false

    init(cache: SeqtaCache, vault: VaultPaths, planURL: URL, now: @escaping @MainActor () -> Date) {
        self.cache = cache
        self.vault = vault
        self.planURL = planURL
        self.now = now
    }

    var today: DayStamp { DayStamp(now()) }

    func start() {
        guard !started else { return }
        started = true
        reloadCache()
        reloadDailyNote()
    }

    // MARK: Reading

    func reloadCache() {
        let lessons = cache.lessons()?.items ?? []
        let assessments = cache.assessments()?.items ?? []
        let notices = cache.notices()?.items ?? []
        let subjects = cache.subjects()?.items ?? []
        guard lessons != self.lessons || assessments != self.assessments || notices != self.notices
            || subjects != self.subjects else { return }
        self.subjects = subjects
        self.lessons = lessons
        self.assessments = assessments
        self.notices = notices
        revision += 1
    }

    /// Re-reads the Top 3, and moves the watcher to the new day's note after midnight.
    func reloadDailyNote() {
        let day = today
        if watchedDay != day { watchDailyNote(for: day) }
        let top = DailyNote.topThree(vault: vault, now: now())
        if top != topThree {
            topThree = top
            revision += 1
        }
    }

    private func watchDailyNote(for day: DayStamp) {
        dailyWatcher?.stop()
        dailyWatcher = nil
        watchedDay = day
        guard FileManager.default.fileExists(atPath: vault.dailyDir.path) else { return }
        dailyWatcher = FileWatcher(folder: vault.dailyDir, fileName: "\(day.description).md") { [weak self] in
            Task { @MainActor [weak self] in self?.reloadDailyNote() }
        }
    }

    /// `#rrggbb` for a subject code, from today's lessons or the subject list.
    func colour(code: String) -> String? {
        lessons.first { $0.code == code && $0.colour != nil }?.colour ?? subjects.first { $0.code == code }?.colour
    }

    var dailyNoteURL: URL { vault.daily(for: now()) }

    func model(tasks: [TaskItem]) -> TodayModel {
        TodayModel.build(lessons: lessons, assessments: assessments, notices: notices, tasks: tasks,
                         topThree: topThree, now: now())
    }

    // MARK: Writing

    /// Fills today's daily note's machine-owned parts from the cache (after a sync).
    func writeDailyNote(syncedAt: Date) {
        let content = DailyNote.content(lessons: lessons, assessments: assessments, notices: notices,
                                        syncedAt: syncedAt, now: now())
        do {
            let result = try DailyNote.update(content, vault: vault, now: now())
            Log.app.info("Daily note machine block: \(String(describing: result), privacy: .public)")
        } catch {
            Log.app.error("Daily note write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes `plan.json` if today's blocks changed.
    func writePlan(tasks: [TaskItem]) {
        do {
            if try PlanFile(model: model(tasks: tasks)).write(to: planURL) {
                Log.app.info("Wrote plan.json")
            }
        } catch {
            Log.app.error("plan.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
