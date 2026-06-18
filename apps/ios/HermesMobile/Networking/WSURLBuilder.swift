import Foundation

/// Builds the `URLRequest`s that talk to the hermes gateway.
///
/// Two transports share the same host: the WebSocket upgrade (JSON-RPC stream)
/// and the REST API. Both must override the `Host` header to `127.0.0.1` — the
/// server validates `Host` against its loopback bind, and a fronting proxy
/// (e.g. Tailscale Serve) would otherwise leak the public hostname and be
/// rejected. REST additionally carries the session token in a custom header.
///
/// **Inc 2 — Host-header derivation:**
/// The `Host` override is mode-aware. For `.sharedDashboard` and `.localDesktop`
/// modes (and any loopback target) the header stays pinned to `127.0.0.1`,
/// preserving the Tailscale Serve→loopback contract. For `.remoteURL` pointing
/// at a non-loopback host (e.g. a `0.0.0.0`-bound gateway on a LAN/remote
/// machine) the override is omitted — URLSession then sends the real host from
/// the URL, which the gateway accepts on its `0.0.0.0` bind.
enum WSURLBuilder {
    /// Loopback host the gateway expects in the `Host` header when
    /// Tailscale Serve is in the path.
    static let loopbackHost = "127.0.0.1"
    /// Header the gateway reads the session token from on REST requests.
    static let sessionTokenHeader = "X-Hermes-Session-Token"

    /// Build the WebSocket upgrade request for `{base}/api/ws?token={token}`.
    ///
    /// The scheme follows `baseURL` (http→ws, https→wss). The token is supplied
    /// as a query item (URL-encoded) and the `Host` header is overridden only
    /// when the target is a loopback/Serve path (see ``effectiveHost(for:mode:)``).
    static func wsRequest(
        baseURL: URL,
        token: String,
        mode: ConnectionMode = .remoteURL
    ) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.scheme = webSocketScheme(for: baseURL.scheme)
        components.path = joinedPath(base: baseURL.path, suffix: "/api/ws")
        components.queryItems = [URLQueryItem(name: "token", value: token)]

        // Fall back to a string-built URL if components somehow can't resolve;
        // in practice `components.url` is always non-nil for a valid base.
        let url = components.url ?? baseURL
        var request = URLRequest(url: url)
        if let host = effectiveHost(for: baseURL, mode: mode) {
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
        token: String,
        mode: ConnectionMode = .remoteURL
    ) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.path = joinedPath(base: baseURL.path, suffix: path)

        let url = components.url ?? baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        if let host = effectiveHost(for: baseURL, mode: mode) {
            request.setValue(host, forHTTPHeaderField: "Host")
        }
        request.setValue(token, forHTTPHeaderField: sessionTokenHeader)
        return request
    }

    // MARK: - Host-header derivation (Inc 2)

    /// Return the `Host` header value to use for `baseURL` under `mode`, or `nil`
    /// to omit the override (URLSession then sends the URL's own host).
    ///
    /// Rules:
    /// - `.sharedDashboard`: always loopback (Tailscale Serve fronts it).
    /// - `.localDesktop`: always loopback (same Serve path in Inc 1/2; Inc 3
    ///   re-routes to the real LAN address but that is a future extension).
    /// - `.remoteURL` with a loopback target (`127.0.0.1` or `localhost`): pin
    ///   loopback — the user pointed us at a local Serve endpoint.
    /// - `.remoteURL` with a non-loopback target: return `nil` — URLSession uses
    ///   the real host, which the `0.0.0.0`-bound remote gateway accepts.
    static func effectiveHost(for baseURL: URL, mode: ConnectionMode) -> String? {
        switch mode {
        case .sharedDashboard, .localDesktop:
            return loopbackHost
        case .remoteURL:
            return isLoopback(baseURL.host) ? loopbackHost : nil
        }
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
