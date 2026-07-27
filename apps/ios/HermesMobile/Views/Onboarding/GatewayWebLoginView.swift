import SwiftUI
import WebKit

struct GatewayWebLoginView: View {
    enum Kind {
        case gateway(interactive: Bool)
        case portal

        var title: String {
            switch self {
            case .gateway: return "Sign in to gateway"
            case .portal: return "Sign in to Hermes Cloud"
            }
        }

        var cookieNames: Set<String> {
            switch self {
            case .gateway:
                return [
                    "hermes_session_at", "hermes_session_rt",
                    "__Host-hermes_session_at", "__Host-hermes_session_rt",
                    "__Secure-hermes_session_at", "__Secure-hermes_session_rt",
                ]
            case .portal:
                return [
                    "privy-token", "privy-session",
                    "__Host-privy-token", "__Secure-privy-token",
                ]
            }
        }
    }

    let baseURL: URL
    let kind: Kind
    let onAuthenticated: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var startURL: URL {
        switch kind {
        case .gateway(let interactive):
            return interactive
                ? baseURL.appendingPathComponent("login")
                : baseURL
        case .portal:
            return baseURL
        }
    }

    var body: some View {
        NavigationStack {
            GatewayLoginWebView(
                startURL: startURL,
                originURL: baseURL,
                acceptedCookieNames: kind.cookieNames
            ) {
                onAuthenticated()
                dismiss()
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct GatewayLoginWebView: UIViewRepresentable {
    let startURL: URL
    let originURL: URL
    let acceptedCookieNames: Set<String>
    let onAuthenticated: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            originURL: originURL,
            acceptedCookieNames: acceptedCookieNames,
            onAuthenticated: onAuthenticated
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.startPolling(webView)
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let originURL: URL
        private let acceptedCookieNames: Set<String>
        private let onAuthenticated: () -> Void
        private var timer: Timer?
        private var finished = false

        init(
            originURL: URL,
            acceptedCookieNames: Set<String>,
            onAuthenticated: @escaping () -> Void
        ) {
            self.originURL = originURL
            self.acceptedCookieNames = acceptedCookieNames
            self.onAuthenticated = onAuthenticated
        }

        func startPolling(_ webView: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) {
                [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.checkCookies(in: webView)
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkCookies(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            checkCookies(in: webView)
        }

        private func checkCookies(in webView: WKWebView) {
            guard !finished else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                [weak self] cookies in
                DispatchQueue.main.async {
                    guard let self, !self.finished else { return }
                    let matching = cookies.filter {
                        self.acceptedCookieNames.contains($0.name)
                            && self.cookie($0, matches: self.originURL)
                    }
                    guard !matching.isEmpty else { return }

                    cookies
                        .filter { self.cookie($0, matches: self.originURL) }
                        .forEach(HTTPCookieStorage.shared.setCookie)
                    self.finished = true
                    self.stopPolling()
                    self.onAuthenticated()
                }
            }
        }

        private func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            let domain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            return host == domain || host.hasSuffix(".\(domain)")
        }
    }
}
