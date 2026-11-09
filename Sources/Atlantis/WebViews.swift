import AtlantisCore
import WebKit

/// Every web view in the app is made here, so network access is a deliberate choice
/// (PRD §17: web views are blocked from the network by default).
@MainActor
enum WebViews {
    enum Network {
        /// No http(s) or websocket requests at all. The default (Docs editor, previews).
        case none
        /// Only these hosts and their subdomains.
        case only([String])
        /// Unrestricted. Only for the SEQTA tab while it exists (PRD §7d).
        case open
    }

    enum Storage {
        /// In-memory: nothing is kept after the web view goes away.
        case ephemeral
        /// Kept on disk in its own store (not shared with SEQTA), e.g. the Writer's view settings.
        case persistent(UUID)
    }

    /// The Docs page's own store (its localStorage holds Writer view settings only).
    static let docsStore = UUID(uuidString: "6A7F3C2E-0D1B-4B8E-9C55-41D1A7E0D0C5")!

    private static var compiled: [String: WKContentRuleList] = [:]
    private static var all: [Weak] = []

    /// A configuration with the network rule already applied. `.none` and `.only` use their own
    /// data store (no shared cookies): in memory unless `storage` says otherwise.
    static func configuration(network: Network, storage: Storage = .ephemeral) async throws -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let own: WKWebsiteDataStore = switch storage {
        case .ephemeral: .nonPersistent()
        case .persistent(let id): WKWebsiteDataStore(forIdentifier: id)
        }
        switch network {
        case .open:
            config.websiteDataStore = .default()
        case .none:
            config.websiteDataStore = own
            config.userContentController.add(try await ruleList("atlantis.block-all", ContentRules.blockAllNetwork()))
        case .only(let hosts):
            config.websiteDataStore = own
            let json = ContentRules.allowOnly(hosts: hosts)
            let id = "atlantis.allow-\(abs(json.hashValue))"
            config.userContentController.add(try await ruleList(id, json))
        }
        return config
    }

    /// Makes a web view and tracks it for the performance HUD.
    static func make(_ config: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        webView.isInspectable = true
        #endif
        all.removeAll { $0.webView == nil }
        all.append(Weak(webView: webView))
        return webView
    }

    /// Web views holding a page right now (not blank). PRD §17 budget: the visible ones plus
    /// one warm Docs editor.
    static var liveCount: Int {
        all.removeAll { $0.webView == nil }
        return all.count { view in
            guard let url = view.webView?.url else { return false }
            return url.absoluteString != "about:blank"
        }
    }

    private static func ruleList(_ id: String, _ json: String) async throws -> WKContentRuleList {
        if let list = compiled[id] { return list }
        let store = WKContentRuleListStore.default()!
        let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)!
        compiled[id] = list
        return list
    }

    private struct Weak {
        weak var webView: WKWebView?
    }
}
