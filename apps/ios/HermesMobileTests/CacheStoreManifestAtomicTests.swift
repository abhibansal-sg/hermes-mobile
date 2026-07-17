import XCTest
import GRDB
@testable import HermesMobile

final class CacheStoreManifestAtomicTests: XCTestCase {
    private func page(
        revision: Int,
        cursor: String,
        reset: Bool,
        gatewayID: String = "gw_gateway",
        authorityEpoch: String = "ae_epoch",
        journalEpoch: String = "je_journal",
        snapshotID: String? = nil,
        upserts: String = "[]",
        tombstones: String = "[]",
        attention: String = "[]",
        heads: String = "[]",
        serverTime: Double = 1
    ) throws -> SyncManifestPage {
        let json = pageJSON(
            revision: revision,
            cursor: cursor,
            reset: reset,
            gatewayID: gatewayID,
            authorityEpoch: authorityEpoch,
            journalEpoch: journalEpoch,
            snapshotID: snapshotID,
            upserts: upserts,
            tombstones: tombstones,
            attention: attention,
            heads: heads,
            serverTime: serverTime
        )
        return try decode(json)
    }

    private func pageJSON(
        revision: Int,
        cursor: String,
        reset: Bool,
        gatewayID: String = "gw_gateway",
        authorityEpoch: String = "ae_epoch",
        journalEpoch: String = "je_journal",
        snapshotID: String? = nil,
        upserts: String = "[]",
        tombstones: String = "[]",
        attention: String = "[]",
        heads: String = "[]",
        serverTime: Double = 1
    ) -> String {
        let reason = reset ? "\"full_snapshot\"" : "null"
        return """
        {
          "schema_version":2,"gateway_id":"\(gatewayID)",
          "profile_authorities":[{"profile_id":"pf_profile","profile_name":"p","authority_epoch":"\(authorityEpoch)"}],
          "journal_epoch":"\(journalEpoch)","complete":true,"revision":\(revision),
          "snapshot_id":"\(snapshotID ?? "ms_\(revision)")","page_size":500,"scope":"profile:pf_profile",
          "continuation_cursor":null,"resume_cursor":"\(cursor)",
          "reset":\(reset),"reset_reason":\(reason),"server_time":\(serverTime),
          "sessions":{"upserts":\(upserts),"tombstones":\(tombstones)},
          "pending_attention":\(attention),
          "runtime_snapshot":{"runtime_instance_id":"gri_runtime","sequence":1,"captured_at":1,"active_turns":[]},
          "transcript_heads":\(heads),
          "widget_summary":{"open_session_count":0,"active_turn_count":0,"pending_attention_count":0,"tokens_today":null,"estimated_cost_today":null},
          "push_registry":{"device_registered":false}
        }
        """
    }

