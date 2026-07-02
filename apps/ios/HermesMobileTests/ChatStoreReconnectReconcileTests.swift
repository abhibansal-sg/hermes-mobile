import XCTest
@testable import HermesMobile

/// ABH-276 + ABH-278 — reconnect reconcile ordering.
///
/// A mid-generation socket drop finalizes the visible assistant row with a
/// "Connection lost" warning. The reconnect path then has two races:
///  - REST backfill can return before the resumed server turn has persisted;
///  - resumed WS frames can arrive before/while that backfill is reconciling.
/// Both must treat the interrupted assistant row as the in-flight turn's
/// placeholder: do not evict it when REST is temporarily behind, and do not append
/// a second assistant bubble when the stream resumes.
@MainActor
final class ChatStoreReconnectReconcileTests: XCTestCase {

    private let activeRuntime = "rt-local-reconnect"
    private let storedId = "stored-session-reconnect"

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

    private func localFrame(type: String, payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(activeRuntime),
            "payload": payload,
        ]))!
    }

    private func storedMessage(role: String, text: String) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
        ]))!
    }

    private func beginLocalPartialTurn(_ chat: ChatStore) -> ChatMessage {
        chat.messages = [ChatMessage(role: .user, text: "prompt before drop")]
        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        chat.handle(event: localFrame(type: "message.delta", payload: ["text": "partial reply"] ))
        #if DEBUG
        chat.drainFlushForTesting()
        #endif
        return chat.messages.last(where: { $0.role == .assistant })!
    }

    private func warningTexts(in message: ChatMessage?) -> [String] {
        message?.parts.compactMap { part in
            if case .warning(_, let text) = part { return text }
            return nil
        } ?? []
    }

    func testBackfillBeforeResumedPersistencePreservesConnectionLostRow() async {
        let (chat, _) = makeStore { _ in
            // The server has not persisted the resumed/final assistant row yet.
            [self.storedMessage(role: "user", text: "prompt before drop")]
        }

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()

        guard let warningRow = chat.messages.first(where: { $0.id == interrupted.id }) else {
            return XCTFail("connection drop must leave the interrupted assistant row visible")
        }
        XCTAssertTrue(warningRow.text.contains("partial reply"))
        XCTAssertEqual(warningRow.warning, "Connection lost")

        await chat.backfill()
        await Task.yield()

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1,
                       "REST history that is temporarily behind must not evict the interrupted in-flight assistant row")
        XCTAssertEqual(assistantRows.first?.id, interrupted.id,
                       "the interrupted row keeps identity across the stale reconnect backfill")
        XCTAssertEqual(assistantRows.first?.warning, "Connection lost",
                       "the user-visible connection-loss warning must not vanish before the resumed turn settles")
    }

    func testResumedStreamReusesInterruptedRowInsteadOfAppendingDuplicateBubble() async {
        let (chat, _) = makeStore()

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1)

        // WS resumes before/around reconnect backfill. The resumed stream belongs
        // to the same interrupted server turn, so it must continue in the warning
        // row rather than append a fresh assistant bubble for one UI turn.
        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1,
                       "resumed WS start must reuse the interrupted assistant row, not spawn a duplicate bubble")
        XCTAssertEqual(chat.messages.last(where: { $0.role == .assistant })?.id, interrupted.id)
        XCTAssertTrue(chat.isStreaming)

        chat.handle(event: localFrame(type: "message.delta", payload: ["text": " resumed"] ))
        #if DEBUG
        chat.drainFlushForTesting()
        #endif
        chat.handle(event: localFrame(
            type: "message.complete",
            payload: ["text": "final reply after reconnect", "status": "completed"]
        ))

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows.first?.id, interrupted.id,
                       "the final resumed reply keeps the interrupted row's identity")
        XCTAssertTrue(assistantRows.first?.text.contains("final reply after reconnect") == true)
        XCTAssertFalse(assistantRows.first?.isStreaming ?? true)
    }

    func testCleanResumedCompletionClearsConnectionLostWarningPart() async {
        let (chat, _) = makeStore()

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()
        XCTAssertEqual(warningTexts(in: chat.messages.first(where: { $0.id == interrupted.id })), ["Connection lost"])

        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        chat.handle(event: localFrame(type: "message.complete", payload: [
            "text": "fully recovered reply",
            "status": "completed",
        ]))

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows.first?.id, interrupted.id)
        XCTAssertEqual(assistantRows.first?.text, "fully recovered reply")
        XCTAssertEqual(warningTexts(in: assistantRows.first), [],
                       "a clean completion for the reconciled resumed row must remove the stale connection-loss warning part")
    }

    func testFailedResumedCompletionKeepsWarningPart() async {
        let (chat, _) = makeStore()

        let interrupted = beginLocalPartialTurn(chat)
        chat.handleConnectionDrop()
        XCTAssertEqual(warningTexts(in: chat.messages.first(where: { $0.id == interrupted.id })), ["Connection lost"])

        chat.handle(event: localFrame(type: "message.start", payload: ["role": "assistant"]))
        chat.handle(event: localFrame(type: "message.complete", payload: [
            "text": "failed after reconnect",
            "status": "failed",
            "warning": "Agent failed after reconnect",
        ]))

        let assistantRows = chat.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows.first?.id, interrupted.id)
        XCTAssertEqual(assistantRows.first?.text, "failed after reconnect")
        XCTAssertFalse(assistantRows.first?.isStreaming ?? true)
        XCTAssertEqual(warningTexts(in: assistantRows.first), ["Agent failed after reconnect"],
                       "a failed/warning-bearing resumed completion must keep its warning part instead of clearing it as stale")
    }
}
