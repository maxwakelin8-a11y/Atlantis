import AppKit
import SwiftUI

/// Settings, using the system form style until the design system lands.
struct SettingsPage: View {
    let model: AppModel
    @State private var extensionPath = AppSettings.extensionURL.path
    @State private var savedAddress = false
    @State private var writerPath = AppSettings.writerURL.path
    @State private var author = AppSettings.authorName
    @AppStorage(AppSettings.showSeqtaTabKey) private var showSeqtaTab = true

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

            SeqtaSyncSection(model: model)

            Section {
                Toggle("Show SEQTA tab", isOn: $showSeqtaTab)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("The SEQTA web tab is temporary. Today, Tasks, Subjects and Messages are meant to replace it; turn it off once they cover your school day.")
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
            BotsSettingsSection(mcp: model.mcp)
            TeamSettingsSection(model: model)

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

/// The SEQTA data sync: when it last ran, what happened, and a Refresh button.
private struct SeqtaSyncSection: View {
    let model: AppModel

    var body: some View {
        let sync = model.seqtaSync
        Section {
            LabeledContent("Last sync") {
                Text(sync.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    .textSelection(.enabled)
            }
            switch sync.state {
            case .idle:
                if !sync.partialFailures.isEmpty {
                    Label("Some parts didn't load: \(sync.partialFailures.joined(separator: ", ")).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            case .syncing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Syncing…").foregroundStyle(.secondary)
                }
            case .needsSignIn:
                Label("You're not signed in to SEQTA. Sign in from the SEQTA tab, then refresh.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh now") { Task { await sync.refresh(reason: .manual) } }
                    .disabled(sync.isSyncing)
                if sync.state == .needsSignIn {
                    Button("Open SEQTA tab") { model.page = .seqta }
                }
            }
        } header: {
            Text("SEQTA sync")
        } footer: {
            Text("Atlantis reads your timetable, assessments, notices, marks and message list once each morning and when you refresh (⇧⌘R). It never sends anything. Kept on this Mac only.")
        }
    }
}
