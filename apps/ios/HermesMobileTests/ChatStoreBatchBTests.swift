import XCTest
@testable import HermesMobile

/// ABH-47 (R1 Batch B) — ChatStore streaming-ownership and backfill races.
///
/// The family these tests pin: `backfill()`/`seed()` lacked post-await
/// re-checks (active stored id, local-turn ownership, foreign-mirror
/// adoption), nothing cleared a wedged `isStreaming` on a transport drop, and
/// pending prompt cards outlived the turns they belonged to. Each test drives
/// `ChatStore.handle` with synthetic frames and injects `backfillFetch` /
/// `transcriptFetch` so no live gateway is required (mirrors
/// `ChatStoreForeignMirrorTests`).
///
/// Ledger coverage: #9, #12, #21, #28, #42, #43, #51, #52, #61, #79.
@MainActor
final class ChatStoreBatchBTests: XCTestCase {

    private let activeRuntime = "rt-local"
    private let foreignRuntime = "rt-foreign"
    private let storedId = "stored-session-1"

    /// Build a wired ChatStore whose active session points at `activeRuntime` /
    /// `storedId`, with an injectable backfill fetch.
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

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, title: nil, preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
    }

    private func pendingApprovalFixture(sessionId: String) -> PendingApproval {
        PendingApproval(
            id: "ap-1",
            sessionId: sessionId,
            request: ApprovalRequestPayload(payload: .object([
                "id": .string("ap-1"),
                "title": .string("Run a command"),
            ]))
        )
    }

    private func pendingClarificationFixture(sessionId: String) -> PendingClarification {
        PendingClarification(
            sessionId: sessionId,
            request: ClarifyRequestPayload(payload: .object([
                "question": .string("Which one?"),
                "request_id": .string("cl-1"),
            ]))
        )
    }

    /// Spin the run loop briefly so the 40ms coalescing flush and detached
    /// Tasks can run.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// A `backfillFetch`/`transcriptFetch` that suspends until released,
    /// so the test can interleave events "during the REST await".
    private final class Gate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    cont.resume()
                    return
                }
                continuation = cont
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            released = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume()
        }
    }

    // MARK: - #12: local turn started during the backfill fetch survives

    func testBackfillDiscardsStaleResultWhenLocalTurnStartsDuringFetch() async {
        let gate = Gate()
        let (chat, _) = makeStore { _ in
            await gate.wait()
            return [self.storedMessage(role: "assistant", text: "STALE HISTORY")]
        }

        let backfillTask = Task { await chat.backfill() }
        // Let the backfillTask start and reach gate.wait() before we handle
        // local frames. The Gate is race-safe (released=true flag handles early
        // release), so a yield is sufficient to give backfill a scheduling slot.
        await Task.yield()

        // The user starts a local turn while the fetch is in flight.
        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        chat.handle(event: frame(
            type: "message.delta", runtime: activeRuntime,
            payload: .object(["text": .string("live local reply")])
        ))
        XCTAssertTrue(chat.isStreaming)

        gate.release()
        await backfillTask.value
        // One yield so any MainActor mutations from the completed task propagate.
        await Task.yield()

        // The stale fetch result was dropped: the live local turn is intact.
        XCTAssertTrue(chat.isStreaming, "stale seed must not cancel the live local turn")
        XCTAssertFalse(
            chat.messages.contains { $0.text.contains("STALE HISTORY") },
            "stale fetch result must be discarded, not seeded"
        )
        XCTAssertEqual(chat.transcriptGeneration, 0)
    }

    // MARK: - #21: session switched during the backfill fetch

    func testBackfillDiscardsStaleResultAfterSessionSwitch() async {
        let gate = Gate()
        let (chat, sessions) = makeStore { _ in
            await gate.wait()
            return [self.storedMessage(role: "assistant", text: "SESSION A HISTORY")]
        }

        let backfillTask = Task { await chat.backfill() }
        // Let the backfillTask reach gate.wait() before switching sessions.
        // Gate is race-safe; a yield gives the task a scheduling slot.
        await Task.yield()

        // The user switches sessions while session A's fetch is in flight.
        sessions.activeStoredId = "stored-session-2"

        gate.release()
        await backfillTask.value
        // Yield so MainActor mutations from the completed task propagate.
        await Task.yield()

        XCTAssertTrue(chat.messages.isEmpty, "A's stale history must not seed over B")
        XCTAssertEqual(chat.transcriptGeneration, 0)
        XCTAssertNil(chat.lastBackfillError)
    }

    /// The catch-side twin: a FAILED fetch from a superseded session must not
    /// surface its error on the new session.
    func testBackfillFailureFromSupersededSessionIsNotSurfaced() async {
        let gate = Gate()
        let (chat, sessions) = makeStore { _ in
            await gate.wait()
            throw URLError(.timedOut)
        }

        let backfillTask = Task { await chat.backfill() }
        // Yield so the backfillTask reaches gate.wait(); Gate is race-safe.
        await Task.yield()
        sessions.activeStoredId = "stored-session-2"
        gate.release()
        await backfillTask.value

        XCTAssertNil(chat.lastBackfillError, "a superseded fetch's failure is not ours")
    }

    // MARK: - #51: reconcile backfill expires stale prompt cards

    func testBackfillSeedExpiresStalePromptCards() async {
        let (chat, _) = makeStore { _ in
            [self.storedMessage(role: "assistant", text: "reconciled")]
        }
        var approvalChanges: [Bool] = []
        chat.onApprovalChange = { approvalChanges.append($0) }
        chat.pendingApproval = pendingApprovalFixture(sessionId: foreignRuntime)
        chat.pendingClarification = pendingClarificationFixture(sessionId: foreignRuntime)

        await chat.backfill()

        XCTAssertNil(chat.pendingApproval, "post-reconcile approval card is stale")
        XCTAssertNil(chat.pendingClarification, "post-reconcile clarify card is stale")
        XCTAssertEqual(approvalChanges, [false], "the badge/widget hook must observe the expiry")
        XCTAssertEqual(chat.messages.map(\.text), ["reconciled"])
    }

    // MARK: - #52: local message.complete expires prompt cards

    func testMessageCompleteExpiresPromptCards() async {
        let (chat, _) = makeStore()
        var approvalChanges: [Bool] = []
        chat.onApprovalChange = { approvalChanges.append($0) }

        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        chat.pendingApproval = pendingApprovalFixture(sessionId: activeRuntime)
        chat.pendingClarification = pendingClarificationFixture(sessionId: activeRuntime)

        chat.handle(event: frame(
            type: "message.complete", runtime: activeRuntime,
            payload: .object(["text": .string("done"), "status": .string("completed")])
        ))

        XCTAssertFalse(chat.isStreaming)
        XCTAssertNil(chat.pendingApproval, "the turn ended — its approval card is stale")
        XCTAssertNil(chat.pendingClarification, "the turn ended — its clarify card is stale")
        XCTAssertEqual(approvalChanges, [false])
    }

    // MARK: - #9: connection drop finalizes a wedged local turn

    func testConnectionDropFinalizesLocalTurnSoBackfillCanRun() async {
        let (chat, _) = makeStore { _ in
            [
                self.storedMessage(role: "user", text: "prompt"),
                self.storedMessage(role: "assistant", text: "authoritative reply"),
            ]
        }

        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        chat.handle(event: frame(
            type: "message.delta", runtime: activeRuntime,
            payload: .object(["text": .string("half a reply…")])
        ))
        // Deterministic drain: flush the 40ms coalescing buffer so the delta
        // lands; isStreaming is already set synchronously by message.start.
        #if DEBUG
        chat.drainFlushForTesting()
        #else
        await settle()
        #endif
        XCTAssertTrue(chat.isStreaming)

        // The transport drops mid-turn (server restart / network loss).
        chat.handleConnectionDrop()

        XCTAssertFalse(chat.isStreaming, "a dead socket can never deliver the completion")
        let finalized = chat.messages.last
        XCTAssertEqual(finalized?.isStreaming, false)
        XCTAssertEqual(finalized?.warning, "Connection lost")

        // The post-reconnect recovery backfill is no longer no-op'd (#9).
        await chat.backfill()
        XCTAssertEqual(chat.messages.map(\.text), ["prompt", "authoritative reply"])
        XCTAssertEqual(chat.transcriptGeneration, 1)
    }

    func testConnectionDropIsIdempotentWhenIdle() async {
        let (chat, _) = makeStore()
        chat.handleConnectionDrop()
        chat.handleConnectionDrop()
        XCTAssertFalse(chat.isStreaming)
        XCTAssertTrue(chat.messages.isEmpty)
    }

    // MARK: - #42: connection drop clears an adopted foreign mirror

    func testConnectionDropClearsAdoptedForeignMirror() async {
        let (chat, _) = makeStore { _ in
            [self.storedMessage(role: "assistant", text: "mirror reconciled")]
        }

        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))
        XCTAssertTrue(chat.isStreaming, "foreign turn adopted")

        chat.handleConnectionDrop()
        XCTAssertFalse(chat.isStreaming, "the mirror died with its transport")

        // The reconnect backfill reconciles instead of no-op'ing (#42).
        await chat.backfill()
        XCTAssertEqual(chat.messages.map(\.text), ["mirror reconciled"])
    }

    // MARK: - #61: a stale seed must not wipe a live foreign mirror

    func testSeedBailsWhileForeignMirrorIsLive() async {
        let (chat, _) = makeStore()

        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))
        chat.handle(event: frame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: .object(["text": .string("live mirror text")])
        ))
        // Deterministic drain: flush the 40ms coalescing buffer so the foreign
        // delta's text lands before sampling the state.
        #if DEBUG
        chat.drainFlushForTesting()
        #else
        await settle()
        #endif
        XCTAssertTrue(chat.isStreaming)
        let generationBefore = chat.transcriptGeneration
        let messagesBefore = chat.messages.map(\.text)

        // A slow open()-path REST seed lands while the mirror is live.
        chat.seed(from: [storedMessage(role: "assistant", text: "STALE SEED")])

        XCTAssertTrue(chat.isStreaming, "the live mirror must keep streaming")
        XCTAssertEqual(chat.transcriptGeneration, generationBefore)
        XCTAssertEqual(chat.messages.map(\.text), messagesBefore,
                       "the stale seed must not replace the live mirror's transcript")
    }

    // MARK: - #28/#43: superseded open() seeds are dropped (token re-check)

    func testSupersededOpenSeedDoesNotClobberNewerSession() async {
        let (chat, sessions) = makeStore()
        let gate = Gate()
        sessions.transcriptFetch = { storedId in
            if storedId == "stored-A" {
                await gate.wait()
                return [self.storedMessage(role: "assistant", text: "SESSION A")]
            }
            return [self.storedMessage(role: "assistant", text: "SESSION B")]
        }

        sessions.open(summary("stored-A"))   // fast-path fetch suspends
        // Let A's open Task start and reach gate.wait(). The Gate is
        // race-safe (released=true flag), so a yield is sufficient here.
        await Task.yield()
        sessions.open(summary("stored-B"))   // newer open supersedes A
        // Deterministic await: wait for stored-B's seed Task (including the
        // normalizeOffMain Task.detached) to complete — no wall-clock dependency.
        #if DEBUG
        await sessions.waitForPendingOpenForTesting()
        #else
        await settle()
        #endif
        XCTAssertEqual(chat.messages.map(\.text), ["SESSION B"])

        gate.release()                        // A's stale fetch finally lands
        await settle()

        XCTAssertEqual(sessions.activeStoredId, "stored-B")
        XCTAssertEqual(chat.messages.map(\.text), ["SESSION B"],
                       "A's stale fetch must not seed over B's transcript")
    }

    // MARK: - #79: failed open()-path seed surfaces a recoverable error

    func testSeedTranscriptFailureSurfacesRecoverableError() async {
        let (chat, sessions) = makeStore()
        sessions.transcriptFetch = { _ in throw URLError(.notConnectedToInternet) }

        sessions.open(summary("stored-A"))
        // Deterministic await: wait for the open's seed Task (and its internal
        // normalizeOffMain Task.detached) to complete — no wall-clock dependency.
        #if DEBUG
        await sessions.waitForPendingOpenForTesting()
        #else
        await settle()
        #endif

        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(chat.transcriptGeneration, 0)
        XCTAssertNotNil(chat.lastBackfillError,
                        "the failure must be visible, not an infinite spinner")

        // Retry (ChatView's "Try Again") recovers via backfill().
        chat.backfillFetch = { _ in [self.storedMessage(role: "assistant", text: "recovered")] }
        await chat.backfill()
        XCTAssertNil(chat.lastBackfillError)
        XCTAssertEqual(chat.messages.map(\.text), ["recovered"])
        XCTAssertEqual(chat.transcriptGeneration, 1)
    }

    // MARK: - Judge round (post-fix adversarial re-verification)

    private func pendingSecurePromptFixture(sessionId: String) -> PendingSecurePrompt {
        PendingSecurePrompt(
            kind: .sudo,
            requestId: "su-1",
            sessionId: sessionId,
            prompt: "sudo password for build",
            envVar: nil,
            metadata: [:]
        )
    }

    /// A live-socket reconcile (e.g. `broadcast_gap`) proves nothing about the
    /// secure prompt's turn — and the secure prompt has NO inbox fallback, so
    /// expiring it there would orphan an agent genuinely blocked on it.
    func testBackfillSeedPreservesPendingSecurePrompt() async {
        let (chat, _) = makeStore { _ in
            [self.storedMessage(role: "assistant", text: "reconciled")]
        }
        chat.pendingSecurePrompt = pendingSecurePromptFixture(sessionId: activeRuntime)

        await chat.backfill()

        XCTAssertNotNil(chat.pendingSecurePrompt,
                        "a live-socket reconcile must not expire the only sudo surface")
        XCTAssertEqual(chat.messages.map(\.text), ["reconciled"])
    }

    /// The `error` terminal ends the turn exactly like `message.complete` —
    /// every card (secure prompt included) died with the turn's pending asks.
    func testGatewayErrorExpiresPromptCards() async {
        let (chat, _) = makeStore()
        var approvalChanges: [Bool] = []
        chat.onApprovalChange = { approvalChanges.append($0) }

        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        chat.pendingApproval = pendingApprovalFixture(sessionId: activeRuntime)
        chat.pendingClarification = pendingClarificationFixture(sessionId: activeRuntime)
        chat.pendingSecurePrompt = pendingSecurePromptFixture(sessionId: activeRuntime)

        chat.handle(event: frame(
            type: "error", runtime: activeRuntime,
            payload: .object(["message": .string("agent crashed")])
        ))

        XCTAssertFalse(chat.isStreaming)
        XCTAssertNil(chat.pendingApproval)
        XCTAssertNil(chat.pendingClarification)
        XCTAssertNil(chat.pendingSecurePrompt)
        XCTAssertEqual(approvalChanges, [false])
    }

    /// The transport drop is where the secure prompt dies: a post-restart
    /// stale card mis-resolves silently (swallowed 4009), and the drop is the
    /// strongest signal the in-memory ask can't be trusted anymore.
    func testConnectionDropExpiresSecurePrompt() async {
        let (chat, _) = makeStore()
        chat.handle(event: frame(type: "message.start", runtime: activeRuntime))
        chat.pendingSecurePrompt = pendingSecurePromptFixture(sessionId: activeRuntime)
        chat.pendingApproval = pendingApprovalFixture(sessionId: activeRuntime)

        chat.handleConnectionDrop()

        XCTAssertFalse(chat.isStreaming)
        XCTAssertNil(chat.pendingSecurePrompt)
        XCTAssertNil(chat.pendingApproval, "approvals re-surface via the inbox when still pending")
    }

    /// Branching away from a session whose foreign mirror is live must land
    /// the NEW session's transcript: reset-then-seed (the branchSession fix)
    /// clears the mirror that belonged to the session being left.
    func testResetThenSeedLandsNewTranscriptDuringForeignMirror() async {
        let (chat, sessions) = makeStore()
        chat.handle(event: frame(
            type: "message.start", runtime: foreignRuntime, stored: storedId
        ))
        XCTAssertTrue(chat.isStreaming, "foreign mirror adopted")

        // branchSession's activate sequence: new ids, reset, seed.
        sessions.activeRuntimeId = "rt-branch"
        sessions.activeStoredId = "stored-branch"
        chat.reset()
        chat.seed(from: [storedMessage(role: "assistant", text: "BRANCH HISTORY")])

        XCTAssertFalse(chat.isStreaming, "the old session's mirror must not survive the switch")
        XCTAssertEqual(chat.messages.map(\.text), ["BRANCH HISTORY"])
        XCTAssertEqual(chat.transcriptGeneration, 1)
    }

    /// A fresh session must never render the previous session's seed failure.
    func testResetClearsStaleBackfillError() async {
        let (chat, sessions) = makeStore()
        sessions.transcriptFetch = { _ in throw URLError(.timedOut) }
        sessions.open(summary("stored-A"))
        // Deterministic await: wait for the open's seed Task to fail and surface
        // the error on lastBackfillError — no wall-clock dependency.
        #if DEBUG
        await sessions.waitForPendingOpenForTesting()
        #else
        await settle()
        #endif
        XCTAssertNotNil(chat.lastBackfillError)

        chat.reset()
        XCTAssertNil(chat.lastBackfillError)
    }
}
