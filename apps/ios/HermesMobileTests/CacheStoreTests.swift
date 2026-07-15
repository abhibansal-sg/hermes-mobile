import XCTest
import GRDB
@testable import HermesMobile

final class CacheStoreTests: XCTestCase {
    private func store() throws -> CacheStore { try CacheStore(testDB: DatabaseQueue()) }
    private let scope = CacheScope(serverId: "https://one.example", profileId: "all")

    private func record(id: String = "a1", revision: Int64 = 1) -> PendingAttentionRecord {
        PendingAttentionRecord(
            id: id, requestId: "request-\(id)", kind: "approval", sessionId: "runtime-\(id)",
            storedSessionId: "stored-\(id)", safeTitle: "Approve \(id)",
            detail: .init(description: "safe summary"), destructive: false,
            createdAt: 100, expiresAt: nil, status: "pending", revision: revision
        )
    }

    private func envelope(instance: String = "i1", cursor: String = "c1", reset: Bool = false,
                          upserts: [PendingAttentionRecord] = [],
                          tombstones: [PendingAttentionTombstone] = []) -> PendingAttentionEnvelope {
        PendingAttentionEnvelope(serverInstanceId: instance, cursor: cursor, reset: reset,
                                 resetReason: reset ? "initial_snapshot" : nil,
                                 upserts: upserts, tombstones: tombstones)
    }

    func testV4MigrationCreatesConcreteAttentionRowsAndMetadata() throws {
        let queue = try DatabaseQueue()
        try CacheSchema.makeMigrator().migrate(queue)
        let columns = try queue.read { db in
            Set(try db.columns(in: "pending_attention_cache").map(\.name))
        }
        XCTAssertTrue(["requestId", "sessionId", "payloadJSON", "state", "revision", "updatedAt"]
            .allSatisfy(columns.contains))
        XCTAssertTrue(try queue.read { try $0.tableExists("attention_reconciliation_meta") })
    }

    func testTombstoneCommitsRowsCursorAndCountTogether() async throws {
        let cache = try store()
        _ = try await cache.applyPendingAttention(envelope(reset: true, upserts: [record()]), scope: scope)
        let tombstone = PendingAttentionTombstone(
            id: "a1", requestId: "request-a1", kind: "approval", sessionId: "runtime-a1",
            storedSessionId: "stored-a1", status: "resolved_elsewhere", deletedAt: 200, revision: 2
        )
        let committed = try await cache.applyPendingAttention(
            envelope(cursor: "c2", tombstones: [tombstone]), scope: scope
        )
        XCTAssertEqual(committed.pendingCount, 0)
        XCTAssertEqual(committed.items.first?.state, .resolvedElsewhere)
        XCTAssertEqual(committed.metadata?.cursor, "c2")
        XCTAssertEqual(committed.metadata?.revision, 2)
        let reloaded = try await cache.loadAttentionSnapshot(scope: scope)
        XCTAssertEqual(reloaded, committed)
        let repeated = try await cache.applyPendingAttention(
            envelope(cursor: "c2", tombstones: [tombstone]), scope: scope
        )
        XCTAssertEqual(repeated.items.first?.state, .resolvedElsewhere)
        XCTAssertEqual(repeated.metadata?.revision, 2)
    }

    func testFailedResponseSurvivesOlderSnapshotAndNewRevisionCanRearm() async throws {
        let cache = try store()
        _ = try await cache.applyPendingAttention(envelope(reset: true, upserts: [record(revision: 4)]), scope: scope)
        _ = try await cache.markAttentionState(id: "a1", state: .failedRetryable, scope: scope)

        let olderReset = try await cache.applyPendingAttention(
            envelope(cursor: "c4", reset: true, upserts: [record(revision: 4)]), scope: scope
        )
        XCTAssertEqual(olderReset.items.first?.state, .failedRetryable)
        XCTAssertEqual(olderReset.pendingCount, 1)

        let newer = try await cache.applyPendingAttention(
            envelope(cursor: "c5", upserts: [record(revision: 5)]), scope: scope
        )
        XCTAssertEqual(newer.items.first?.state, .pending)
        XCTAssertEqual(newer.items.first?.revision, 5)
    }

    func testSuccessfulResponseIsNotResurrectedByOlderResetSnapshot() async throws {
        let cache = try store()
        _ = try await cache.applyPendingAttention(
            envelope(reset: true, upserts: [record(revision: 9)]), scope: scope
        )
        _ = try await cache.markAttentionState(id: "a1", state: .resolvedElsewhere, scope: scope)

        let raced = try await cache.applyPendingAttention(
            envelope(cursor: "old-full", reset: true, upserts: [record(revision: 9)]), scope: scope
        )

        XCTAssertEqual(raced.pendingCount, 0)
        XCTAssertEqual(raced.items.first?.state, .resolvedElsewhere)
    }

    func testInstanceResetAndGatewayScopesCannotBleed() async throws {
        let cache = try store()
        let other = CacheScope(serverId: "https://two.example", profileId: "all")
        _ = try await cache.applyPendingAttention(envelope(reset: true, upserts: [record(id: "old")]), scope: scope)
        _ = try await cache.applyPendingAttention(
            envelope(instance: "i2", cursor: "fresh", reset: true, upserts: [record(id: "new", revision: 1)]),
            scope: scope
        )
        _ = try await cache.applyPendingAttention(envelope(reset: true, upserts: [record(id: "other")]), scope: other)

        var first = try await cache.loadAttentionSnapshot(scope: scope)
        var second = try await cache.loadAttentionSnapshot(scope: other)
        XCTAssertEqual(first.items.map(\.id), ["new"])
        XCTAssertEqual(second.items.map(\.id), ["other"])
        _ = try await cache.purgeGateway(serverId: scope.serverId)
        first = try await cache.loadAttentionSnapshot(scope: scope)
        second = try await cache.loadAttentionSnapshot(scope: other)
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertEqual(second.items.map(\.id), ["other"])
    }
}
