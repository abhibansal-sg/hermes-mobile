import XCTest
import GRDB
@testable import HermesMobile

final class CacheStoreManifestAtomicTests: XCTestCase {
    private func page(_ json: String) throws -> SyncManifestPage {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SyncManifestPage.self, from: Data(json.utf8))
    }
    private func store() throws -> CacheStore { try CacheStore(testDB: DatabaseQueue()) }

    func testAtomicCommitAndDuplicateReplay() async throws {
        let store = try store(); let scope = CacheScope(serverId: "server", profileId: "p")
        let p = try page(#"{"revision":4,"cursor":"c4","has_more":false,"sessions":[{"id":"s","title":"one"}],"attention":[{"id":"a","session_id":"s","kind":"approval"}],"transcript_heads":{"s":3}}"#)
        let chain = try ManifestChain(validating: [p])
        let first = try await store.applyManifest(chain, scope: scope)
        let replay = try await store.applyManifest(chain, scope: scope)
        XCTAssertEqual(first, replay); XCTAssertEqual(first.revision, 4); XCTAssertEqual(first.sessions.map(\.id), ["s"])
    }

    func testTombstoneRemovesRowsAndDoesNotReappearOffline() async throws {
        let store = try store(); let scope = CacheScope(serverId: "server", profileId: "p")
        _ = try await store.applyManifest(ManifestChain(validating: [page(#"{"revision":1,"cursor":"c1","has_more":false,"sessions":[{"id":"s","title":"one"}]}"#)]), scope: scope)
        _ = try await store.applyManifest(ManifestChain(validating: [page(#"{"revision":2,"cursor":"c2","has_more":false,"tombstones":["s"]}"#)]), scope: scope)
        let cold = try await store.loadManifestProjection(scope: scope)
        XCTAssertTrue(cold.sessions.isEmpty); XCTAssertEqual(cold.revision, 2)
    }

    func testInvalidChainLeavesOldDrawerInboxWidgetRevisionIntact() async throws {
        let store = try store(); let scope = CacheScope(serverId: "server", profileId: "p")
        _ = try await store.applyManifest(ManifestChain(validating: [page(#"{"revision":1,"cursor":"c1","has_more":false,"sessions":[{"id":"s"}],"attention":[{"id":"a","session_id":"s","kind":"approval"}]}"#)]), scope: scope)
        let incomplete = try page(#"{"revision":2,"cursor":"c2","next_cursor":"more","has_more":true,"tombstones":["s"]}"#)
        XCTAssertThrowsError(try ManifestChain(validating: [incomplete]))
        let old = try await store.loadManifestProjection(scope: scope)
        XCTAssertEqual(old.revision, 1); XCTAssertEqual(old.sessions.map(\.id), ["s"]); XCTAssertEqual(old.attention.map(\.id), ["a"])
    }
}
