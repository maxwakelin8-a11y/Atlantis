import AtlantisCore
import SwiftUI

/// The last step before a message leaves (PRD §7d): lists exactly who it goes to and what it
/// says, and sends only on an explicit "Send message". This sheet is the only code that makes a
/// `SeqtaSend.Confirmation`, so nothing but a click here can send. Bots and MCP tools can't.
struct SendConfirmSheet: View {
    /// What's shown is a copy taken when the sheet opened; the send is checked against it.
    let message: SeqtaSend.Outgoing
    let sending: Bool
    let error: String?
    let cancel: () -> Void
    let send: (SeqtaSend.Confirmation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Send this message?").font(Typo.pageTitle)
            VStack(alignment: .leading, spacing: Space.s) {
                Text(message.recipients.count == 1 ? "It will be sent to" : "It will be sent to these \(message.recipients.count) people")
                    .font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                ForEach(message.recipients) { person in
                    HStack(spacing: Space.s) {
                        Image(systemName: person.kind == .staff ? "person.crop.square" : "person")
                            .foregroundStyle(Palette.textSecondary)
                        Text(person.name).font(Typo.body.weight(.medium))
                        Pill(text: person.kind == .staff ? "Staff" : "Student")
                        if !person.detail.isEmpty {
                            Text(person.detail).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                if message.blind {
                    Label("Recipients can't see each other (blind copy).", systemImage: "eye.slash")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Subject").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                Text(message.subject).font(Typo.body.weight(.medium))
            }
            ScrollView {
                Text(message.body)
                    .font(Typo.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
            }
            .frame(minHeight: 80, maxHeight: 180)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.m))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Typo.secondary).foregroundStyle(Palette.danger)
            }
            HStack {
                Text("Messages can't be unsent.").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Keep editing", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(sending)
                Button("Send message") { send(SeqtaSend.Confirmation(confirming: message)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending)
            }
        }
        .padding(Space.l)
        .frame(width: Size.readableWidth)
    }
}
