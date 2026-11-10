import AtlantisCore
import SwiftUI

/// Settings ▸ Bots on their own (M7): the switch for automatic runs, the daily cap and the morning time.
struct TeamSettingsSection: View {
    let model: AppModel

    @AppStorage(AppSettings.automaticRunsKey) private var automaticRuns = false
    @AppStorage(AppSettings.dailyRunCapKey) private var dailyCap = TeamSettings.defaultDailyCap
    @AppStorage(AppSettings.morningMinuteKey) private var morningMinute = TeamSettings.defaultMorningMinute

    var body: some View {
        Section {
            Toggle("Let bots run on their own", isOn: $automaticRuns)
                .onChange(of: automaticRuns) { _, on in
                    if on { model.teamTriggers.launchOrWake() } else { model.agents.automaticRunsSwitchedOff() }
                }
            Stepper(value: $dailyCap, in: TeamSettings.dailyCapRange) {
                LabeledContent("Most runs a day", value: "\(dailyCap)")
            }
            .disabled(!automaticRuns)
            DatePicker("Morning plan from", selection: morningTime, displayedComponents: .hourAndMinute)
                .disabled(!automaticRuns)
        } header: {
            Text("Bots on Their Own")
        } footer: {
            Text("When on, bots with a morning schedule (Coach) plan your day right after the morning SEQTA sync, or from this time at the first launch or wake if SEQTA can't sync. School looks at each new assessment, and overdue tasks go to Coach in one batch. Runs wait their turn, one at a time, and each bot keeps its own daily cost cap. Chat, assigned tasks and @mentions work either way.")
        }
    }

    /// The morning minute as a time today (the date part is ignored).
    private var morningTime: Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(morningMinute * 60))
        } set: { date in
            morningMinute = TodayTime.minuteOfDay(date)
        }
    }
}
