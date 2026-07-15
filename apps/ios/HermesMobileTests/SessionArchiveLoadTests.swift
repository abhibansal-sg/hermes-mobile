import XCTest
@testable import HermesMobile

/// ABH-80 item 5 — ``SessionStore/loadArchived(limit:)`` unit tests.
///
/// Covers:
/// - Success: the injected fetch is called with the requested limit; the result
///   lands in `archivedSessions` and `lastError` is cleared.
/// - Empty result: `archivedSessions` is set to an empty array (not nil/unchanged).
/// - Failure: the list is cleared, `lastError` is populated, and `archivedSessions`
///   is empty (no stale data stays).
/// - No-connection guard: when no `archivedFetch` seam is set and there is no
///   live REST client, `archivedSessions` is cleared and `lastError` is set.
///
/// The seam mirrors the established `transcriptFetch`/`rpcSend` injection idiom
/// (``SessionDeleteFlowTests``) — no live gateway required.
@MainActor
final class SessionArchiveLoadTests: XCTestCase {

    // MARK: - Fixtures

    private func summary(_ id: String, title: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id, title: title, preview: nil, startedAt: 1_700_000_000,
            messageCount: nil, source: nil, lastActive: nil, cwd: nil
        )
    }

    /// Build a minimal wired ``SessionStore`` with the `archivedFetch` seam
    /// injectable. The store has no configured REST client (no server URL/token),
    /// so any test that omits a seam hits the no-connection guard.
    private func makeStore() -> SessionStore {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return sessions
    }

    // MARK: - Success

    /// A successful fetch populates `archivedSessions` with the returned rows,
    /// forwards the `limit` parameter, and clears `lastError`.
    func testLoadArchivedPopulatesListOnSuccess() async {
        let sessions = makeStore()
        let expected = [
            summary("arch-1", title: "First archived"),
            summary("arch-2", title: "Second archived"),
        ]
        var capturedLimit: Int?
        sessions.archivedFetch = { limit in
            capturedLimit = limit
            return expected
        }
        sessions.lastError = "stale error from before"

        await sessions.loadArchived(limit: 42)

        XCTAssertEqual(sessions.archivedSessions.map(\.id), ["arch-1", "arch-2"],
                       "loadArchived must populate archivedSessions with the fetch result")
        XCTAssertEqual(capturedLimit, 42, "The requested limit must be forwarded to the fetch")
        XCTAssertNil(sessions.lastError, "A successful fetch must clear lastError")
    }

    /// An empty result is accepted as a valid (non-error) response.
    func testLoadArchivedAcceptsEmptyResult() async {
        let sessions = makeStore()
        sessions.archivedSessions = [summary("stale")]
        sessions.archivedFetch = { _ in [] }

        await sessions.loadArchived()

        XCTAssertTrue(sessions.archivedSessions.isEmpty,
                      "An empty fetch result must replace any stale archivedSessions")
        XCTAssertNil(sessions.lastError)
    }

    // MARK: - Failure

    /// A fetch error clears `archivedSessions` and surfaces the error in `lastError`.
    func testLoadArchivedClearsListAndSetsErrorOnFailure() async {
        let sessions = makeStore()
        sessions.archivedSessions = [summary("arch-stale")]
        sessions.archivedFetch = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await sessions.loadArchived()

        XCTAssertTrue(sessions.archivedSessions.isEmpty,
                      "A failed fetch must clear archivedSessions (no stale data)")
        XCTAssertNotNil(sessions.lastError,
                        "A failed fetch must surface the error in lastError")
    }

    /// A `LocalizedError`'s `errorDescription` is preferred over the default
    /// `localizedDescription` — matching the pattern in `rename`/`archive`/`delete`.
    func testLoadArchivedUsesLocalizedErrorDescription() async {
        let sessions = makeStore()
        sessions.archivedFetch = { _ in
            throw RestError.badStatus(503, body: "Service Unavailable")
        }

        await sessions.loadArchived()

        XCTAssertEqual(
            sessions.lastError,
            "Server returned HTTP 503: Service Unavailable",
            "lastError must contain the RestError's localized description"
        )
    }

    // MARK: - No-connection guard

    /// When neither an `archivedFetch` seam nor a live REST client is configured,
    /// `loadArchived` must set `lastError` to "Not connected." and clear the list.
    func testLoadArchivedSetsErrorWhenNoConnection() async {
        let sessions = makeStore()
        // No seam injected; no server URL → resolvedArchivedFetch returns nil.
        sessions.archivedSessions = [summary("arch-stale")]

        await sessions.loadArchived()

        XCTAssertTrue(sessions.archivedSessions.isEmpty,
                      "No-connection guard must clear archivedSessions")
        XCTAssertEqual(sessions.lastError, "Not connected.",
                       "No-connection guard must set the canonical 'Not connected.' message")
    }

    // MARK: - Unarchive

    /// Unarchiving a session via the injected seam removes it from `archivedSessions`
    /// and clears `sessionActionError`. Uses the same `rpcSend`-less approach:
    /// the `archivedFetch` seam is re-used here just to pre-seed the list;
    /// `unarchive` calls the REST path, so we test the no-connection failure guard.
    func testUnarchiveFailsGracefullyWithoutConnection() async {
        let sessions = makeStore()
        let target = summary("arch-unarchive")
        sessions.archivedSessions = [target]

        // No archivedFetch / REST client → unarchive hits the "Not connected" guard.
        await sessions.unarchive(target)

        XCTAssertFalse(sessions.archivedSessions.isEmpty,
                       "A failed unarchive must not remove the row")
        XCTAssertEqual(sessions.sessionActionError?.action, "Unarchive",
                       "unarchive must surface a SessionActionError with action 'Unarchive'")
        XCTAssertEqual(sessions.sessionActionError?.message, "Not connected.")
    }
}
