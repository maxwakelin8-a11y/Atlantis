import AppKit
import SwiftUI

/// Replaces the plain file window when SEQTA asks for files (assessment submissions, message
/// attachments): pick from iCloud, Google Drive, OneDrive or LifeOS, or fall back to Finder.
/// (From seqta-app. Google Docs export was left out: it needs Google network access, PRD §17.)
/// Uses system styling until the design system lands.
@MainActor
enum FileChooser {
    enum Outcome { case files([URL]), finder, cancelled }

    static func run(on window: NSWindow, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]? {
        let model = ChooserModel(allowsMultiple: allowsMultiple, allowsDirectories: allowsDirectories)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 640, height: 400)
        panel.contentView = NSHostingView(rootView: ChooserView(model: model))

        let outcome: Outcome = await withCheckedContinuation { cont in
            model.finish = { cont.resume(returning: $0) }
            window.beginSheet(panel)
        }
        window.endSheet(panel)
        panel.orderOut(nil)

        switch outcome {
        case .files(let urls): return urls
        case .cancelled: return nil
        case .finder:
            let open = NSOpenPanel()
            open.allowsMultipleSelection = allowsMultiple
            open.canChooseDirectories = allowsDirectories
            open.prompt = "Attach"
            return await open.beginSheetModal(for: window) == .OK ? open.urls : nil
        }
    }
}

struct ChooserSource: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let root: URL?   // nil = "This Mac" (Finder window)

    static func all() -> [ChooserSource] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var out: [ChooserSource] = [ChooserSource(id: "mac", name: "This Mac", symbol: "laptopcomputer", root: nil)]
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) {
            out.append(.init(id: "icloud", name: "iCloud Drive", symbol: "icloud", root: icloud))
        }
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        let entries = ((try? fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in entries where dir.lastPathComponent.hasPrefix("GoogleDrive-") {
            let myDrive = dir.appendingPathComponent("My Drive")
            out.append(.init(id: dir.lastPathComponent, name: "Google Drive", symbol: "triangle",
                             root: fm.fileExists(atPath: myDrive.path) ? myDrive : dir))
        }
        for dir in entries where dir.lastPathComponent.hasPrefix("OneDrive") {
            // Skip empty leftovers like "OneDrive-School(2)".
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path), items.contains(where: { !$0.hasPrefix(".") }) else { continue }
            let suffix = dir.lastPathComponent.replacingOccurrences(of: "OneDrive-", with: "")
                .replacingOccurrences(of: #"\((\d+)\)$"#, with: " $1", options: .regularExpression)
            out.append(.init(id: dir.lastPathComponent, name: suffix == "OneDrive" ? "OneDrive" : "OneDrive (\(suffix))",
                             symbol: "cloud", root: dir))
        }
        out.append(.init(id: "lifeos", name: "LifeOS", symbol: "diamond", root: AppSettings.vaultURL))
        return out
    }
}

struct ChooserItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let isDir: Bool
    let date: Date?
    let size: Int?
    let detail: String   // folder path for search results

    /// Google Docs/Sheets/Slides shortcut files, which hold a link rather than the document.
    var isGoogleNative: Bool { ["gdoc", "gsheet", "gslides"].contains(url.pathExtension.lowercased()) }
    var displayName: String {
        isGoogleNative ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
}

@MainActor
final class ChooserModel: ObservableObject {
    let allowsMultiple: Bool
    let allowsDirectories: Bool
    let sources = ChooserSource.all()
    var finish: (FileChooser.Outcome) -> Void = { _ in }

    @Published var source: ChooserSource?
    @Published var stack: [URL] = []
    @Published var items: [ChooserItem] = []
    @Published var selection = Set<URL>()
    @Published var query = ""
    @Published var loading = false
    @Published var busy: String?
    @Published var error: String?

    private var loadTask: Task<Void, Never>?

    init(allowsMultiple: Bool, allowsDirectories: Bool) {
        self.allowsMultiple = allowsMultiple
        self.allowsDirectories = allowsDirectories
        let last = UserDefaults.standard.string(forKey: "chooserLastSource")
        select(sources.first { $0.id == last && $0.root != nil }
               ?? sources.first { $0.id.hasPrefix("GoogleDrive-") }
               ?? sources.first { $0.root != nil })
    }

    var current: URL? { stack.last }
    var selectedItems: [ChooserItem] { items.filter { selection.contains($0.url) } }

    func select(_ s: ChooserSource?) {
        guard let s else { return }
        source = s
        error = nil
        query = ""
        guard let root = s.root else { stack = []; items = []; return }
        UserDefaults.standard.set(s.id, forKey: "chooserLastSource")
        stack = [root]
        reload()
    }

    func open(_ item: ChooserItem) {
        if item.isDir {
            query = ""
            stack.append(item.url)
            reload()
        } else {
            selection = [item.url]
            attach()
        }
    }

    func up(to index: Int) {
        guard index < stack.count else { return }
        stack = Array(stack.prefix(index + 1))
        query = ""
        reload()
    }

