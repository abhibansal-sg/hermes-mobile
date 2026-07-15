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
