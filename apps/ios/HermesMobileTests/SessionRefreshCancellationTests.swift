import XCTest
import Foundation
import GRDB
@testable import HermesMobile

/// #208 regression: a cancelled background refresh is control flow, never a
/// user-facing failure. These tests pin the cache-retention invariant — the
/// drawer must never regress from populated to empty (or paint a false error
/// row) because a refresh was cancelled or superseded — while preserving the
/// genuine-failure path.
@MainActor
final class SessionRefreshCancellationTests: XCTestCase {

    // MARK: - Harness

    private func makeSummary(id: String, lastActive: Double? = 100) -> SessionSummary {
        SessionSummary(
            id: id, title: "T-\(id)", preview: nil, startedAt: 1_000,
            messageCount: 3, source: nil, lastActive: lastActive, cwd: nil
        )
    }

    private func makeInMemoryCache() throws -> CacheStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        return try CacheStore(testDB: queue)
    }

    private func makeGraph() -> (ConnectionStore, SessionStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (connection, sessions)
    }

    private let serverURL = "https://cancel.example:9443"

    // MARK: - Classifier

    /// The single cancellation predicate must recognise all three shapes and must
    /// NOT swallow a genuine timeout or generic failure.
    func testIsRefreshCancellationClassifiesAllThreeShapes() {
        XCTAssertTrue(SessionStore.isRefreshCancellation(CancellationError()))
        XCTAssertTrue(SessionStore.isRefreshCancellation(URLError(.cancelled)))
        XCTAssertFalse(SessionStore.isRefreshCancellation(URLError(.timedOut)))
        struct Boom: Error {}
        XCTAssertFalse(SessionStore.isRefreshCancellation(Boom()))
    }

    // MARK: - Cancellation keeps cached rows + no error

    /// A `CancellationError` thrown mid-refresh must leave the retained rows in
    /// place and must NOT write `lastError`.
    func testCancellationDuringRefreshKeepsCachedRowsAndNoError() async {
        let store = SessionStore()
        store.sessions = [makeSummary(id: "A", lastActive: 200),
                          makeSummary(id: "B", lastActive: 100)]
        store.lastError = nil
        store.sessionsFetch = { throw CancellationError() }

        await store.refresh()

        XCTAssertEqual(store.sessions.map(\.id), ["A", "B"],
            "a cancelled refresh must retain the cached rows (#208)")
        XCTAssertNil(store.lastError,
            "cancellation is control flow and must never reach lastError (#208)")
    }

    /// A `URLError.cancelled` (a torn-down URLSession task on reconnect/scope
    /// switch) is cancellation too — it must not surface an error row.
    func testURLErrorCancelledDoesNotSetLastError() async {
        let store = SessionStore()
        store.sessions = [makeSummary(id: "A")]
        store.lastError = nil
        store.sessionsFetch = { throw URLError(.cancelled) }

        await store.refresh()

        XCTAssertNil(store.lastError,
            "URLError.cancelled is a torn-down session, not a failure (#208)")
        XCTAssertEqual(store.sessions.map(\.id), ["A"])
    }

    // MARK: - Genuine failure preserved

    /// A genuine failure with NOTHING cached must still surface the error so the
    /// drawer can show the error row (existing behavior preserved).
    func testGenuineFailureWithEmptyCacheSetsLastError() async {
        struct Boom: LocalizedError { var errorDescription: String? { "network down" } }
        let store = SessionStore()
        store.sessions = []
        store.lastError = nil
        store.sessionsFetch = { throw Boom() }

        await store.refresh()

        XCTAssertEqual(store.lastError, "network down",
            "a genuine failure with nothing cached must still surface the error (#208)")
    }

    // MARK: - paintFromCache re-paint after the list regressed to empty

    /// The cold-read latch must not permanently suppress a re-paint: if the
    /// in-memory list was emptied (a cancelled/failed refresh, or a foreground
    /// recovery), `paintFromCache()` must re-read the disk snapshot rather than
    /// leave the drawer stuck empty.
    func testPaintFromCacheRepaintsAfterListEmptied() async throws {
        let (connection, sessions) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        try await cache.saveSessionList(
            [makeSummary(id: "s1", lastActive: 200), makeSummary(id: "s2", lastActive: 100)],
            scope: scope)

        // First paint arms the latch and populates the drawer.
        await sessions.paintFromCache()
        XCTAssertEqual(Set(sessions.sessions.map(\.id)), ["s1", "s2"])

        // The list regresses to empty (a cancelled refresh cleared it). A repaint
        // must re-read disk despite the latch already being set for this scope.
        sessions.sessions = []
        await sessions.paintFromCache()
        XCTAssertEqual(Set(sessions.sessions.map(\.id)), ["s1", "s2"],
            "paintFromCache must re-paint after the list regressed to empty (#208)")
    }

    /// The latch is still honoured for a WARM list: a repaint while rows are on
    /// screen must not re-clobber them (guards against over-eager re-reads).
    func testPaintFromCacheStillLatchedWhileWarm() async throws {
        let (connection, sessions) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        try await cache.saveSessionList([makeSummary(id: "s1")], scope: scope)

        await sessions.paintFromCache()
        XCTAssertEqual(sessions.sessions.map(\.id), ["s1"])

        sessions.sessions = [makeSummary(id: "warm")]
        await sessions.paintFromCache()
        XCTAssertEqual(sessions.sessions.map(\.id), ["warm"],
            "a warm list is never re-clobbered by a latched repaint (#208)")
    }
}
