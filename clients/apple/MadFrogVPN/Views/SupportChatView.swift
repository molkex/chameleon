import SwiftUI
import WebKit

/// SUPPORT-CHAT P2 — in-app support chat. Hosts the bundled web widget
/// (clients/widget/index.html, the same "write-once" surface that will later
/// live at chat.madfrog.online) inside a WKWebView.
///
/// The widget is loaded as an HTML *string* with `baseURL` = the API origin, so
/// its fetch()/EventSource calls to /api/v1/mobile/support/* are SAME-ORIGIN —
/// no CORS, no need to allowlist a file:// / null origin on the backend. After
/// the page loads, `window.initChat({...})` injects the user's access token,
/// the current theme (neon/calm), and the UI language.
struct SupportChatView: View {
    @Environment(AppState.self) private var app
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    // nil = still fetching a fresh access token. The webview can't refresh on
    // its own, so we hand it a guaranteed-fresh token (else a token that
    // expired while backgrounded 401s the chat into a confusing "нет связи").
    @State private var token: String?

    var body: some View {
        NavigationStack {
            Group {
                if let token {
                    SupportChatWebView(
                        accessToken: token,
                        theme: themeManager.current.id, // "neon" | "calm"
                        lang: Locale.current.language.languageCode?.identifier == "ru" ? "ru" : "en"
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(Text(L10n.Settings.contactSupport))
            .iosInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .task { token = await app.accessTokenForSupportChat() }
    }
}

// MARK: - WKWebView host (platform-specific shell, shared loader/coordinator)

/// Builds + configures the WKWebView and kicks off the widget load. Shared by
/// the iOS (UIViewRepresentable) and macOS (NSViewRepresentable) shells below.
private func makeSupportWebView(coordinator: SupportChatCoordinator) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent() // chat creds live in-memory only
    let wv = WKWebView(frame: .zero, configuration: config)
    wv.navigationDelegate = coordinator
    #if os(iOS)
    wv.isOpaque = false
    wv.backgroundColor = .clear
    wv.scrollView.backgroundColor = .clear
    #endif

    guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
          let html = try? String(contentsOf: url, encoding: .utf8) else {
        wv.loadHTMLString("<body style='background:#05140d;color:#eafff0;font-family:-apple-system'>Чат временно недоступен.</body>", baseURL: nil)
        return wv
    }
    // baseURL = API origin → the widget's /api/... fetch + SSE are same-origin.
    wv.loadHTMLString(html, baseURL: URL(string: AppConstants.baseURL))
    return wv
}

/// Navigation delegate: once the widget DOM is ready, inject the auth/theme/lang
/// bridge. The access token is a JWT (URL-safe base64 — no quote chars), so the
/// single-quoted interpolation below is safe.
final class SupportChatCoordinator: NSObject, WKNavigationDelegate {
    let accessToken: String
    let theme: String
    let lang: String

    init(accessToken: String, theme: String, lang: String) {
        self.accessToken = accessToken
        self.theme = theme
        self.lang = lang
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        let js = """
        window.initChat({apiBase:'', accessToken:'\(accessToken)', theme:'\(theme)', lang:'\(lang)'});
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

#if os(iOS)
private struct SupportChatWebView: UIViewRepresentable {
    let accessToken: String
    let theme: String
    let lang: String

    func makeCoordinator() -> SupportChatCoordinator {
        SupportChatCoordinator(accessToken: accessToken, theme: theme, lang: lang)
    }
    func makeUIView(context: Context) -> WKWebView { makeSupportWebView(coordinator: context.coordinator) }
    func updateUIView(_: WKWebView, context _: Context) {}
}
#elseif os(macOS)
private struct SupportChatWebView: NSViewRepresentable {
    let accessToken: String
    let theme: String
    let lang: String

    func makeCoordinator() -> SupportChatCoordinator {
        SupportChatCoordinator(accessToken: accessToken, theme: theme, lang: lang)
    }
    func makeNSView(context: Context) -> WKWebView { makeSupportWebView(coordinator: context.coordinator) }
    func updateNSView(_: WKWebView, context _: Context) {}
}
#endif
