import XCTest
@testable import HermesMobile

/// ABH-73 (UX-1 P0) — session delete-flow correctness + failure surface.
///
/// The family these tests pin: a `session.delete` on a session the app holds
/// open used to hit the server's `4023` "active session" guard (every opened
/// session is registered live), the thrown error was swallowed into the
/// unobserved `lastError`, and nothing interrupted the actively-streaming
/// runtime before deleting it. The fix (`SessionStore.delete`):
///   1. interrupt the in-flight turn (RIDER) → `session.close` (RUNTIME id) →
///      `session.delete` (STORED id) for the app's own active session, so the
///      server can evict cleanly and the orphaned runtime stops spending;
///   2. on failure, keep the row and populate the dedicated, OBSERVED
///      `sessionActionError` so the drawer can alert;
///   3. archive/rename failures populate the same surface for consistency.
///
/// The store reaches the gateway via the injectable `rpcSend` seam and the live
/// runtime via the injectable `interruptActive` seam (mirroring the established
/// `transcriptFetch`/`backfillFetch` injection idiom), so no live gateway is
/// required and the interrupt→close→delete ORDER is assertable on one recorder.
@MainActor
final class SessionDeleteFlowTests: XCTestCase {

    private let activeRuntime = "rt-local"
    private let storedId = "stored-session-1"

    // MARK: - Recorder

    /// Ordered log of seam invocations shared across `rpcSend` and
    /// `interruptActive` so a single call sequence proves the ABH-73 ordering.
    /// `@MainActor` only (the seams fire on the main actor), so a plain class
    /// without locking is safe here.
    private final class CallRecorder {
        /// `("interrupt", "")` for the interrupt seam, else `(method, session_id)`.
        private(set) var calls: [(method: String, sessionId: String)] = []
        /// Methods the recorder should fail with the given `GatewayError`.
        var failures: [String: GatewayError] = [:]

        func recordInterrupt() {
            calls.append((method: "interrupt", sessionId: ""))
        }

        func recordRPC(_ method: String, _ params: JSONValue) throws -> JSONValue {
            let sid: String
            if case let .object(obj) = params, case let .string(value)? = obj["session_id"] {
                sid = value
            } else {
                sid = ""
            }
            calls.append((method: method, sessionId: sid))
            if let error = failures[method] { throw error }
            return .object([:])
        }

        var methods: [String] { calls.map(\.method) }
    }

    // MARK: - Fixtures

    private func summary(_ id: String, title: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id, title: title, preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
    }

    /// Build a wired SessionStore with the two seams pointed at a fresh recorder.
    /// `active` decides whether the active pointers reference the given session.
    private func makeStore(
        seedSessions: [SessionSummary] = [],
        activeStored: String? = nil,
        activeRuntime: String? = nil
    ) -> (SessionStore, CallRecorder) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        sessions.sessions = seedSessions
        sessions.activeStoredId = activeStored
        sessions.activeRuntimeId = activeRuntime

