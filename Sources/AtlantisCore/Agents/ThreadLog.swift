import Foundation

/// One message in a bot thread.
public struct ThreadMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, bot }

    public var role: Role
    public var at: Date
    public var text: String
    /// Tools the bot called for this reply, in order (Atlantis names). A call that was refused or
    /// failed has a `!` in front (`!atlantis_school_assessments`); see `toolCalls`.
    public var tools: [String]
    /// How the run that wrote this reply went (bot messages only).
    public var run: RunInfo?

    public init(role: Role, at: Date, text: String, tools: [String] = [], run: RunInfo? = nil) {
        self.role = role
        self.at = at
        self.text = text
        self.tools = tools
        self.run = run
    }

    /// The tool calls with whether each was refused or failed.
    public var toolCalls: [(name: String, failed: Bool)] {
        tools.map { $0.hasPrefix("!") ? (String($0.dropFirst()), true) : ($0, false) }
    }

    /// `tools` entry for a call.
    public static func toolEntry(_ name: String, failed: Bool) -> String { failed ? "!" + name : name }
}

public struct RunInfo: Sendable, Equatable {
    public var status: RunSummary.Status
    public var steps: Int
    public var costUSD: Double
    public var note: String?

    public init(status: RunSummary.Status, steps: Int, costUSD: Double, note: String? = nil) {
        self.status = status
        self.steps = steps
        self.costUSD = costUSD
        self.note = note
    }
}

/// A chat with one bot: `machine/atlantis/threads/<bot>/<YYYY-MM-DD>-<id>.md`.
public struct AgentThread: Sendable, Equatable, Identifiable {
    public var id: String
    public var bot: String
    public var title: String
    public var created: Date
    public var updated: Date
    public var messages: [ThreadMessage]

    public init(id: String = ThreadLog.newID(), bot: String, title: String, created: Date, updated: Date? = nil,
                messages: [ThreadMessage] = []) {
        self.id = id
        self.bot = bot
        self.title = title
        self.created = created
        self.updated = updated ?? created
        self.messages = messages
    }

    public var runs: Int { messages.filter { $0.run != nil }.count }
    public var steps: Int { messages.compactMap(\.run?.steps).reduce(0, +) }
    public var costUSD: Double { messages.compactMap(\.run?.costUSD).reduce(0, +) }

    /// `2026-11-10-a1b2c3.md`, dated by when the thread started.
    public func fileName(calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: created)
        return String(format: "%04d-%02d-%02d-", c.year ?? 0, c.month ?? 0, c.day ?? 0) + id + ".md"
    }
}

/// A thread as the list shows it (front matter only).
public struct ThreadSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var bot: String
    public var title: String
    public var updated: Date
    public var url: URL
}

/// Writes and reads thread logs. The file is readable markdown (front matter, then each message
/// under a heading); `<!-- atlantis:message … -->` markers make it parse back exactly.
public enum ThreadLog {
    public struct ParseError: Error, Equatable { public var message: String }

