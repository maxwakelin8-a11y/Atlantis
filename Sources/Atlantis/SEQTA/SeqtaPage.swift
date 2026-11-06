import AtlantisCore
import SwiftUI
import WebKit

/// The SEQTA page: SEQTA Learn with BetterSEQTA+, or a prompt for the school's address.
struct SeqtaPage: View {
    let seqta: SeqtaController
    @State private var hasAddress = AppSettings.seqtaURL != nil

    var body: some View {
        if hasAddress {
            WebViewHost(webView: seqta.webView)
                .overlay {
                    if seqta.phase != .ready { ProgressView().controlSize(.small) }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let problem = seqta.extensionProblem {
                        NoticeBar(text: problem) { seqta.dismissExtensionProblem() }
                    }
                }
                .onAppear { seqta.start() }
        } else {
            ContentUnavailableView {
                Label("Connect SEQTA", systemImage: "graduationcap")
            } description: {
                Text("Enter your school's SEQTA Learn address. It's saved on this Mac only.")
            } actions: {
                SeqtaAddressField { _ in
                    hasAddress = true
                    seqta.start()
                }
                .frame(maxWidth: 360)
            }
        }
    }
}

/// A one-line warning above a page, with a close button.
struct NoticeBar: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.callout)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding()
        .background(.bar)
    }
}

/// Text field + Save button for the SEQTA address. Calls `onSave` with a checked URL.
struct SeqtaAddressField: View {
    var onSave: (URL) -> Void
    @State private var text = AppSettings.seqtaURL?.absoluteString ?? ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("SEQTA address", text: $text, prompt: Text("learn.yourschool.edu.au"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if invalid {
                Text("That doesn't look like a web address.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func save() {
        guard let url = SeqtaLinks.homeURL(from: text) else { invalid = true; return }
        invalid = false
        text = url.absoluteString
        AppSettings.seqtaURL = url
        onSave(url)
    }
}

/// Puts an existing WKWebView into SwiftUI. The same web view is reused every time.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
