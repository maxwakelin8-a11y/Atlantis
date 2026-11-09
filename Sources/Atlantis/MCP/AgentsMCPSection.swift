import AppKit
import SwiftUI

/// Settings ▸ Agents & MCP: is the server running, and how to connect Claude Code to it.
struct AgentsMCPSection: View {
    let mcp: MCPService
    @State private var copied: String?

    var body: some View {
        Section {
            LabeledContent("Server") {
                Text(statusText)
                    .foregroundStyle(statusColor)
            }
            LabeledContent("Socket") {
                Text(mcp.socketPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let command = mcp.claudeCommand {
                snippet("Add to Claude Code", text: command, id: "command")
            }
            if let json = mcp.jsonSnippet {
                snippet("Or a .mcp.json file", text: json, id: "json")
            }
            if !mcp.helperExists {
                Text("The helper isn't next to this build. Run scripts/build-app.sh to bundle it.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warning)
            }
        } header: {
            Text("Agents & MCP")
        } footer: {
            Text("Agents connect through the bundled atlantis-mcp helper, which talks to this app over a private socket only you can use. Reads are free. Writes that need approval land in the Inbox. Atlantis must be open for the tools to work.")
        }
    }

    private func snippet(_ title: String, text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title)
                Spacer()
                Button(copied == id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = id
                }
            }
            Text(text)
                .font(Typo.mono)
                .textSelection(.enabled)
                .padding(Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.s))
        }
    }

    private var statusText: String {
        switch mcp.state {
        case .stopped: "Not running"
        case .starting: "Starting…"
        case .running: "Running"
        case .failed(let reason): "Failed: \(reason)"
        }
    }

    private var statusColor: Color {
        switch mcp.state {
        case .running: Palette.success
        case .failed: Palette.danger
        default: Palette.textSecondary
        }
    }
}
