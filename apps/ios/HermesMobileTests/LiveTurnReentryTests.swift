import XCTest
@testable import HermesMobile

/// ABH-371 — live re-entry.
///
/// A stored transcript seed is not enough to decide the UI is idle: a session can
/// be resumed while its runtime is already running. Re-entry must reconcile
/// against the live `session.status`, restore the in-flight chat affordances, and
/// avoid showing completed-turn action rows while the runtime is still working.
@MainActor
final class LiveTurnReentryTests: XCTestCase {
    private let storedId = "stored-live-reentry"
    private let runtimeId = "rt-live-reentry"

    private func makeStore() -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.activeStoredId = storedId
        sessions.activeRuntimeId = runtimeId
        return (chat, sessions)
    }

    private func storedMessage(role: String, text: String) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
        ]))!
    }

    private func status(running: Bool) -> SessionStatusResult {
        JSONValue.object(["running": .bool(running)]).decoded(as: SessionStatusResult.self)!
    }

    private func openResult(runtimeId: String, storedId: String) -> SessionOpenResult {
        JSONValue.object([
            "session_id": .string(runtimeId),
            "resumed": .string(storedId),
        ]).decoded(as: SessionOpenResult.self)!
    }

    private func summary(id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            title: "Live re-entry",
            preview: "previous reply",
            startedAt: 0,
            messageCount: 2,
            source: "cli",
            lastActive: 0,
            cwd: nil
        )
    }

    func testStatusRunningRestoresStreamingPlaceholderStopStateAndActionGate() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "previous prompt"),
            storedMessage(role: "assistant", text: "previous reply"),
        ])
        XCTAssertFalse(chat.isStreaming)
        XCTAssertTrue(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: true,
            assistantTurnActionsEnabled: !chat.isStreaming
        ))

        var requestedRuntime: String?
        chat.liveTurnStatusFetch = { runtime in
            requestedRuntime = runtime
            return self.status(running: true)
        }

        await chat.reconcileLiveTurnStatus(runtimeId: runtimeId)

        XCTAssertEqual(requestedRuntime, runtimeId)
        XCTAssertTrue(chat.isStreaming, "live re-entry must show an in-progress turn, not a settled transcript")
        XCTAssertTrue(chat.localTurnInFlight, "live re-entry is owned by the active runtime, so mutable actions stay disabled")
        XCTAssertEqual(chat.interruptTarget, runtimeId, "Stop must target the resumed runtime")
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 2)
        XCTAssertTrue(chat.messages.last?.isStreaming == true, "a working placeholder/cursor is appended at the transcript tail")
        XCTAssertFalse(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: true,
            assistantTurnActionsEnabled: !chat.isStreaming
        ), "completed-turn rows are suppressed while the live runtime is still working")
    }

    func testStatusIdleDoesNotInventAStreamingTurn() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "previous prompt"),
            storedMessage(role: "assistant", text: "previous reply"),
        ])
        chat.liveTurnStatusFetch = { _ in self.status(running: false) }

        await chat.reconcileLiveTurnStatus(runtimeId: runtimeId)

        XCTAssertFalse(chat.isStreaming)
        XCTAssertFalse(chat.localTurnInFlight)
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: true,
            assistantTurnActionsEnabled: !chat.isStreaming
        ))
    }

    func testOpenWaitsForSeedThenRestoresLiveStatus() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.resumeRPC = { [runtimeId, storedId] requested, _ in
            XCTAssertEqual(requested, storedId)
            return self.openResult(runtimeId: runtimeId, storedId: storedId)
        }
        sessions.transcriptFetch = { [storedId] requested in
            XCTAssertEqual(requested, storedId)
            return [
                self.storedMessage(role: "user", text: "previous prompt"),
                self.storedMessage(role: "assistant", text: "previous reply"),
            ]
        }
        chat.liveTurnStatusFetch = { [runtimeId] requested in
            XCTAssertEqual(requested, runtimeId)
            XCTAssertEqual(chat.messages.map(\.text), ["previous prompt", "previous reply"],
                           "live status reconcile should run after the transcript seed has landed")
            return self.status(running: true)
        }
        var streamingWhenRuntimeBound: Bool?
        sessions.onActiveRuntimeBound = { streamingWhenRuntimeBound = chat.isStreaming }

        sessions.open(summary(id: storedId))
        #if DEBUG
        await sessions.waitForPendingOpenForTesting()
        #endif

        XCTAssertEqual(sessions.activeRuntimeId, runtimeId)
        XCTAssertTrue(chat.isStreaming)
        XCTAssertTrue(chat.localTurnInFlight)
        XCTAssertEqual(streamingWhenRuntimeBound, true,
                       "the runtime-bound queue drain must see restored busy state, not the pre-status idle gap")
        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant, .assistant])
        XCTAssertTrue(chat.messages.last?.isStreaming == true)
    }
}
