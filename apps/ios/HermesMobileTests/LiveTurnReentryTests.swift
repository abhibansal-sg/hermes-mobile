import XCTest
@testable import HermesMobile

/// ABH-371 — live re-entry.
///
/// A stored transcript seed is not enough to decide the UI is idle: a session can
/// be resumed while its runtime is already running. Re-entry consumes the stock
/// resume snapshot, restores the in-flight chat affordances, and avoids showing
/// completed-turn action rows while the runtime is still working.
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

    private func openResult(
        runtimeId: String,
        storedId: String,
        running: Bool? = nil,
        inflight: JSONValue? = nil
    ) -> SessionOpenResult {
        var payload: [String: JSONValue] = [
            "session_id": .string(runtimeId),
            "resumed": .string(storedId),
        ]
        if let running { payload["running"] = .bool(running) }
        if let inflight { payload["inflight"] = inflight }
        return JSONValue.object(payload).decoded(as: SessionOpenResult.self)!
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

    /// Regression (Lane B): a SETTLED assistant turn with NO rendered `.text` part
    /// — a tool-only / reasoning-only / error-only turn — must STILL expose the
    /// turn-level actions (retry / undo / branch). The old always-attached
    /// whole-bubble context menu guaranteed this; after the text-selection fix
    /// moved actions into the gated inline row, a text-less turn would otherwise
    /// show no affordance at all. The row must appear whenever there is prose to
    /// act on OR at least one turn-level action, and be suppressed only while
    /// streaming or when the chat-level gate is closed.
    func testActionRowStaysReachableOnTextlessSettledTurn() {
        // Text-less settled turn, but retry/undo/branch exist → row shows.
        XCTAssertTrue(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: false,
            hasTurnActions: true,
            assistantTurnActionsEnabled: true
        ), "a tool-only / error-only settled turn must keep its retry/undo/branch affordance")

        // Text-less settled turn with NO turn-level actions → nothing to show.
        XCTAssertFalse(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: false,
            hasTurnActions: false,
            assistantTurnActionsEnabled: true
        ), "with neither prose nor turn actions the row is empty and must stay hidden")

        // Rendered prose alone still shows the row even without turn actions.
        XCTAssertTrue(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: true,
            hasTurnActions: false,
            assistantTurnActionsEnabled: true
        ), "a normal prose turn shows copy/share even when retry/undo/branch are absent")

        // Streaming and the closed chat-level gate both suppress the row regardless.
        XCTAssertFalse(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: true,
            hasRenderedText: true,
            hasTurnActions: true,
            assistantTurnActionsEnabled: true
        ), "a streaming turn never shows the end-of-turn row")
        XCTAssertFalse(MessageBubble.shouldShowAssistantActionRow(
            messageIsStreaming: false,
            hasRenderedText: true,
            hasTurnActions: true,
            assistantTurnActionsEnabled: false
        ), "the closed chat-level gate suppresses the row while the runtime works")
    }

    func testResumeSnapshotRestoresPartialTurnWithoutStatusRoundTrip() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "previous prompt"),
            storedMessage(role: "assistant", text: "previous reply"),
        ])
        await chat.reconcileLiveTurnStatus(
            runtimeId: runtimeId,
            snapshotRunning: true,
            inflight: SessionInflightTurn(
                user: "write a long answer",
                assistant: "partial answer",
                streaming: true
            )
        )

        XCTAssertEqual(chat.messages.suffix(2).map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.messages.suffix(2).map(\.text), ["write a long answer", "partial answer"])
        XCTAssertTrue(chat.messages.last?.isStreaming == true)
        XCTAssertTrue(chat.localTurnInFlight)
        XCTAssertEqual(chat.interruptTarget, runtimeId)
    }

    func testRepeatResumeSnapshotDoesNotDuplicateInflightPrompt() async {
        // Regression: reconcileLiveTurnStatus runs once at open and again on every
        // reconnect-recovery resume for the same running turn. The prompt bubble
        // must not multiply across repeat reconciles of one inflight turn.
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "previous prompt"),
            storedMessage(role: "assistant", text: "previous reply"),
        ])
        let inflight = SessionInflightTurn(
            user: "write a long answer",
            assistant: "partial answer",
            streaming: true
        )

        for _ in 0..<3 {
            await chat.reconcileLiveTurnStatus(
                runtimeId: runtimeId,
                snapshotRunning: true,
                inflight: inflight
            )
        }

        XCTAssertEqual(
            chat.messages.map(\.role),
            [.user, .assistant, .user, .assistant],
            "repeat reconciles of the same inflight turn must not append duplicate prompt bubbles"
        )
        XCTAssertEqual(chat.messages.filter { $0.role == .user && $0.text == "write a long answer" }.count, 1)
        XCTAssertTrue(chat.messages.last?.isStreaming == true)
        XCTAssertTrue(chat.localTurnInFlight)
        XCTAssertEqual(chat.interruptTarget, runtimeId)
    }

    func testOpenWaitsForSeedThenRestoresResumeSnapshot() async {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.resumeRPC = { [runtimeId, storedId] requested, _ in
            XCTAssertEqual(requested, storedId)
            return self.openResult(
                runtimeId: runtimeId,
                storedId: storedId,
                running: true,
                inflight: .object([
                    "user": .string("current prompt"),
                    "assistant": .string("partial answer"),
                    "streaming": .bool(true),
                ])
            )
        }
        sessions.transcriptFetch = { [storedId] requested in
            XCTAssertEqual(requested, storedId)
            return [
                self.storedMessage(role: "user", text: "previous prompt"),
                self.storedMessage(role: "assistant", text: "previous reply"),
            ]
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
        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(chat.messages.suffix(2).map(\.text), ["current prompt", "partial answer"])
        XCTAssertTrue(chat.messages.last?.isStreaming == true)
    }
}
