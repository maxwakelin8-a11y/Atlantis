import AtlantisCore
import SwiftUI

/// Writes a message (new, reply, or an agent's draft). "Send" never sends by itself: it opens the
/// confirm sheet, which lists the recipients and subject (`SendConfirmSheet`).
struct ComposeView: View {
    let model: MessagesModel
    @Bindable var state: ComposeState

    @State private var query = ""
    @State private var scope: SeqtaPerson.Kind = .staff
    @State private var confirming: SendSnapshot?
    @FocusState private var focus: Field?

    private enum Field { case search, subject, body }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            recipientsField
            TextField("Subject", text: $state.subject)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .subject)
            TextEditor(text: $state.body)
                .font(Typo.body)
                .focused($focus, equals: .body)
                .scrollContentBackground(.hidden)
                .padding(Space.s)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.m))
                .frame(minHeight: 180)
            footer
        }
        .padding(Space.l)
        .frame(maxWidth: Size.readableWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .sheet(item: $confirming) { snapshot in
            SendConfirmSheet(message: snapshot.message, sending: state.sending, error: state.error,
                             cancel: { confirming = nil },
                             send: { confirmation in
                                 Task {
                                     await model.send(state, confirmed: confirmation)
                                     if state.error == nil { confirming = nil }
                                 }
                             })
        }
        .onAppear { focus = state.recipients.isEmpty ? .search : .body }
    }

    private var header: some View {
        HStack {
            Text(state.replyTo == nil ? "New message" : "Reply").font(Typo.pageTitle)
            if state.inboxItemID != nil {
                Pill(text: "Draft from your Inbox", color: Palette.accent)
            }
            Spacer()
        }
    }

    // MARK: Recipients

    private var recipientsField: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("To").font(Typo.secondary).foregroundStyle(Palette.textSecondary)
                    .frame(width: Size.avatar, alignment: .leading)
                FlowChips(items: state.recipients) { person in
                    Button {
                        state.recipients.removeAll { $0.key == person.key }
                    } label: {
                        HStack(spacing: Space.xs) {
                            Text(person.name)
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary)
                        }
                        .font(Typo.secondary)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xs)
                        .background(Palette.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(person.name)")
                    .accessibilityLabel("Remove \(person.name)")
                }
            }
            if !state.hintNames.isEmpty {
                HStack(spacing: Space.xs) {
                    Image(systemName: "sparkles").foregroundStyle(Palette.accent)
                    Text("The draft is for \(state.hintNames.joined(separator: ", ")). Pick them below.")
                        .font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    ForEach(state.hintNames, id: \.self) { name in
                        Button(name) { query = name }.buttonStyle(.link).font(Typo.caption)
                    }
                }
            }
            HStack(spacing: Space.s) {
                TextField("Search people", text: $query, prompt: Text("Search \(scope == .staff ? "staff" : "students")"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .onSubmit { if let first = matches.first { add(first) } }
                Picker("List", selection: $scope) {
                    Text("Staff").tag(SeqtaPerson.Kind.staff)
                    Text("Students").tag(SeqtaPerson.Kind.student)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: Size.recipientScope)
                .onChange(of: scope) { Task { await model.loadPeople(scope) } }
            }
            peopleResults
        }
    }

    private var matches: [SeqtaPerson] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let chosen = Set(state.recipients.map(\.key))
        return model.people(scope)
            .filter { !chosen.contains($0.key) && $0.name.localizedCaseInsensitiveContains(needle) }
            .prefix(6).map { $0 }
    }

    @ViewBuilder private var peopleResults: some View {
        if model.loadingPeople.contains(scope) {
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text("Loading the list…").font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
        } else if let error = model.peopleError, model.people(scope).isEmpty {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle").font(Typo.caption).foregroundStyle(Palette.danger)
                Button("Try again") { Task { await model.loadPeople(scope) } }.controlSize(.small)
            }
        } else if !matches.isEmpty {
            VStack(spacing: 0) {
                ForEach(matches) { person in
                    Button { add(person) } label: {
                        HStack {
                            Text(person.name)
                            if !person.detail.isEmpty {
                                Text(person.detail).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.m))
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty, !model.people(scope).isEmpty {
            Text("No one matches.").font(Typo.caption).foregroundStyle(Palette.textSecondary)
        }
    }

    private func add(_ person: SeqtaPerson) {
        guard !state.recipients.contains(where: { $0.key == person.key }) else { return }
        state.recipients.append(person)
        state.hintNames.removeAll { $0.localizedCaseInsensitiveCompare(person.name) == .orderedSame }
        query = ""
        focus = state.subject.isEmpty ? .subject : .body
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.m) {
            Toggle("Hide recipients from each other", isOn: $state.blind)
                .toggleStyle(.checkbox)
                .font(Typo.secondary)
            Spacer()
            if let problem = state.problem {
                Text(problem.message).font(Typo.caption).foregroundStyle(Palette.textSecondary)
            }
            Button("Discard", role: .destructive) { model.closeCompose() }
                .keyboardShortcut(.cancelAction)
            Button("Send…") { confirming = SendSnapshot(message: state.outgoing) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(state.problem != nil)
                .help("Review and confirm before it's sent (⌘↩)")
        }
    }
}

/// `sheet(item:)` needs an `Identifiable`; one snapshot per time the sheet opens.
struct SendSnapshot: Identifiable {
    let id = UUID()
    let message: SeqtaSend.Outgoing
}

/// Chips that wrap onto more lines when there are many.
struct FlowChips<Item: Identifiable, Chip: View>: View {
    let items: [Item]
    @ViewBuilder var chip: (Item) -> Chip

    var body: some View {
        if items.isEmpty {
            Text("Nobody yet").font(Typo.secondary).foregroundStyle(Palette.textTertiary)
        } else {
            FlowLayout(spacing: Space.xs) {
                ForEach(items) { chip($0) }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
