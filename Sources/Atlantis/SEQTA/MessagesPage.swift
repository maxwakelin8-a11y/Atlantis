import AtlantisCore
import QuickLook
import SwiftUI

/// SEQTA messages (PRD §7d): the list comes from the cache, a message's body is fetched when it's
/// opened (once, then kept), and the user can reply or write a new one. Sending goes through the
/// compose view's Send and a confirm sheet; nothing else sends.
struct MessagesPage: View {
    let model: AppModel
    @State private var files: SeqtaFileOpener

    init(model: AppModel) {
        self.model = model
        _files = State(initialValue: SeqtaFileOpener(sync: model.seqtaSync))
    }

    private var messages: MessagesModel { model.messages }
    private var data: SeqtaData { model.seqtaData }

    var body: some View {
        HStack(spacing: 0) {
            MessageList(model: messages, data: data, sync: model.seqtaSync, signIn: { model.page = .seqta })
                .frame(width: Size.sidePanel + Space.xxl)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open in SEQTA", systemImage: "arrow.up.forward.app") {
                    model.openInSeqta(model.seqtaPage(SeqtaPages.messages))
                }
                .help("Open messages in a SEQTA window")
                Button("New message", systemImage: "square.and.pencil") { messages.startCompose() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("New message (⇧⌘N)")
            }
        }
        .quickLookPreview(Bindable(files).preview)
    }

    @ViewBuilder private var detail: some View {
        if let compose = messages.compose {
            ScrollView { ComposeView(model: messages, state: compose).id(compose.id) }
        } else if messages.selectedID == nil {
            EmptyState(title: "No message selected", systemImage: "envelope.open",
                       message: data.messages.isEmpty ? "Messages appear here after a sync." : "Pick a message from the list.")
        } else if let message = messages.open {
            MessageDetail(message: message, files: files, reply: { messages.startReply(to: message) },
                          openInSeqta: { model.openInSeqta(model.seqtaPage(SeqtaPages.messages)) })
        } else if messages.opening {
            VStack(spacing: Space.s) {
                ProgressView()
                Text("Opening…").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
            }
        } else {
            ContentUnavailableView {
                Label("Couldn't open it", systemImage: "exclamationmark.triangle")
            } description: {
                Text(messages.openError ?? "Something went wrong.")
            } actions: {
                Button("Try again", action: messages.retryOpen)
            }
        }
    }
}

// MARK: List

private struct MessageList: View {
    let model: MessagesModel
    let data: SeqtaData
    let sync: SeqtaSync
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if sync.state == .needsSignIn {
                HStack {
                    Label("Not signed in to SEQTA", systemImage: "person.crop.circle.badge.exclamationmark")
                    Spacer()
                    Button("Sign in", action: signIn).controlSize(.small)
                }
                .font(Typo.caption)
                .padding(Space.s)
                .background(Palette.surface)
            }
            if data.messages.isEmpty {
                EmptyState(title: "No messages", systemImage: "envelope",
                           message: data.hasData ? "Your SEQTA inbox is empty." : "Refresh in Settings to load your messages.")
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(data.messages) { message in
                        MessageRow(message: message, unread: data.isUnread(message))
                            .tag(message.id)
                    }
                }
                .listStyle(.inset)
            }
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            Text(data.syncedAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet")
                .font(Typo.caption).foregroundStyle(Palette.textSecondary)
            Spacer()
            if sync.isSyncing {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await sync.refresh(reason: .manual) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh from SEQTA (⇧⌘R)")
            }
        }
        .padding(Space.s)
        .background(Palette.surface)
    }
}

private struct MessageRow: View {
    let message: MessageSummary
    let unread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Circle()
                .fill(unread ? Palette.accent : .clear)
                .frame(width: Space.s, height: Space.s)
                .padding(.top, Space.xs)
                .accessibilityLabel(unread ? "Unread" : "")
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack {
                    Text(message.sender.isEmpty ? "Unknown sender" : message.sender)
                        .font(Typo.body.weight(unread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: Space.s)
                    if message.attachmentCount > 0 {
                        Image(systemName: "paperclip").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    }
                    Text(MessageFormat.listDate(message.date))
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(Typo.secondary)
                    .foregroundStyle(unread ? Palette.text : Palette.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Space.xxs)
    }
}

enum MessageFormat {
    /// Time for today, "Mon" within a week, otherwise the short date.
    static func listDate(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days > 0, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: Detail

private struct MessageDetail: View {
    let message: Message
    let files: SeqtaFileOpener
    let reply: () -> Void
    let openInSeqta: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(message.summary.subject.isEmpty ? "(no subject)" : message.summary.subject)
                        .font(Typo.pageTitle)
                    HStack(spacing: Space.s) {
                        Text(message.summary.sender).font(Typo.body.weight(.medium))
                        if !message.summary.senderType.isEmpty { Pill(text: message.summary.senderType.capitalized) }
                        Spacer()
                        if let date = message.summary.date {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    if !message.recipients.isEmpty {
                        Text("To \(message.recipients.joined(separator: ", "))")
                            .font(Typo.caption).foregroundStyle(Palette.textSecondary).lineLimit(2)
                    }
                }
                Divider()
                // Plain text on purpose: SEQTA's HTML was reduced to text when it was read, so
                // there is no remote content or script to run.
                Text(verbatim: message.body.isEmpty ? "(no text)" : message.body)
                    .font(Typo.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.files.isEmpty { attachments }
                if let error = files.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Typo.secondary).foregroundStyle(Palette.danger)
                }
                HStack {
                    Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
                        .keyboardShortcut("r", modifiers: [.command, .option])
                        .help("Reply (⌥⌘R)")
                    Button("Open in SEQTA", systemImage: "arrow.up.forward.app", action: openInSeqta)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: Size.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Attachments").font(Typo.sectionTitle)
            ForEach(message.files, id: \.uuid) { file in
                Button {
                    files.open(uuid: file.uuid, name: file.name, source: .message)
                } label: {
                    HStack {
                        Image(systemName: "paperclip")
                        Text(file.name)
                        if files.busy.contains(file.uuid) { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.link)
            }
        }
    }
}
