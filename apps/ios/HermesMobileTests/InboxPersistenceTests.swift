import XCTest
import GRDB
@testable import HermesMobile

@MainActor
final class InboxPersistenceTests: XCTestCase {
    private let scope = CacheScope(serverId: "https://persist.example", profileId: "all")

    private func record(kind: String = "clarify") -> PendingAttentionRecord {
        PendingAttentionRecord(
            id: "attention-1", requestId: "request-1", kind: kind, sessionId: "runtime-1",
            storedSessionId: "stored-1", safeTitle: kind == "clarify" ? "Which option?" : "Approve?",
            detail: .init(question: "Which option?", choices: ["A", "B"]), destructive: false,
            createdAt: 100, expiresAt: nil, status: "pending", revision: 1
        )
    }

    func testRelaunchHydratesBeforeAnyNetworkAndPublishesCommittedWidgetCount() async throws {
        let queue = try DatabaseQueue()
        let firstCache = try CacheStore(testDB: queue)
        let response = PendingAttentionEnvelope(
            serverInstanceId: "instance", cursor: "cursor-1", reset: true,
            resetReason: "initial_snapshot", upserts: [record()], tombstones: []
        )
        _ = try await firstCache.applyPendingAttention(response, scope: scope)

        let relaunched = InboxStore()
        relaunched.attachCache(try CacheStore(testDB: queue))
        var widgetCount: Int?
        relaunched.onCommittedSnapshot = { widgetCount = $0.pendingCount }
        await relaunched.hydrate(scope: scope)

        XCTAssertEqual(relaunched.pendingItems.map(\.id), ["attention-1"])
        XCTAssertEqual(relaunched.storedSessionId(forRuntime: "runtime-1"), "stored-1")
        XCTAssertEqual(widgetCount, relaunched.pendingCount)
    }

    func testLiveReplayCannotResurrectTerminalCommittedItem() async throws {
        let cache = try CacheStore(testDB: DatabaseQueue())
        let response = PendingAttentionEnvelope(
            serverInstanceId: "instance", cursor: "cursor-1", reset: true,
            resetReason: "initial_snapshot", upserts: [record(kind: "approval")], tombstones: []
        )
        _ = try await cache.applyPendingAttention(response, scope: scope)
        _ = try await cache.markAttentionState(id: "attention-1", state: .resolvedElsewhere, scope: scope)

        let inbox = InboxStore()
        inbox.attachCache(cache)
        await inbox.hydrate(scope: scope)
        let replay = GatewayEvent(params: .object([
            "type": .string("approval.request"), "session_id": .string("runtime-1"),
            "stored_session_id": .string("stored-1"),
            "payload": .object(["id": .string("attention-1"), "title": .string("Old replay")]),
        ]))!
        inbox.handle(event: replay)
        await inbox.flushPersistence()

        XCTAssertEqual(inbox.pendingCount, 0)
        let persisted = try await cache.loadAttentionSnapshot(scope: scope)
        XCTAssertEqual(persisted.items.first?.state, .resolvedElsewhere)
    }
}
