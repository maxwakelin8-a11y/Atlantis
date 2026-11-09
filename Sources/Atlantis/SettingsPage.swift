import AppKit
import SwiftUI

/// Settings, using the system form style until the design system lands.
struct SettingsPage: View {
    let model: AppModel
    @State private var extensionPath = AppSettings.extensionURL.path
    @State private var savedAddress = false
    @State private var writerPath = AppSettings.writerURL.path
    @State private var author = AppSettings.authorName

    var body: some View {
        Form {
            Section {
                SeqtaAddressField { _ in
                    savedAddress = true
                    if let seqta = model.seqtaIfStarted, seqta.phase == .ready {
                        seqta.goHome()
                    } else {
                        model.seqtaIfStarted?.start()
                    }
                }
                if savedAddress {
                    Text("Saved.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("SEQTA")
            } footer: {
                Text("Saved on this Mac only. Atlantis connects only to this address and its sign-in pages.")
            }

            Section {
                LabeledContent("Folder") {
                    Text(extensionPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…", action: chooseExtension)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.extensionURL])
                    }
                }
            } header: {
                Text("BetterSEQTA+")
            } footer: {
                Text("The fork's `npm run build:safari` output. Quit and reopen Atlantis to load a new build.")
            }

            Section {
                LabeledContent("Folder") {
                    Text(writerPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…", action: chooseWriterFolder)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.writerURL])
                    }
                }
                TextField("Your name", text: $author, prompt: Text("Used on exported title pages"))
                    .onSubmit { AppSettings.authorName = author }
                    .onChange(of: author) { AppSettings.authorName = author }
            } header: {
                Text("Docs")
            } footer: {
                Text("One folder per project, as plain Markdown files. The same folder the BetterSEQTA+ Writer uses, so its projects open here too. Reopen Docs after changing it.")
            }

            AgentsMCPSection(mcp: model.mcp)

            Section("About") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Your data", value: "Stays on this Mac")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseExtension() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = AppSettings.extensionURL
        panel.prompt = "Use Folder"
        panel.message = "Choose the BetterSEQTA+ build folder (it has a manifest.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.extensionURL = url
        extensionPath = url.path
    }

    private func chooseWriterFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = AppSettings.writerURL
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder Docs keeps your projects in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.writerURL = url
        writerPath = url.path
        model.docsIfStarted?.reloadPage()
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
