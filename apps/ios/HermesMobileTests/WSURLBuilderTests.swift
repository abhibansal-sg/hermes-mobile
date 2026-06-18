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
}
