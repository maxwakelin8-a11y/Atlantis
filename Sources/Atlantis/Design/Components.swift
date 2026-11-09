import SwiftUI

/// Shared building blocks. Screens compose these instead of styling things themselves.

/// A titled group on a page (Today's columns, Subject sections).
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let systemImage {
                Label(title, systemImage: systemImage).font(Typo.sectionTitle)
            } else {
                Text(title).font(Typo.sectionTitle)
            }
            content
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.l))
    }
}

/// A small rounded label (subject, mode, project, due date).
struct Pill: View {
    let text: String
    var color: Color = Palette.textSecondary

    var body: some View {
        Text(text)
            .font(Typo.caption)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Empty or not-ready state for a page or section.
struct EmptyState: View {
    let title: String
    let systemImage: String
    var message: String = ""

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if !message.isEmpty { Text(message) }
        }
    }
}
