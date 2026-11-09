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

let handler = MCPProtocolHandler(backend: SocketToolBackend(), serverName: "atlantis", serverVersion: MCPInfo.version)
await StdioTransport.run(handler: handler)
