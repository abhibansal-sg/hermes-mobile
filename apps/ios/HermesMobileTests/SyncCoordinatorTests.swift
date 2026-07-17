import XCTest
@testable import HermesMobile

final class SyncCoordinatorTests: XCTestCase {
    private func decode(_ json: String) throws -> SyncManifestPage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SyncManifestPage.self, from: Data(json.utf8))
    }

    func testMultiPageValidationRejectsRevisionAndSnapshotRaces() throws {
        let first = try decode(Self.continuationPage)
        let changedRevision = try decode(Self.finalPage.replacingOccurrences(of: "\"revision\":2", with: "\"revision\":3"))
        XCTAssertThrowsError(try ManifestChain(validating: [first, changedRevision])) {
            XCTAssertEqual($0 as? ManifestValidationError, .revisionChanged)
        }
        let changedSnapshot = try decode(Self.finalPage.replacingOccurrences(of: "ms_snapshot", with: "ms_other"))
        XCTAssertThrowsError(try ManifestChain(validating: [first, changedSnapshot])) {
            XCTAssertEqual($0 as? ManifestValidationError, .pageContractChanged)
        }
    }

    func testCompleteChainReconcilesAttentionTurnsHeadsAndResumeCursor() throws {
        let final = try decode(Self.finalPage)
        let chain = try ManifestChain(validating: [try decode(Self.continuationPage), final])
        XCTAssertTrue(chain.reset)
        XCTAssertEqual(chain.resetReason, "full_snapshot")
        XCTAssertEqual(chain.cursor, "m2.je_journal.resume")
        XCTAssertEqual(chain.attention.map(\.id), ["a"])
        XCTAssertEqual(chain.activeTurns.map(\.id), ["s"])
        XCTAssertEqual(chain.transcriptHeads["s"], 12)
        XCTAssertEqual(chain.gatewayID, "gw_gateway")
    }

    func testPageChainRejectsAuthorityEpochChange() throws {
        let first = try decode(Self.continuationPage)
        let changed = try decode(
            Self.finalPage.replacingOccurrences(of: "ae_epoch", with: "ae_changed")
        )
        XCTAssertThrowsError(try ManifestChain(validating: [first, changed])) {
            XCTAssertEqual($0 as? ManifestValidationError, .authorityChanged)
        }
    }

    func testContinuationPageRejectsAuxiliaryState() throws {
        let invalid = Self.continuationPage.replacingOccurrences(
            of: "\"sessions\":{\"upserts\":[],\"tombstones\":[]}",
            with: "\"sessions\":{\"upserts\":[],\"tombstones\":[]},\"pending_attention\":[]"
        )
        XCTAssertThrowsError(try ManifestChain(validating: [try decode(invalid), try decode(Self.finalPage)])) {
            XCTAssertEqual($0 as? ManifestValidationError, .invalidPagination)
        }
    }

    private static let continuationPage = #"""
    {
      "schema_version":2,"gateway_id":"gw_gateway",
      "profile_authorities":[{"profile_id":"pf_profile","profile_name":"default","authority_epoch":"ae_epoch"}],
      "journal_epoch":"je_journal","complete":false,"revision":2,
      "snapshot_id":"ms_snapshot","page_size":1,"scope":"all",
      "continuation_cursor":"m2.je_journal.page","resume_cursor":null,
      "reset":true,"reset_reason":"full_snapshot","server_time":10,
      "sessions":{"upserts":[],"tombstones":[]}
    }
    """#

    private static let finalPage = #"""
    {
      "schema_version":2,"gateway_id":"gw_gateway",
      "profile_authorities":[{"profile_id":"pf_profile","profile_name":"default","authority_epoch":"ae_epoch"}],
      "journal_epoch":"je_journal","complete":true,"revision":2,
      "snapshot_id":"ms_snapshot","page_size":1,"scope":"all",
      "continuation_cursor":null,"resume_cursor":"m2.je_journal.resume",
      "reset":true,"reset_reason":"full_snapshot","server_time":10,
      "sessions":{"upserts":[],"tombstones":[]},
      "pending_attention":[{"id":"a","session_id":"runtime","stored_session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","kind":"approval","safe_title":"Approval required","status":"pending","entity_revision":2}],
      "runtime_snapshot":{"runtime_instance_id":"gri_runtime","sequence":4,"captured_at":10,"active_turns":[{"session_id":"runtime","stored_session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","state":"running","started_at":9}]},
      "transcript_heads":[{"session_id":"s","profile_id":"pf_profile","authority_epoch":"ae_epoch","max_message_id":12,"message_count":3,"last_message_at":9,"entity_revision":2}],
      "widget_summary":{"open_session_count":1,"active_turn_count":1,"pending_attention_count":1,"tokens_today":null,"estimated_cost_today":null},
      "push_registry":{"device_registered":true}
    }
    """#
}
