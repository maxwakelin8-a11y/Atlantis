import AtlantisCore
import Foundation
import os

/// Starts bots on their own (M7): `schedule morning` and the `seqta.assessment.new` and
/// `task.overdue` events. Only while Settings ▸ Bots ▸ "Let bots run on their own" is on.
///
/// No timers (AGENTS.md: idle = zero work). It is called from two events the app already has:
/// - `afterSync`: a SEQTA sync just wrote the cache (`AppModel.didSync`);
/// - `launchOrWake`: the morning sync was tried at launch or wake, whatever happened.
/// The rules are `MorningTrigger` (tested in AtlantisCore); runs go through `AgentService`'s queue.
@MainActor
final class TeamTriggers {
    private unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    /// After a sync: a run per new assessment for each subscribed bot, then the morning trigger.
    func afterSync(newAssessments: [Assessment]) {
        guard AppSettings.teamSettings.automaticRuns else { return }
        let agents = model.agents
        agents.reloadBotsOnly()
        let bots = agents.definitions
        let now = model.now()
        let today = DayStamp(now)
        for assessment in newAssessments {
            for bot in bots where bot.subscribes(to: .seqtaAssessmentNew) {
                agents.enqueue(QueuedRun(bot: bot.id, trigger: .event(.seqtaAssessmentNew),
                                         title: AssessmentJob.title(assessment),
                                         userText: "New assessment: \(assessment.title) (\(assessment.subject)), due \(assessment.due).",
                                         prompt: AssessmentJob.prompt(assessment, today: today),
                                         origin: AssessmentJob.origin(assessment),
                                         subject: "plan for \(assessment.title)", queuedAt: now))
            }
        }
        morning(cause: .afterSync)
    }

    /// The morning sync was tried (launch or wake). Fires the morning trigger from the morning time
    /// on, if a sync hasn't fired it already today.
    func launchOrWake() {
        guard AppSettings.teamSettings.automaticRuns else { return }
        morning(cause: .launchOrWake)
    }

    private func morning(cause: MorningTrigger.Cause) {
        let settings = AppSettings.teamSettings
        let agents = model.agents
        let ledger = agents.triggerLedger
        let now = model.now()
        let minute = TodayTime.minuteOfDay(now)
        guard MorningTrigger.shouldFire(settings: settings, lastDay: ledger.morningDay, today: ledger.todayKey(),
                                        cause: cause, minute: minute) else { return }
        ledger.markMorning()
        agents.reloadBotsOnly()
        let tasks = model.tasks
        tasks.start()
        tasks.reload()
        model.today.start()
        let day = DayStamp(now)
        let overdue = OverdueJob.overdue(tasks.tasks, today: day)
        let bots = MorningTrigger.bots(agents.definitions, overdue: overdue)
        Log.app.info("Morning trigger (\(String(describing: cause), privacy: .public)): \(bots.count) bots, \(overdue.count) overdue")
        guard !bots.isEmpty else { return }
        let today = model.today.model(tasks: tasks.tasks)
        let plan = DayPlan.build(today, minute: minute)
        for bot in bots {
            let plans = bot.runsInMorning
            agents.enqueue(QueuedRun(
                bot: bot.id, trigger: plans ? .morning : .event(.taskOverdue),
                title: plans ? MorningJob.title(day: day) : "Overdue tasks · \(day)",
                userText: plans ? "Good morning. Plan my day." : "\(overdue.count) overdue task\(overdue.count == 1 ? "" : "s").",
                prompt: MorningJob.prompt(bot: bot, model: today, plan: plan, overdue: overdue, minute: minute),
                origin: MorningJob.origin(day: day), subject: plans ? "Morning plan" : "Overdue tasks", queuedAt: now))
        }
    }
}
