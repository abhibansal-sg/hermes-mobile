import Foundation

/// Builds the `URLRequest`s that talk to the hermes gateway.
///
/// Two transports share the same host: the WebSocket upgrade (JSON-RPC stream)
/// and the REST API. Both must override the `Host` header to `127.0.0.1` — the
/// server validates `Host` against its loopback bind, and a fronting proxy
/// (e.g. Tailscale Serve) would otherwise leak the public hostname and be
/// rejected. REST additionally carries the session token in a custom header.
enum WSURLBuilder {
    /// Loopback host the gateway expects in the `Host` header.
    static let loopbackHost = "127.0.0.1"
    /// Header the gateway reads the session token from on REST requests.
    static let sessionTokenHeader = "X-Hermes-Session-Token"

    /// Build the WebSocket upgrade request for `{base}/api/ws?token={token}`.
    ///
    /// The scheme follows `baseURL` (http→ws, https→wss). The token is supplied
    /// as a query item (URL-encoded) and the `Host` header is overridden.
    static func wsRequest(baseURL: URL, token: String) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = webSocketScheme(for: baseURL.scheme)
        components.path = joinedPath(base: baseURL.path, suffix: "/api/ws")
        components.queryItems = [URLQueryItem(name: "token", value: token)]

        // Fall back to a string-built URL if components somehow can't resolve;
        // in practice `components.url` is always non-nil for a valid base.
        let url = components.url ?? baseURL
        var request = URLRequest(url: url)
        request.setValue(loopbackHost, forHTTPHeaderField: "Host")
        return request
    }

    /// Build a REST request for `{base}{path}` with the `Host` override and the
    /// session-token header set. `path` should begin with `/` (e.g. `/api/status`).
    static func restRequest(baseURL: URL, path: String, token: String) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.path = joinedPath(base: baseURL.path, suffix: path)

        let url = components.url ?? baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue(loopbackHost, forHTTPHeaderField: "Host")
        request.setValue(token, forHTTPHeaderField: sessionTokenHeader)
        return request
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
