import XCTest
@testable import HermesMobile

/// Wave-2 relay↔phone decode coverage (docs/RELAY-PHONE-PROTOCOL.md §1–§3).
/// Round-trips the wire envelope + item model, exercises the forward-compat
/// folding rules (unknown item type → generic `toolCall`; unknown frame kind →
/// `.unknown` preserving the raw string), and pins the `ChatItem → ChatMessagePart`
/// render mapping. Deterministic: fixtures are the source of truth, no I/O.
final class RelayProtocolDecodeTests: XCTestCase {

    private func decodeFrame(_ json: String) throws -> RelayFrame {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(RelayFrame.self, from: data)
    }

    // MARK: - Envelope round-trip (§1)

    func testFrameRoundTripsThroughEncodeDecode() throws {
        let original = try decodeFrame(RelayFixtures.sampleAgentMessageJSON)
        let reEncoded = try JSONEncoder().encode(original)
        let reDecoded = try JSONDecoder().decode(RelayFrame.self, from: reEncoded)
        XCTAssertEqual(original, reDecoded, "RelayFrame must survive encode→decode unchanged")

        XCTAssertEqual(original.seq, 7)
        XCTAssertEqual(original.sid, "3d62926c")
        XCTAssertEqual(original.turn, "turn-1")
        XCTAssertEqual(original.kind, .itemCompleted)
    }

    // MARK: - Item decode (§2)

    func testItemCompletedDecodesFullItem() throws {
        let frame = try decodeFrame(RelayFixtures.sampleAgentMessageJSON)
        let item = try XCTUnwrap(frame.item, "item.completed must project a ChatItem")
        XCTAssertEqual(item.itemID, "msg-1")
        XCTAssertEqual(item.type, .agentMessage)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.ord, 3)
        XCTAssertEqual(item.summary, "Answered the question")
        XCTAssertEqual(item.textBody, "Here is the answer, rendered as **markdown**.")
    }

    func testUnknownItemTypeFoldsToGenericToolCall() throws {
        // §2 rule: an unrecognized `type` renders as a generic toolCall, but the
        // raw wire type is preserved so the tool name is not lost.
        let json = """
        { "seq": 99, "sid": "s", "turn": "t", "kind": "item.completed",
          "body": { "item_id": "x-1", "type": "quantum_flux", "status": "completed",
                    "ord": 0, "body": { "name": "quantum_flux" } } }
        """
        let item = try XCTUnwrap(try decodeFrame(json).item)
        XCTAssertEqual(item.type, .toolCall, "unknown type must fold to generic toolCall")
        XCTAssertEqual(item.rawType, "quantum_flux", "raw wire type must be preserved")
        XCTAssertEqual(item.toolName, "quantum_flux")
    }

    func testMissingStatusDefaultsToInProgress() throws {
        let json = """
        { "seq": 1, "sid": "s", "turn": "t", "kind": "item.started",
          "body": { "item_id": "a", "type": "agentMessage", "ord": 0 } }
        """
        let item = try XCTUnwrap(try decodeFrame(json).item)
        XCTAssertEqual(item.status, .inProgress)
    }

    // MARK: - Frame-kind projections (§3)

    func testItemDeltaProjection() throws {
        let json = """
        { "seq": 4, "sid": "s", "turn": "t", "kind": "item.delta",
          "body": { "item_id": "reason-1", "patch": { "text": "partial" } } }
        """
        let delta = try XCTUnwrap(try decodeFrame(json).itemDelta)
        XCTAssertEqual(delta.itemID, "reason-1")
        XCTAssertEqual(delta.patch["text"]?.stringValue, "partial")
    }

    func testSnapshotProjectionReconcilesByItem() throws {
        let snapshotFrame = try XCTUnwrap(
            RelayFixtures.sampleTurn().first { $0.kind == .snapshot }
        )
        let snapshot = try XCTUnwrap(snapshotFrame.snapshot)
        XCTAssertEqual(snapshot.cursor, 16)
        XCTAssertEqual(snapshot.items.map(\.itemID), ["user-1", "msg-1"])
    }

    func testUnknownFrameKindPreservesRawWireString() throws {
        let json = """
        { "seq": 5, "sid": "s", "turn": "t", "kind": "future.kind", "body": {} }
        """
        let frame = try decodeFrame(json)
        XCTAssertEqual(frame.kind, .unknown("future.kind"))
        XCTAssertEqual(frame.kind.wire, "future.kind", "unknown kind must round-trip its wire name")
    }

    // MARK: - Full fixture integrity

    func testSampleTurnDecodesWithMonotonicSeq() {
        let frames = RelayFixtures.sampleTurn()
        XCTAssertEqual(frames.count, 17)
        XCTAssertEqual(frames.map(\.seq), Array(1...17), "seq must be dense + monotonic")
        // Every declared item type appears somewhere in the turn.
        let itemTypes = Set(frames.compactMap(\.item).map(\.type))
        for expected in [ChatItemType.userMessage, .agentMessage, .reasoning,
                         .toolCall, .fileChange, .browser, .error, .usage] {
            XCTAssertTrue(itemTypes.contains(expected), "fixture missing item type \(expected)")
        }
    }

    // MARK: - Item → render-part mapping (§2 compat layer)

    func testRenderPartMapping() {
        func item(_ type: ChatItemType, body: JSONValue = .null) -> ChatItem {
            ChatItem(itemID: "i", type: type, status: .completed, ord: 0, summary: "s", body: body)
        }

        // Text-shaped kinds reuse the legacy renderers.
        if case .text(let id, let text)? = item(.agentMessage, body: ["text": "hi"]).renderPart {
            XCTAssertEqual(id, "i"); XCTAssertEqual(text, "hi")
        } else { XCTFail("agentMessage must map to .text") }

        if case .reasoning? = item(.reasoning, body: ["text": "why"]).renderPart {} else {
            XCTFail("reasoning must map to .reasoning")
        }

        let usageBody: JSONValue = ["usage": ["input": 10, "output": 5, "total": 15]]
        if case .usage? = item(.usage, body: usageBody).renderPart {} else {
            XCTFail("usage must map to .usage")
        }

        // userMessage is the user bubble, not an assistant part.
        XCTAssertNil(item(.userMessage).renderPart)

        // New special renders route through the item-backed case.
        for special in [ChatItemType.toolCall, .fileChange, .image, .browser, .error] {
            if case .item(let id, let mapped)? = item(special).renderPart {
                XCTAssertEqual(id, "i")
                XCTAssertEqual(mapped.type, special)
            } else {
                XCTFail("\(special) must map to .item")
            }
        }
    }

    // MARK: - Mock source delivery (§7)

    @MainActor
    func testMockSourceDeliversAllFramesInOrder() async {
        let source = MockRelayItemSource(frames: RelayFixtures.sampleTurn())
        let collector = SeqCollector()
        await source.run { frame in collector.seqs.append(frame.seq) }
        XCTAssertEqual(collector.seqs, Array(1...17))
    }
}

/// MainActor-confined sink so the `@Sendable @MainActor` frame handler has a
/// reference (not a mutable local capture) to accumulate into.
@MainActor
private final class SeqCollector {
    var seqs: [Int] = []
}