    func reload() {
        loadTask?.cancel()
        selection = []
        guard let dir = current else { items = []; return }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let root = source?.root ?? dir
        loading = true
        loadTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                q.isEmpty ? Self.contents(of: dir) : Self.search(q, in: root)
            }.value
            guard !Task.isCancelled else { return }
            items = found
            loading = false
        }
    }

    nonisolated private static func contents(of dir: URL) -> [ChooserItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.map { item($0, keys: keys, detail: "") }.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    nonisolated private static func search(_ q: String, in root: URL) -> [ChooserItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [ChooserItem] = []
        for case let url as URL in e {
            if Task.isCancelled || out.count >= 300 { break }
            guard url.lastPathComponent.lowercased().contains(q) else { continue }
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "")
            out.append(item(url, keys: keys, detail: folder.isEmpty ? "/" : folder))
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    nonisolated private static func item(_ url: URL, keys: [URLResourceKey], detail: String) -> ChooserItem {
        let v = try? url.resourceValues(forKeys: Set(keys))
        let isDir = v?.isDirectory == true && v?.isPackage != true
        return ChooserItem(url: url, isDir: isDir, date: v?.contentModificationDate, size: v?.fileSize, detail: detail)
    }

    func attach() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        if chosen.count == 1, chosen[0].isDir, !allowsDirectories { open(chosen[0]); return }
        let files = chosen.filter { !$0.isDir || allowsDirectories }
        if files.contains(where: \.isGoogleNative) {
            error = "Google Docs files can't be attached directly. Download it from Google Docs as a PDF or Word file first."
            return
        }
        error = nil
        busy = "Getting files ready…"
        Task {
            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Atlantis-Uploads/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var out: [URL] = []
                for item in files {
                    let url = item.url
                    out.append(try await Task.detached { try Coordinated.copy(url, to: dir) }.value)
                }
                busy = nil
                finish(.files(out))
            } catch {
                busy = nil
                self.error = error.localizedDescription
            }
        }
    }
}

struct ChooserView: View {
    @ObservedObject var model: ChooserModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                if model.source?.root == nil { finderPrompt } else { browser }
                Divider()
                footer
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ADD FROM").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
            ForEach(model.sources) { s in
                Button { model.select(s) } label: {
                    Label(s.name, systemImage: s.symbol)
                        .lineLimit(1).truncationMode(.middle)
                        .help(s.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(model.source == s ? Color.accentColor.opacity(0.85) : .clear, in: .rect(cornerRadius: 7))
                        .foregroundStyle(model.source == s ? .white : .primary)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 36).padding(.horizontal, 8).padding(.bottom, 10)
        .frame(width: 210)
        .background(.background.secondary)
    }

    private var finderPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Choose files anywhere on this Mac").font(.headline)
            Button("Open Finder Window…") { model.finish(.finder) }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.up(to: model.stack.count - 2) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.stack.count < 2 || !model.query.isEmpty)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(model.stack.enumerated()), id: \.offset) { i, url in
                            if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Button(i == 0 ? (model.source?.name ?? "") : url.lastPathComponent) { model.up(to: i) }
                                .buttonStyle(.plain)
                                .foregroundStyle(i == model.stack.count - 1 ? .primary : .secondary)
                        }
                    }
                }
                TextField("Search \(model.source?.name ?? "")", text: $model.query)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { model.reload() }
                    .onChange(of: model.query) { model.reload() }
            }
            .padding(.horizontal, 12).padding(.top, 34).padding(.bottom, 8)

            ZStack {
                List(model.items, selection: $model.selection) { item in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.displayName).lineLimit(1)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if item.isGoogleNative { Text("Google").font(.caption2).foregroundStyle(.secondary) }
                        if let d = item.date {
                            Text(d, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(item.url)
                }
                .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
                    if let url = urls.first, let item = model.items.first(where: { $0.url == url }) { model.open(item) }
                }
                .onChange(of: model.selection) { _, new in
                    if !model.allowsMultiple, new.count > 1, let last = new.first { model.selection = [last] }
                }
                if model.loading { ProgressView().controlSize(.small) }
                else if model.items.isEmpty {
                    Text(model.query.isEmpty ? "Empty folder" : "No matches").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).foregroundStyle(.secondary)
            } else if let error = model.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.callout).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { model.finish(.cancelled) }.keyboardShortcut(.cancelAction)
            if model.source?.root != nil {
                Button("Attach") { model.attach() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection.isEmpty || model.busy != nil)
            }
        }
        .padding(12)
    }
}

/// Coordinated file access, so iCloud / Drive / OneDrive download cloud-only files first.
enum Coordinated {
    /// Copies a file (downloading it if it's cloud-only) into `dir`.
    static func copy(_ url: URL, to dir: URL) throws -> URL {
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.forUploading], error: &coordError) { real in
            result = Result {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                // .forUploading zips folders; keep the original name for files.
                let name = isDir ? url.lastPathComponent + ".zip" : url.lastPathComponent
                let out = DownloadSaver.uniqueURL(in: dir, name: name)
                try FileManager.default.copyItem(at: real, to: out)
                return out
            }
        }
        if let coordError { throw coordError }
        return try result.get()
    }
}
