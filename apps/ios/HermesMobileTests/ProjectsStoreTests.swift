import XCTest
import GRDB
@testable import HermesMobile

/// Store-level behaviour for the Projects repair:
///   • fix (a) — Project detail fetches the plugin `project-sessions` route and
///     falls back to the legacy `cwd_prefix` path on a 404 (old gateway) OR a
///     transient 401/403/5xx/network failure (PROJECTS-401: a gateway
///     crash-respawn window can race device-token auth), then retries the
///     whole two-tier fetch once with a short backoff before surfacing a
///     directional error.
///   • fix (c) — cache-first: offline seeds paint the last-known list instead of
///     a blank "Not connected" wall, and successful fetches write through.
///
/// The fallback/retry and write-through paths are driven through a real
/// ``RestClient`` wired to a `URLProtocol` stub (the STR-1417
/// `_restOverrideForTesting` seam), so the actual route selection + decode runs.
/// Cache paths use a real in-memory ``CacheStore``.
@MainActor
final class ProjectsStoreTests: XCTestCase {

    // MARK: - Routing stub transport

    /// Routes by URL path: the plugin `project-sessions` route, the legacy
    /// `/api/sessions` fallback, and `/projects` (overview GET) are each answered
    /// from an independently-settable `(body, status)`. A route may instead be
    /// driven by `*Sequence` — one entry per call, by 1-indexed hit count,
    /// clamped to the last entry once exhausted — so a fix-(a) retry test can
    /// simulate "401 once, then recovers" across the two calls the retry makes.
    final class RoutingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var projectSessions: (Data, Int) = (Data(), 200)
        nonisolated(unsafe) static var legacySessions: (Data, Int) = (Data(), 200)
        nonisolated(unsafe) static var overview: (Data, Int) = (Data("[]".utf8), 200)
        nonisolated(unsafe) static var projectSessionsSequence: [(Data, Int)]?
        nonisolated(unsafe) static var legacySessionsSequence: [(Data, Int)]?
        nonisolated(unsafe) static var projectSessionsHits = 0
        nonisolated(unsafe) static var legacySessionsHits = 0

        static func reset() {
            projectSessions = (Data(), 200)
            legacySessions = (Data(), 200)
            overview = (Data("[]".utf8), 200)
            projectSessionsSequence = nil
            legacySessionsSequence = nil
            projectSessionsHits = 0
            legacySessionsHits = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            let (body, status): (Data, Int)
            if path.hasSuffix("/project-sessions") {
                Self.projectSessionsHits += 1
                if let sequence = Self.projectSessionsSequence, !sequence.isEmpty {
                    (body, status) = sequence[min(Self.projectSessionsHits, sequence.count) - 1]
                } else {
                    (body, status) = Self.projectSessions
                }
            } else if path.hasSuffix("/sessions") {
                Self.legacySessionsHits += 1
                if let sequence = Self.legacySessionsSequence, !sequence.isEmpty {
                    (body, status) = sequence[min(Self.legacySessionsHits, sequence.count) - 1]
                } else {
                    (body, status) = Self.legacySessions
                }
            } else {
                (body, status) = Self.overview
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    // MARK: - Fixtures

    private let scope = CacheScope(serverId: "https://gw.example", profileId: "all")

    private func makeCache() throws -> CacheStore { try CacheStore(testDB: DatabaseQueue()) }

    private func attach(_ store: ProjectsStore, cache: CacheStore) {
        store.attachCache(cache, scope: { [scope] in scope })
    }

    private func makeConnectedStore(cache: CacheStore? = nil) throws -> ProjectsStore {
        RoutingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutingProtocol.self]
        let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())
        connection._restOverrideForTesting = RestClient(
            baseURL: URL(string: "https://gw.example:9119")!,
            token: "tok",
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )
        let store = ProjectsStore()
        store.attach(connection: connection)
        // Zero out the fix-(a) retry backoff so the transient-failure tests
        // don't burn real wall-clock time on the production 600ms delay.
        store.projectSessionsRetryDelayOverrideNanoseconds = 0
        if let cache { attach(store, cache: cache) }
        return store
    }

    private func project(_ id: String, count: Int = 1) -> Project {
        Project(id: id, label: "label-\(id)", root: id, sessionCount: count)
    }

