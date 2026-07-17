import XCTest
@testable import HermesMobile

final class SyncManifestClientTests: XCTestCase {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))!
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
            XCTAssertEqual(request.url?.path, "/api/plugins/hermes-mobile/sync/manifest")
            XCTAssertTrue(request.url!.query!.contains("scope=all"))
            XCTAssertTrue(request.url!.query!.contains("resume_cursor=a%2Bb"))
            XCTAssertTrue(request.url!.query!.contains("limit=500"))
            return (200, Data(Self.completePageJSON.utf8))
        }
        let client = RestClient(baseURL: URL(string: "https://example.test")!, token: "secret", session: URLSession(configuration: config), pathStyle: .plugin)
        let response = try await client.syncManifest(scope: "all", resumeCursor: "a+b", continuationCursor: nil)
        XCTAssertEqual(response.page.revision, 7)
        XCTAssertEqual(response.encodedByteCount, Data(Self.completePageJSON.utf8).count)
    }

    func testLegacyStyleDoesNotProbePluginRoute() async {
        let client = RestClient(baseURL: URL(string: "https://example.test")!, token: "x", pathStyle: .legacy)
        do { _ = try await client.syncManifest(scope: "all", resumeCursor: nil, continuationCursor: nil); XCTFail("expected 404") }
        catch RestError.badStatus(let code, _) { XCTAssertEqual(code, 404) }
        catch { XCTFail("unexpected \(error)") }
    }

    func testShippingDecoderConsumesRealPythonRouterFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins/hermes-mobile/tests/fixtures/sync_manifest_v2_complete.json")
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(SyncManifestPage.self, from: data)
        let chain = try ManifestChain(validating: [page])

        XCTAssertEqual(chain.gatewayID, "gw_9-Cfia51aBCBzvgZ25nqow")
        XCTAssertEqual(chain.profileAuthorities.first?.profileName, "default")
        XCTAssertEqual(chain.sessions.map(\.id), ["fixture-session"])
        XCTAssertEqual(chain.transcriptHeads["fixture-session"], 1)
        XCTAssertEqual(chain.cursor, page.resumeCursor)
    }

    private static let completePageJSON = #"""
    {
      "schema_version":2,
      "gateway_id":"gw_AAAAAAAAAAAAAAAAAAAAAA",
      "profile_authorities":[{"profile_id":"pf_BBBBBBBBBBBBBBBBBBBBBB","profile_name":"default","authority_epoch":"ae_CCCCCCCCCCCCCCCCCCCCCC"}],
      "journal_epoch":"je_DDDDDDDDDDDDDDDDDDDDDD",
      "complete":true,
      "revision":7,
      "snapshot_id":"ms_EEEEEEEEEEEEEEEEEEEEEE",
      "page_size":500,
      "scope":"all",
      "continuation_cursor":null,
      "resume_cursor":"m2.je_DDDDDDDDDDDDDDDDDDDDDD.done",
      "reset":true,
      "reset_reason":"full_snapshot",
      "server_time":1,
      "sessions":{"upserts":[],"tombstones":[]},
      "pending_attention":[],
      "runtime_snapshot":{"runtime_instance_id":"gri_test","sequence":1,"captured_at":1,"active_turns":[]},
      "transcript_heads":[],
      "widget_summary":{"open_session_count":0,"active_turn_count":0,"pending_attention_count":0,"tokens_today":null,"estimated_cost_today":null},
      "push_registry":{"device_registered":false}
    }
    """#
}
