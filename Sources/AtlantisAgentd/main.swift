// atlantis-agentd: runs Atlantis's bots (PRD §7b). The app starts it on the first chat and talks to it
// over a private Unix socket; it exits by itself after a while with nothing to do.
// Usage: atlantis-agentd [--socket <path>] [--idle-exit <seconds>] [--usage <path>]
import AtlantisCore
import Dispatch
import Foundation

signal(SIGPIPE, SIG_IGN)

var socketPath = AgentDaemonInfo.defaultSocketPath
var idleExit: Double = 600
var usageURL = UsageLedger.defaultURL
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--version":
        print("atlantis-agentd \(AgentDaemonInfo.version)")
        exit(0)
    case "--socket": if let value = args.next(), value.hasPrefix("/") { socketPath = value }
    case "--idle-exit": if let value = args.next(), let seconds = Double(value), seconds > 0 { idleExit = seconds }
    case "--usage": if let value = args.next(), value.hasPrefix("/") { usageURL = URL(fileURLWithPath: value) }
    default:
        FileHandle.standardError.write(Data("Unknown option \(arg)\n".utf8))
        exit(2)
    }
}

let daemon = AgentDaemon(socketURL: URL(fileURLWithPath: socketPath), ledger: UsageLedger(url: usageURL),
                         providers: [.claudeCode: ClaudeCodeProvider(), .api: APIWorkerProvider()],
                         idleExitAfter: idleExit)
do {
    try daemon.start()
} catch UnixSocketStartError.alreadyRunning {
    exit(0) // another copy is serving; the app will use that one
} catch {
    FileHandle.standardError.write(Data("atlantis-agentd: \(error)\n".utf8))
    exit(1)
}

// Quit cleanly (stopping any CLI runs) when the app or the system asks.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        daemon.shutdown()
        exit(0)
    }
    source.resume()
    return source
}
withExtendedLifetime(signals) { dispatchMain() }
