import XCTest
@testable import HermesMobile

/// ABH-49 (R1 Batch D, iOS half) — the ChatStore seam that keeps the Live
/// Activity in lockstep with the rendered turn.
///
/// `LiveActivityManager` itself is ActivityKit-bound (activities are disabled
/// in the test runner, so `start()` no-ops by design); what IS unit-testable
/// is the new `onTurnDiscarded` seam: every path that tears down a rendered
/// turn WITHOUT a completion must fire it, because before this seam only
/// `message.complete` ended the activity and every discard path orphaned it
/// on the Dynamic Island (R1 #26, #73).
@MainActor
final class ChatStoreBatchDTests: XCTestCase {

    private let activeRuntime = "rt-local"
    private let foreignRuntime = "rt-foreign"
    private let storedId = "stored-session-1"

    private func makeStore(
        backfill: @escaping (String) async throws -> [StoredMessage] = { _ in [] }
    ) -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = activeRuntime
        sessions.activeStoredId = storedId
        chat.backfillFetch = backfill
        return (chat, sessions)
    }

    private func frame(
        type: String,
        runtime: String,
        stored: String? = nil,
        payload: JSONValue = .null
    ) -> GatewayEvent {
        var params: [String: JSONValue] = [
            "type": .string(type),
            "session_id": .string(runtime),
            "payload": payload,
        ]
        if let stored { params["stored_session_id"] = .string(stored) }
        return GatewayEvent(params: .object(params))!
    }

    private func storedMessage(role: String, text: String) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
        ]))!
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    // MARK: - #26: connection drop discards the turn's activity

    func testConnectionDropFiresTurnDiscardedForLocalTurn() async {
        let (chat, _) = makeStore()
        var discards = 0
        chat.onTurnDiscarded = { discards += 1 }

        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        XCTAssertTrue(chat.isStreaming)

        chat.handleConnectionDrop()

        XCTAssertGreaterThanOrEqual(discards, 1,
                                    "a dropped local turn must end its Live Activity")
        XCTAssertFalse(chat.isStreaming)
    }

    func testConnectionDropFiresTurnDiscardedForForeignMirror() async {
        let (chat, _) = makeStore()
        var discards = 0
        chat.onTurnDiscarded = { discards += 1 }

        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))
        XCTAssertTrue(chat.isStreaming, "foreign mirror adopted (it owns an LA too)")

        chat.handleConnectionDrop()

        XCTAssertGreaterThanOrEqual(discards, 1,
                                    "the foreign-only drop path bypasses cancelStreaming "
                                    + "and must fire the discard seam itself")
    }

    // MARK: - #73: session switch / draft discards the turn's activity

    func testResetFiresTurnDiscarded() async {
        let (chat, _) = makeStore()
        var discards = 0
        chat.onTurnDiscarded = { discards += 1 }

        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        chat.reset()  // open()/startDraft()/clearActive() all route here

        XCTAssertGreaterThanOrEqual(discards, 1,
                                    "switching away mid-turn must end the activity")
    }

    // MARK: - Judge round: the `.error` terminal must end the activity too

    func testGatewayErrorFiresTurnDiscarded() async {
        let (chat, _) = makeStore()
        var discards = 0
        var completions = 0
        chat.onTurnDiscarded = { discards += 1 }
        chat.onTurnComplete = { completions += 1 }

        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        chat.handle(event: frame(
            type: "error", runtime: activeRuntime,
            payload: .object(["message": .string("agent crashed")])
        ))

        XCTAssertFalse(chat.isStreaming)
        XCTAssertGreaterThanOrEqual(
            discards, 1,
            "the error terminal was the one turn-ending path with no LA seam — "
            + "the orphaned activity froze on 'Thinking' and the next turn reused it"
        )
        XCTAssertEqual(completions, 0,
                       "an errored turn is a discard, not a completion — the queue "
                       + "must not auto-drain into a session that just errored")
    }

    // MARK: - Foreign reconcile path: discard AND completion both fire

    func testForeignCompleteReconcileFiresDiscardAndCompletion() async {
        let (chat, _) = makeStore { _ in
            [self.storedMessage(role: "assistant", text: "reconciled")]
        }
        var discards = 0
        var completions = 0
        chat.onTurnDiscarded = { discards += 1 }
        chat.onTurnComplete = { completions += 1 }

        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))
        chat.handle(event: frame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: .object(["text": .string("done")])
        ))
        // Deterministic drain: await the foreign-complete backfill Task so the
        // reconcile seed fires onTurnDiscarded + onTurnComplete.
        #if DEBUG
        await chat.waitForPendingForeignBackfillForTesting()
        #else
        await settle()
        #endif

        // The reconcile seed's cancelStreaming fires the discard, and the
        // Batch C foreign-complete trigger fires the completion — both routes
        // to LiveActivityManager.end(), which is idempotent.
        XCTAssertGreaterThanOrEqual(discards, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(chat.messages.map(\.text), ["reconciled"])
    }
}
