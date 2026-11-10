// atlantis-mcp: an MCP server over stdio that forwards tools/list and tools/call to the running
// Atlantis app on a local Unix socket. It does no work itself and never launches the app.
// Messages go on stdout; anything for humans goes to stderr.
import AtlantisCore
import Foundation

signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--version") {
    print("atlantis-mcp \(MCPInfo.version)")
    exit(0)
}

// A bot's run sets ATLANTIS_AGENT_TOKEN; the app then only offers that bot's tools.
let token = ProcessInfo.processInfo.environment[MCPCaller.agentTokenEnv]
let handler = MCPProtocolHandler(backend: SocketToolBackend(agentToken: token), serverName: "atlantis", serverVersion: MCPInfo.version)
await StdioTransport.run(handler: handler)
