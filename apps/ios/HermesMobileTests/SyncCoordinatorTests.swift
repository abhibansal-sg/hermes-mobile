import XCTest
@testable import HermesMobile

final class SyncCoordinatorTests: XCTestCase {
    private func decode(_ json: String) throws -> SyncManifestPage {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SyncManifestPage.self, from: Data(json.utf8))
    }

    func testMultiPageValidationRejectsRevisionRaceAndBrokenCursor() throws {
        let first = try decode(#"{"revision":2,"cursor":"start","next_cursor":"next","has_more":true}"#)
        let changed = try decode(#"{"revision":3,"cursor":"next","has_more":false}"#)
        XCTAssertThrowsError(try ManifestChain(validating: [first, changed]))
        let broken = try decode(#"{"revision":2,"cursor":"wrong","has_more":false}"#)
        XCTAssertThrowsError(try ManifestChain(validating: [first, broken]))
    }

    func testCompleteChainReconcilesAttentionTurnsHeadsAndCursorReset() throws {
        let p = try decode(#"{"revision":9,"cursor":"c9","reset":true,"has_more":false,"attention":[{"id":"a","session_id":"s","kind":"approval"}],"active_turns":[{"id":"t","session_id":"s"}],"transcript_heads":{"s":12}}"#)
        let chain = try ManifestChain(validating: [p])
        XCTAssertTrue(chain.reset); XCTAssertEqual(chain.attention.map(\.id), ["a"])
        XCTAssertEqual(chain.activeTurns.map(\.id), ["t"]); XCTAssertEqual(chain.transcriptHeads["s"], 12)
    }

    func testPageChainRejectsAuthorityEpochChange() throws {
        let first = try decode(#"{"revision":2,"cursor":"start","next_cursor":"next","has_more":true,"gateway_id":"gw_AAAAAAAAAAAAAAAAAAAAAA","journal_epoch":"je_BBBBBBBBBBBBBBBBBBBBBB","profile_authorities":[{"profile_id":"pf_CCCCCCCCCCCCCCCCCCCCCC","profile_name":"default","authority_epoch":"ae_DDDDDDDDDDDDDDDDDDDDDD"}]}"#)
        let changed = try decode(#"{"revision":2,"cursor":"next","has_more":false,"gateway_id":"gw_AAAAAAAAAAAAAAAAAAAAAA","journal_epoch":"je_BBBBBBBBBBBBBBBBBBBBBB","profile_authorities":[{"profile_id":"pf_CCCCCCCCCCCCCCCCCCCCCC","profile_name":"default","authority_epoch":"ae_EEEEEEEEEEEEEEEEEEEEEE"}]}"#)
        XCTAssertThrowsError(try ManifestChain(validating: [first, changed])) { error in
            XCTAssertEqual(error as? ManifestValidationError, .authorityChanged)
        }
    }
}
