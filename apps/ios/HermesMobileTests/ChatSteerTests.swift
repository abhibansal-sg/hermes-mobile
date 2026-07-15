import XCTest
@testable import HermesMobile

/// Coverage for `ChatStore.steer(text:)` — the `session.steer` RPC path.
///
/// Key invariant being guarded: `steer()` MUST route to `interruptTarget`
/// (= `mirroringRuntimeId ?? activeSessionId`), NOT `activeSessionId` alone.
/// An adopted foreign mirror streams from its OWN runtime; targeting the local
/// session id would send the steer to the wrong (possibly idle) session — the
/// same class of bug that R1 #2 fixed for `interrupt()`.
///
/// All tests use the injectable `steerRPC` DEBUG seam so no live gateway or
/// custom transport is required. Pattern mirrors `ConnectionStoreReconnectTests`
/// (`connectRPC`) and `ChatStoreForeignMirrorTests` (foreign-frame injection).
@MainActor
final class ChatSteerTests: XCTestCase {

    private let localRuntime  = "rt-local"
    private let foreignRuntime = "rt-foreign"
    private let storedId = "stored-session-1"

    /// Build a wired store graph with an active local session.
    private func makeStore() -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeRuntimeId = localRuntime
        sessions.activeStoredId = storedId
        chat.backfillFetch = { _ in [] }
        return (chat, sessions)
    }

    /// A broadcast `message.start` frame from a foreign runtime on the same
    /// stored session — triggers `handleForeignFrame` adoption of `foreignRuntime`,
    /// setting `mirroringRuntimeId = foreignRuntime` (and thus
    /// `interruptTarget = foreignRuntime` per R1 #2).
    private func adoptForeignMirror(chat: ChatStore) {
        chat.handle(event: GatewayEvent(params: .object([
            "type": .string("message.start"),
            "session_id": .string(foreignRuntime),
            "stored_session_id": .string(storedId),
            "payload": .object(["role": .string("assistant")]),
        ]))!)
    }

    // MARK: - Routing: interruptTarget (load-bearing R1 #2 mirror)

    /// LOAD-BEARING: when a foreign mirror is adopted, `steer()` MUST target
    /// the mirror's runtime, NOT the local session id.
    func testSteerRoutesToInterruptTargetWhenMirrorAdopted() async {
        let (chat, _) = makeStore()

        // Adopt the foreign mirror — sets mirroringRuntimeId = foreignRuntime,
        // so interruptTarget == foreignRuntime (not localRuntime).
        adoptForeignMirror(chat: chat)
        XCTAssertEqual(chat.interruptTarget, foreignRuntime,
                       "precondition: mirror adoption sets interruptTarget to foreign runtime")

        var capturedSessionId: String?
        chat.steerRPC = { sessionId, _ in
            capturedSessionId = sessionId
            return ChatStore.SessionSteerResponse(status: "queued", text: nil)
        }

        _ = await chat.steer(text: "redirect the turn")

        XCTAssertEqual(capturedSessionId, foreignRuntime,
                       "steer MUST target the mirror's runtime (interruptTarget), not localRuntime")
    }

    /// Without a mirror, `steer()` targets the local `activeSessionId`.
    func testSteerRoutesToActiveSessionIdWhenNoMirror() async {
        let (chat, _) = makeStore()

        var capturedSessionId: String?
        chat.steerRPC = { sessionId, _ in
            capturedSessionId = sessionId
            return ChatStore.SessionSteerResponse(status: "queued", text: nil)
        }

        _ = await chat.steer(text: "go faster")

        XCTAssertEqual(capturedSessionId, localRuntime,
                       "without a mirror, steer targets the local active session id")
    }

    // MARK: - Outcome mapping

    func testSteerQueuedOutcome() async {
        let (chat, _) = makeStore()
        chat.steerRPC = { _, _ in
            ChatStore.SessionSteerResponse(status: "queued", text: nil)
        }

        let outcome = await chat.steer(text: "pivot now")

        XCTAssertEqual(outcome, .queued)
        XCTAssertNil(chat.lastError, "a queued steer must not set lastError")
    }

    func testSteerRejectedOutcomePreservesNoLastError() async {
        let (chat, _) = makeStore()
        chat.steerRPC = { _, _ in
            ChatStore.SessionSteerResponse(status: "rejected", text: "turn completing")
        }

        let outcome = await chat.steer(text: "try to steer")

        XCTAssertEqual(outcome, .rejected)
        XCTAssertNil(chat.lastError, "a rejected steer (gateway soft-decline) must not set lastError")
    }

    func testSteerUnknownStatusTreatedAsRejected() async {
        // Defensive: an unrecognised status from a future gateway version must
        // not crash or succeed silently — treat as a soft rejection.
        let (chat, _) = makeStore()
        chat.steerRPC = { _, _ in
            ChatStore.SessionSteerResponse(status: "pending_future_feature", text: nil)
        }

        let outcome = await chat.steer(text: "hello")

        XCTAssertEqual(outcome, .rejected,
                       "unknown status → defensive .rejected (not .queued or .error)")
    }

    // MARK: - Empty text short-circuit

    func testSteerEmptyTextReturnsRejectedWithoutRPC() async {
        let (chat, _) = makeStore()

        var rpcCalled = false
        chat.steerRPC = { _, _ in
            rpcCalled = true
            return ChatStore.SessionSteerResponse(status: "queued", text: nil)
        }

        let outcome = await chat.steer(text: "   ")

        XCTAssertEqual(outcome, .rejected,
                       "empty/whitespace text must return .rejected without calling the RPC")
        XCTAssertFalse(rpcCalled, "steerRPC must NOT be called for empty text")
    }

    // MARK: - RPC error sets lastError

    func testSteerRPCErrorSetsLastError() async {
        let (chat, _) = makeStore()
        chat.steerRPC = { _, _ in
            throw GatewayError.rpc(code: 4009, message: "session busy")
        }

        let outcome = await chat.steer(text: "steer during busy")

        if case .error(let msg) = outcome {
            XCTAssertTrue(msg.contains("4009") || msg.contains("busy"),
                          "error message should reference the gateway error: \(msg)")
        } else {
            XCTFail("expected .error outcome, got \(outcome)")
        }
        XCTAssertNotNil(chat.lastError, "a gateway RPC error must set lastError")
    }
}
