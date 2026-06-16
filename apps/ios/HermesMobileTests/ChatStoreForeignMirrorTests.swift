import XCTest
@testable import HermesMobile

/// F3-H — coverage for the foreign-turn mirror reconcile path in `ChatStore`.
///
/// The bug these tests pin: the app adopts a foreign turn's `message.start`
/// (`isStreaming` becomes true), then the live foreign deltas are dropped and
/// the `message.complete` recovery `backfill()` no-ops while it still believes
/// it is streaming — so the foreign text never renders and streaming never
/// clears. The fix must (1) reconcile the foreign turn even while
/// `isStreaming == true`, (2) NEVER disturb a genuinely-local in-flight turn,
/// and (3) surface a backfill REST failure instead of swallowing it.
///
/// These tests drive `ChatStore.handle` directly with synthetic broadcast
/// frames and inject `backfillFetch` so no live gateway is required.
@MainActor
final class ChatStoreForeignMirrorTests: XCTestCase {

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

    /// A broadcast frame from a foreign runtime, tagged with the stored id the
    /// app has open (so it passes the correlation gate).
    private func foreignFrame(
        type: String,
        runtime: String,
        stored: String,
        payload: JSONValue = .null
    ) -> GatewayEvent {
        GatewayEvent(params: .object([
            "type": .string(type),
            "session_id": .string(runtime),
            "stored_session_id": .string(stored),
            "payload": payload,
        ]))!
    }

    private func storedMessage(role: String, text: String) -> StoredMessage {
        StoredMessage(json: .object([
            "role": .string(role),
            "content": .string(text),
        ]))!
    }

    /// Spin the run loop briefly so the 40ms coalescing flush and the
    /// detached backfill Task can run.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    // MARK: - PRIMARY: foreign complete reconciles while isStreaming

