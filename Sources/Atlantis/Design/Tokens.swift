import SwiftUI

/// Design tokens: the only place screens get spacing, sizes, radii, type and colours from.
///
/// Plain macOS look for now (AGENTS.md "Design"). When the user's design is approved, restyle
/// here and in `Components.swift`, not in each screen. Screens never use raw numbers or colours.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let s: CGFloat = 4
    static let m: CGFloat = 8
    static let l: CGFloat = 12
}

enum Size {
    /// Narrowest a page's main column gets before it scrolls sideways.
    static let pageMinWidth: CGFloat = 420
    /// Readable width for text-heavy columns (messages, task notes).
    static let readableWidth: CGFloat = 720
    static let listRowMinHeight: CGFloat = 28
    static let iconS: CGFloat = 14
    static let iconM: CGFloat = 18
    static let avatar: CGFloat = 28
    /// Width of a side panel (inspector, task detail).
    static let sidePanel: CGFloat = 300
    /// Today's right-hand column (Next up, tasks, Top 3).
    static let todaySide: CGFloat = 340
    /// Time column on a timeline ("08:55").
    static let timeColumn: CGFloat = 44
    /// Subject colour bar beside a class.
    static let subjectBar: CGFloat = 4
    /// Small dot (subject colour in a list).
    static let dot: CGFloat = 8
    /// The "now" line on a timeline.
    static let nowLine: CGFloat = 1.5
    /// Narrowest card in a grid of cards (assessments due).
    static let cardMinWidth: CGFloat = 200
}

enum Typo {
    static let pageTitle = Font.title2.weight(.semibold)
    static let sectionTitle = Font.headline
    static let body = Font.body
    static let secondary = Font.callout
    static let caption = Font.caption
    static let mono = Font.body.monospaced()
    static let number = Font.body.monospacedDigit()
}

/// Semantic colours. System colours so light and dark mode work for free.
enum Palette {
    static let text = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color.accentColor
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let selection = Color(nsColor: .selectedContentBackgroundColor)
    static let danger = Color.red
    static let warning = Color.orange
    static let success = Color.green
    /// Priority 1–3 (PRD §9 `pri::`).
    static func priority(_ level: Int) -> Color {
        switch level {
        case 1: .red
        case 2: .orange
        case 3: .blue
        default: .secondary
        }
    }
    /// Fallback subject colour when SEQTA gives none.
    static let subjectFallback = Color.gray
    /// A subject's colour from SEQTA (`#rrggbb`), or the fallback.
    static func subject(_ hex: String?) -> Color {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return subjectFallback }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return subjectFallback }
        return Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }
    /// Light tint behind a highlighted row (the class happening now).
    static let highlightOpacity = 0.10
    /// How much a finished class fades.
    static let pastOpacity = 0.55
}

enum Motion {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.25)
}

