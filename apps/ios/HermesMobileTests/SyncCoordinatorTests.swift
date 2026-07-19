import XCTest
import GRDB
@testable import HermesMobile

final class SyncCoordinatorTests: XCTestCase {
    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func decode(_ json: String) throws -> SyncManifestPage {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SyncManifestPage.self, from: Data(json.utf8))
    }

    func testMultiPageValidationRejectsRevisionRaceAndBrokenCursor() throws {
        let first = try decode(#"{"revision":2,"cursor":"start","next_cursor":"next","has_more":true}"#)
        let changed = try decode(#"{"revision":3,"cursor":"next","has_more":false}"#)
        XCTAssertThrowsError(try ManifestChain(validating: [first, changed]))
        let broken = try decode(#"{"revision":2,"cursor":"wrong","has_more":false}"#)
        XCTAssertThrowsError(try ManifestChain(validating: [first, broken]))
    }

    func testCompleteChainReconcilesAttentionTurnsHeadsAndCursorReset() throws {
        let p = try decode(#"{"revision":9,"cursor":"c9","reset":true,"has_more":false,"attention":[{"id":"a","session_id":"s","kind":"approval"}],"active_turns":[{"id":"t","session_id":"s"}],"transcript_heads":{"s":12}}"#)
        let chain = try ManifestChain(validating: [p])
        XCTAssertTrue(chain.reset); XCTAssertEqual(chain.attention.map(\.id), ["a"])
        XCTAssertEqual(chain.activeTurns.map(\.id), ["t"]); XCTAssertEqual(chain.transcriptHeads["s"], 12)
    }

    @MainActor
    func testSynchronizeCommitsRelayManifestProjection() async throws {
        Stub.body = Data(#"{"revision":4,"cursor":"sm1.i.scope.4","reset":true,"has_more":false,"sessions":[{"id":"s1","title":"Fresh"}]}"#.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let client = RestClient(
            baseURL: URL(string: "https://gateway.test")!, token: "t",
            session: URLSession(configuration: config), pathStyle: .legacy,
            relayControlBaseURL: URL(string: "https://relay.test")!
        )
        let cache = try CacheStore(testDB: DatabaseQueue())
        let scope = CacheScope(serverId: "https://gateway.test", profileId: "all")
        let coordinator = SyncCoordinator(cache: cache, scope: scope, client: client)
        let projection = await coordinator.synchronize()
        XCTAssertEqual(projection?.revision, 4)
        XCTAssertEqual(projection?.sessions.map(\.id), ["s1"])
        let persisted = try await cache.loadManifestProjection(scope: scope)
        XCTAssertEqual(persisted.cursor, "sm1.i.scope.4")
    }
}
