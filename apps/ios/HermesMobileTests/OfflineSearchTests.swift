import XCTest
import GRDB
@testable import HermesMobile

final class OfflineSearchTests: XCTestCase {
    private func store() throws -> CacheStore {
        var config = Configuration()
        config.prepareDatabase { try $0.execute(sql: "PRAGMA foreign_keys=ON") }
        return try CacheStore(testDB: DatabaseQueue(configuration: config))
    }

    private func session(_ id: String) -> SessionSummary {
        SessionSummary(id: id, title: id, preview: nil, startedAt: 1,
                       messageCount: 3, source: nil, lastActive: 2, cwd: nil)
    }

    private func message(_ role: String, _ text: String, wireId: Int? = nil) -> StoredMessage {
        StoredMessage(role: role, content: .string(text), timestamp: 3, wireId: wireId)
    }

    func testOfflineIndexRolesUnicodeScopeAndDuplicateIds() async throws {
        let cache = try store()
        let a = CacheScope(serverId: "gateway-a", profileId: "default")
        let b = CacheScope(serverId: "gateway-a", profileId: "work")
        try await cache.saveSessionList([session("same")], scope: a)
        try await cache.saveTranscript(sessionId: "same", messages: [
            message("user", "café 東京", wireId: 11),
            message("assistant", "answer needle"),
            message("system", "needle secret")
        ], scope: a)
        try await cache.saveSessionList([session("same")], scope: b)
        try await cache.saveTranscript(sessionId: "same", messages: [message("tool", "needle work")], scope: b)

        XCTAssertEqual(try await cache.searchTranscript(query: "cafe", scope: a).hits.count, 1)
        XCTAssertEqual(try await cache.searchTranscript(query: "東京", scope: a).hits.count, 1)
        XCTAssertEqual(try await cache.searchTranscript(query: "needle", scope: a, roles: ["user"]).hits.count, 0)
        XCTAssertEqual(try await cache.searchTranscript(query: "needle", scope: a).hits.map(\.role), ["assistant"])
        XCTAssertEqual(try await cache.searchTranscript(query: "needle", scope: b).hits.map(\.role), ["tool"])
        XCTAssertEqual(try await cache.searchTranscript(query: "needle", scope: CacheScope(serverId: "gateway-b", profileId: "work")).hits.count, 0)
    }

    func testReplaceAppendTombstoneAndExactOfflineLoad() async throws {
        let cache = try store()
        let scope = CacheScope(serverId: "gateway", profileId: "default")
        try await cache.saveSessionList([session("s")], scope: scope)
        try await cache.saveTranscript(sessionId: "s", messages: [message("user", "old", wireId: 1)], scope: scope)
        try await cache.saveTranscript(sessionId: "s", messages: [message("user", "new", wireId: 2)], scope: scope)
        XCTAssertTrue(try await cache.searchTranscript(query: "old", scope: scope).hits.isEmpty)
        try await cache.appendTranscript(sessionId: "s", messages: [message("assistant", "later", wireId: 3)], scope: scope)
        XCTAssertEqual(try await cache.searchTranscript(query: "later", scope: scope).hits.first?.wireId, 3)
        let loaded = try await cache.loadTranscript(scope: scope, sessionId: "s")
        XCTAssertEqual(loaded?.count, 2)
        try await cache.removeSession(scope: scope, sessionId: "s")
        XCTAssertTrue(try await cache.searchTranscript(query: "later", scope: scope).hits.isEmpty)
    }

    func testBackfillProgressPartialResumeAndGatewayPurge() async throws {
        let cache = try store()
        let scope = CacheScope(serverId: "gateway", profileId: "default")
        try await cache.saveSessionList([session("s")], scope: scope)
        try await cache.saveTranscript(sessionId: "s", messages: [message("user", "durable week")], scope: scope)
        XCTAssertTrue(try await cache.searchTranscript(query: "durable", scope: scope).partial)
        XCTAssertTrue(try await cache.backfillSearchIndex(scope: scope, batchSize: 1))
        XCTAssertFalse(try await cache.searchTranscript(query: "durable", scope: scope).partial)
        XCTAssertEqual(try await cache.purgeGateway(serverId: "gateway"), 1)
        XCTAssertTrue(try await cache.searchTranscript(query: "durable", scope: scope).hits.isEmpty)
    }
}
