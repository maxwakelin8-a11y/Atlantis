import Foundation

/// How much a bot may do on its own (PRD §7b).
public enum Autonomy: String, Sendable, Codable, CaseIterable {
    /// Inbox only (the default): every change is a proposal.
    case suggest
    /// Approve before applying. Until M6 this behaves like `suggest`.
    case ask
    /// Actions on the Settings allow list run without asking. Everything else is still a proposal.
    case act

    /// Gated writes always become Inbox proposals, whatever the allow list says.
    public var proposalsOnly: Bool { self != .act }
}

/// Which AI runs the bot (PRD §7b "Runtime").
public enum AgentProviderKind: String, Sendable, Codable, CaseIterable {
    /// The official Claude Code CLI, headless, on the user's subscription.
    case claudeCode = "claude-code"
    /// A cheap API worker (key in the Keychain). Not set up in M5.
    case api
}

/// A bot: `machine/atlantis/agents/<id>.md`. Front matter holds the settings; the body is its "soul".
public struct BotDefinition: Sendable, Equatable, Codable, Identifiable {
    /// The file name without `.md`: lowercase letters, digits and `-`.
    public var id: String
    public var name: String
    public var avatar: String
    public var model: String
    public var provider: AgentProviderKind
    /// Atlantis MCP tool names (`atlantis_today`), the only tools the bot gets.
    public var tools: [String]
    public var autonomy: Autonomy
    /// `chat`, `mention`, `task`, `schedule HH:MM` or `event <name>`. Only `chat` works in M5.
    public var triggers: [String]
    /// Tool calls one run may make before it's stopped.
    public var maxSteps: Int
    /// Estimated US dollars the bot may use per day (the CLI reports the cost of each run).
    public var dailyCostUSD: Double
    /// The system prompt, written by the user.
    public var soul: String

    public init(id: String, name: String, avatar: String = "🤖", model: String = "sonnet",
                provider: AgentProviderKind = .claudeCode, tools: [String], autonomy: Autonomy = .suggest,
                triggers: [String] = ["chat"], maxSteps: Int = 12, dailyCostUSD: Double = 1, soul: String) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.model = model
        self.provider = provider
        self.tools = tools
        self.autonomy = autonomy
        self.triggers = triggers
        self.maxSteps = maxSteps
        self.dailyCostUSD = dailyCostUSD
        self.soul = soul
    }

    public var allowsChat: Bool { triggers.contains("chat") }
}

/// Everything wrong with a bot file, so the user can fix it in one go.
public struct BotFileError: Error, Equatable, Sendable, CustomStringConvertible {
    public var problems: [String]
    public init(_ problems: [String]) { self.problems = problems }
    public var description: String { problems.joined(separator: "\n") }
}

public enum BotFile {
    /// Tools a bot may be given: every Atlantis MCP tool except the SEQTA sync (bots read the
    /// cache and never sync, PRD §7b). No tool sends a SEQTA message, so none can be listed.
    public static var allowedTools: Set<String> {
        Set(AtlantisTools.names + ["atlantis_ping"]).subtracting(forbiddenTools)
    }

    /// Never on a bot's list.
    public static let forbiddenTools: Set<String> = ["atlantis_seqta_refresh"]

    /// Tools that hand a bot nothing personal, so a non-Claude provider may have them
    /// (AGENTS.md: SEQTA and personal data never go to non-Claude providers).
    public static let toolsSafeForOtherProviders: Set<String> = ["atlantis_ping", "atlantis_inbox_post"]

    public static let modelAliases: Set<String> = ["haiku", "sonnet", "opus", "fable"]
    public static let triggerKinds: Set<String> = ["chat", "mention", "task", "schedule", "event"]
    public static let maxStepsRange = 1...50
    public static let dailyCostRange = 0.01...50.0

