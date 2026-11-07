import Foundation

/// Rules for SEQTA addresses and which links stay inside the app.
public enum SeqtaLinks {
    /// Sign-in and BetterSEQTA+ hosts that must stay in the app so login and the extension work.
    public static let inAppHosts = [
        "microsoftonline.com", "microsoft.com", "live.com", "msauth.net", "msftauth.net",
        "betterseqta.org",
    ]

    /// Turns what the user typed ("learn.school.edu.au", "https://…/") into a SEQTA home URL.
    /// Returns nil unless it's an http(s) address with a host.
    public static func homeURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, host.contains(".") else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }

    /// Whether a link should open inside the SEQTA page (true) or in the default browser.
    public static func opensInApp(_ url: URL, seqtaHost: String?) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        if let seqtaHost, host == seqtaHost.lowercased() { return true }
        return inAppHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Schemes the web view handles itself; anything else (mailto:, msteams:) goes to macOS.
    public static func isWebScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return true }
        return ["http", "https", "about", "blob", "data", "webkit-extension"].contains(scheme)
    }
}
