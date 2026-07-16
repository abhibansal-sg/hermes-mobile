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

        let cafe = try await cache.searchTranscript(query: "cafe", scope: a)
        let japanese = try await cache.searchTranscript(query: "東京", scope: a)
        let userNeedle = try await cache.searchTranscript(query: "needle", scope: a, roles: ["user"])
        let defaultNeedle = try await cache.searchTranscript(query: "needle", scope: a)
        let workNeedle = try await cache.searchTranscript(query: "needle", scope: b)
        let otherGateway = try await cache.searchTranscript(
            query: "needle", scope: CacheScope(serverId: "gateway-b", profileId: "work")
        )
        XCTAssertEqual(cafe.hits.count, 1)
        XCTAssertEqual(japanese.hits.count, 1)
        XCTAssertEqual(userNeedle.hits.count, 0)
        XCTAssertEqual(defaultNeedle.hits.map(\.role), ["assistant"])
        XCTAssertEqual(workNeedle.hits.map(\.role), ["tool"])
        XCTAssertEqual(otherGateway.hits.count, 0)
    }

    func testReplaceAppendTombstoneAndExactOfflineLoad() async throws {
        let cache = try store()
        let scope = CacheScope(serverId: "gateway", profileId: "default")
        try await cache.saveSessionList([session("s")], scope: scope)
        try await cache.saveTranscript(sessionId: "s", messages: [message("user", "old", wireId: 1)], scope: scope)
        try await cache.saveTranscript(sessionId: "s", messages: [message("user", "new", wireId: 2)], scope: scope)
        let oldHits = try await cache.searchTranscript(query: "old", scope: scope)
        XCTAssertTrue(oldHits.hits.isEmpty)
        try await cache.appendTranscript(sessionId: "s", messages: [message("assistant", "later", wireId: 3)], scope: scope)
        let laterHits = try await cache.searchTranscript(query: "later", scope: scope)
        XCTAssertEqual(laterHits.hits.first?.wireId, 3)
        let loaded = try await cache.loadTranscript(scope: scope, sessionId: "s")
        XCTAssertEqual(loaded?.count, 2)
        try await cache.removeSession(scope: scope, sessionId: "s")
        let removedHits = try await cache.searchTranscript(query: "later", scope: scope)
        XCTAssertTrue(removedHits.hits.isEmpty)
    }

    func testBackfillProgressPartialResumeAndGatewayPurge() async throws {
        let cache = try store()
        let scope = CacheScope(serverId: "gateway", profileId: "default")
        try await cache.saveSessionList([session("s")], scope: scope)
        try await cache.saveTranscript(sessionId: "s", messages: [message("user", "durable week")], scope: scope)
        let partial = try await cache.searchTranscript(query: "durable", scope: scope)
        let completed = try await cache.backfillSearchIndex(scope: scope, batchSize: 1)
        let complete = try await cache.searchTranscript(query: "durable", scope: scope)
        let purged = try await cache.purgeGateway(serverId: "gateway")
        let removed = try await cache.searchTranscript(query: "durable", scope: scope)
        XCTAssertTrue(partial.partial)
        XCTAssertTrue(completed)
        XCTAssertFalse(complete.partial)
        XCTAssertEqual(purged, 1)
        XCTAssertTrue(removed.hits.isEmpty)
    }
}
