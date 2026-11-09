import Foundation

/// `~/Library/Application Support/LifeOS/shared/plan.json`: today's blocks, written by Atlantis
/// and read by the AI Dock to switch modes and show Next up (PRD §10).
///
/// Times are local "HH:mm" on `date`, so the file never shifts with time zones. There is no
/// "written at" stamp, so writing the same plan twice leaves the file alone.
public struct PlanFile: Codable, Equatable, Sendable {
    public struct Block: Codable, Equatable, Sendable {
        public var id: String
        /// "class" or "task".
        public var kind: String
        public var title: String
        public var start: String
        public var end: String
        /// A shared mode name (school, building, bjj, social) when known.
        public var mode: String?
        public var room: String?
        public var taskID: String?
    }

    public var version = 1
    public var date: String
    public var blocks: [Block]

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LifeOS/shared/plan.json")
    }

    public init(model: TodayModel) {
        date = model.day.description
        blocks = model.blocks.map { block in
            switch block.kind {
            case let .lesson(lesson):
                Block(id: block.id, kind: "class", title: lesson.subject, start: block.startText, end: block.endText,
                      mode: "school", room: lesson.room.isEmpty ? nil : lesson.room, taskID: nil)
            case let .task(task):
                Block(id: block.id, kind: "task", title: block.title, start: block.startText, end: block.endText,
                      mode: (task.mode ?? task.area).map { $0.lowercased() }.flatMap { TaskModes.all.contains($0) ? $0 : nil },
                      room: nil, taskID: task.id)
            }
        }
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Writes the plan if it changed. Returns whether it wrote.
    @discardableResult
    public func write(to url: URL = PlanFile.defaultURL) throws -> Bool {
        try TextFile.write(json(), to: url)
    }
}
