import XCTest
import GRDB
@testable import HermesMobile

final class CacheStoreManifestAtomicTests: XCTestCase {
    private func page(
        revision: Int,
        cursor: String,
        reset: Bool,
        upserts: String = "[]",
        tombstones: String = "[]",
        attention: String = "[]",
        heads: String = "[]",
        serverTime: Double = 1
    ) throws -> SyncManifestPage {
        let reason = reset ? "\"full_snapshot\"" : "null"
        let json = """
        {
          "schema_version":2,"gateway_id":"gw_gateway",
          "profile_authorities":[{"profile_id":"pf_profile","profile_name":"p","authority_epoch":"ae_epoch"}],
          "journal_epoch":"je_journal","complete":true,"revision":\(revision),
          "snapshot_id":"ms_\(revision)","page_size":500,"scope":"profile:pf_profile",
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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SyncManifestPage.self, from: Data(json.utf8))
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
}
