import XCTest
@testable import HermesMobile

/// Coverage for `ChatStore.steer(text:)` — the `session.steer` RPC path.
///
/// All tests use the injectable `steerRPC` DEBUG seam so no live gateway or
/// custom transport is required.
@MainActor
final class ChatSteerTests: XCTestCase {

    private let localRuntime  = "rt-local"
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

    /// Steer targets the selected active runtime.
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
