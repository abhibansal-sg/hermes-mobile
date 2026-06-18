import XCTest
@testable import HermesMobile

/// Unit tests for ``WSURLBuilder`` — Inc 2 Host-header derivation.
///
/// Spec (CONTRACT-CONNECTION-MODES.md §Inc2):
///   - Non-loopback `.remoteURL` target → NO Host override (URLSession sends the
///     real host so the `0.0.0.0`-bound gateway accepts it).
///   - Loopback target or `.sharedDashboard`/`.localDesktop` mode → Host pinned
///     to `127.0.0.1` (the Tailscale-Serve→loopback contract, unchanged).
///   - Regression: the Serve/loopback path must STILL pin loopback after Inc 2.
final class WSURLBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func wsRequest(
        urlString: String,
        mode: ConnectionMode
    ) -> URLRequest {
        let url = URL(string: urlString)!
        return WSURLBuilder.wsRequest(baseURL: url, token: "test-token", mode: mode)
    }

    private func restRequest(
        urlString: String,
        mode: ConnectionMode
    ) -> URLRequest {
        let url = URL(string: urlString)!
        return WSURLBuilder.restRequest(baseURL: url, path: "/api/status", token: "test-token", mode: mode)
    }

    // MARK: - effectiveHost

    func testEffectiveHost_sharedDashboard_alwaysLoopback() {
        let nonLoopback = URL(string: "http://192.168.1.100:9123")!
        let host = WSURLBuilder.effectiveHost(for: nonLoopback, mode: .sharedDashboard)
        XCTAssertEqual(
            host, "127.0.0.1",
            ".sharedDashboard must always pin loopback regardless of the target IP"
        )
    }

    func testEffectiveHost_localDesktop_alwaysLoopback() {
        let nonLoopback = URL(string: "http://10.0.0.5:9123")!
        let host = WSURLBuilder.effectiveHost(for: nonLoopback, mode: .localDesktop)
        XCTAssertEqual(
            host, "127.0.0.1",
            ".localDesktop must always pin loopback (Tailscale-Serve path in Inc 1/2)"
        )
    }

    func testEffectiveHost_remoteURL_loopbackTarget_pinsLoopback() {
        let loopback = URL(string: "http://127.0.0.1:9123")!
        let host = WSURLBuilder.effectiveHost(for: loopback, mode: .remoteURL)
        XCTAssertEqual(
            host, "127.0.0.1",
            ".remoteURL pointing at 127.0.0.1 must still pin loopback (local Serve target)"
        )
    }

    func testEffectiveHost_remoteURL_localhostTarget_pinsLoopback() {
        let local = URL(string: "http://localhost:9123")!
        let host = WSURLBuilder.effectiveHost(for: local, mode: .remoteURL)
        XCTAssertEqual(
            host, "127.0.0.1",
            ".remoteURL pointing at localhost must still pin loopback"
        )
    }

    func testEffectiveHost_remoteURL_nonLoopbackIP_omitsOverride() {
        let remote = URL(string: "http://192.168.1.42:9123")!
        let host = WSURLBuilder.effectiveHost(for: remote, mode: .remoteURL)
        XCTAssertNil(
            host,
            ".remoteURL with non-loopback IP must return nil (no Host override — real host sent)"
        )
    }

    func testEffectiveHost_remoteURL_hostnameTarget_omitsOverride() {
        let remote = URL(string: "http://mymac.local:9123")!
        let host = WSURLBuilder.effectiveHost(for: remote, mode: .remoteURL)
        XCTAssertNil(
            host,
            ".remoteURL with a hostname target must return nil (real host sent to gateway)"
        )
    }

    // MARK: - wsRequest Host header

    func testWsRequest_sharedDashboard_nonLoopback_hasLoopbackHost() {
        let req = wsRequest(urlString: "http://192.168.1.42:9123", mode: .sharedDashboard)
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "WS request in .sharedDashboard mode must carry loopback Host"
        )
    }

    func testWsRequest_remoteURL_nonLoopback_hasRealHost() {
        // The REAL host for the non-loopback case: no override → URLRequest
        // carries no explicit Host, meaning the system sends the URL's own host.
        let req = wsRequest(urlString: "http://192.168.1.42:9123", mode: .remoteURL)
        let overriddenHost = req.value(forHTTPHeaderField: "Host")
        // We assert it is NOT 127.0.0.1 — either nil or the real host is fine.
        XCTAssertNotEqual(
            overriddenHost, "127.0.0.1",
            "WS request in .remoteURL mode for a non-loopback target must NOT pin loopback"
        )
    }

    func testWsRequest_remoteURL_loopbackTarget_hasLoopbackHost() {
        // Regression: a remoteURL pointing at 127.0.0.1 (local Serve) must still pin loopback.
        let req = wsRequest(urlString: "http://127.0.0.1:9123", mode: .remoteURL)
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "WS request in .remoteURL mode for 127.0.0.1 must still pin loopback Host"
        )
    }

    // MARK: - restRequest Host header

    func testRestRequest_sharedDashboard_nonLoopback_hasLoopbackHost() {
        let req = restRequest(urlString: "http://192.168.1.42:9123", mode: .sharedDashboard)
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "REST request in .sharedDashboard mode must carry loopback Host"
        )
    }

    func testRestRequest_remoteURL_nonLoopback_omitsLoopbackHost() {
        let req = restRequest(urlString: "http://192.168.1.42:9123", mode: .remoteURL)
        XCTAssertNotEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "REST request in .remoteURL mode for non-loopback must NOT pin loopback"
        )
    }

    // MARK: - isLoopback helper

    func testIsLoopback_positives() {
        XCTAssertTrue(WSURLBuilder.isLoopback("127.0.0.1"))
        XCTAssertTrue(WSURLBuilder.isLoopback("localhost"))
        XCTAssertTrue(WSURLBuilder.isLoopback("LOCALHOST"))
        XCTAssertTrue(WSURLBuilder.isLoopback("::1"))
    }

    func testIsLoopback_negatives() {
        XCTAssertFalse(WSURLBuilder.isLoopback(nil))
        XCTAssertFalse(WSURLBuilder.isLoopback("192.168.1.1"))
        XCTAssertFalse(WSURLBuilder.isLoopback("10.0.0.1"))
        XCTAssertFalse(WSURLBuilder.isLoopback("mymac.local"))
    }

    // MARK: - WS scheme derivation (unchanged from pre-Inc2)

    func testWsRequest_usesWsSchemeForHttp() {
        let req = wsRequest(urlString: "http://127.0.0.1:9123", mode: .remoteURL)
        XCTAssertTrue(
            req.url?.scheme == "ws",
            "HTTP base URL must produce a ws:// WebSocket URL"
        )
    }

    func testWsRequest_usesWssSchemeForHttps() {
        let req = wsRequest(urlString: "https://myserver.example.com", mode: .remoteURL)
        XCTAssertTrue(
            req.url?.scheme == "wss",
            "HTTPS base URL must produce a wss:// WebSocket URL"
        )
    }

    // MARK: - Regression: Serve/loopback path still pins loopback

    func testRegression_serveLoopbackPath_stillPinsLoopback_ws() {
        // This is the EXISTING shared-dashboard flow: a Tailscale-Serve URL
        // resolving to localhost. Must still pin loopback after Inc 2.
        let req = wsRequest(urlString: "http://127.0.0.1:8080", mode: .sharedDashboard)
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "REGRESSION: shared-dashboard WS request must pin loopback Host"
        )
    }

    func testRegression_serveLoopbackPath_stillPinsLoopback_rest() {
        let req = restRequest(urlString: "http://127.0.0.1:8080", mode: .sharedDashboard)
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "REGRESSION: shared-dashboard REST request must pin loopback Host"
        )
    }

    // MARK: - isPrivateOrLocalHost (Inc-4 hardening)
    //
    // Table-driven: every accept/reject class has at least one representative.
    // The function is pure so these are synchronous and always run (no skip guards).

    func testPrivateHost_loopbackIPv4_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("127.0.0.1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("127.0.0.2"))   // full /8
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("127.255.255.255"))
    }

    func testPrivateHost_localhost_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("localhost"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("LOCALHOST"))
    }

    func testPrivateHost_loopbackIPv6_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("::1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("[::1]"))        // URL bracket form
    }

    func testPrivateHost_rfc1918_10slash8_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("10.0.0.1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("10.255.255.255"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("10.1.2.3"))
    }

    func testPrivateHost_rfc1918_172_16slash12_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("172.16.0.1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("172.20.0.1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("172.31.255.255"))
    }

    func testPrivateHost_rfc1918_192_168_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("192.168.0.1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("192.168.1.42"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("192.168.255.255"))
    }

    func testPrivateHost_linkLocal_169_254_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("169.254.0.1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("169.254.1.100"))
    }

    func testPrivateHost_dotLocal_mDNS_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("mymac.local"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("MYMAC.LOCAL"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("raspberrypi.local"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("gateway.internal"))
    }

    func testPrivateHost_bareHostname_noDots_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("mymac"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("desktop"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("hermes-box"))
    }

    func testPrivateHost_ipv6ULA_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("fd00::1"))    // ULA fd
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("fc80::1"))    // ULA fc
    }

    func testPrivateHost_ipv6LinkLocal_accepted() {
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("fe80::1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("[fe80::1]"))   // URL bracket form
    }

    // MARK: - isPrivateOrLocalHost — rejected (public)

    func testPrivateHost_publicIPv4_rejected() {
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("8.8.8.8"))
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("1.1.1.1"))
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("203.0.113.1"))  // TEST-NET-3
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("172.32.0.1"))   // just outside 172.16/12
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("172.15.255.255")) // just below 172.16/12
    }

    func testPrivateHost_publicHostname_rejected() {
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("myserver.example.com"))
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("api.openai.com"))
    }

    func testPrivateHost_tailscaleMagicDNS_accepted() {
        // Lane 4a (Inc-4 plugin) makes the gateway prefer a MagicDNS hostname
        // (<host>.<tailnet>.ts.net) as the stable pair address. .ts.net hosts
        // are only reachable by enrolled tailnet members (ACL-enforced), so
        // they are trusted targets for manual_token pairing.
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("mymac.tailnet.ts.net"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("mydesktop.example-corp.ts.net"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("GATEWAY.MYNET.TS.NET")) // case-insensitive
    }

    func testPrivateHost_malformedOrNil_rejected() {
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost(nil))
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost(""))
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("not an ip at all .com.example"))
    }

    // MARK: - Bypass regressions (Opus security review must-fix)

    func testPrivateHost_integerIPLiteral_rejected() {
        // BYPASS-1: dotless all-digit strings are integer IP literals that the OS
        // resolves to public addresses — must NOT be classified as LAN hostnames.
        // 134744072 == 8.8.8.8, 16843009 == 1.1.1.1 (big-endian 32-bit).
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("134744072"),
                       "integer form of 8.8.8.8 must be rejected")
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("16843009"),
                       "integer form of 1.1.1.1 must be rejected")
    }

    func testPrivateHost_hexIPLiteral_rejected() {
        // BYPASS-1 (hex variant): 0x-prefixed all-hex dotless strings are hex IP
        // literals (e.g. 0x08080808 == 8.8.8.8).
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("0x08080808"),
                       "hex form of 8.8.8.8 must be rejected")
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("0X08080808"),
                       "uppercase 0X hex form must also be rejected")
    }

    func testPrivateHost_alphaLANHostname_stillAccepted() {
        // BYPASS-1 regression guard: real LAN hostnames (non-digit chars) must
        // still pass through — the fix must not break the legitimate case.
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("homeserver"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("raspberrypi"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("hermes-box"))
    }

    func testPrivateHost_trailingLabelIPv4_rejected() {
        // BYPASS-2: "192.168.1.1.evil.com" was previously mis-classified as
        // private because compactMap silently dropped "evil"/"com" and left
        // [192,168,1,1]. Now the raw split count must also be exactly 4.
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("192.168.1.1.evil.com"),
                       "trailing-label IPv4 disguise must be rejected")
        XCTAssertFalse(WSURLBuilder.isPrivateOrLocalHost("10.0.0.1.attacker.com"),
                       "trailing-label IPv4 disguise (10/8) must be rejected")
        // Regression guard: plain private IPv4 quads must still accept.
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("192.168.1.1"))
        XCTAssertTrue(WSURLBuilder.isPrivateOrLocalHost("10.0.0.1"))
    }

    // MARK: - isSafeForManualTokenPair (end-to-end via URL string)

    func testSafeForManualTokenPair_privateURLs_accepted() {
        XCTAssertTrue(WSURLBuilder.isSafeForManualTokenPair("http://127.0.0.1:9123"))
        XCTAssertTrue(WSURLBuilder.isSafeForManualTokenPair("http://192.168.1.42:9119"))
        XCTAssertTrue(WSURLBuilder.isSafeForManualTokenPair("http://10.0.0.5:9119"))
        XCTAssertTrue(WSURLBuilder.isSafeForManualTokenPair("http://mymac.local:9119"))
        XCTAssertTrue(WSURLBuilder.isSafeForManualTokenPair("http://localhost:9123"))
        // Tailscale MagicDNS — the stable-address path from lane 4a.
        XCTAssertTrue(WSURLBuilder.isSafeForManualTokenPair("http://mymac.tailnet.ts.net:9119"))
    }

    func testSafeForManualTokenPair_publicURLs_rejected() {
        XCTAssertFalse(WSURLBuilder.isSafeForManualTokenPair("http://8.8.8.8:9119"))
        XCTAssertFalse(WSURLBuilder.isSafeForManualTokenPair("http://myserver.example.com:9119"))
        XCTAssertFalse(WSURLBuilder.isSafeForManualTokenPair("https://api.openai.com/gateway"))
        // Bypass-1 end-to-end: integer + hex IP literals via full URL.
        XCTAssertFalse(WSURLBuilder.isSafeForManualTokenPair("http://134744072:9119"),
                       "integer-IP URL for 8.8.8.8 must be rejected")
        XCTAssertFalse(WSURLBuilder.isSafeForManualTokenPair("http://16843009:9119"),
                       "integer-IP URL for 1.1.1.1 must be rejected")
    }

    func testSafeForManualTokenPair_malformedURL_rejected() {
        XCTAssertFalse(WSURLBuilder.isSafeForManualTokenPair("not a url"))
        XCTAssertFalse(WSURLBuilder.isSafeForManualTokenPair(""))
    }
}
