import AppKit
import AtlantisCore
import SwiftUI

/// Settings ▸ Bots: which Claude Code CLI bots run on, and where their files are.
struct BotsSettingsSection: View {
    let mcp: MCPService
    @State private var cliPath: String?
    @State private var apiWorkerReady = false

    var body: some View {
        Section {
            LabeledContent("Claude Code") {
                if let cliPath {
                    Text(cliPath.isEmpty ? "Not found" : cliPath)
                        .foregroundStyle(cliPath.isEmpty ? Palette.warning : Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Button("Choose…", action: chooseCLI)
                if AppSettings.claudePath != nil {
                    Button("Use the usual place") {
                        AppSettings.claudePath = nil
                        locate()
                    }
                }
            }
            LabeledContent("Bot files") {
                Text("machine/atlantis/agents")
                    .font(Typo.mono)
                    .foregroundStyle(Palette.textSecondary)
            }
            Button("Show Bot Files in Finder") {
                let dir = VaultPaths(root: AppSettings.vaultURL).agentsDir
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
            LabeledContent("Agent helper") {
                Text(daemonExists ? "Bundled" : "Missing: run scripts/build-app.sh")
                    .foregroundStyle(daemonExists ? Palette.textSecondary : Palette.warning)
            }
            LabeledContent("Cheap API worker") {
                Text(apiWorkerReady ? "Key saved (not used yet)" : "Not set up")
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("Bots")
        } footer: {
            Text("Bots run on the official Claude Code CLI with your subscription, locked to their own Atlantis tools: no shell, files or web. Atlantis never reads your Claude login. Each bot's file sets its model, tools, step limit and daily cost cap. Your own data only ever goes to Claude.")
        }
        .onAppear(perform: locate)
    }

    private var daemonExists: Bool {
        mcp.agentDaemonURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }

    private func locate() {
        cliPath = nil
        let saved = AppSettings.claudePath
        Task.detached(priority: .utility) {
            let found = ClaudeCLI.locate(savedPath: saved)?.path ?? ""
            let ready = APIWorkerProvider().isReady
            await MainActor.run {
                cliPath = found
                apiWorkerReady = ready
            }
        }
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use This"
        panel.message = "Choose the claude program (often ~/.local/bin/claude)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.claudePath = url.path
        locate()
    }
}
