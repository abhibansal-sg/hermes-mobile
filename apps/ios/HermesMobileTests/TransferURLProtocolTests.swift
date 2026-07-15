import XCTest
@testable import HermesMobile

final class TransferURLProtocolTests: XCTestCase {
    func testAuthenticationHeadersAreAppliedOnlyToRequest() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = RestClient(baseURL: URL(string: "https://example.invalid")!,
                                token: "secret", session: session)
        let request = client.makeRequest(path: "/api/upload", method: "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "secret")
    }

    func testRetryableStatusesAreExplicit() {
        XCTAssertTrue([408, 429, 500, 502, 503, 504].allSatisfy(TransferHTTPPolicy.isRetryable))
        XCTAssertFalse(TransferHTTPPolicy.isRetryable(401))
        XCTAssertFalse(TransferHTTPPolicy.isRetryable(404))
    }
}
private final class TransferMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
