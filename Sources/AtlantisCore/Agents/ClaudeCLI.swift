import Foundation

/// How Atlantis runs the official Claude Code CLI headless for a bot (PRD §7b): `claude -p` with
/// stream-json output, locked to the bundled `atlantis-mcp` server and the bot's own tools.
///
/// Atlantis never reads, copies or passes on the subscription's login: the CLI uses its own.
public enum ClaudeCLI {
    /// The MCP server name in the config, so tools are `mcp__atlantis__<tool>`.
    public static let serverName = "atlantis"

    /// Built-in Claude Code tools, all denied by name as well as removed with `--tools ""`
    /// (belt and braces: a new CLI version that ignored `--tools ""` still couldn't use them).
    public static let builtInTools = [
        "Bash", "BashOutput", "KillShell", "KillBash", "PowerShell", "Read", "Write", "Edit", "MultiEdit",
        "NotebookEdit", "NotebookRead", "Glob", "Grep", "LS", "WebFetch", "WebSearch", "Task", "Agent",
        "TodoWrite", "TodoRead", "ExitPlanMode", "EnterPlanMode", "EnterWorktree", "ExitWorktree",
        "SlashCommand", "Skill", "ListMcpResourcesTool", "ReadMcpResourceTool", "Monitor", "SendMessage",
        "ToolSearch", "CronCreate", "CronDelete", "CronList", "RemoteTrigger", "ScheduleWakeup",
        "Artifact", "AskUserQuestion", "Workflow",
    ]

    /// `mcp__atlantis__<tool>` for each tool.
    public static func qualified(_ tools: [String]) -> [String] {
        tools.map { "mcp__\(serverName)__\($0)" }
    }

    /// The Atlantis tool name for a CLI tool name, or nil if it isn't one of ours.
    public static func atlantisTool(_ qualifiedName: String) -> String? {
        let prefix = "mcp__\(serverName)__"
        guard qualifiedName.hasPrefix(prefix) else { return nil }
        return String(qualifiedName.dropFirst(prefix.count))
    }

    public struct Invocation: Sendable, Equatable {
        public var model: String
        public var tools: [String]
        public var maxTurns: Int
        /// Dollars left of the bot's daily cap; the CLI stops the run there itself.
        public var maxBudgetUSD: Double?
        public var mcpConfigPath: String
        public var systemPromptPath: String

        public init(model: String, tools: [String], maxTurns: Int, maxBudgetUSD: Double?,
                    mcpConfigPath: String, systemPromptPath: String) {
            self.model = model
            self.tools = tools
            self.maxTurns = maxTurns
            self.maxBudgetUSD = maxBudgetUSD
            self.mcpConfigPath = mcpConfigPath
            self.systemPromptPath = systemPromptPath
        }
    }

    /// The command-line arguments. The prompt goes on stdin, never in argv.
    ///
    /// - `--tools ""` removes every built-in tool (shell, files, web, subagents); `--disallowedTools`
    ///   denies them by name too.
    /// - `--strict-mcp-config` + `--mcp-config` (a 0600 file): only the bundled `atlantis-mcp` server.
    /// - `--allowedTools`: exactly the bot's tools; `--permission-mode dontAsk` denies anything else
    ///   instead of asking.
    /// - `--setting-sources ""`: the user's own Claude Code settings, plugins and hooks don't load.
    /// - `--disable-slash-commands`, `--no-session-persistence`: no skills, nothing saved in ~/.claude.
    /// - Free text (the system prompt) is read from a file, so nothing the user wrote can look like a flag.
    public static func arguments(_ invocation: Invocation) -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", invocation.model,
            "--system-prompt-file", invocation.systemPromptPath,
            "--tools", "",
            "--strict-mcp-config",
            "--mcp-config", invocation.mcpConfigPath,
            "--allowedTools", qualified(invocation.tools).joined(separator: ","),
            "--disallowedTools", builtInTools.joined(separator: ","),
            "--permission-mode", "dontAsk",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--max-turns", String(invocation.maxTurns),
        ]
        if let budget = invocation.maxBudgetUSD {
            args += ["--max-budget-usd", String(format: "%.4f", max(budget, 0.0001))]
        }
        return args
    }

    /// The `--mcp-config` file: only the bundled helper, with the run's grant token in its environment.
    public static func mcpConfig(helperPath: String, agentToken: String, mcpSocketPath: String) -> Data {
        let value: JSONValue = ["mcpServers": [
            .init(stringLiteral: serverName): [
                "type": "stdio",
                "command": .string(helperPath),
                "args": [],
                "env": [
                    .init(stringLiteral: MCPCaller.agentTokenEnv): .string(agentToken),
                    "ATLANTIS_MCP_SOCKET": .string(mcpSocketPath),
                ],
            ],
        ]]
        return value.encoded()
    }

    /// The CLI's environment: only what it needs to find its own login and run, nothing from the
    /// app's environment (no stray API keys). Non-essential traffic (telemetry, auto-update) is off.
    public static func environment(home: String, user: String, tmpDir: String, cliPath: String) -> [String: String] {
        let cliDir = (cliPath as NSString).deletingLastPathComponent
        return [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "TMPDIR": tmpDir,
            "LANG": "en_AU.UTF-8",
            // The CLI's own folder first (npm installs need `node` beside it).
            "PATH": [cliDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_AUTOUPDATER": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            // A tool call may wait for the user to approve a write (`ask` bots): a bit longer than
            // the helper's own limit, so the helper's clear message arrives first.
            "MCP_TOOL_TIMEOUT": String(Int(SocketToolBackend.agentCallTimeout + 15) * 1000),
        ]
    }

    // MARK: Finding the CLI

    /// Usual install places, newest first.
    public static func candidatePaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
    }

    /// The `claude` executable: a saved path, the usual places, then the login shell's PATH.
    /// Runs a shell only when the usual places miss, and only when asked (never at idle).
    public static func locate(savedPath: String? = nil, home: String = NSHomeDirectory(),
                              useLoginShell: Bool = true) -> URL? {
        let fm = FileManager.default
        if let savedPath, !savedPath.isEmpty, fm.isExecutableFile(atPath: savedPath) {
            return URL(fileURLWithPath: savedPath)
        }
        for path in candidatePaths(home: home) where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard useLoginShell else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(50_000) } // one-off, bounded
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/"), fm.isExecutableFile(atPath: text) else { return nil }
        return URL(fileURLWithPath: text)
    }
}