    static let marker = "<!-- atlantis:message "

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    /// A short title from the first message: its first line, clipped.
    public static func title(from message: String) -> String {
        let first = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "New chat" }
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }

    // MARK: Render

    public static func render(_ thread: AgentThread, botName: String, avatar: String,
                              timeZone: TimeZone = .current) -> String {
        let iso = isoFormatter(timeZone)
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_AU")
        time.timeZone = timeZone
        time.dateFormat = "d MMM, h:mm a"

        var out = "---\n"
        out += "id: \(thread.id)\n"
        out += "bot: \(thread.bot)\n"
        out += "title: \(FrontMatter.quoted(thread.title))\n"
        out += "created: \(iso.string(from: thread.created))\n"
        out += "updated: \(iso.string(from: thread.updated))\n"
        out += "runs: \(thread.runs)\n"
        out += "steps: \(thread.steps)\n"
        out += "cost_usd: \(String(format: "%.4f", thread.costUSD))\n"
        out += "---\n"

        for message in thread.messages {
            var attributes = [("role", message.role.rawValue), ("at", iso.string(from: message.at))]
            var meta: [String] = []
            var header: String
            if message.role == .user {
                header = "**You** · \(time.string(from: message.at))"
            } else {
                header = "**\(avatar) \(botName)** · \(time.string(from: message.at))"
                if !message.tools.isEmpty {
                    attributes.append(("tools", message.tools.joined(separator: ",")))
                    meta.append("> " + message.toolCalls.map { $0.failed ? "~~\(ToolLabels.label($0.name))~~ (refused)" : ToolLabels.label($0.name) }
                        .joined(separator: " · "))
                }
                if let run = message.run {
                    attributes += [("status", run.status.rawValue), ("steps", String(run.steps)),
                                   ("cost_usd", String(format: "%.4f", run.costUSD))]
                    header += " · \(run.steps) step\(run.steps == 1 ? "" : "s") · \(UsageLedger.dollars(run.costUSD))"
                    if let note = run.note, !note.isEmpty {
                        attributes.append(("note", note))
                        meta.append("> ⚠️ " + note.replacingOccurrences(of: "\n", with: " "))
                    }
                }
            }
            attributes.append(("meta_lines", String(meta.count)))
            out += "\n" + marker + attributes.map { "\($0.0)=\"\(escapeAttribute($0.1))\"" }.joined(separator: " ") + " -->\n"
            out += header + "\n"
            if !meta.isEmpty { out += "\n" + meta.joined(separator: "\n") + "\n" }
            let body = message.text.trimmingCharacters(in: .newlines)
            if !body.isEmpty { out += "\n" + protectMarkers(body) + "\n" }
        }
        return out
    }

    // MARK: Parse

    public static func parse(_ text: String) throws -> AgentThread {
        guard let (yaml, body) = FrontMatter.split(text) else { throw ParseError(message: "no front matter") }
        let fields = (try? FrontMatter.parse(yaml)) ?? [:]
        let iso = isoFormatter(.current)
        guard let id = fields["id"]?.string, let bot = fields["bot"]?.string else {
            throw ParseError(message: "front matter needs id and bot")
        }
        let created = fields["created"]?.string.flatMap { iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        let updated = fields["updated"]?.string.flatMap { iso.date(from: $0) } ?? created
        var thread = AgentThread(id: id, bot: bot, title: fields["title"]?.string ?? "Chat", created: created, updated: updated)

        var current: (attributes: [String: String], lines: [String])?
        func finish() {
            guard let item = current else { return }
            if let message = makeMessage(item.attributes, item.lines, iso: iso) { thread.messages.append(message) }
        }
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix(marker), line.hasSuffix("-->") {
                finish()
                current = (parseAttributes(line), [])
            } else if current != nil {
                current?.lines.append(line)
            }
        }
        finish()
        return thread
    }

    private static func makeMessage(_ attributes: [String: String], _ rawLines: [String], iso: ISO8601DateFormatter) -> ThreadMessage? {
        guard let role = attributes["role"].flatMap(ThreadMessage.Role.init(rawValue:)) else { return nil }
        var lines = rawLines
        if !lines.isEmpty { lines.removeFirst() } // the heading line
        let metaCount = Int(attributes["meta_lines"] ?? "0") ?? 0
        if metaCount > 0 {
            while lines.first?.isEmpty == true { lines.removeFirst() }
            lines.removeFirst(min(metaCount, lines.count))
        }
        let text = unprotectMarkers(lines.joined(separator: "\n").trimmingCharacters(in: .newlines))
        let tools = (attributes["tools"] ?? "").split(separator: ",").map(String.init)
        var run: RunInfo?
        if let status = attributes["status"].flatMap(RunSummary.Status.init(rawValue:)) {
            run = RunInfo(status: status, steps: Int(attributes["steps"] ?? "") ?? 0,
                          costUSD: Double(attributes["cost_usd"] ?? "") ?? 0, note: attributes["note"])
        }
        return ThreadMessage(role: role, at: attributes["at"].flatMap { iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0),
                             text: text, tools: tools, run: run)
    }

    // MARK: Files

    public static func folder(vault: VaultPaths, bot: String) -> URL {
        vault.threadsDir.appendingPathComponent(bot, isDirectory: true)
    }

    /// The bot's threads, newest first. Reads only the front matter of each file.
    public static func list(vault: VaultPaths, bot: String) -> [ThreadSummary] {
        guard BotFile.isValidID(bot) else { return [] }
        let dir = folder(vault: vault, bot: bot)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let iso = isoFormatter(.current)
        return files.filter { $0.pathExtension == "md" }.compactMap { url -> ThreadSummary? in
            guard let text = try? TextFile.read(url), let (yaml, _) = FrontMatter.split(text),
                  let fields = try? FrontMatter.parse(yaml), let id = fields["id"]?.string else { return nil }
            let updated = fields["updated"]?.string.flatMap { iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
            return ThreadSummary(id: id, bot: bot, title: fields["title"]?.string ?? "Chat", updated: updated, url: url)
        }
        .sorted { $0.updated > $1.updated }
    }

    public static func load(_ url: URL) throws -> AgentThread {
        guard let text = try TextFile.read(url) else { throw ParseError(message: "missing") }
        return try parse(text)
    }

    /// Writes the thread atomically inside the vault (never `human/`). Returns where it went.
    @discardableResult
    public static func save(_ thread: AgentThread, vault: VaultPaths, botName: String, avatar: String) throws -> URL {
        guard BotFile.isValidID(thread.bot) else { throw ParseError(message: "bad bot id") }
        let url = try vault.writableURL(folder(vault: vault, bot: thread.bot).appendingPathComponent(thread.fileName()))
        try TextFile.write(render(thread, botName: botName, avatar: avatar), to: url)
        return url
    }

    // MARK: Helpers

    static func isoFormatter(_ timeZone: TimeZone) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f
    }

    static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    static func unescapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func parseAttributes(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"([a-z_]+)="([^"]*)""#)
        let ns = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: match.range(at: 1))] = unescapeAttribute(ns.substring(with: match.range(at: 2)))
        }
        return out
    }

    /// A message line that looks like a marker gets a zero-width joiner so it can't start a new message.
    private static let guardMark = "\u{2060}"

    static func protectMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.hasPrefix("<!-- atlantis:") ? guardMark + $0 : $0 }
            .joined(separator: "\n")
    }

    static func unprotectMarkers(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.hasPrefix(guardMark + "<!-- atlantis:") ? String($0.dropFirst()) : $0 }
            .joined(separator: "\n")
    }
}
