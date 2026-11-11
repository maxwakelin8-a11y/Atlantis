import Darwin
import Foundation

/// Stop button plumbing: thread-safe, and the cancel action runs once.
public final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            let a = onCancel
            onCancel = nil
            return a
        }
        action?()
    }

    /// What `cancel()` does (kill the process). Runs at once if already cancelled.
    public func setOnCancel(_ action: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if cancelled { return true }
            onCancel = action
            return false
        }
        if runNow { action() }
    }
}

/// Something that runs a bot (PRD §7b "Runtime": a provider interface).
public protocol AgentProvider: Sendable {
    /// Runs to the end on the calling thread (it may block), calling `emit` as things happen.
    /// `budgetUSD` is what's left of today's cap. The returned summary's `todayCostUSD` is filled by the daemon.
    func run(_ spec: AgentRunSpec, budgetUSD: Double, control: RunControl,
             emit: @escaping @Sendable (AgentEvent) -> Void) -> RunSummary
}

/// The Claude Code CLI on the user's subscription, headless and locked to MCP tools (see `ClaudeCLI`).
public struct ClaudeCodeProvider: AgentProvider {
    /// An empty folder the CLI runs in, so no project's CLAUDE.md or settings apply.
    public var workDir: URL
    /// Private per-run files (MCP config with the grant token, system prompt), 0600 in 0700 folders.
    public var runsDir: URL
    public var home: String
    /// Seconds to wait after SIGTERM before SIGKILL.
    public var killGrace: Double

    public init(workDir: URL = AppSupport.root.appendingPathComponent("agents/work", isDirectory: true),
                runsDir: URL = AppSupport.root.appendingPathComponent("agents/runs", isDirectory: true),
                home: String = NSHomeDirectory(), killGrace: Double = 3) {
        self.workDir = workDir
        self.runsDir = runsDir
        self.home = home
        self.killGrace = killGrace
    }

    public static let missingCLIMessage = "Claude Code isn't installed (or Atlantis can't find it). Install it from claude.ai/code, sign in once in Terminal with `claude`, then try again."

    public func run(_ spec: AgentRunSpec, budgetUSD: Double, control: RunControl,
                    emit: @escaping @Sendable (AgentEvent) -> Void) -> RunSummary {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        guard let cli = ClaudeCLI.locate(savedPath: spec.claudePath, home: home) else {
            return RunSummary(status: .refused, message: Self.missingCLIMessage)
        }

        // Private files for this run.
        let runDir = runsDir.appendingPathComponent(spec.runID.filter { $0.isLetter || $0.isNumber }, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runDir) }
        let configURL = runDir.appendingPathComponent("mcp.json")
        let promptURL = runDir.appendingPathComponent("system.md")
        do {
            for dir in [runsDir, runDir, workDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try writePrivate(ClaudeCLI.mcpConfig(helperPath: spec.mcpHelperPath, agentToken: spec.grantToken,
                                                 mcpSocketPath: spec.mcpSocketPath), to: configURL)
            try writePrivate(Data(spec.systemPrompt.utf8), to: promptURL)
        } catch {
            return RunSummary(status: .failed, message: "Couldn't prepare the run: \(error.localizedDescription)")
        }

        let invocation = ClaudeCLI.Invocation(model: spec.model, tools: spec.tools, maxTurns: spec.maxSteps + 3,
                                              maxBudgetUSD: budgetUSD, mcpConfigPath: configURL.path,
                                              systemPromptPath: promptURL.path)
        let process = Process()
        process.executableURL = cli
        process.arguments = ClaudeCLI.arguments(invocation)
        process.currentDirectoryURL = workDir
        process.environment = ClaudeCLI.environment(home: home, user: NSUserName(),
                                                    tmpDir: NSTemporaryDirectory(), cliPath: cli.path)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Wakes the reader when the CLI exits, even if something it started still holds stdout open.
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else { return RunSummary(status: .failed, message: "Couldn't start the run (pipe).") }
        let wakeRead = wake[0], wakeWrite = wake[1]
        let exitHandled = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
            exitHandled.signal()
        }
        defer {
            // Close the wake pipe only once the handler has used it (never a reused fd number).
            if exitHandled.wait(timeout: .now() + 2) == .success { close(wakeRead); close(wakeWrite) }
        }

