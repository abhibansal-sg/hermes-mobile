import Foundation

/// Builds the `URLRequest`s that talk to the hermes gateway.
///
/// Builds stock-gateway REST and WebSocket requests. Like Desktop, remote
/// requests keep the URL's real Host; explicit loopback URLs stay loopback.
enum WSURLBuilder {
    /// Canonical Host header for explicit loopback URLs.
    static let loopbackHost = "127.0.0.1"
    /// Header the gateway reads the session token from on REST requests.
    static let sessionTokenHeader = "X-Hermes-Session-Token"

    /// Build the WebSocket upgrade request for `{base}/api/ws?token={token}`.
    ///
    /// The scheme follows `baseURL` (http→ws, https→wss). The token is supplied
    /// as a query item (URL-encoded) and the `Host` header is overridden only
    /// when the target itself is loopback (see ``effectiveHost(for:)``).
    static func wsRequest(
        baseURL: URL,
        token: String
    ) -> URLRequest {
        authenticatedWSRequest(
            baseURL: baseURL,
            queryName: "token",
            credential: token
        )
    }

    /// Build Desktop's gated-gateway WebSocket request. `ticket` is short-lived
    /// and single-use; the caller must mint a new one before every invocation.
    static func wsTicketRequest(
        baseURL: URL,
        ticket: String
    ) -> URLRequest {
        authenticatedWSRequest(
            baseURL: baseURL,
            queryName: "ticket",
            credential: ticket
        )
    }

    private static func authenticatedWSRequest(
        baseURL: URL,
        queryName: String,
        credential: String
    ) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = webSocketScheme(for: baseURL.scheme)
        components.path = joinedPath(base: baseURL.path, suffix: "/api/ws")
        components.queryItems = [URLQueryItem(name: queryName, value: credential)]

        // Fall back to a string-built URL if components somehow can't resolve;
        // in practice `components.url` is always non-nil for a valid base.
        let url = components.url ?? baseURL
        var request = URLRequest(url: url)
        if let host = effectiveHost(for: baseURL) {
            request.setValue(host, forHTTPHeaderField: "Host")
        }
        return request
    }

    /// Build a REST request for `{base}{path}` with the `Host` override (when
    /// applicable) and the session-token header set. `path` should begin with `/`
    /// (e.g. `/api/status`).
    static func restRequest(
        baseURL: URL,
        path: String,
        token: String
    ) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.path = joinedPath(base: baseURL.path, suffix: path)

        let url = components.url ?? baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        if let host = effectiveHost(for: baseURL) {
            request.setValue(host, forHTTPHeaderField: "Host")
        }
        request.setValue(token, forHTTPHeaderField: sessionTokenHeader)
        return request
    }

    // MARK: - Host-header derivation

    /// Override only an explicit loopback URL. Remote and cloud URLs preserve
    /// the host the user entered, matching the stock Desktop client.
    static func effectiveHost(for baseURL: URL) -> String? {
        if isLoopback(baseURL.host) {
            return loopbackHost
        }
        return nil
    }

    /// `true` when `host` resolves to the local loopback interface.
    static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        let lower = host.lowercased()
        return lower == "127.0.0.1" || lower == "localhost" || lower == "::1"
    }

    // MARK: - Helpers

    /// Map an HTTP(S) scheme to its WebSocket equivalent (defaulting to `ws`).
    private static func webSocketScheme(for httpScheme: String?) -> String {
        switch httpScheme?.lowercased() {
        case "https", "wss": return "wss"
        default: return "ws"
        }
    }

    /// Concatenate a base path and a suffix without producing a double slash or
    /// dropping the separator.
    private static func joinedPath(base: String, suffix: String) -> String {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let normalizedSuffix = suffix.hasPrefix("/") ? suffix : "/" + suffix
        return trimmedBase + normalizedSuffix
    }
}
