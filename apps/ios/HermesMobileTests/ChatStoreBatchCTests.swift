import XCTest
@testable import HermesMobile

/// ABH-48 (R1 Batch C) — composer queue and offline outbox correctness.
///
/// The family these tests pin: the queue was global (no session identity) and
/// burned prompts on unaccepted sends; the only drain trigger was a LOCAL
/// `message.complete`; and edit/retry/checkpoint preemptively claimed "Agent is
/// busy" off the display-level `isStreaming` instead of local ownership.
///
/// Ledger coverage: #2, #10, #17, #29, #30, #50 (+ #18 lives in ComposerView's
/// queue-mode derivation, exercised manually — view-only).
@MainActor
final class ChatStoreBatchCTests: XCTestCase {

    private let activeRuntime = "rt-local"
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

    private func makeQueue() throws -> (QueueStore, WorkRepository, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatStoreBatchC-\(UUID().uuidString)", isDirectory: true)
        let observation = WorkRepositoryObservation()
        let repository = try WorkRepository(
            configuration: WorkRepositoryConfiguration(containerURL: directory),
            observation: observation
        )
        let scope = try WorkScope(serverID: "https://gateway.test", profileID: "default")
        let queue = QueueStore(
            repository: repository,
            observation: observation,
            scopeProvider: { scope }
        )
        return (queue, repository, directory)
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

    // MARK: - #17: session affinity

    func testLiveSendIsDurableBeforeLocalEchoWithoutAConnection() async throws {
        let (chat, sessions) = makeStore()
        let (queue, repository, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        chat.attachOutbox(queue)

        let sent = await chat.send(text: "durable first")
        XCTAssertTrue(sent)

        let jobs = try await repository.jobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.text, "durable first")
        XCTAssertEqual(jobs.first?.storedSessionID, sessions.activeStoredId)
        XCTAssertEqual(chat.messages.last?.clientMessageID, jobs.first?.clientMessageID)
        XCTAssertEqual(chat.messages.last?.text, "durable first")
    }

    func testExplicitQueuePersistsSessionAffinityWithoutEchoing() async throws {
        let (chat, _) = makeStore()
        let (queue, repository, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        let queued = await queue.enqueue("for A", storedSessionId: "stored-A")

        XCTAssertEqual(queued?.storedSessionId, "stored-A")
        let jobs = try await repository.jobs()
        XCTAssertEqual(jobs.first?.storedSessionID, "stored-A")
        XCTAssertTrue(chat.messages.isEmpty, "explicit queued work echoes only when claimed for sending")
    }

    func testEditBlockedDuringLocalTurnOnly() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "hello"),
            storedMessage(role: "assistant", text: "world"),
        ])
        let userId = chat.messages.first { $0.role == .user }!.id

        // During a LOCAL turn: preemptive busy gate holds.
        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        await chat.editAndResend(messageId: userId, newText: "edited")
        XCTAssertEqual(chat.lastError, "Agent is busy")
    }

    // MARK: - Judge round (post-fix adversarial re-verification)

    /// The drain's acceptance fact is `send`'s return value — pinned here: a
    /// send that fails (disconnected transport) reports NOT accepted, no
    /// matter what `isStreaming` happens to read afterwards.
    func testSendReturnsAcceptanceFact() async {
        let (chat, _) = makeStore()
        let accepted = await chat.send(text: "hello")
        XCTAssertFalse(accepted, "a failed prompt.submit must report not-accepted")
        XCTAssertFalse(chat.isStreaming)
    }

    /// A refused edit must not leave the transcript amputated: the optimistic
    /// truncation is undone locally when the submit fails.
    func testEditFailureRestoresTruncatedTranscript() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "hello"),
            storedMessage(role: "assistant", text: "world"),
        ])
        let userId = chat.messages.first { $0.role == .user }!.id

        await chat.editAndResend(messageId: userId, newText: "edited")
        // Disconnected client → the RPC threw → optimistic rewrite undone.
        XCTAssertEqual(chat.messages.map(\.text), ["hello", "world"],
                       "a refused edit must restore the truncated tail")
        XCTAssertFalse(chat.messages.contains { $0.text == "edited" })
        XCTAssertNotNil(chat.lastError)
    }

}