    func testForeignCompleteReconcilesWhileStreaming() async {
        var fetched = false
        let (chat, _) = makeStore { _ in
            fetched = true
            return [
                self.storedMessage(role: "user", text: "ping from desktop"),
                self.storedMessage(role: "assistant", text: "MIRRORTEST reply"),
            ]
        }

        // Foreign turn is adopted: start → app begins streaming the foreign turn.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        XCTAssertTrue(chat.isStreaming, "adopting a foreign start should begin streaming")

        // The foreign turn completes while we still believe we are streaming.
        // The OLD code no-op'd backfill here; the fix must tear down the foreign
        // stream and run backfill.
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRRORTEST reply", "status": "completed"]))

        await settle()

        XCTAssertTrue(fetched, "foreign message.complete must run backfill, not no-op while streaming")
        XCTAssertFalse(chat.isStreaming, "streaming must clear after the mirrored turn reconciles")
        XCTAssertTrue(
            chat.messages.contains { $0.role == .assistant && $0.text.contains("MIRRORTEST") },
            "the reconciled transcript must contain the foreign reply")
        XCTAssertTrue(
            chat.messages.contains { $0.role == .user && $0.text.contains("ping from desktop") },
            "the foreign user prompt is reconciled from REST, not the dropped stream")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignCompletesReconciled, 1)
        XCTAssertGreaterThanOrEqual(chat.foreignMirrorTelemetry.backfillRuns, 1)
        #endif
    }

    /// ABH-159 — the foreign turn's USER prompt must surface at message.START
    /// (before any message.complete), and must NOT be duplicated when the
    /// authoritative complete-time backfill later reconciles the same transcript.
    /// The gateway never broadcasts the user message as a frame, so without this
    /// the user bubble is absent until a force-quit reseed whenever
    /// `message.complete` is dropped/late.
    func testForeignUserRowSurfacesAtStartAndIsNotDuplicated() async {
        let (chat, _) = makeStore { _ in
            [
                self.storedMessage(role: "user", text: "hello from desktop"),
                self.storedMessage(role: "assistant", text: "MIRRORTEST reply"),
            ]
        }

        // Foreign START only — NO complete yet. The OLD behavior deferred the user
        // bubble to the complete-time backfill, so it would be absent right here.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        await settle()  // let the detached mergeForeignUserRows fetch + apply run

        XCTAssertTrue(
            chat.messages.contains { $0.role == .user && $0.text.contains("hello from desktop") },
            "the foreign user prompt must surface at message.start, before message.complete")
        XCTAssertEqual(
            chat.messages.filter { $0.role == .user && $0.text.contains("hello from desktop") }.count, 1,
            "exactly one user row at start time")

        // The turn completes: the authoritative backfill reconciles the SAME
        // transcript. Because the start-time row carried the deterministic id the
        // backfill also computes, it reconciles in place — never a duplicate.
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRRORTEST reply", "status": "completed"]))
        await settle()

        XCTAssertEqual(
            chat.messages.filter { $0.role == .user && $0.text.contains("hello from desktop") }.count, 1,
            "the start-time user row reconciles in place — the complete-time backfill must not duplicate it")
    }

    /// ABH-159 — index-stability / in-place-reconcile contract. The start-time
    /// fetch sees only the just-committed user row; the complete-time backfill
    /// sees the FULL turn (assistant appended AFTER the user prompt). The user
    /// row's deterministic id must be IDENTICAL across both (its index doesn't
    /// shift — the reply appends after it), so it reconciles in place: exactly one
    /// bubble AND the same row identity (no remount/blink), not just no duplicate.
    func testForeignUserRowIdentityStableAcrossGrowingTranscript() async {
        var calls = 0
        let (chat, _) = makeStore { _ in
            calls += 1
            if calls == 1 {
                return [self.storedMessage(role: "user", text: "hello from desktop")]
            }
            return [
                self.storedMessage(role: "user", text: "hello from desktop"),
                self.storedMessage(role: "assistant", text: "MIRRORTEST reply"),
            ]
        }

        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        await settle()
        let userRowsAtStart = chat.messages.filter { $0.role == .user && $0.text.contains("hello from desktop") }
        XCTAssertEqual(userRowsAtStart.count, 1, "user row surfaces once at start time")
        let idAtStart = userRowsAtStart.first?.id

        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRRORTEST reply", "status": "completed"]))
        await settle()
        let userRowsAfter = chat.messages.filter { $0.role == .user && $0.text.contains("hello from desktop") }
        XCTAssertEqual(userRowsAfter.count, 1,
            "a growing complete-time transcript reconciles the start-time user row in place — exactly one bubble")
        XCTAssertEqual(userRowsAfter.first?.id, idAtStart,
            "the user row's identity is STABLE across start→complete (reconciled in place, not remounted)")
        XCTAssertTrue(chat.messages.contains { $0.role == .assistant && $0.text.contains("MIRRORTEST") },
            "the assistant reply lands via the complete-time backfill")
    }

    /// Live foreign deltas of the adopted stream must be applied, not dropped,
    /// even though `isStreaming` is true for the foreign stream the app adopted.
    func testForeignDeltasAppliedWhileStreaming() async {
        let (chat, _) = makeStore()
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRROR"]))
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "TEST"]))

        await settle()  // let the 40ms flush apply the buffered deltas

        XCTAssertTrue(
            chat.messages.contains { $0.role == .assistant && $0.text.contains("MIRRORTEST") },
            "adopted foreign deltas must render into the streaming message")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 1)
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignDeltasApplied, 2)
        #endif
    }

    // MARK: - NON-REGRESSION: a local turn is never disturbed by foreign frames

    func testLocalTurnUndisturbedByForeignFrames() async {
        var backfillCalled = false
        let (chat, _) = makeStore { _ in
            backfillCalled = true
            return []
        }

        // Start a genuinely-LOCAL turn (frames on our own active runtime).
        let localStart = GatewayEvent(params: .object([
            "type": .string("message.start"),
            "session_id": .string(activeRuntime),
            "payload": ["role": .string("assistant")],
        ]))!
        chat.handle(event: localStart)
        let localDelta = GatewayEvent(params: .object([
            "type": .string("message.delta"),
            "session_id": .string(activeRuntime),
            "payload": ["text": .string("local answer")],
        ]))!
        chat.handle(event: localDelta)
        await settle()
        XCTAssertTrue(chat.isStreaming)
        let localCountBefore = chat.messages.count

        // A foreign turn (start, deltas, complete) arrives mid local turn. None
        // of it may be adopted, none of it may touch the local turn, and the
        // foreign complete must NOT tear down our stream or trigger backfill.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "FOREIGN"]))
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "FOREIGN reply", "status": "completed"]))
        await settle()

        XCTAssertTrue(chat.isStreaming, "the local turn must still be streaming")
        XCTAssertFalse(backfillCalled, "a foreign turn must not backfill over a live local turn")
        XCTAssertEqual(chat.messages.count, localCountBefore,
                       "foreign frames must not add rows while a local turn owns the stream")
        XCTAssertFalse(chat.messages.contains { $0.text.contains("FOREIGN") },
                       "foreign text must never leak into a local turn's transcript")

        // The local turn completes normally and its own text survives intact.
        let localComplete = GatewayEvent(params: .object([
            "type": .string("message.complete"),
            "session_id": .string(activeRuntime),
            "payload": ["text": .string("local answer final"), "status": .string("completed")],
        ]))!
        chat.handle(event: localComplete)
        await settle()
        XCTAssertFalse(chat.isStreaming)
        XCTAssertTrue(chat.messages.contains { $0.role == .assistant && $0.text.contains("local answer") },
                      "the local reply must be intact after foreign interference")
        #if DEBUG
        XCTAssertGreaterThanOrEqual(chat.foreignMirrorTelemetry.foreignDroppedWhileStreaming, 1)
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 0)
        #endif
    }

    // MARK: - OBSERVABILITY: backfill error surfaces

    struct BackfillProbeError: LocalizedError {
        var errorDescription: String? { "simulated REST 503" }
    }

    func testBackfillErrorSurfaces() async {
        let (chat, _) = makeStore { _ in throw BackfillProbeError() }

        // Drive a foreign complete (the reconcile path) so backfill runs and
        // throws; the failure must be visible, not swallowed.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "x", "status": "completed"]))
        await settle()

        XCTAssertEqual(chat.lastBackfillError, "simulated REST 503",
                       "a backfill REST error must surface on lastBackfillError")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.backfillFailures, 1)
        #endif
    }

    /// A successful backfill clears any prior error.
    func testBackfillSuccessClearsError() async {
        var shouldThrow = true
        let (chat, _) = makeStore { _ in
            if shouldThrow { throw BackfillProbeError() }
            return [self.storedMessage(role: "assistant", text: "ok")]
        }

        await chat.backfill()
        XCTAssertEqual(chat.lastBackfillError, "simulated REST 503")

        shouldThrow = false
        await chat.backfill()
        XCTAssertNil(chat.lastBackfillError, "a later successful backfill clears the error")
    }

    // MARK: - H3 correlation guard at the gate

    /// A foreign frame whose stored id differs from the active stored id is
    /// dropped (no adoption, no streaming).
    func testForeignFrameWithMismatchedStoredIdIsDropped() async {
        let (chat, _) = makeStore()
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: "some-other-stored",
            payload: ["role": "assistant"]))
        await settle()
        XCTAssertFalse(chat.isStreaming)
        XCTAssertTrue(chat.messages.isEmpty)
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 0)
        #endif
    }

    /// Whitespace drift on the active stored id must not break correlation: the
    /// gate trims both sides.
    func testForeignFrameMatchesAcrossWhitespaceDrift() async {
        let (chat, sessions) = makeStore()
        sessions.activeStoredId = "  \(storedId) "   // padded local id
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        await settle()
        XCTAssertTrue(chat.isStreaming, "a trimmed-equal stored id must still correlate")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 1)
        #endif
    }

    // MARK: - F3-H2 CULPRIT: resume-window foreign start (activeRuntimeId == nil)

    /// THE round-2 culprit, reproduced exactly. During `session.resume`,
    /// `activeRuntimeId` (== `ChatStore.activeSessionId`) is `nil` while
    /// `activeStoredId` is already set. A FOREIGN `message.start` (different
    /// runtime, enriched with our stored id) arrives in that window. The round-1
    /// gate `if let sid = event.sessionId, let active = activeSessionId, sid !=
    /// active` SKIPPED the foreign branch because `let active` failed on nil, so
    /// `beginStreamingMessage()` ran on the DIRECT path and claimed a LOCAL turn
    /// (`streamingIsForeign == false`). Every later foreign frame was then dropped.
    ///
    /// The fix must classify this frame as FOREIGN at the source and adopt it —
    /// despite `activeRuntimeId` being nil — so deltas apply and the complete
    /// reconciles. This is the gate failure mode the live 9121 repro proved.
    func testResumeWindowForeignStartAdoptedWhileRuntimeNil() async {
        var fetched = false
        let (chat, sessions) = makeStore { _ in
            fetched = true
            return [
                self.storedMessage(role: "user", text: "MIRRORTEST prompt"),
                self.storedMessage(role: "assistant", text: "MIRRORTEST reply"),
            ]
        }
        // Reproduce the resume window: stored id known, runtime id still nil.
        // `ChatStore.activeSessionId` reads `sessions.activeRuntimeId`, so nil here
        // is exactly the nil binding that made the round-1 gate skip the foreign
        // branch.
        sessions.activeRuntimeId = nil
        XCTAssertNil(sessions.activeRuntimeId,
                     "precondition: activeRuntimeId is nil during the resume window")
        XCTAssertNotNil(sessions.activeStoredId,
                        "precondition: stored id is already known during resume")

        // Foreign start arrives BEFORE resume lands.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))

        // It must be ADOPTED as foreign — not misclassified local.
        XCTAssertTrue(chat.isStreaming, "the resume-window foreign start must begin streaming")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 1,
                       "the foreign start must be adopted, not run as a local turn")
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignDroppedWhileStreaming, 0,
                       "nothing may be dropped: the start was correctly classified foreign")
        #endif

        // Deltas of the adopted foreign runtime must apply, not drop.
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRROR"]))
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "TEST"]))
        await settle()
        XCTAssertTrue(
            chat.messages.contains { $0.role == .assistant && $0.text.contains("MIRRORTEST") },
            "adopted foreign deltas must render even though they arrived while runtime was nil")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignDeltasApplied, 2)
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignDroppedWhileStreaming, 0)
        #endif

        // The foreign turn completes → teardown + backfill reconcile; streaming clears.
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRRORTEST reply", "status": "completed"]))
        await settle()
        XCTAssertTrue(fetched, "foreign complete must reconcile via backfill")
        XCTAssertFalse(chat.isStreaming, "streaming must clear after the mirrored turn reconciles")
        XCTAssertTrue(
            chat.messages.contains { $0.role == .assistant && $0.text.contains("MIRRORTEST reply") },
            "the reconciled transcript must contain the foreign reply")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignCompletesReconciled, 1)
        #endif
    }

    /// The same resume-window race, but resume LANDS mid-turn (the gateway returns
    /// and `activeRuntimeId` becomes populated) AFTER the foreign start was already
    /// adopted. The live repro showed resume returning at t=9.26s while the foreign
    /// turn was streaming. Populating the runtime id must NOT re-classify the
    /// already-adopted foreign frames as local, drop them, or strand streaming.
    func testResumeLandsMidForeignTurnStillReconciles() async {
        var fetched = false
        let (chat, sessions) = makeStore { _ in
            fetched = true
            return [self.storedMessage(role: "assistant", text: "MIRRORTEST reply")]
        }
        sessions.activeRuntimeId = nil

        // Foreign start adopted during the nil window.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 1)
        #endif

        // session.resume returns: runtime id becomes our LOCAL runtime (distinct
        // from the foreign runtime we adopted).
        sessions.activeRuntimeId = activeRuntime

        // More foreign frames of the adopted runtime arrive after resume landed.
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRRORTEST"]))
        await settle()
        XCTAssertTrue(
            chat.messages.contains { $0.role == .assistant && $0.text.contains("MIRRORTEST") },
            "foreign deltas after resume-land must still apply to the adopted stream")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignDroppedWhileStreaming, 0,
                       "no foreign frame may be dropped after resume populates the runtime id")
        #endif

        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "MIRRORTEST reply", "status": "completed"]))
        await settle()
        XCTAssertTrue(fetched)
        XCTAssertFalse(chat.isStreaming, "streaming must not be stranded true")
    }

    /// Resume-with-inflight LOCAL turn coexisting with a foreign turn (the design
    /// principle's named coexistence case). The user sends a genuinely-local turn
    /// (explicit `localTurnToken`) while a foreign client drives the SAME stored
    /// session over the broadcast. The foreign frames must be refused adoption (a
    /// local turn owns the stream), the foreign complete must NOT backfill over the
    /// live local turn, and the local turn must finish intact.
    func testLocalSendCoexistsWithForeignTurn() async {
        var backfillCalled = false
        let (chat, sessions) = makeStore { _ in
            backfillCalled = true
            return []
        }
        // Stub the gateway send so `send()` reaches the local-turn claim without a
        // live socket. A real send would `prompt.submit`; here the throw is caught
        // by send()'s error path AFTER beginLocalTurn() — so to test the held-token
        // case we instead drive the local turn via our own-runtime frames, which is
        // the same explicit-ownership path send() funnels into.
        let localStart = GatewayEvent(params: .object([
            "type": .string("message.start"),
            "session_id": .string(activeRuntime),
            "payload": ["role": .string("assistant")],
        ]))!
        chat.handle(event: localStart)
        chat.handle(event: GatewayEvent(params: .object([
            "type": .string("message.delta"),
            "session_id": .string(activeRuntime),
            "payload": ["text": .string("local answer")],
        ]))!)
        await settle()
        XCTAssertTrue(chat.isStreaming)
        let rowsBefore = chat.messages.count
        _ = sessions  // silence unused in release

        // Foreign turn on the same stored session, fully interleaved.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        chat.handle(event: foreignFrame(
            type: "message.delta", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "FOREIGN"]))
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "FOREIGN reply", "status": "completed"]))
        await settle()

        XCTAssertTrue(chat.isStreaming, "the local turn must keep the stream")
        XCTAssertFalse(backfillCalled, "a foreign complete must not backfill over a live local turn")
        XCTAssertEqual(chat.messages.count, rowsBefore,
                       "foreign frames must not add rows while a local turn owns the stream")
        XCTAssertFalse(chat.messages.contains { $0.text.contains("FOREIGN") },
                       "foreign text must never leak into the local transcript")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 0)
        XCTAssertGreaterThanOrEqual(chat.foreignMirrorTelemetry.foreignDroppedWhileStreaming, 1)
        #endif

        // Local turn completes; its text survives.
        chat.handle(event: GatewayEvent(params: .object([
            "type": .string("message.complete"),
            "session_id": .string(activeRuntime),
            "payload": ["text": .string("local answer final"), "status": .string("completed")],
        ]))!)
        await settle()
        XCTAssertFalse(chat.isStreaming)
        XCTAssertTrue(chat.messages.contains { $0.role == .assistant && $0.text.contains("local answer") })
    }

    /// After a foreign turn has been adopted and reconciled (the post-culprit
    /// steady state), a NEW foreign turn on the same stored session must be
    /// adoptable again — the prior foreign turn's residue must not leave a token
    /// that blocks the next mirror. Guards against a token-leak regression.
    func testSecondForeignTurnAdoptableAfterReconcile() async {
        let (chat, sessions) = makeStore { _ in
            [self.storedMessage(role: "assistant", text: "first reply")]
        }
        sessions.activeRuntimeId = nil

        // First foreign turn: start → complete (adopt, reconcile).
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: foreignRuntime, stored: storedId,
            payload: ["role": "assistant"]))
        chat.handle(event: foreignFrame(
            type: "message.complete", runtime: foreignRuntime, stored: storedId,
            payload: ["text": "first reply", "status": "completed"]))
        await settle()
        XCTAssertFalse(chat.isStreaming, "first foreign turn cleared streaming")

        // A second, distinct foreign runtime drives the same stored session.
        chat.handle(event: foreignFrame(
            type: "message.start", runtime: "rt-foreign-2", stored: storedId,
            payload: ["role": "assistant"]))
        await settle()
        XCTAssertTrue(chat.isStreaming, "the second foreign turn must be adoptable, not blocked")
        #if DEBUG
        XCTAssertEqual(chat.foreignMirrorTelemetry.foreignAdopted, 2,
                       "both foreign turns adopted — no stale token blocked the second")
        #endif
    }
}
