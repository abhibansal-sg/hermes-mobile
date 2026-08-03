import XCTest
@testable import HermesMobile

/// Stock-gateway URL and authentication request tests.
final class WSURLBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func wsRequest(urlString: String) -> URLRequest {
        let url = URL(string: urlString)!
        return WSURLBuilder.wsRequest(baseURL: url, token: "test-token")
    }

    private func restRequest(urlString: String) -> URLRequest {
        let url = URL(string: urlString)!
        return WSURLBuilder.restRequest(baseURL: url, path: "/api/status", token: "test-token")
    }

    // MARK: - effectiveHost

    func testEffectiveHost_remoteURL_loopbackTarget_pinsLoopback() {
        let loopback = URL(string: "http://127.0.0.1:9123")!
        let host = WSURLBuilder.effectiveHost(for: loopback)
        XCTAssertEqual(
            host, "127.0.0.1",
            ".remoteURL pointing at 127.0.0.1 must still pin loopback (local Serve target)"
        )
    }

    func testEffectiveHost_remoteURL_localhostTarget_pinsLoopback() {
        let local = URL(string: "http://localhost:9123")!
        let host = WSURLBuilder.effectiveHost(for: local)
        XCTAssertEqual(
            host, "127.0.0.1",
            ".remoteURL pointing at localhost must still pin loopback"
        )
    }

    func testEffectiveHost_remoteURL_nonLoopbackIP_omitsOverride() {
        let remote = URL(string: "http://192.168.1.42:9123")!
        let host = WSURLBuilder.effectiveHost(for: remote)
        XCTAssertNil(
            host,
            ".remoteURL with non-loopback IP must return nil (no Host override — real host sent)"
        )
    }

    func testEffectiveHost_remoteURL_hostnameTarget_omitsOverride() {
        let remote = URL(string: "http://mymac.local:9123")!
        let host = WSURLBuilder.effectiveHost(for: remote)
        XCTAssertNil(
            host,
            ".remoteURL with a hostname target must return nil (real host sent to gateway)"
        )
    }

    // MARK: - wsRequest Host header

    func testWsRequest_remoteURL_nonLoopback_hasRealHost() {
        // The REAL host for the non-loopback case: no override → URLRequest
        // carries no explicit Host, meaning the system sends the URL's own host.
        let req = wsRequest(urlString: "http://192.168.1.42:9123")
        let overriddenHost = req.value(forHTTPHeaderField: "Host")
        // We assert it is NOT 127.0.0.1 — either nil or the real host is fine.
        XCTAssertNotEqual(
            overriddenHost, "127.0.0.1",
            "WS request in .remoteURL mode for a non-loopback target must NOT pin loopback"
        )
    }

    func testWsRequest_remoteURL_loopbackTarget_hasLoopbackHost() {
        // Regression: a remoteURL pointing at 127.0.0.1 (local Serve) must still pin loopback.
        let req = wsRequest(urlString: "http://127.0.0.1:9123")
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "WS request in .remoteURL mode for 127.0.0.1 must still pin loopback Host"
        )
    }

    func testWsTicketRequest_usesTicketWithoutToken() {
        let request = WSURLBuilder.wsTicketRequest(
            baseURL: URL(string: "https://gateway.example")!,
            ticket: "single-use"
        )
        let items = URLComponents(
            url: request.url!,
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "ticket" })?.value, "single-use")
        XCTAssertNil(items?.first(where: { $0.name == "token" }))
        XCTAssertEqual(request.url?.path, "/api/ws")
        XCTAssertEqual(request.url?.scheme, "wss")
    }

    // MARK: - restRequest Host header

    func testRestRequest_remoteURL_nonLoopback_omitsLoopbackHost() {
        let req = restRequest(urlString: "http://192.168.1.42:9123")
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
        let req = wsRequest(urlString: "http://127.0.0.1:9123")
        XCTAssertTrue(
            req.url?.scheme == "ws",
            "HTTP base URL must produce a ws:// WebSocket URL"
        )
    }

    func testWsRequest_usesWssSchemeForHttps() {
        let req = wsRequest(urlString: "https://myserver.example.com")
        XCTAssertTrue(
            req.url?.scheme == "wss",
            "HTTPS base URL must produce a wss:// WebSocket URL"
        )
    }

    // MARK: - Regression: Serve/loopback path still pins loopback

    func testRegression_explicitLoopbackPath_stillPinsLoopback_ws() {
        let req = wsRequest(urlString: "http://127.0.0.1:8080")
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "An explicit loopback WS URL must pin loopback Host"
        )
    }

    func testRegression_explicitLoopbackPath_stillPinsLoopback_rest() {
        let req = restRequest(urlString: "http://127.0.0.1:8080")
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Host"), "127.0.0.1",
            "An explicit loopback REST URL must pin loopback Host"
        )
    }

}
