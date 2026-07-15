import XCTest
@testable import HermesMobile

final class SyncManifestClientTests: XCTestCase {
    final class Stub: URLProtocol {
        static var handler: ((URLRequest) throws -> (Int, Data))!
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, data) = try Self.handler(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }

    func testPluginRouteCarriesScopeCursorAndSessionToken() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
        Stub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "secret")
            XCTAssertEqual(request.url?.path, "/api/plugins/hermes-mobile/sync-manifest")
            XCTAssertTrue(request.url!.query!.contains("profile=work")); XCTAssertTrue(request.url!.query!.contains("cursor=a%2Bb"))
            return (200, Data(#"{"revision":7,"cursor":"done","has_more":false}"#.utf8))
        }
        let client = RestClient(baseURL: URL(string: "https://example.test")!, token: "secret", session: URLSession(configuration: config), pathStyle: .plugin)
        let page = try await client.syncManifest(scope: CacheScope(serverId: "s", profileId: "work"), cursor: "a+b")
        XCTAssertEqual(page.revision, 7)
    }

    func testLegacyStyleDoesNotProbePluginRoute() async {
        let client = RestClient(baseURL: URL(string: "https://example.test")!, token: "x", pathStyle: .legacy)
        do { _ = try await client.syncManifest(scope: CacheScope(serverId: "s", profileId: "all"), cursor: nil); XCTFail("expected 404") }
        catch RestError.badStatus(let code, _) { XCTAssertEqual(code, 404) }
        catch { XCTFail("unexpected \(error)") }
    }
}
