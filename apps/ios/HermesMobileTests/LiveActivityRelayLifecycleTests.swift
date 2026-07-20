import Foundation
import XCTest
@testable import HermesMobile

/// R16 — Live Activity lifecycle on the RELAY path.
///
/// The relay wire (`RelaySessionCoordinator.ingest` → `ChatStore.applyRelayItems`)
/// never flows through `handleMessageComplete` / `handleGatewayError`, so the
/// `onTurnComplete` / `onTurnDiscarded` seams that end the lock-screen Live
/// Activity on the direct path must be fired at the relay projection's
/// streaming-settle edge (and on session switch). These tests pin that
/// contract: a relay turn that streams then settles fires `onTurnComplete`
/// exactly once; an errored relay turn fires `onTurnDiscarded` instead (no
/// queue drain); a session switch mid-turn discards the outgoing turn's
/// activity. Before the R16 fix these tests FAILED — the relay settle edge
/// cleared `turnStartedAt` but never fired the end seam, so the activity's
/// `startedAt` drove the lock-screen timer forever.
@MainActor
final class LiveActivityRelayLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private func itemFrame(_ seq: Int, kind: String, id: String, _ type: ChatItemType,
                           status: String, ord: Int, body: JSONValue) -> RelayFrame {
        RelayFrame(seq: seq, sid: "s", turn: "t", kind: RelayFrameKind(wire: kind), body: .object([
            "item_id": .string(id), "type": .string(type.rawValue),
            "status": .string(status), "ord": .number(Double(ord)), "body": body,
        ]))
    }

    /// Frames for a normal turn: user prompt → assistant in-progress →
    /// assistant completed.
    private func streamingThenSettledFrames() -> [RelayFrame] {
        [
            itemFrame(1, kind: "item.completed", id: "user-1", .userMessage,
                      status: "completed", ord: 0, body: ["text": "hi"]),
            itemFrame(2, kind: "item.started", id: "msg-1", .agentMessage,
                      status: "in_progress", ord: 1, body: ["text": ""]),
            itemFrame(3, kind: "item.completed", id: "msg-1", .agentMessage,
                      status: "completed", ord: 1, body: ["text": "hello back"]),
        ]
    }

    /// Frames for an errored turn: user prompt → assistant in-progress →
    /// a FAILED `.error` item (parity with the direct path's `error` event).
    private func streamingThenErrorFrames() -> [RelayFrame] {
        [
            itemFrame(1, kind: "item.completed", id: "user-1", .userMessage,
                      status: "completed", ord: 0, body: ["text": "hi"]),
            itemFrame(2, kind: "item.started", id: "msg-1", .agentMessage,
                      status: "in_progress", ord: 1, body: ["text": ""]),
            itemFrame(3, kind: "item.completed", id: "err-1", .error,
                      status: "failed", ord: 2, body: ["text": "agent crashed"]),
        ]
    }

    // MARK: - Pure helper

    func testHasRelayErrorTerminalDetection() {
        let errItem = ChatItem(
            itemID: "e", type: .error, status: .failed, ord: 1,
            body: ["text": "boom"]
        )
        let okItem = ChatItem(
            itemID: "m", type: .agentMessage, status: .completed, ord: 1,
            body: ["text": "ok"]
        )
        // Pure decision: only a failed .error item is a turn-error terminal.
        XCTAssertTrue(ChatStore.hasRelayErrorTerminal([errItem]))
        XCTAssertTrue(ChatStore.hasRelayErrorTerminal([okItem, errItem]))
        XCTAssertFalse(ChatStore.hasRelayErrorTerminal([okItem]))
        XCTAssertFalse(ChatStore.hasRelayErrorTerminal([]))
        // A `.error` item still IN PROGRESS is not yet a terminal — the turn
        // could yet stream more frames behind it.
        let inProgressErr = ChatItem(
            itemID: "e2", type: .error, status: .inProgress, ord: 1,
            body: ["text": "boom"]
        )
        XCTAssertFalse(ChatStore.hasRelayErrorTerminal([inProgressErr]))
    }

    // MARK: - Happy-path settle fires onTurnComplete

    func testRelaySettleFiresOnTurnComplete() {
        var store = RelayItemStore()
        let chat = ChatStore()
        var starts = 0
        var completions = 0
        var discards = 0
        chat.onTurnStart = { starts += 1 }
        chat.onTurnComplete = { completions += 1 }
        chat.onTurnDiscarded = { discards += 1 }

        let frames = streamingThenSettledFrames()
        // Apply through the in-progress item — turn is streaming, LA started.
        store.apply(Array(frames.prefix(2)))
        chat.applyRelayItems(store.items)
        XCTAssertTrue(chat.isStreaming, "in-progress trailing item keeps the turn streaming")
        XCTAssertEqual(starts, 1, "the first streaming projection starts the Live Activity")

        // Settle: the assistant message completes. The turn is no longer
        // streaming — the Live Activity MUST end here (R16). Before the fix
        // this fired nothing and the lock-screen timer counted forever.
        store.apply(Array(frames.suffix(1)))
        chat.applyRelayItems(store.items)
        XCTAssertFalse(chat.isStreaming, "after the completion lands the turn settles")

        XCTAssertEqual(completions, 1,
                       "relay turn settle must fire onTurnComplete exactly once (R16)")
        XCTAssertEqual(discards, 0,
                       "a happy-path relay settle is a completion, never a discard")
        XCTAssertEqual(starts, 1, "start fires once per turn (idempotent on re-projection)")
    }

    // MARK: - Settle is not re-fired on subsequent re-projections

    func testRelaySettleFiresOnceAcrossReprojection() {
        var store = RelayItemStore()
        let chat = ChatStore()
        var completions = 0
        chat.onTurnComplete = { completions += 1 }

        let frames = streamingThenSettledFrames()
        store.apply(frames)
        chat.applyRelayItems(store.items)
        XCTAssertEqual(completions, 1, "settle fires on the streaming→settled edge")

        // Re-projecting the SAME settled snapshot must not re-fire — the
        // branch is gated on the PRIOR `isStreaming` (already false here).
        chat.applyRelayItems(store.items)
        chat.applyRelayItems(store.items)
        XCTAssertEqual(completions, 1, "re-projection of an already-settled turn is a no-op")
    }

    // MARK: - Errored relay turn fires onTurnDiscarded (no queue drain)

    func testRelayErrorSettleFiresOnTurnDiscardedNotComplete() {
        var store = RelayItemStore()
        let chat = ChatStore()
        var completions = 0
        var discards = 0
        chat.onTurnComplete = { completions += 1 }
        chat.onTurnDiscarded = { discards += 1 }

        let frames = streamingThenErrorFrames()
        store.apply(Array(frames.prefix(2)))
        chat.applyRelayItems(store.items)
        XCTAssertTrue(chat.isStreaming)

        store.apply(Array(frames.suffix(1)))
        chat.applyRelayItems(store.items)
        XCTAssertFalse(chat.isStreaming, "the failed `.error` terminal settles the turn")

        XCTAssertEqual(discards, 1,
                       "an errored relay turn is a discard (parity with handleGatewayError)")
        XCTAssertEqual(completions, 0,
                       "the queue must not auto-drain into a session that just errored")
    }

    // MARK: - Session switch mid-turn discards the outgoing activity

    func testSessionSwitchDiscardsLiveRelayTurn() {
        let chat = ChatStore()
        var discards = 0
        chat.onTurnDiscarded = { discards += 1 }

        // Seed a streaming relay turn.
        var store = RelayItemStore()
        store.apply(Array(streamingThenSettledFrames().prefix(2)))
        chat.applyRelayItems(store.items)
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(discards, 0, "no discard while the turn is live and projected")

        // R16 seam: switching the projected session while a turn is live ends
        // the outgoing session's Live Activity (it no longer reflects what the
        // user is looking at). No-op when nothing is live.
        chat.endRelayTurnForSessionSwitch()
        XCTAssertEqual(discards, 1,
                       "switching away mid-turn ends the outgoing Live Activity (R16)")

        // Idempotent guard: when no turn is live, the switch seam is a no-op.
        chat.endRelayTurnForSessionSwitch()
        XCTAssertEqual(discards, 1, "the switch discard is a no-op when nothing is streaming")
    }
}