        do { try process.run() } catch {
            exitHandled.signal()
            return RunSummary(status: .failed, message: "Couldn't start Claude Code: \(error.localizedDescription)")
        }
        let pid = process.processIdentifier
        let grace = killGrace
        let terminate: @Sendable () -> Void = {
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { kill(pid, SIGKILL) }
        }
        control.setOnCancel(terminate)

        // The prompt goes on stdin (never argv, so it isn't visible in `ps`).
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(spec.prompt.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let errors = TailBuffer(limit: 4096)
        let errorsDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = stderr.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty { errors.append(chunk) }
            errorsDone.signal()
        }

        var monitor = RunMonitor(bot: spec.botName, allowedTools: spec.tools, maxSteps: spec.maxSteps)
        var killed = false
        let outFD = stdout.fileHandleForReading.fileDescriptor
        var lines = LineSplitter()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var exited = false
        reading: while true {
            var fds = [pollfd(fd: outFD, events: Int16(POLLIN), revents: 0), pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            // Blocks until output or exit (no timer). After exit, take what's still buffered, then stop.
            let ready = poll(&fds, 2, exited ? 300 : -1)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { break }
            if fds[1].revents & Int16(POLLIN) != 0 {
                var byte: UInt8 = 0
                _ = read(wakeRead, &byte, 1)
                exited = true
            }
            guard fds[0].revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { read(outFD, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break } // EOF
            for line in lines.append(buffer[0..<count]) {
                for event in monitor.consume(line) { emit(event) }
                if monitor.stop != nil, !killed {
                    killed = true
                    terminate()
                }
                if killed { continue reading }
            }
        }
        if let rest = lines.rest() { for event in monitor.consume(rest) { emit(event) } }
        process.waitUntilExit()
        _ = errorsDone.wait(timeout: .now() + 2)
        let exit = process.terminationReason == .exit ? process.terminationStatus : nil
        return monitor.summary(cancelled: control.isCancelled, exitCode: exit, errorTail: errors.text, durationMs: elapsed())
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Splits a byte stream into lines.
struct LineSplitter {
    private var pending = Data()

    mutating func append(_ bytes: ArraySlice<UInt8>) -> [String] {
        pending.append(contentsOf: bytes)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > Framing.maxFrameSize { pending.removeAll() } // not a real line
        return lines
    }

    mutating func rest() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// The last few KB of a stream (the CLI's stderr), for error messages.
final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data = data.suffix(limit) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// The cheap API worker slot (PRD §7b "Fusion" and fallback). Interface only in M5: no bot uses it,
/// and it makes no network calls. Its key would live in the Keychain, never in files.
/// SEQTA and personal data never go to it (enforced in `BotFile.parse`: `provider: api` bots can't
/// have tools that read the user's data).
public struct APIWorkerProvider: AgentProvider {
    public static let keychainAccount = "agents.api-worker-key"
    public static let notSetUpMessage = "The cheap API worker isn't set up. Bots run on Claude Code for now (set provider: claude-code in the bot's file)."

    let isConfigured: @Sendable () -> Bool

    /// Whether a key is saved (reads the Keychain; call it only when someone looks).
    public var isReady: Bool { isConfigured() }

    public init(isConfigured: @escaping @Sendable () -> Bool = {
        (try? Keychain().get(APIWorkerProvider.keychainAccount)) != nil
    }) {
        self.isConfigured = isConfigured
    }

    public func run(_ spec: AgentRunSpec, budgetUSD: Double, control: RunControl,
                    emit: @escaping @Sendable (AgentEvent) -> Void) -> RunSummary {
        guard isConfigured() else { return RunSummary(status: .refused, message: Self.notSetUpMessage) }
        return RunSummary(status: .refused, message: "The API worker has a key but isn't built yet (it comes after M5).")
    }
}