        let recorder = CallRecorder()
        sessions.rpcSend = { method, params in try recorder.recordRPC(method, params) }
        sessions.interruptActive = { recorder.recordInterrupt() }
        return (sessions, recorder)
    }

    // MARK: - Success path

    /// Deleting a NON-active session: a plain `session.delete`, no interrupt/close,
    /// the row drops, and no error surfaces.
    func testDeleteInactiveSessionRemovesRowAndSendsDeleteOnly() async {
        let target = summary("stored-other")
        let keep = summary("stored-keep")
        let (sessions, recorder) = makeStore(
            seedSessions: [target, keep],
            activeStored: storedId,
            activeRuntime: activeRuntime
        )

        await sessions.delete(target)

        XCTAssertEqual(recorder.methods, ["session.delete"],
                       "Inactive delete must not interrupt or close")
        XCTAssertEqual(recorder.calls.first?.sessionId, "stored-other",
                       "session.delete keys on the STORED id")
        XCTAssertFalse(sessions.sessions.contains(where: { $0.id == "stored-other" }),
                       "Row should be removed on success")
        XCTAssertTrue(sessions.sessions.contains(where: { $0.id == "stored-keep" }))
        XCTAssertNil(sessions.sessionActionError, "Success is silent")
        // Active pointers untouched — the deleted session was not the active one.
        XCTAssertEqual(sessions.activeStoredId, storedId)
    }

    /// Deleting the ACTIVE (app-held) session: interrupt → close → delete, IN
    /// ORDER, with close on the RUNTIME id and delete on the STORED id; the row
    /// drops and the active pointers clear.
    func testDeleteActiveSessionInterruptsThenClosesThenDeletesInOrder() async {
        let target = summary(storedId)
        let (sessions, recorder) = makeStore(
            seedSessions: [target],
            activeStored: storedId,
            activeRuntime: activeRuntime
        )

        await sessions.delete(target)

        XCTAssertEqual(recorder.methods, ["interrupt", "session.close", "session.delete"],
                       "Active delete must interrupt, then close, then delete — in that order")
        // close keys on the RUNTIME id, delete on the STORED id.
        let close = recorder.calls.first { $0.method == "session.close" }
        XCTAssertEqual(close?.sessionId, activeRuntime, "session.close keys on the RUNTIME id")
        let del = recorder.calls.first { $0.method == "session.delete" }
        XCTAssertEqual(del?.sessionId, storedId, "session.delete keys on the STORED id")

        XCTAssertFalse(sessions.sessions.contains(where: { $0.id == storedId }))
        XCTAssertNil(sessions.activeStoredId, "Active pointers clear after deleting the active session")
        XCTAssertNil(sessions.activeRuntimeId)
        XCTAssertNil(sessions.sessionActionError)
    }

    // MARK: - Failure path (the core ABH-73 surface)

    /// A `session.delete` RPC error must NOT remove the row and MUST populate the
    /// dedicated `sessionActionError` with the SERVER message and `action ==
    /// "Delete"` (the drawer binds an alert to this).
    func testDeleteFailureKeepsRowAndSurfacesServerError() async {
        let target = summary("stored-fail")
        let (sessions, recorder) = makeStore(
            seedSessions: [target],
            activeStored: nil,
            activeRuntime: nil
        )
        recorder.failures["session.delete"] =
            .rpc(code: 5036, message: "session store is unavailable")

        await sessions.delete(target)

        XCTAssertTrue(sessions.sessions.contains(where: { $0.id == "stored-fail" }),
                      "Row must stay when delete fails")
        let surfaced = sessions.sessionActionError
        XCTAssertNotNil(surfaced, "Failure must surface on the observed seam")
        XCTAssertEqual(surfaced?.action, "Delete")
        XCTAssertEqual(surfaced?.message, "session store is unavailable",
                       "Prefer the server's own message for an RPC error frame")
    }

    /// The close-before-delete is best-effort: a `session.close` failure must NOT
    /// block the delete, which still proceeds (the server auto-evicts regardless).
    func testActiveDeleteSucceedsEvenWhenCloseFails() async {
        let target = summary(storedId)
        let (sessions, recorder) = makeStore(
            seedSessions: [target],
            activeStored: storedId,
            activeRuntime: activeRuntime
        )
        recorder.failures["session.close"] =
            .rpc(code: 9999, message: "already gone")

        await sessions.delete(target)

        XCTAssertTrue(recorder.methods.contains("session.delete"),
                      "A failed close must not block the delete")
        XCTAssertFalse(sessions.sessions.contains(where: { $0.id == storedId }),
                       "Delete still succeeds")
        XCTAssertNil(sessions.sessionActionError,
                     "A best-effort close failure is not a delete failure")
    }

    // MARK: - Consistency: archive / rename surface the same seam

    /// An unconfigured store (no REST client) makes archive fail its guard; the
    /// failure must surface on `sessionActionError` with `action == "Archive"`.
    func testArchiveFailureSurfacesActionError() async {
        let target = summary("stored-arch")
        let (sessions, _) = makeStore(seedSessions: [target])

        await sessions.archive(target)

        XCTAssertEqual(sessions.sessionActionError?.action, "Archive")
        XCTAssertTrue(sessions.sessions.contains(where: { $0.id == "stored-arch" }),
                      "Archive must not drop the row when it fails")
    }

    /// Rename's not-connected guard surfaces on `sessionActionError` too.
    func testRenameFailureSurfacesActionError() async {
        let target = summary("stored-ren", title: "Old")
        let (sessions, _) = makeStore(seedSessions: [target])

        await sessions.rename(target, to: "New")

        XCTAssertEqual(sessions.sessionActionError?.action, "Rename")
    }

    // MARK: - SessionActionError value type

    /// Each constructed `SessionActionError` has a distinct identity (so the
    /// value-presenting alert re-fires for back-to-back failures) but compares
    /// equal only on identical id (Equatable for @Observable tracking).
    func testSessionActionErrorIdentityIsUnique() {
        let a = SessionActionError(action: "Delete", message: "x")
        let b = SessionActionError(action: "Delete", message: "x")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a)
    }
}
