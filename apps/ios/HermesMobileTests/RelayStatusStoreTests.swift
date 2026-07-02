import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class RelayStatusStoreTests: XCTestCase {
    func testRefreshStatusStoresFailingHealthAndRealFailureCount() async {
        let store = RelayStore(rest: stubClient(returning: #"{"configured":true,"health":"failing","delivery_failure_count":2,"tunnel_status":{"ok":true,"agent_online":true}}"#))

        await store.refreshStatus()

        XCTAssertEqual(RelayStatusStubProtocol.requestedPath, "/api/plugins/hermes-mobile/relay/status")
        XCTAssertEqual(store.relayStatus?.health, "failing")
        XCTAssertEqual(store.relayStatus?.deliveryFailureCount, 2)
        XCTAssertEqual(store.statusSummary, "Relay health: failing (2 delivery failures).")
        XCTAssertNil(store.errorMessage)
    }

    func testRefreshStatusPreservesServerErrorDetail() async {
        let store = RelayStore(
            rest: stubClient(
                returning: #"{"configured":false,"health":"unconfigured","delivery_failure_count":0,"detail":"relay URL is not configured"}"#,
                status: 400
            )
        )

        await store.refreshStatus()

        XCTAssertNil(store.relayStatus)
        XCTAssertEqual(store.errorMessage, "Server returned HTTP 400: {\"configured\":false,\"health\":\"unconfigured\",\"delivery_failure_count\":0,\"detail\":\"relay URL is not configured\"}")
    }

    private func stubClient(returning json: String, status: Int = 200) -> RestClient {
        RelayStatusStubProtocol.nextResponse = (json.data(using: .utf8) ?? Data(), status)
        RelayStatusStubProtocol.requestedPath = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayStatusStubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )
    }
}

final class RelayStatusStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (data: Data, status: Int)?
    nonisolated(unsafe) static var requestedPath: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedPath = request.url?.path
        guard let (data, status) = Self.nextResponse else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