    private func decode(_ json: String) throws -> SyncManifestPage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SyncManifestPage.self, from: Data(json.utf8))
    }

    private func response(_ json: String) throws -> SyncManifestHTTPPage {
        let data = Data(json.utf8)
        return SyncManifestHTTPPage(
            page: try decode(json),
            encodedData: data,
            encodedByteCount: data.count
        )
    }

    private var session: String {
        #"[{"id":"s","title":"one","profile":"p","profile_id":"pf_profile","authority_epoch":"ae_epoch","entity_revision":1}]"#
    }

    private func store() throws -> CacheStore { try CacheStore(testDB: DatabaseQueue()) }

    func testAtomicCommitAndDuplicateReplay() async throws {
        let store = try store()
        let scope = CacheScope(serverId: "server", profileId: "p")
        let chain = try ManifestChain(validating: [page(
            revision: 4,
            cursor: "m2.je_journal.c4",
            reset: true,
            upserts: session,
            attention: #"[{"id":"a","session_id":"r","stored_session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","kind":"approval","status":"pending","entity_revision":4}]"#,
            heads: #"[{"session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","max_message_id":3,"message_count":1,"entity_revision":4}]"#
        )])
        let first = try await store.applyManifest(chain, scope: scope)
        let replay = try await store.applyManifest(chain, scope: scope)
        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.revision, 4)
        XCTAssertEqual(first.sessions.map(\.id), ["s"])
    }

    func testTombstoneRemovesRowsAndDoesNotReappearOffline() async throws {
        let store = try store()
        let scope = CacheScope(serverId: "server", profileId: "p")
        _ = try await store.applyManifest(
            ManifestChain(validating: [page(revision: 1, cursor: "m2.je_journal.c1", reset: true, upserts: session)]),
            scope: scope
        )
        let tombstone = #"[{"session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","entity_revision":2,"deleted_at":2,"reason":"deleted"}]"#
        _ = try await store.applyManifest(
            ManifestChain(validating: [page(revision: 2, cursor: "m2.je_journal.c2", reset: false, tombstones: tombstone)]),
            scope: scope
        )
        let cold = try await store.loadManifestProjection(scope: scope)
        XCTAssertTrue(cold.sessions.isEmpty)
        XCTAssertEqual(cold.revision, 2)
    }

    func testInvalidChainLeavesOldDrawerInboxWidgetRevisionIntact() async throws {
        let store = try store()
        let scope = CacheScope(serverId: "server", profileId: "p")
        let attention = #"[{"id":"a","session_id":"r","stored_session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","kind":"approval","status":"pending","entity_revision":1}]"#
        _ = try await store.applyManifest(
            ManifestChain(validating: [page(revision: 1, cursor: "m2.je_journal.c1", reset: true, upserts: session, attention: attention)]),
            scope: scope
        )
        let incompleteJSON = #"{"schema_version":2,"gateway_id":"gw_gateway","profile_authorities":[{"profile_id":"pf_profile","profile_name":"p","authority_epoch":"ae_epoch"}],"journal_epoch":"je_journal","complete":false,"revision":2,"snapshot_id":"ms_2","page_size":500,"scope":"profile:pf_profile","continuation_cursor":"m2.je_journal.more","resume_cursor":null,"reset":false,"reset_reason":null,"server_time":2,"sessions":{"upserts":[],"tombstones":[]}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let incomplete = try decoder.decode(SyncManifestPage.self, from: Data(incompleteJSON.utf8))
        XCTAssertThrowsError(try ManifestChain(validating: [incomplete]))
        let old = try await store.loadManifestProjection(scope: scope)
        XCTAssertEqual(old.revision, 1)
        XCTAssertEqual(old.sessions.map(\.id), ["s"])
        XCTAssertEqual(old.attention.map(\.id), ["a"])
    }

    func testStagingDoesNotPublishAndDiscardPreservesPriorProjection() async throws {
        let store = try store()
        let locator = "HTTPS://Example.COM/"
        let scope = CacheScope(serverId: locator, profileId: "p")
        _ = try await store.applyManifest(
            ManifestChain(validating: [page(
                revision: 1,
                cursor: "m2.je_journal.c1",
                reset: true,
                upserts: session
            )]),
            scope: scope
        )

        let staged = pageJSON(
            revision: 2,
            cursor: "m2.je_journal.c2",
            reset: false,
            snapshotID: "ms_staged",
            tombstones: #"[{"session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","entity_revision":2,"deleted_at":2,"reason":"deleted"}]"#
        )
        try await store.stageManifestPage(try response(staged), locator: locator, pageIndex: 0)

        let beforeCommit = try await store.loadManifestProjection(scope: scope)
        XCTAssertEqual(beforeCommit.revision, 1)
        XCTAssertEqual(beforeCommit.sessions.map(\.id), ["s"])

        try await store.discardStagedManifest(snapshotID: "ms_staged")
        do {
            _ = try await store.commitStagedManifest(
                snapshotID: "ms_staged",
                locator: locator,
                expectedPageCount: 1
            )
            XCTFail("discarded staging must not commit")
        } catch {
            XCTAssertEqual(error as? ManifestBindingError, .invalidStage)
        }
        let afterDiscard = try await store.loadManifestProjection(scope: scope)
        XCTAssertEqual(afterDiscard, beforeCommit)
    }

    func testStagedCommitNormalizesLocatorAndPublishesOnce() async throws {
        let store = try store()
        let json = pageJSON(
            revision: 4,
            cursor: "m2.je_journal.c4",
            reset: true,
            snapshotID: "ms_staged_commit",
            upserts: session
        )
        try await store.stageManifestPage(
            try response(json),
            locator: " HTTPS://Example.COM/ ",
            pageIndex: 0
        )
        let result = try await store.commitStagedManifest(
            snapshotID: "ms_staged_commit",
            locator: "https://example.com",
            expectedPageCount: 1
        )

        XCTAssertEqual(result.binding.normalizedLocator, "https://example.com")
        XCTAssertFalse(result.transition.changed)
        XCTAssertEqual(result.projection.revision, 4)
        XCTAssertEqual(result.projection.sessions.map(\.id), ["s"])
        let reloaded = try await store.loadManifestProjection(
            locator: "https://example.com/",
            manifestScope: "profile:pf_profile"
        )
        XCTAssertEqual(
            reloaded,
            result.projection.withFreshness(.cached)
        )
    }

    func testAuthorityReplacementReportsTransitionAndStartsFreshPartition() async throws {
        let store = try store()
        let locator = "https://example.com"
        let old = try ManifestChain(validating: [page(
            revision: 9,
            cursor: "m2.je_old.c9",
            reset: true,
            gatewayID: "gw_old",
            journalEpoch: "je_old",
            upserts: session
        )])
        _ = try await store.applyManifest(old, scope: CacheScope(serverId: locator, profileId: "p"))

        let replacementJSON = pageJSON(
            revision: 1,
            cursor: "m2.je_new.c1",
            reset: true,
            gatewayID: "gw_new",
            authorityEpoch: "ae_new",
            journalEpoch: "je_new",
            snapshotID: "ms_replacement"
        )
        try await store.stageManifestPage(try response(replacementJSON), locator: locator, pageIndex: 0)
        let result = try await store.commitStagedManifest(
            snapshotID: "ms_replacement",
            locator: locator,
            expectedPageCount: 1
        )

        XCTAssertEqual(result.transition.replacedGatewayID, "gw_old")
        XCTAssertTrue(result.projection.sessions.isEmpty)
        XCTAssertEqual(result.projection.revision, 1)
        XCTAssertEqual(result.binding.gatewayID, "gw_new")
    }

    func testNewerTombstoneDominatesDelayedOlderUpsert() async throws {
        let store = try store()
        let scope = CacheScope(serverId: "server", profileId: "p")
        let tombstone = #"[{"session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","entity_revision":8,"deleted_at":8,"reason":"deleted"}]"#
        _ = try await store.applyManifest(
            ManifestChain(validating: [page(
                revision: 8,
                cursor: "m2.je_journal.c8",
                reset: true,
                tombstones: tombstone
            )]),
            scope: scope
        )
        _ = try await store.applyManifest(
            ManifestChain(validating: [page(
                revision: 9,
                cursor: "m2.je_journal.c9",
                reset: false,
                upserts: session
            )]),
            scope: scope
        )

        let projection = try await store.loadManifestProjection(scope: scope)
        XCTAssertEqual(projection.revision, 9)
        XCTAssertTrue(projection.sessions.isEmpty)
    }
}

private extension ManifestProjection {
    func withFreshness(_ freshness: ManifestFreshness) -> ManifestProjection {
        ManifestProjection(
            gatewayID: gatewayID,
            journalEpoch: journalEpoch,
            profileAuthorities: profileAuthorities,
            revision: revision,
            cursor: cursor,
            sessions: sessions,
            attention: attention,
            activeTurns: activeTurns,
            transcriptHeads: transcriptHeads,
            capabilities: capabilities,
            freshness: freshness,
            lastSyncedAt: lastSyncedAt
        )
    }
}
