import XCTest
@testable import HermesMobile

/// ABH-48 (R1 Batch C) — composer queue, foreign mirror, and offline outbox
/// correctness.
///
/// The family these tests pin: the queue was global (no session identity) and
/// burned prompts on unaccepted sends; the only drain trigger was a LOCAL
/// `message.complete`; STOP targeted the local runtime even when the visible
/// stream was an adopted foreign mirror; and edit/retry/checkpoint preemptively
/// claimed "Agent is busy" off the display-level `isStreaming` instead of
/// local ownership.
///
/// Ledger coverage: #2, #10, #17, #29, #30, #50 (+ #18 lives in ComposerView's
/// queue-mode derivation, exercised manually — view-only).
@MainActor
final class ChatStoreBatchCTests: XCTestCase {

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

    // MARK: - #29: foreign complete is a turn completion (drain trigger)

    func testForeignCompleteFiresTurnCompleteAfterReconcile() async {
        let (chat, _) = makeStore { _ in
            [self.storedMessage(role: "assistant", text: "mirror reconciled")]
        }
        var transcriptAtTrigger: [String]?
        chat.onTurnComplete = { transcriptAtTrigger = chat.messages.map(\.text) }

        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))
        XCTAssertTrue(chat.isStreaming, "foreign turn adopted")
        chat.handle(event: frame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: .object(["text": .string("done")])
        ))
        // Deterministic drain: await the foreign-complete backfill Task — onTurnComplete
        // fires AFTER the reconcile inside that Task.
        #if DEBUG
        await chat.waitForPendingForeignBackfillForTesting()
        #else
        await settle()
        #endif

        XCTAssertEqual(
            transcriptAtTrigger, ["mirror reconciled"],
            "onTurnComplete must fire for a foreign complete — and only AFTER "
            + "the backfill reconcile, so a drained prompt can't race the seed"
        )
    }

    // MARK: - #2: STOP routes to the runtime that owns the visible stream

    func testInterruptTargetsForeignRuntimeWhileMirroring() async {
        let (chat, _) = makeStore()
        XCTAssertEqual(chat.interruptTarget, activeRuntime, "idle: local runtime")

        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))
        XCTAssertEqual(chat.interruptTarget, foreignRuntime,
                       "an adopted mirror is stopped at its OWN runtime")

        chat.handleConnectionDrop()
        XCTAssertEqual(chat.interruptTarget, activeRuntime,
                       "after teardown, STOP targets the local runtime again")
    }

    // MARK: - #30: edit/retry/checkpoint gate on ownership, not mirror state

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

    func testEditNotPreemptivelyBlockedDuringForeignMirror() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "hello"),
            storedMessage(role: "assistant", text: "world"),
        ])
        let userId = chat.messages.first { $0.role == .user }!.id

        // Adopt a foreign mirror: user owns no local turn.
        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))
        XCTAssertTrue(chat.isStreaming)

        await chat.editAndResend(messageId: userId, newText: "edited")

        // The ownership gate let the attempt through — whatever the
        // (disconnected) transport said, it was NOT the client-side
        // preemptive "Agent is busy" heuristic.
        XCTAssertNotEqual(chat.lastError, "Agent is busy",
                          "a foreign mirror must not preemptively block edit")
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

    /// Same restore, while a foreign mirror is live — the case where a
    /// backfill-based restore would be discarded by its own `!isStreaming`
    /// post-await guard. The local undo is seed-free, so it works regardless.
    func testEditFailureDuringForeignMirrorRestoresTranscript() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "hello"),
            storedMessage(role: "assistant", text: "world"),
        ])
        let userId = chat.messages.first { $0.role == .user }!.id
        let before = chat.messages.map(\.text)

        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))

        await chat.editAndResend(messageId: userId, newText: "edited")

        XCTAssertEqual(chat.messages.map(\.text).prefix(before.count).map { $0 },
                       before,
                       "the truncated tail must be restored in place")
        XCTAssertFalse(chat.messages.contains { $0.text == "edited" })
    }

    func testCheckpointNotPreemptivelyBlockedDuringForeignMirror() async {
        let (chat, _) = makeStore()
        chat.seed(from: [
            storedMessage(role: "user", text: "hello"),
            storedMessage(role: "assistant", text: "world"),
        ])
        let userId = chat.messages.first { $0.role == .user }!.id

        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))

        await chat.restoreCheckpoint(toUserMessageId: userId)

        XCTAssertNotEqual(chat.lastError, "Agent is busy")
    }
}
