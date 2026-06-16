import XCTest
@testable import HermesMobile

/// Queue self-heal — the "No active session" / queues-forever trap on
/// desktop-driven sessions (ABH-155/156 family).
///
/// Pins three behaviors the fix adds:
///  1. `QueueStore.restamp(from:to:)` migrates queued prompts parent → continuation
///     when a resume follows a compression chain tip, so drain's session-affinity
///     guard doesn't skip them forever (A3).
///  2. The restamp makes a previously-skipped prompt drain-eligible (A3 end-to-end).
///  3. `SessionStore.ensureActiveRuntime()` guard behavior — returns an existing
///     runtime as-is, and `nil` (no crash) when there's nothing to resume — and
///     `ChatStore.send` fails gracefully with "No active session" when no runtime
///     can bind.
///
/// The LIVE resume-binds path (ensureActiveRuntime actually re-resuming and
/// flushing the outbox) needs a gateway and is device-verified; these tests avoid
/// a network call so they can never hang the suite.
@MainActor
final class QueueSelfHealTests: XCTestCase {

    private let storedParent = "stored-parent"
    private let storedTip = "stored-continuation"

    private func makeQueue() -> (QueueStore, UserDefaults) {
        let suite = "test.hermes.queueheal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (QueueStore(defaults: defaults), defaults)
    }

    private func makeStores() -> (ChatStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (chat, sessions)
    }

    // MARK: - A3: restamp migrates queued prompts parent → continuation

    func testRestampMigratesMatchingPromptsAndPreservesOrder() {
        let (queue, defaults) = makeQueue()
        queue.enqueue("first", storedSessionId: storedParent)
        queue.enqueue("unrelated", storedSessionId: "other")
        queue.enqueue("second", storedSessionId: storedParent)

        queue.restamp(from: storedParent, to: storedTip)

        XCTAssertEqual(queue.items.map(\.text), ["first", "unrelated", "second"],
                       "FIFO order preserved")
        XCTAssertEqual(queue.items.map(\.storedSessionId),
                       [storedTip, "other", storedTip],
                       "only parent-stamped prompts migrate to the continuation")
        // The migration is persisted (survives a relaunch).
        let reloaded = QueueStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.map(\.storedSessionId),
                       [storedTip, "other", storedTip])
    }

    func testRestampIsNoopWhenOldEqualsNewOrNothingMatches() {
        let (queue, _) = makeQueue()
        queue.enqueue("p", storedSessionId: storedParent)
        queue.restamp(from: storedParent, to: storedParent)  // old == new → no-op
        XCTAssertEqual(queue.items.first?.storedSessionId, storedParent)
        queue.restamp(from: "nonexistent", to: storedTip)    // no match → no-op
        XCTAssertEqual(queue.items.first?.storedSessionId, storedParent)
    }

    // MARK: - A3 end-to-end: a migrated prompt becomes drain-eligible

    func testRestampMakesAChainTipPromptDrainEligible() async {
        let (chat, sessions) = makeStores()
        let (queue, _) = makeQueue()
        // The session resumed onto its compression continuation; a prompt was
        // queued earlier under the PARENT id (the drawer row the user tapped).
        sessions.activeRuntimeId = "rt"   // runtime bound → send is attempted
        sessions.activeStoredId = storedTip
        queue.enqueue("queued under parent", storedSessionId: storedParent)

        // Before restamp: affinity mismatch (stamp=parent, active=tip) → skipped,
        // never attempted, never dropped.
        await queue.drain(chat: chat)
        XCTAssertFalse(chat.messages.contains { $0.text == "queued under parent" },
                       "a parent-stamped prompt is skipped while the tip is active")
        XCTAssertEqual(queue.items.count, 1, "skipped, not dropped")

        // After restamp: the stamp now matches the active tip → eligible → attempted
        // (the disconnected client doesn't accept it, but the appended user bubble
        // proves the prompt was no longer skipped).
        queue.restamp(from: storedParent, to: storedTip)
        await queue.drain(chat: chat)
        XCTAssertTrue(chat.messages.contains { $0.text == "queued under parent" },
                      "after restamp the prompt is eligible and attempted")
    }

    // MARK: - ensureActiveRuntime guards (no network)

    func testEnsureActiveRuntimeReturnsExistingRuntimeWithoutResuming() async {
        let (_, sessions) = makeStores()
        sessions.activeRuntimeId = "rt-live"
        sessions.activeStoredId = storedParent
        let rid = await sessions.ensureActiveRuntime()
        XCTAssertEqual(rid, "rt-live", "an already-bound runtime is returned as-is")
    }

    func testEnsureActiveRuntimeReturnsNilWithNothingToResume() async {
        let (_, sessions) = makeStores()
        sessions.activeRuntimeId = nil
        sessions.activeStoredId = nil
        let rid = await sessions.ensureActiveRuntime()
        XCTAssertNil(rid, "nothing to resume → nil, no crash")
    }

    // MARK: - ChatStore.send graceful failure when no runtime can bind

    func testSendSurfacesNoActiveSessionWhenNothingToResume() async {
        let (chat, sessions) = makeStores()
        sessions.activeRuntimeId = nil   // forces the self-heal path
        sessions.activeStoredId = nil    // …which has nothing to resume (no network)
        let accepted = await chat.send(text: "hello")
        XCTAssertFalse(accepted)
        XCTAssertEqual(chat.lastError, "No active session",
                       "a self-heal that can't bind still fails gracefully")
    }

    // MARK: - Supersession: a stale on-demand resume must not clobber a switch

    private func stagedResult(sessionId: String, resumed: String) -> SessionOpenResult {
        JSONValue.object([
            "session_id": .string(sessionId),
            "resumed": .string(resumed),
        ]).decoded(as: SessionOpenResult.self)!
    }

    func testResumeDoesNotClobberWhenUserSwitchedSessionsMidResume() async {
        let (_, sessions) = makeStores()
        sessions.activeStoredId = "A"
        sessions.activeRuntimeId = nil
        // While A's resume is "in flight", the user taps session B (open(B) sets
        // activeStoredId = B). A's result then comes back stale.
        sessions.resumeRPC = { storedId, _ in
            XCTAssertEqual(storedId, "A", "resume targets the session active at call time")
            sessions.activeStoredId = "B"          // simulate the switch during the await
            return self.stagedResult(sessionId: "rt-A", resumed: "A")
        }

        let rid = await sessions.resumeActiveAfterReconnect()

        XCTAssertNil(rid, "a stale resume for A self-aborts once the user moved to B")
        XCTAssertEqual(sessions.activeStoredId, "B",
                       "B's stored pointer is NOT clobbered back to A")
        XCTAssertNil(sessions.activeRuntimeId,
                     "A's runtime is NOT bound while B is the active session")
    }

    func testResumeBindsWhenSessionUnchanged() async {
        let (_, sessions) = makeStores()
        sessions.activeStoredId = "A"
        sessions.activeRuntimeId = nil
        sessions.resumeRPC = { _, _ in self.stagedResult(sessionId: "rt-A", resumed: "A") }

        let rid = await sessions.resumeActiveAfterReconnect()

        XCTAssertEqual(rid, "rt-A", "an un-superseded resume binds the runtime")
        XCTAssertEqual(sessions.activeRuntimeId, "rt-A")
        XCTAssertEqual(sessions.activeStoredId, "A")
    }
}
