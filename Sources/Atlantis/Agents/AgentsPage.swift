import AppKit
import AtlantisCore
import SwiftUI

/// The Agents page (PRD §7b, M5): bots and their threads on the left, the open thread on the right.
/// Plain macOS look, shared tokens only (AGENTS.md "Design").
struct AgentsPage: View {
    @Bindable var service: AgentService

    var body: some View {
        Group {
            if service.vaultMissing {
                EmptyState(title: "No LifeOS vault", systemImage: "folder.badge.questionmark",
                           message: "Bots live in machine/atlantis/agents in your LifeOS vault, and it isn't there.")
            } else {
                HStack(spacing: 0) {
                    BotList(service: service)
                        .frame(width: Size.threadList)
                    Divider()
                    ThreadPane(service: service)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { service.start() }
    }
}

// MARK: - Left: bots and threads

private struct BotList: View {
    @Bindable var service: AgentService

    var body: some View {
        List(selection: $service.selection) {
            ForEach(service.bots) { entry in
                Section {
                    if let bot = entry.definition {
                        Label("New chat", systemImage: "square.and.pencil")
                            .tag(AgentService.Selection.newChat(bot.id))
                        ForEach(service.threads[bot.id] ?? []) { thread in
                            ThreadRow(thread: thread, running: service.live?.threadID == thread.id)
                                .tag(AgentService.Selection.thread(bot: bot.id, id: thread.id))
                        }
                    } else {
                        Label {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text("\(entry.id).md can't be used")
                                Text(entry.problems.joined(separator: "\n"))
                                    .font(Typo.caption)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(4)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.warning)
                        }
                        .selectionDisabled()
                    }
                } header: {
                    if let bot = entry.definition {
                        Text("\(bot.avatar) \(bot.name)")
                    } else {
                        Text(entry.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if service.bots.isEmpty {
                EmptyState(title: "No bots", systemImage: "person.2",
                           message: "Add a bot file to machine/atlantis/agents.")
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary
    let running: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(thread.title).lineLimit(1)
                Text(thread.updated, format: .relative(presentation: .named))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            if running { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, Space.xxs)
    }
}

// MARK: - Right: the open thread

private struct ThreadPane: View {
    @Bindable var service: AgentService

    var body: some View {
        if let bot = service.selectedBot {
            VStack(spacing: 0) {
                ThreadHeader(service: service, bot: bot)
                Divider()
                if service.cliPath == "" {
                    MissingCLIBanner()
                    Divider()
                }
                Messages(service: service, bot: bot)
                Divider()
                Composer(service: service, bot: bot)
            }
        } else {
            EmptyState(title: "Pick a bot", systemImage: "person.2",
                       message: "Choose a bot on the left to start a chat.")
        }
    }
}

private struct ThreadHeader: View {
    let service: AgentService
    let bot: BotDefinition

    var body: some View {
        HStack(spacing: Space.s) {
            Text(bot.avatar).font(Typo.pageTitle)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(service.thread?.title ?? bot.name).font(Typo.sectionTitle).lineLimit(1)
                Text(summary).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Pill(text: bot.model)
            Pill(text: autonomyText)
            Pill(text: service.todayText(for: bot), color: overCap ? Palette.danger : Palette.textSecondary)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }

    private var summary: String {
        let tools = "\(bot.tools.count) tool\(bot.tools.count == 1 ? "" : "s")"
        guard let thread = service.thread, thread.runs > 0 else {
            return "\(bot.name) · \(tools) · up to \(bot.maxSteps) steps a run"
        }
        return "\(bot.name) · \(thread.runs) run\(thread.runs == 1 ? "" : "s") · \(thread.steps) steps · \(UsageLedger.dollars(thread.costUSD))"
    }

    private var autonomyText: String {
        switch bot.autonomy {
        case .suggest: "Suggests only"
        case .ask: "Asks first"
        case .act: "Acts on allow list"
        }
    }

    private var overCap: Bool { (service.todayCost[bot.id] ?? 0) >= bot.dailyCostUSD }
}

private struct MissingCLIBanner: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Claude Code isn't installed").font(Typo.sectionTitle)
                Text("Bots run on the Claude Code CLI with your subscription. Install it from claude.ai/code, run `claude` once in Terminal to sign in, then come back. You can also pick it in Settings ▸ Bots.")
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
    }
}

private struct Messages: View {
    let service: AgentService
    let bot: BotDefinition
    private static let bottom = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if let thread = service.thread {
                        ForEach(Array(thread.messages.enumerated()), id: \.offset) { _, message in
                            MessageView(message: message, bot: bot)
                        }
                    } else if service.live == nil {
                        NewChatPrompt(service: service, bot: bot)
                    }
                    if let live = service.live, live.threadID == service.thread?.id {
                        LiveReply(live: live, bot: bot)
                    }
                    Color.clear.frame(height: Space.xs).id(Self.bottom)
                }
                .frame(maxWidth: Size.readableWidth, alignment: .leading)
                .padding(Space.l)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: service.thread?.messages.count) { withAnimation(Motion.quick) { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onChange(of: service.live?.segments) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }
}

private struct NewChatPrompt: View {
    let service: AgentService
    let bot: BotDefinition

    private var suggestions: [String] {
        bot.tools.contains(where: { $0.hasPrefix("atlantis_school_") })
            ? ["What's due this week?", "What's on tomorrow?", "How are my marks going?"]
            : ["What's on today?", "What's in my Inbox?"]
    }

    var body: some View {
        VStack(spacing: Space.m) {
            EmptyState(title: "Chat with \(bot.name)", systemImage: "bubble.left.and.bubble.right",
                       message: "\(bot.name) reads your Atlantis data with its own tools. It can't change anything: suggestions land in your Inbox.")
            HStack(spacing: Space.s) {
                ForEach(suggestions, id: \.self) { text in
                    Button(text) { service.draft = text }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xxl)
    }
}

private struct MessageView: View {
    let message: ThreadMessage
    let bot: BotDefinition

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: Space.xxl)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .cardStyle()
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                BotByline(bot: bot, date: message.at)
                if !message.tools.isEmpty { ToolChips(tools: message.tools.map { ($0, false) }) }
                if !message.text.isEmpty { ReplyText(text: message.text) }
                if let run = message.run { RunFooter(run: run) }
            }
        }
    }
}

private struct LiveReply: View {
    let live: AgentService.LiveRun
    let bot: BotDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            BotByline(bot: bot, date: nil)
            ForEach(live.segments) { segment in
                switch segment {
                case .text(_, let text): ReplyText(text: text)
                case .tool(_, let name, let failed): ToolChips(tools: [(name, failed == true)])
                }
            }
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text(statusText).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var statusText: String {
        if live.stopping { return "Stopping…" }
        let steps = live.steps == 0 ? "" : " · \(live.steps) of \(bot.maxSteps) steps"
        return (live.segments.isEmpty ? "Thinking…" : "Working…") + steps
    }
}

private struct BotByline: View {
    let bot: BotDefinition
    let date: Date?

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(bot.avatar)
            Text(bot.name).font(Typo.sectionTitle)
            if let date {
                Text(date, format: .dateTime.hour().minute())
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

/// Tool calls, compact: "📚 Read the timetable · ✅ Read your tasks".
private struct ToolChips: View {
    let tools: [(name: String, failed: Bool)]

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                if index > 0 { Text("·").foregroundStyle(Palette.textTertiary) }
                Text(ToolLabels.label(tool.name))
                    .strikethrough(tool.failed)
                    .help(tool.failed ? "\(tool.name) (refused or failed)" : tool.name)
            }
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(2)
    }
}

private struct ReplyText: View {
    let text: String

    var body: some View {
        Text(Self.markdown(text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct RunFooter: View {
    let run: RunInfo

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if let note = run.note, !note.isEmpty {
                Label(note, systemImage: run.status == .stopped ? "stop.circle" : "exclamationmark.triangle")
                    .font(Typo.secondary)
                    .foregroundStyle(run.status == .stopped ? Palette.textSecondary : Palette.warning)
            }
            Text("\(run.steps) step\(run.steps == 1 ? "" : "s") · \(UsageLedger.dollars(run.costUSD))")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}

private struct Composer: View {
    @Bindable var service: AgentService
    let bot: BotDefinition
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            TextField("Ask \(bot.name)…", text: $service.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .cardStyle()
                .disabled(service.cliPath == "")
            if service.isRunning {
                Button("Stop", systemImage: "stop.fill", action: service.stop)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop (⌘.)")
                    .disabled(service.live?.stopping == true)
            } else {
                Button("Send", systemImage: "arrow.up", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (⌘↩)")
                    .disabled(service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.cliPath == "")
            }
        }
        .labelStyle(.iconOnly)
        .controlSize(.large)
        .padding(Space.m)
        .onAppear { focused = true }
    }

    private func send() {
        service.send()
        focused = true
    }
}