    private func sessionsWrapper(ids: [String], total: Int) -> Data {
        let rows = ids.map { #"{"id":"\#($0)","title":"\#($0)","message_count":3,"cwd":"/repo/wt"}"# }
        return Data(#"{"sessions":[\#(rows.joined(separator: ","))],"total":\#(total)}"#.utf8)
    }

    /// Poll the injected cache until the fire-and-forget write-through lands
    /// (both write helpers spawn a detached Task).
    private func waitForProjects(in cache: CacheStore) async throws -> [Project] {
        for _ in 0..<50 {
            let loaded = try await cache.loadProjects(scope: scope)
            if !loaded.isEmpty { return loaded }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try await cache.loadProjects(scope: scope)
    }

    private func waitForProjectSessions(in cache: CacheStore, id: String) async throws -> [SessionSummary]? {
        for _ in 0..<50 {
            if let loaded = try await cache.loadProjectSessions(scope: scope, projectId: id) {
                return loaded
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try await cache.loadProjectSessions(scope: scope, projectId: id)
    }

    // MARK: - fix (a): project-sessions route + 404 fallback

    func testDetailUsesPluginProjectSessionsRoute() async throws {
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessions = (sessionsWrapper(ids: ["s1", "s2"], total: 2), 200)
        // If the primary route were skipped this stub would never be consulted.
        RoutingProtocol.legacySessions = (sessionsWrapper(ids: ["WRONG"], total: 1), 200)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertEqual(store.sessions(for: proj).map(\.id), ["s1", "s2"])
        XCTAssertNil(store.sessionsError(for: proj))
        XCTAssertEqual(RoutingProtocol.projectSessionsHits, 1)
        XCTAssertEqual(RoutingProtocol.legacySessionsHits, 0, "must not hit the legacy path when the plugin route serves")
    }

    /// S10 (QA-3): a fetch that SUCCEEDS with `[]` while the project overview's
    /// `sessionCount > 0` must NOT be accepted as authoritative — the server's
    /// detail query missed worktree cwds (the cwd_prefix LIKE cannot fold them;
    /// IMG_2593 "SESSIONS 0"). Treat it as a transient failure: surface the
    /// directional "Reconnecting to gateway — retry" state instead of a lying
    /// "No sessions yet". The server-side `_cwd_prefix_clause` fix closes the
    /// actual data hole; this is the iOS-side defensive backstop.
    func testDetailEmptyListWhenCountPositiveSurfacesRetryNotLyingEmpty() async throws {
        let store = try makeConnectedStore()
        // The plugin route "succeeds" but with an empty list — the worktree
        // cwd-prefix miss. The overview count (4) is authoritative.
        RoutingProtocol.projectSessions = (sessionsWrapper(ids: [], total: 0), 200)
        RoutingProtocol.legacySessions = (sessionsWrapper(ids: [], total: 0), 200)

        let proj = project("/Volumes/MainData/Developer/products/hermes-mobile", count: 4)
        await store.refreshSessions(for: proj)

        XCTAssertTrue(
            store.sessions(for: proj).isEmpty,
            "an empty list must not be stored as the authoritative detail when count > 0"
        )
        XCTAssertEqual(
            store.sessionsError(for: proj),
            ProjectsStore.projectSessionsEmptyButCountedMessage,
            "a count>0 empty list must surface the retry state, not a lying No-sessions-yet"
        )
    }

    /// S10 sanity: a project whose overview count is genuinely 0 (a brand-new
    /// project with no sessions yet) must still show the honest empty state —
    /// the count-positive gate is precise, not a blanket suppression.
    func testDetailEmptyListWhenCountZeroStoresEmptyWithoutError() async throws {
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessions = (sessionsWrapper(ids: [], total: 0), 200)

        let proj = project("/brand/new/project", count: 0)
        await store.refreshSessions(for: proj)

        XCTAssertTrue(store.sessions(for: proj).isEmpty)
        XCTAssertNil(store.sessionsError(for: proj), "count==0 + empty list is the honest empty state")
    }

    func testDetailFallsBackToCwdPrefixOn404() async throws {
        let store = try makeConnectedStore()
        // Old gateway: plugin route 404s, legacy cwd_prefix path answers.
        RoutingProtocol.projectSessions = (Data(#"{"detail":"Not Found"}"#.utf8), 404)
        RoutingProtocol.legacySessions = (sessionsWrapper(ids: ["legacy1"], total: 1), 200)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertEqual(store.sessions(for: proj).map(\.id), ["legacy1"], "404 must fall back to cwd_prefix")
        XCTAssertNil(store.sessionsError(for: proj))
        XCTAssertEqual(RoutingProtocol.projectSessionsHits, 1)
        XCTAssertEqual(RoutingProtocol.legacySessionsHits, 1)
    }

    func testDetailNonTransientErrorDoesNotFallBackAndSurfacesError() async throws {
        // A genuinely malformed request (not an auth race, not "old gateway",
        // not a 5xx) must propagate honestly — no fallback, no retry.
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessions = (Data(#"{"detail":"bad request"}"#.utf8), 400)
        RoutingProtocol.legacySessions = (sessionsWrapper(ids: ["should-not-appear"], total: 1), 200)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertTrue(store.sessions(for: proj).isEmpty, "a 400 must not silently fall back")
        XCTAssertEqual(store.sessionsError(for: proj), "Server returned HTTP 400: {\"detail\":\"bad request\"}")
        XCTAssertEqual(RoutingProtocol.legacySessionsHits, 0)
        XCTAssertEqual(RoutingProtocol.projectSessionsHits, 1, "no retry for a non-transient failure")
    }

    // MARK: - fix (a): PROJECTS-401 — 401/403/5xx treated like the 404 fallback

    func testDetail401FallsBackToCwdPrefixLike404() async throws {
        // Gateway respawn window: the plugin route rejects the still-registering
        // device token, but the core /api/sessions path (older, always-wired
        // auth) already accepts it.
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessions = (Data(#"{"detail":"Unauthorized"}"#.utf8), 401)
        RoutingProtocol.legacySessions = (sessionsWrapper(ids: ["legacy1"], total: 1), 200)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertEqual(store.sessions(for: proj).map(\.id), ["legacy1"], "401 must fall back to cwd_prefix, like 404")
        XCTAssertNil(store.sessionsError(for: proj))
        XCTAssertEqual(RoutingProtocol.legacySessionsHits, 1)
    }

    func testDetail403FallsBackToCwdPrefixLike404() async throws {
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessions = (Data(#"{"detail":"Forbidden"}"#.utf8), 403)
        RoutingProtocol.legacySessions = (sessionsWrapper(ids: ["legacy1"], total: 1), 200)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertEqual(store.sessions(for: proj).map(\.id), ["legacy1"])
        XCTAssertNil(store.sessionsError(for: proj))
    }

    func testDetail5xxFallsBackToCwdPrefixLike404() async throws {
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessions = (Data(#"{"detail":"boom"}"#.utf8), 503)
        RoutingProtocol.legacySessions = (sessionsWrapper(ids: ["legacy1"], total: 1), 200)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertEqual(store.sessions(for: proj).map(\.id), ["legacy1"])
        XCTAssertNil(store.sessionsError(for: proj))
    }

    func testDetailRetriesOnceAfterBothTiersFailTransiently() async throws {
        // Both the plugin route and its fallback 401 on the first pass (mid
        // respawn); by the retry a beat later the gateway has finished
        // wiring device-token auth and both succeed.
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessionsSequence = [
            (Data(#"{"detail":"Unauthorized"}"#.utf8), 401),
            (Data(#"{"detail":"Unauthorized"}"#.utf8), 401),
        ]
        RoutingProtocol.legacySessionsSequence = [
            (Data(#"{"detail":"Unauthorized"}"#.utf8), 401),
            (sessionsWrapper(ids: ["recovered"], total: 1), 200),
        ]

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertEqual(store.sessions(for: proj).map(\.id), ["recovered"], "the single retry must recover once the respawn window closes")
        XCTAssertNil(store.sessionsError(for: proj))
        XCTAssertEqual(RoutingProtocol.projectSessionsHits, 2, "primary route: initial attempt + the one retry")
        XCTAssertEqual(RoutingProtocol.legacySessionsHits, 2, "fallback route: initial attempt + the one retry")
    }

    func testDetailGivesUpAfterOneRetryAndShowsDirectionalCopy() async throws {
        // The respawn window outlasts both the initial attempt and the retry.
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessions = (Data(#"{"detail":"Unauthorized"}"#.utf8), 401)
        RoutingProtocol.legacySessions = (Data(#"{"detail":"Unauthorized"}"#.utf8), 401)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertTrue(store.sessions(for: proj).isEmpty)
        XCTAssertEqual(store.sessionsError(for: proj), "Reconnecting to gateway — retry",
                        "a still-transient failure after the retry gets directional copy, not raw HTTP")
        XCTAssertEqual(RoutingProtocol.projectSessionsHits, 2, "exactly one retry — not an unbounded loop")
        XCTAssertEqual(RoutingProtocol.legacySessionsHits, 2)
    }

    // MARK: - fix (c): cache-first detail

    func testDetailWritesThroughToCache() async throws {
        let cache = try makeCache()
        let store = try makeConnectedStore(cache: cache)
        RoutingProtocol.projectSessions = (sessionsWrapper(ids: ["s1", "s2"], total: 2), 200)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        let persisted = try await waitForProjectSessions(in: cache, id: proj.id)
        XCTAssertEqual(persisted?.map(\.id), ["s1", "s2"], "successful fetch must write through to the cache")
    }

    func testDetailOfflineSeedsFromCacheInsteadOfNotConnected() async throws {
        let cache = try makeCache()
        let proj = project("/repo/root")
        try await cache.saveProjectSessions(
            [SessionSummary(id: "cached", title: "Cached", preview: nil, startedAt: 1,
                            messageCount: 2, source: "tui", lastActive: 9, cwd: "/repo/wt")],
            scope: scope, projectId: proj.id
        )
        // No connection — offline cold launch.
        let store = ProjectsStore()
        attach(store, cache: cache)

        await store.refreshSessions(for: proj)

        XCTAssertEqual(store.sessions(for: proj).map(\.id), ["cached"])
        XCTAssertNil(store.sessionsError(for: proj), "a cache hit must not show Not connected")
    }

    func testDetailOfflineWithoutCacheShowsNotConnected() async throws {
        let cache = try makeCache()
        let store = ProjectsStore()
        attach(store, cache: cache)
        let proj = project("/repo/root")

        await store.refreshSessions(for: proj)

        XCTAssertTrue(store.sessions(for: proj).isEmpty)
        XCTAssertEqual(store.sessionsError(for: proj), "Not connected")
    }

    // MARK: - fix (c): cache-first overview

    func testRefreshOfflineSeedsProjectsFromCache() async throws {
        let cache = try makeCache()
        try await cache.saveProjects([project("/a/one"), project("/a/two")], scope: scope)
        let store = ProjectsStore()          // no connection
        attach(store, cache: cache)

        await store.refresh()

        XCTAssertEqual(store.projects?.map(\.id), ["/a/one", "/a/two"])
        XCTAssertNil(store.loadError, "a cache hit must not surface Not connected")
    }

    func testRefreshOfflineEmptyCacheShowsNotConnected() async throws {
        let cache = try makeCache()
        let store = ProjectsStore()
        attach(store, cache: cache)

        await store.refresh()

        XCTAssertNil(store.projects)
        XCTAssertEqual(store.loadError, "Not connected")
    }

    func testRefreshWritesThroughOverviewToCache() async throws {
        let cache = try makeCache()
        let store = try makeConnectedStore(cache: cache)
        RoutingProtocol.overview = (
            Data(#"[{"id":"/a/one","label":"One","root":"/a/one","session_count":4}]"#.utf8), 200
        )

        await store.refresh()

        XCTAssertEqual(store.projects?.map(\.id), ["/a/one"])
        let persisted = try await waitForProjects(in: cache)
        XCTAssertEqual(persisted.map(\.id), ["/a/one"])
        XCTAssertEqual(persisted.first?.sessionCount, 4)
    }

    // MARK: - create

    func testCreateProjectValidatesEmptyInputLocally() async throws {
        let store = try makeConnectedStore()
        if case .failure = await store.createProject(name: "  ", root: "/x") {} else {
            XCTFail("empty name must fail fast")
        }
        if case .failure = await store.createProject(name: "x", root: "  ") {} else {
            XCTFail("empty root must fail fast")
        }
    }
}
