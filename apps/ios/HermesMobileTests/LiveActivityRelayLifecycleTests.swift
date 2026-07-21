import Foundation
import XCTest
@testable import HermesMobile

/// R16 — Live Activity lifecycle on the RELAY path.
///
/// The relay wire (`RelaySessionCoordinator.ingest`) never flows through
/// `handleMessageComplete` / `handleGatewayError`, so the `onTurnComplete` /
/// `onTurnDiscarded` seams that END the lock-screen Live Activity on the direct
/// path must be fired explicitly at the relay's explicit turn boundaries:
///  - `.turnCompleted` frame  → `notifyRelayTurnCompleted()` → `onTurnComplete`
///  - failed `.error` item    → `notifyRelayTurnDiscarded()` → `onTurnDiscarded`
///  - session switch mid-turn → write-gate move (`relayWriteGateMoved`) → `onTurnDiscarded`
///
/// Before the R16 fix NONE of these fired on the relay path, so the activity's
/// `startedAt` drove the lock-screen elapsed timer ENDLESSLY (owner's
/// "timer runs forever on the lock screen" complaint). These tests pin the
/// contract at the ChatStore seam (the coordinator's call into ChatStore),
/// which is exactly where ActivityKit's `end()` is ultimately reached via
/// `AppEnvironment`'s wiring.
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

    /// Seed a streaming relay turn (user prompt + in-progress assistant) so the
    /// Live Activity is started (`onTurnStart` fired, `turnStartedAt` set).
    private func seedStreamingTurn(_ chat: ChatStore) {
        var store = RelayItemStore()
        store.apply([
            itemFrame(1, kind: "item.completed", id: "user-1", .userMessage,
                      status: "completed", ord: 0, body: ["text": "hi"]),
            itemFrame(2, kind: "item.started", id: "msg-1", .agentMessage,
                      status: "in_progress", ord: 1, body: ["text": ""]),
        ])
        chat.applyRelayItems(store.items)
    }

    /// Settle the current relay turn (finalize the assistant message). The
    /// projection's streaming→settled edge clears `turnStartedAt`, so a
    /// subsequent `seedStreamingTurn` re-fires `onTurnStart` (a genuine new
    /// turn) rather than no-opping on the stale marker.
    private func settleCurrentTurn(_ chat: ChatStore) {
        var store = RelayItemStore()
        store.apply([
            itemFrame(1, kind: "item.completed", id: "user-1", .userMessage,
                      status: "completed", ord: 0, body: ["text": "hi"]),
            itemFrame(2, kind: "item.completed", id: "msg-1", .agentMessage,
                      status: "completed", ord: 1, body: ["text": "done"]),
        ])
        chat.applyRelayItems(store.items)
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
        XCTAssertTrue(ChatStore.hasRelayErrorTerminal([errItem]))
        XCTAssertTrue(ChatStore.hasRelayErrorTerminal([okItem, errItem]))
        XCTAssertFalse(ChatStore.hasRelayErrorTerminal([okItem]))
        XCTAssertFalse(ChatStore.hasRelayErrorTerminal([]))
        let inProgressErr = ChatItem(
            itemID: "e2", type: .error, status: .inProgress, ord: 1,
            body: ["text": "boom"]
        )
        XCTAssertFalse(ChatStore.hasRelayErrorTerminal([inProgressErr]),
                       "an in-progress .error item is not yet a turn-error terminal")
    }

    // MARK: - .turnCompleted fires onTurnComplete

    func testRelayTurnCompletedFiresOnTurnComplete() {
        let chat = ChatStore()
        var starts = 0
        var completions = 0
        var discards = 0
        chat.onTurnStart = { starts += 1 }
        chat.onTurnComplete = { completions += 1 }
        chat.onTurnDiscarded = { discards += 1 }

        seedStreamingTurn(chat)
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(starts, 1, "the first streaming projection starts the Live Activity")

        // The relay's .turnCompleted frame → coordinator → notifyRelayTurnCompleted.
        chat.notifyRelayTurnCompleted()

        XCTAssertEqual(completions, 1,
                       "relay .turnCompleted must fire onTurnComplete (R16) — the direct path's handleMessageComplete is never called on relay")
        XCTAssertEqual(discards, 0,
                       "a happy-path relay completion is never a discard")
    }

    // MARK: - Failed .error item fires onTurnDiscarded AND suppresses the trailing completion

    func testRelayErrorFiresDiscardAndSuppressesCompletion() {
        let chat = ChatStore()
        var completions = 0
        var discards = 0
        chat.onTurnComplete = { completions += 1 }
        chat.onTurnDiscarded = { discards += 1 }

        seedStreamingTurn(chat)
        XCTAssertTrue(chat.isStreaming)

        // A failed .error item arrives (coordinator → notifyRelayTurnDiscarded).
        chat.notifyRelayTurnDiscarded()
        XCTAssertEqual(discards, 1,
                       "an errored relay turn is a discard (parity with handleGatewayError)")
        XCTAssertEqual(completions, 0,
                       "the queue must not auto-drain into a session that just errored")

        // The relay emits .turnCompleted even for errored turns. It MUST NOT
        // fire a spurious completion (the latch suppresses it).
        chat.notifyRelayTurnCompleted()
        XCTAssertEqual(completions, 0,
                       "the trailing .turnCompleted after an error must NOT fire onTurnComplete")
        XCTAssertEqual(discards, 1)
    }

    // MARK: - The error latch does not leak into the NEXT turn

    func testRelayErrorLatchClearsOnNextTurnStart() {
        let chat = ChatStore()
        var completions = 0
        chat.onTurnComplete = { completions += 1 }

        seedStreamingTurn(chat)
        chat.notifyRelayTurnDiscarded()    // errored turn latches the suppression
        chat.notifyRelayTurnCompleted()    // suppressed
        XCTAssertEqual(completions, 0)

        // The errored turn settles (projection finalizes), clearing
        // `turnStartedAt` so the next turn's first streaming projection
        // re-fires `markTurnStartedIfNeeded` — which resets the latch.
        settleCurrentTurn(chat)
        // A NEW turn starts and completes normally.
        seedStreamingTurn(chat)
        chat.notifyRelayTurnCompleted()
        XCTAssertEqual(completions, 1,
                       "the next (healthy) turn's completion fires normally — the error latch cleared on turn start")
    }

    // MARK: - Session switch mid-turn discards the outgoing activity

    func testSessionSwitchDiscardsLiveRelayTurn() {
        let chat = ChatStore()
        var discards = 0
        chat.onTurnDiscarded = { discards += 1 }

        seedStreamingTurn(chat)
        XCTAssertTrue(chat.isStreaming)
        XCTAssertEqual(discards, 0, "no discard while the turn is live and projected")

        // R1 seam (contract I2): the write-gate MOVES to another session —
        // the outgoing session's Live Activity ends as a discard (it no
        // longer reflects what the user is looking at; its entry keeps
        // folding frames — nothing stream-side is torn down).
        chat.relayWriteGateMoved(toSession: "other-session", items: [])
        XCTAssertEqual(discards, 1,
                       "switching away mid-turn ends the outgoing Live Activity (R16/I2)")

        // Idempotent: the outgoing turn's chrome is already gone.
        chat.relayWriteGateMoved(toSession: "other-session", items: [])
        XCTAssertEqual(discards, 1, "the switch discard is idempotent")

        // And it's a no-op when no turn is live at all.
        let idle = ChatStore()
        var idleDiscards = 0
        idle.onTurnDiscarded = { idleDiscards += 1 }
        idle.relayWriteGateMoved(toSession: "other-session", items: [])
        XCTAssertEqual(idleDiscards, 0, "the switch discard is a no-op when nothing is streaming")
    }
}
