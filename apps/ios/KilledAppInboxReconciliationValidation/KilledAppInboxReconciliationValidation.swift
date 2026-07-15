import XCTest
import GRDB
@testable import HermesMobile

/// Named physical-device acceptance target. Run on a signed device, terminate
/// the host between the two phases, then relaunch; the test also performs an
/// in-process database close/reopen so CI pins the same durable boundary.
final class KilledAppInboxReconciliationValidation: XCTestCase {
    func testCommittedPendingAttentionSurvivesDatabaseReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("killed-inbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let scope = CacheScope(serverId: "physical-device-gateway", profileId: "all")

        do {
            let cache = try CacheStore(testDB: DatabaseQueue(path: url.path))
            let record = PendingAttentionRecord(
                id: "killed-1", requestId: "request-1", kind: "approval",
                sessionId: "runtime-1", storedSessionId: "stored-1", safeTitle: "Approve",
                detail: .init(description: "safe"), destructive: false,
                createdAt: 1, expiresAt: nil, status: "pending", revision: 1
            )
            _ = try await cache.applyPendingAttention(.init(
                serverInstanceId: "instance", cursor: "cursor", reset: true,
                resetReason: "initial_snapshot", upserts: [record], tombstones: []
            ), scope: scope)
        }

        let relaunched = try CacheStore(testDB: DatabaseQueue(path: url.path))
        let snapshot = try await relaunched.loadAttentionSnapshot(scope: scope)
        XCTAssertEqual(snapshot.items.map(\.id), ["killed-1"])
        XCTAssertEqual(snapshot.pendingCount, 1)
        XCTAssertEqual(snapshot.metadata?.cursor, "cursor")
    }
}
