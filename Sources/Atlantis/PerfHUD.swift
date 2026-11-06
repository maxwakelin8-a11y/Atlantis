import AtlantisCore
import SwiftUI

/// Debug overlay with live CPU, memory, wake-ups, web views, launch and page-switch times
/// (PRD §17). It only measures while it's showing; hidden, it does no work.
struct PerfHUD: View {
    let model: AppModel
    @State private var previous = ProcessStats.current()
    @State private var lines: [(String, String)] = []

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12) {
            ForEach(lines, id: \.0) { line in
                GridRow {
                    Text(line.0).foregroundStyle(.secondary)
                    Text(line.1).monospacedDigit()
                }
            }
        }
        .font(.caption.monospaced())
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .padding()
        .allowsHitTesting(false)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        guard let now = ProcessStats.current() else { return }
        let earlier = previous ?? now
        previous = now
        let memoryMB = Double(now.footprintBytes) / 1_048_576
        lines = [
            ("CPU", String(format: "%.1f%%", now.cpuPercent(since: earlier))),
            ("Memory", String(format: "%.0f MB", memoryMB)),
            ("Wake-ups", String(format: "%.0f/s", now.wakeupsPerSecond(since: earlier))),
            ("Web views", "\(WebViews.liveCount) live"),
            ("Launch", model.launchSeconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "–"),
            ("Page switch", model.lastPageSwitchMs.map { String(format: "%.0f ms", $0) } ?? "–"),
        ]
    }
}