    /// True for a usable bot id (and file name).
    public static func isValidID(_ id: String) -> Bool {
        guard (1...40).contains(id.count), let first = id.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.lowercaseLetters.contains($0))
            || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// A model the CLI understands: an alias, or a full `claude-…` id. Nothing that could read as a flag.
    public static func isValidModel(_ model: String) -> Bool {
        if modelAliases.contains(model) { return true }
        guard model.hasPrefix("claude-"), model.count <= 64 else { return false }
        return model.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-._[]".unicodeScalars.contains($0)) }
    }

    /// Reads and checks a bot file. Throws `BotFileError` listing every problem.
    public static func parse(_ text: String, id: String) throws -> BotDefinition {
        var problems: [String] = []
        if !isValidID(id) { problems.append("The file name \"\(id).md\" must be lowercase letters, digits and dashes.") }
        guard let (yaml, body) = FrontMatter.split(text) else {
            throw BotFileError(problems + ["The file needs front matter between --- lines at the top."])
        }
        let fields: [String: FrontMatter.Value]
        do { fields = try FrontMatter.parse(yaml) } catch {
            throw BotFileError(problems + [String(describing: error)])
        }

        func string(_ key: String) -> String? {
            guard let value = fields[key] else { return nil }
            guard let text = value.string else { problems.append("\(key): must be a single value."); return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        func list(_ key: String, in map: [String: FrontMatter.Value]? = nil) -> [String]? {
            guard let value = (map ?? fields)[key] else { return nil }
            guard let items = value.list else { problems.append("\(key): must be a list."); return nil }
            return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        let name = string("name") ?? id.capitalized
        if name.count > 40 { problems.append("name: keep it under 40 characters.") }
        let avatar = string("avatar") ?? "🤖"
        if avatar.count > 4 { problems.append("avatar: use one emoji.") }

        let model = string("model") ?? "sonnet"
        if !isValidModel(model) { problems.append("model: \"\(model)\" isn't a Claude model (use haiku, sonnet, opus, fable or a claude-… id).") }

        var provider = AgentProviderKind.claudeCode
        if let raw = string("provider") {
            if let kind = AgentProviderKind(rawValue: raw) { provider = kind }
            else { problems.append("provider: use claude-code or api.") }
        }

        var autonomy = Autonomy.suggest
        if let raw = string("autonomy") {
            if let value = Autonomy(rawValue: raw) { autonomy = value }
            else { problems.append("autonomy: use suggest, ask or act.") }
        }

        let tools = list("tools") ?? []
        if tools.isEmpty { problems.append("tools: list at least one Atlantis tool.") }
        var seen = Set<String>()
        for tool in tools {
            if forbiddenTools.contains(tool) {
                problems.append("tools: \(tool) isn't allowed for bots (they use saved SEQTA data and never sync).")
            } else if !allowedTools.contains(tool) {
                problems.append("tools: unknown tool \"\(tool)\".")
            }
            if !seen.insert(tool).inserted { problems.append("tools: \(tool) is listed twice.") }
            if provider == .api, !toolsSafeForOtherProviders.contains(tool) {
                problems.append("tools: \(tool) reads your data, so it only works with provider claude-code (personal data never goes to other AI providers).")
            }
        }

        let triggers = list("triggers") ?? ["chat"]
        for trigger in triggers {
            let kind = trigger.split(separator: " ").first.map(String.init) ?? ""
            if !triggerKinds.contains(kind) {
                problems.append("triggers: unknown trigger \"\(trigger)\" (use chat, mention, task, schedule HH:MM or event <name>).")
            }
        }

        var maxSteps = 12
        var dailyCost = 1.0
        if let raw = fields["budget"] {
            guard let budget = raw.map else {
                problems.append("budget: must hold max_steps and daily_cost_usd on indented lines.")
                throw BotFileError(problems)
            }
            if let value = budget["max_steps"]?.string {
                if let n = Int(value), maxStepsRange.contains(n) { maxSteps = n }
                else { problems.append("budget.max_steps: use a whole number from \(maxStepsRange.lowerBound) to \(maxStepsRange.upperBound).") }
            }
            if let value = budget["daily_cost_usd"]?.string {
                let cleaned = value.hasPrefix("$") ? String(value.dropFirst()) : value
                if let n = Double(cleaned), dailyCostRange.contains(n) { dailyCost = n }
                else { problems.append("budget.daily_cost_usd: use dollars from 0.01 to 50.") }
            }
        }

        let soul = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if soul.isEmpty { problems.append("The body is empty: write the bot's instructions under the front matter.") }
        if soul.count > 20_000 { problems.append("The instructions are too long (keep them under 20,000 characters).") }

        guard problems.isEmpty else { throw BotFileError(problems) }
        return BotDefinition(id: id, name: name, avatar: avatar, model: model, provider: provider, tools: tools,
                             autonomy: autonomy, triggers: triggers, maxSteps: maxSteps, dailyCostUSD: dailyCost,
                             soul: soul)
    }
}

/// A bot file as loaded: the definition, or why it couldn't be used.
public struct BotEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var url: URL
    public var result: Result<BotDefinition, BotFileError>

    public var definition: BotDefinition? { try? result.get() }
    public var problems: [String] {
        if case .failure(let error) = result { return error.problems }
        return []
    }
}

/// Reads the bot files and writes the default School bot the first time.
public enum BotLibrary {
    /// Every `*.md` file in `machine/atlantis/agents/`, sorted with School first, then by name.
    public static func load(vault: VaultPaths) -> [BotEntry] {
        let dir = vault.agentsDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let entries = files.filter { $0.pathExtension == "md" }.map { url -> BotEntry in
            let id = url.deletingPathExtension().lastPathComponent
            let result: Result<BotDefinition, BotFileError>
            do {
                guard let text = try TextFile.read(url) else { throw BotFileError(["The file is missing."]) }
                result = .success(try BotFile.parse(text, id: id))
            } catch let error as BotFileError {
                result = .failure(error)
            } catch {
                result = .failure(BotFileError(["Couldn't read the file: \(error.localizedDescription)"]))
            }
            return BotEntry(id: id, url: url, result: result)
        }
        return entries.sorted { a, b in
            if (a.id == "school") != (b.id == "school") { return a.id == "school" }
            return a.id < b.id
        }
    }

    /// Writes `agents/school.md` only if it doesn't exist (never overwrites the user's copy).
    /// Returns true if it wrote the file.
    @discardableResult
    public static func ensureDefaults(vault: VaultPaths) throws -> Bool {
        guard FileManager.default.fileExists(atPath: vault.root.path) else { return false }
        let url = try vault.writableURL(vault.agentsDir.appendingPathComponent("school.md"))
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create-only: fails rather than replace a file that appeared in the meantime.
        guard FileManager.default.createFile(atPath: url.path, contents: Data(schoolTemplate.utf8)) else {
            if FileManager.default.fileExists(atPath: url.path) { return false }
            throw CocoaError(.fileWriteUnknown)
        }
        return true
    }

    /// The default School bot. Read-only tools plus posting to the Inbox.
    public static let schoolTemplate = """
    ---
    name: School
    avatar: 🎓
    model: sonnet
    autonomy: suggest
    triggers: [chat]
    tools:
      - atlantis_today
      - atlantis_tasks_list
      - atlantis_inbox_list
      - atlantis_school_timetable
      - atlantis_school_assessments
      - atlantis_school_subjects
      - atlantis_school_notices
      - atlantis_school_messages
      - atlantis_docs_list
      - atlantis_docs_search
      - atlantis_doc_read
      - atlantis_inbox_post
    budget:
      max_steps: 12
      daily_cost_usd: 1.00
    ---

    You are School, a study helper for a Year 9 student in Australia. You know their timetable,
    assessments, marks, teacher feedback, notices and messages from SEQTA (saved in Atlantis), plus
    their tasks and docs.

    - Answer from the real data. Look it up with your tools before answering; if something isn't
      there, say so instead of guessing.
    - Be short and concrete: what's due, what matters most, and one next step.
    - When something should become a task or a reminder, post it to the Inbox so the user can accept
      it. You can't change anything yourself, and you never send messages.
    - Use Australian spelling and plain words.

    """
}
