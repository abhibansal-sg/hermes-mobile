import XCTest
import GRDB
@testable import HermesMobile

/// Store-level behaviour for the Projects repair:
///   • fix (a) — Project detail fetches the plugin `project-sessions` route and
///     falls back to the legacy `cwd_prefix` path ONLY on a 404 (old gateway).
///   • fix (c) — cache-first: offline seeds paint the last-known list instead of
///     a blank "Not connected" wall, and successful fetches write through.
///
/// The 404-fallback and write-through paths are driven through a real
/// ``RestClient`` wired to a `URLProtocol` stub (the STR-1417
/// `_restOverrideForTesting` seam), so the actual route selection + decode runs.
/// Cache paths use a real in-memory ``CacheStore``.
@MainActor
final class ProjectsStoreTests: XCTestCase {

    // MARK: - Routing stub transport

    /// Routes by URL path: the plugin `project-sessions` route, the legacy
    /// `/api/sessions` fallback, and `/projects` (overview GET) are each answered
    /// from an independently-settable `(body, status)`.
    final class RoutingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var projectSessions: (Data, Int) = (Data(), 200)
        nonisolated(unsafe) static var legacySessions: (Data, Int) = (Data(), 200)
        nonisolated(unsafe) static var overview: (Data, Int) = (Data("[]".utf8), 200)
        nonisolated(unsafe) static var projectSessionsHits = 0
        nonisolated(unsafe) static var legacySessionsHits = 0

        static func reset() {
            projectSessions = (Data(), 200)
            legacySessions = (Data(), 200)
            overview = (Data("[]".utf8), 200)
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
                (body, status) = Self.projectSessions
            } else if path.hasSuffix("/sessions") {
                Self.legacySessionsHits += 1
                (body, status) = Self.legacySessions
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

    func testDetailNon404ErrorDoesNotFallBackAndSurfacesError() async throws {
        let store = try makeConnectedStore()
        RoutingProtocol.projectSessions = (Data(#"{"detail":"boom"}"#.utf8), 500)
        RoutingProtocol.legacySessions = (sessionsWrapper(ids: ["should-not-appear"], total: 1), 200)

        let proj = project("/repo/root")
        await store.refreshSessions(for: proj)

        XCTAssertTrue(store.sessions(for: proj).isEmpty, "a 500 must not silently fall back")
        XCTAssertNotNil(store.sessionsError(for: proj))
        XCTAssertEqual(RoutingProtocol.legacySessionsHits, 0)
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
