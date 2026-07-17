import GRDB
import XCTest
@testable import HermesMobile

final class CompactTurnCacheTests: XCTestCase {
    private func authority() throws -> AuthorityScopeV1 {
        try AuthorityScopeV1(
            gatewayID: "gw_test",
            profileID: "pf_test",
            authorityEpoch: "ae_test"
        )
    }

    private func page(
        revision: Int64,
        turnID: String = "turn_1",
        clientMessageID: String = "cm_1",
        tombstones: [CompactTurnTombstoneV1] = []
    ) -> CompactTurnPageV1 {
        CompactTurnPageV1(
            schemaVersion: 1,
            projectionVersion: 1,
            storedSessionID: "session_1",
            sourceHeadID: revision,
            coverageComplete: true,
            projectionPending: false,
            reset: false,
            turns: [CompactTurnV1(
                turnID: turnID,
                clientMessageID: clientMessageID,
                inputs: [CompactTurnInputV1(
                    inputID: clientMessageID,
                    clientMessageID: clientMessageID,
                    ordinal: 0,
                    inputKind: "prompt",
                    content: .string("hello"),
                    createdAt: 1
                )],
                state: "completed",
                acceptedAt: 1,
                startedAt: 1,
                completedAt: 3,
                elapsedMs: 2_000,
                timingQuality: "exact",
                authorityState: "authoritative",
                serverRevision: revision,
                final: CompactTurnFinalV1(
                    messageID: "origin_2",
                    content: .string("done"),
                    createdAt: 3
                ),
                activityGroups: [CompactTurnActivityGroupV1(
                    groupID: "group_1",
                    ordinal: 0,
                    category: "files",
                    displayLabel: "Inspected files",
                    operationCount: 2,
                    state: "completed",
                    startedAt: 1.5,
                    completedAt: 2.5,
                    detailAvailable: true
                )]
            )],
            tombstones: tombstones,
            previousCursor: nil,
            hasOlder: false
        )
    }

    func testAtomicApplyLoadsBoundedCompactTurnAndReturnsReceiptIdentity() async throws {
        let queue = try DatabaseQueue()
        let store = try CacheStore(testDB: queue)
        let identity = try await store.applyCompactTurnPage(
            page(revision: 10),
            authority: authority()
        )

        XCTAssertEqual(identity, [CacheStore.CompactTurnCommitIdentity(
            clientMessageID: "cm_1",
            turnID: "turn_1"
        )])
        let turns = try await store.loadCompactTurns(
            authority: authority(),
            storedSessionID: "session_1",
            limit: 1
        )
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].inputs[0].content, .string("hello"))
        XCTAssertEqual(turns[0].final?.content, .string("done"))
        XCTAssertEqual(turns[0].activityGroups[0].operationCount, 2)
    }

    func testNewerTombstoneDominatesDelayedTurnPage() async throws {
        let queue = try DatabaseQueue()
        let store = try CacheStore(testDB: queue)
        let tombstone = CompactTurnTombstoneV1(
            turnID: "turn_1",
            state: "rewound_no_display",
            serverRevision: 20,
            deletedAt: 20
        )
        _ = try await store.applyCompactTurnPage(
            page(revision: 20, tombstones: [tombstone]),
            authority: authority()
        )
        do {
            _ = try await store.applyCompactTurnPage(
                page(revision: 10),
                authority: authority()
            )
            XCTFail("stale page must fail closed")
        } catch let error as CompactTurnCacheError {
            XCTAssertEqual(error, .stalePage)
        }
        let turns = try await store.loadCompactTurns(
            authority: authority(),
            storedSessionID: "session_1"
        )
        XCTAssertTrue(turns.isEmpty)
    }

    func testCompactAdapterRendersOnlySafeEnvelopeAndCommittedBodies() {
        let messages = ChatStore.toChatMessages(compactTurns: page(revision: 10).turns)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "hello")
        XCTAssertEqual(messages[0].clientMessageID, "cm_1")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].text, "done")
        XCTAssertTrue(messages[1].thinking.isEmpty)
        XCTAssertEqual(messages[1].tools.count, 1)
        XCTAssertEqual(messages[1].tools[0].resultSummary, "Inspected files")
        XCTAssertTrue(messages[1].tools[0].argsSummary.isEmpty)
        XCTAssertTrue(messages[1].tools[0].resultPreview.isEmpty)
        XCTAssertEqual(messages[1].turnElapsed, 2)
    }
}
