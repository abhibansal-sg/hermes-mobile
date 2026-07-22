import XCTest
import GRDB
@testable import HermesMobile

final class PendingAttentionClientTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, data) = try Self.handler!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                )!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }

    private func client() -> RestClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return RestClient(
            baseURL: URL(string: "https://gateway.example")!, token: "token",
            session: URLSession(configuration: configuration), pathStyle: .plugin
        )
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testDecodesSnapshotAndSendsOpaqueCursor() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/plugins/hermes-mobile/attention/pending")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first?.value, "pa1.instance.7.scope.signature")
            let json = """
            {"server_instance_id":"instance","cursor":"next","reset":false,
             "reset_reason":null,"upserts":[{"id":"a1","request_id":"r1",
             "kind":"approval","session_id":"runtime","stored_session_id":"stored",
             "safe_title":"Run command","detail":{"description":"safe","choices":[]},
             "destructive":true,"created_at":10,"expires_at":20,"status":"pending","revision":7}],
             "tombstones":[]}
            """
            return (200, Data(json.utf8))
        }
        let result = try await client().pendingAttention(cursor: "pa1.instance.7.scope.signature")
        XCTAssertEqual(result.serverInstanceId, "instance")
        XCTAssertEqual(result.upserts.first?.storedSessionId, "stored")
        XCTAssertEqual(result.upserts.first?.revision, 7)
    }

    func testLegacyPathStyleDoesNotProbePluginEndpoint() async {
        let client = RestClient(baseURL: URL(string: "https://gateway.example")!, token: "x")
        do {
            _ = try await client.pendingAttention(cursor: nil)
            XCTFail("expected unsupported endpoint")
        } catch RestError.badStatus(let code, _) {
            XCTAssertEqual(code, 404)
        } catch { XCTFail("unexpected error: \(error)") }
    }

    @MainActor
    func testLaunchFetchAddsAttentionCreatedWhileAppWasTerminated() async throws {
        StubURLProtocol.handler = { _ in
            let json = """
            {"server_instance_id":"instance","cursor":"cursor-1","reset":true,
             "reset_reason":"initial_snapshot","upserts":[{"id":"offline-1","request_id":"r1",
             "kind":"clarify","session_id":"runtime","stored_session_id":"stored",
             "safe_title":"Choose","detail":{"question":"Choose","choices":["A","B"]},
             "destructive":false,"created_at":10,"expires_at":null,"status":"pending","revision":1}],
             "tombstones":[]}
            """
            return (200, Data(json.utf8))
        }
        let cache = try CacheStore(testDB: DatabaseQueue())
        let inbox = InboxStore()
        inbox.attachCache(cache)
        let scope = CacheScope(serverId: "https://gateway.example", profileId: "all")
        await inbox.hydrate(scope: scope)
        XCTAssertTrue(inbox.items.isEmpty)

        await inbox.refresh(scope: scope, rest: client())

        XCTAssertEqual(inbox.pendingItems.map(\.id), ["offline-1"])
        let persisted = try await cache.loadAttentionSnapshot(scope: scope)
        XCTAssertEqual(persisted.metadata?.cursor, "cursor-1")
    }
}
