import XCTest
@testable import HermesMobile

/// ABH-80 item 4 — delete-confirmation staging state.
///
/// The destructive-delete confirmation (ABH-80) introduces a two-step flow in
/// the drawer: the context menu's "Delete" button sets `sessionPendingDelete`
/// (staging), and the `confirmationDialog` calls `SessionStore.delete` only
/// after the user confirms. These tests verify the ``SessionStore`` behaviour
/// that underpins that flow:
///
/// - Staging (`sessionPendingDelete`) is a pure view-layer `@State`, so it is
///   not tested here; what matters is that the final `delete` call executes the
///   ABH-73 correctness logic, which is fully covered by `SessionDeleteFlowTests`.
///
/// This file pins the `SessionActionError` Equatable semantics (required for the
/// confirmation dialog's binding) and the fact that a successful delete resets
/// `sessionActionError` (the confirmation should not leave stale error state).
@MainActor
final class DrawerDeleteConfirmationTests: XCTestCase {

    // MARK: - Fixtures

    private func summary(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, title: "Session \(id)", preview: nil, startedAt: nil,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
    }

    private func makeStore(seedSessions: [SessionSummary] = []) -> (SessionStore, MockRPC) {
        let chat = ChatStore()
        let store = SessionStore()
        let connection = ConnectionStore(sessionStore: store, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: store, attachments: attachments)
        store.attach(connection: connection, chat: chat)
        store.sessions = seedSessions
        let mock = MockRPC()
        store.rpcSend = { method, params in try mock.record(method, params) }
        store.interruptActive = {}
        return (store, mock)
    }

    // MARK: - MockRPC

    private final class MockRPC {
        private(set) var called: [String] = []
        var shouldFail = false

        func record(_ method: String, _ params: JSONValue) throws -> JSONValue {
            called.append(method)
            if shouldFail { throw GatewayError.rpc(code: 500, message: "boom") }
            return .object([:])
        }
    }

    // MARK: - Confirmed-delete path

    /// After the user confirms, `delete` is called: the row disappears and
    /// `sessionActionError` is nil (no stale error from prior operations).
    func testConfirmedDeleteRemovesRowAndClearsActionError() async {
        let target = summary("s1")
        let (store, _) = makeStore(seedSessions: [target, summary("s2")])
        store.sessionActionError = SessionActionError(action: "Archive", message: "old")

        await store.delete(target)

        XCTAssertFalse(store.sessions.contains(where: { $0.id == "s1" }),
                       "Confirmed delete must remove the row")
        XCTAssertNil(store.sessionActionError,
                     "Successful delete must clear any prior sessionActionError")
    }

    // MARK: - Cancelled-delete path (simulator: just don't call delete)

    /// When the user cancels the dialog (no call to `delete`), the session list
    /// is untouched and `sessionActionError` remains nil.
    func testCancelledDeleteLeavesSessionIntact() {
        let target = summary("s1")
        // A cancel means `store.delete` is simply never called.
        let (store, _) = makeStore(seedSessions: [target])

        // No delete call — simulate the cancelled confirmation.
        XCTAssertTrue(store.sessions.contains(where: { $0.id == "s1" }),
                      "Cancelled delete must not remove the row")
        XCTAssertNil(store.sessionActionError,
                     "Cancelled delete must not produce a sessionActionError")
    }

    // MARK: - SessionActionError binding semantics

    /// Two `SessionActionError` instances with identical content are NOT equal
    /// (each has a unique `id` UUID). This means a back-to-back delete failure
    /// produces a NEW value, re-firing the `.alert`/`.confirmationDialog` binding —
    /// the drawer's error alert re-presents for each failure.
    func testSessionActionErrorBindingFiresPerInstance() {
        let e1 = SessionActionError(action: "Delete", message: "gone")
        let e2 = SessionActionError(action: "Delete", message: "gone")
        XCTAssertNotEqual(e1.id, e2.id,
                          "Each SessionActionError instance must have a unique id")
        XCTAssertNotEqual(e1, e2,
                          "Two separately-constructed errors must not be equal (re-fires binding)")
        XCTAssertEqual(e1, e1,
                       "An error is equal only to itself")
    }

    // MARK: - Failure surfaces correctly

    /// A failed `delete` call populates `sessionActionError` with `action == "Delete"`.
    /// This is the error alert path — separate from the confirmation dialog path.
    func testFailedDeleteSurfacesActionError() async {
        let target = summary("fail-s1")
        let (store, mock) = makeStore(seedSessions: [target])
        mock.shouldFail = true

        await store.delete(target)

        XCTAssertEqual(store.sessionActionError?.action, "Delete",
                       "A failed delete must set sessionActionError.action to 'Delete'")
        XCTAssertTrue(store.sessions.contains(where: { $0.id == "fail-s1" }),
                      "Row must stay when delete fails")
    }
}
