import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class RelayTestPushStoreTests: XCTestCase {
    func testSendTestPushShowsDeliveredMessage() async {
        let store = RelayStore(rest: stubClient(returning: #"{"ok":true,"detail":"Test push delivered"}"#))

        await store.sendTestPush()

        XCTAssertEqual(store.testPushMessage, "✅ Test push delivered")
        XCTAssertFalse(store.isTestingPush)
        XCTAssertNil(store.errorMessage)
    }

    func testSendTestPushShowsServerFailureDetailInline() async {
        let store = RelayStore(rest: stubClient(returning: #"{"ok":false,"detail":"TimeoutError: relay timed out"}"#))

        await store.sendTestPush()

        XCTAssertEqual(store.testPushMessage, "❌ TimeoutError: relay timed out")
        XCTAssertFalse(store.isTestingPush)
        XCTAssertNil(store.errorMessage)
    }

    private func stubClient(returning json: String, status: Int = 200) -> RestClient {
        RelayTestPushStubProtocol.nextResponse = (json.data(using: .utf8) ?? Data(), status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayTestPushStubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )
    }
}

final class RelayTestPushStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (data: Data, status: Int)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
