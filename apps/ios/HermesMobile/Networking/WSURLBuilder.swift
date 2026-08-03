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

    // MARK: - Manual-token pair host safety (Inc-4 hardening)

    /// `true` when `host` is a private/local address safe to trust as a
    /// manual-token pair target (loopback, RFC1918, IPv6 ULA, link-local,
    /// `.local`/`.internal` mDNS names, or a bare hostname with no dots).
    ///
    /// A `manual_token=true` pair payload is produced by the LOCAL-desktop
    /// plugin when the gateway runs on the same LAN as the iOS device. Pairing
    /// with a public internet host via manual token would be unsafe: the URL
    /// came from a QR/deep-link without TLS verification, so a MITM could
    /// substitute any host and harvest the pasted token. The check is a
    /// defence-in-depth guard — the token is already short-lived — but it
    /// prevents the most obvious abuse vector.
    ///
    /// Range summary:
    ///   Loopback IPv4 : 127.0.0.0/8
    ///   Private IPv4  : 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    ///   Link-local IPv4: 169.254.0.0/16
    ///   Loopback IPv6 : ::1
    ///   ULA IPv6      : fc00::/7 (fc00:: – fdff::)
    ///   Link-local IPv6: fe80::/10
    ///   mDNS hostname : *.local, *.internal
    ///   Bare hostname : no dots (e.g. "mydesktop") — must be a LAN host
    ///
    /// Returns `false` for `nil` (safe default → reject).
    static func isPrivateOrLocalHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let lower = host.lowercased()

        // Loopback / localhost aliases.
        if isLoopback(host) { return true }

        // mDNS / well-known local domain names (case-insensitive suffix check).
        if lower.hasSuffix(".local") || lower.hasSuffix(".internal") {
            return true
        }

        // Tailscale MagicDNS hostnames (<host>.<tailnet>.ts.net). Lane 4a
        // (Inc-4 plugin) prefers a stable `.ts.net` address when the gateway
        // node is on a tailnet — this is the PRIMARY stable-address path for
        // manual_token pairs from a Tailscale-connected desktop. The address
        // is only reachable by enrolled tailnet members (Tailscale enforces
        // ACLs), so it is safe to treat as a trusted local target.
        if lower.hasSuffix(".ts.net") {
            return true
        }

        // Bare hostname — no dots → could be a local network name resolution
        // (e.g. "homeserver", "raspberrypi"). However, a dotless string that is
        // ALL-DIGITS or `0x`-prefixed ALL-HEX is an integer/hex IP literal that
        // the OS resolves to a public address (e.g. `134744072` → 8.8.8.8,
        // `0x08080808` → 8.8.8.8). REJECT those; accept only names that contain
        // at least one character that cannot appear in an integer/hex literal
        // (i.e. a letter other than a-f/A-F in hex, or any non-digit/non-hex char).
        if !lower.contains(".") && !lower.contains(":") {
            let looksLikeIntegerIP = lower.allSatisfy({ $0.isNumber })
            let looksLikeHexIP = (lower.hasPrefix("0x") || lower.hasPrefix("0X"))
                && lower.dropFirst(2).allSatisfy({ $0.isHexDigit })
                && lower.count > 2
            guard !looksLikeIntegerIP && !looksLikeHexIP else { return false }
            return true
        }

        // IPv6: strip URL brackets (e.g. "[::1]" → "::1") so all subsequent
        // IPv6 checks operate on the bare address.
        let strippedIPv6 = lower.hasPrefix("[") && lower.hasSuffix("]")
            ? String(lower.dropFirst().dropLast())
            : lower

        // Re-check loopback on the stripped form to catch "[::1]".
        if isLoopback(strippedIPv6) { return true }

        // IPv6 ULA (fc00::/7) — first byte fc or fd.
        if strippedIPv6.hasPrefix("fc") || strippedIPv6.hasPrefix("fd") {
            return true
        }
        // IPv6 link-local (fe80::/10) — first 10 bits = 1111 1110 10.
        if strippedIPv6.hasPrefix("fe8") || strippedIPv6.hasPrefix("fe9")
            || strippedIPv6.hasPrefix("fea") || strippedIPv6.hasPrefix("feb") {
            return true
        }

        // IPv4 octet parsing — split on "." and check ranges.
        // SAFETY: use `split` count == 4 BEFORE `compactMap` so a host like
        // "192.168.1.1.evil.com" (6 components) is rejected outright rather
        // than silently dropping the non-numeric labels and mis-classifying the
        // numeric prefix as a private address. Both conditions must hold: the
        // raw split produces exactly 4 components AND every component is numeric.
        let rawComponents = lower.split(separator: ".", omittingEmptySubsequences: false)
        let octets = rawComponents.compactMap { Int($0) }
        guard rawComponents.count == 4,
              octets.count == 4,
              octets.allSatisfy({ $0 >= 0 && $0 <= 255 })
        else { return false }  // not a bare IPv4 quad → reject

        let o0 = octets[0], o1 = octets[1]
        // Loopback 127.0.0.0/8 (already caught above for 127.0.0.1, but covers
        // the full /8 for completeness — 127.x.y.z is always loopback).
        if o0 == 127 { return true }
        // RFC1918 10.0.0.0/8
        if o0 == 10 { return true }
        // RFC1918 172.16.0.0/12 (172.16–172.31)
        if o0 == 172 && o1 >= 16 && o1 <= 31 { return true }
        // RFC1918 192.168.0.0/16
        if o0 == 192 && o1 == 168 { return true }
        // Link-local 169.254.0.0/16
        if o0 == 169 && o1 == 254 { return true }

        return false
    }

    /// `true` when `urlString` resolves to a host that is safe for a
    /// `manual_token` pair (loopback, RFC1918, link-local, `.local`, or a bare
    /// LAN hostname). Malformed URLs return `false` (reject by default).
    ///
    /// Call this before accepting a user-supplied token for a `manual_token`
    /// pair payload: a public host in that context is almost certainly wrong
    /// (the plugin only discovers LAN/loopback targets) and could expose the
    /// pasted token to a non-local server.
    static func isSafeForManualTokenPair(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        // `host(percentEncoded: false)` strips brackets from IPv6 literals and
        // percent-decodes IDNs; available on iOS 16+ (our deployment target is 17).
        return isPrivateOrLocalHost(url.host(percentEncoded: false))
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
