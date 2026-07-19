import XCTest
import GRDB
@testable import HermesMobile

/// Cache-first Projects (fix c) — persistence round-trips for the two
/// CacheSchema-v6 tables backing the Projects tab:
///   • `project_cache`          — the overview list (order-preserving,
///     full-list write-through so server-side deletions never linger).
///   • `project_session_cache`  — one JSON snapshot of a project's detail list.
///
/// Every case drives a real (in-memory) migrated `CacheStore`, so the migrator,
/// the GRDB record mapping, and the scope partitioning are all exercised end to
/// end. No gateway or filesystem is touched.
final class ProjectsCacheTests: XCTestCase {

    private func store() throws -> CacheStore { try CacheStore(testDB: DatabaseQueue()) }

    private let scopeA = CacheScope(serverId: "https://a.example", profileId: "all")
    private let scopeB = CacheScope(serverId: "https://b.example", profileId: "all")

    private func project(_ id: String, count: Int = 0) -> Project {
        Project(id: id, label: "label-\(id)", root: id, sessionCount: count)
    }

    private func summary(_ id: String, cwd: String) -> SessionSummary {
        SessionSummary(
            id: id, title: id, preview: nil, startedAt: 1, messageCount: 2,
            source: "tui", lastActive: 10, cwd: cwd
        )
    }

    // MARK: - project_cache (overview)

    func testSaveLoadProjectsPreservesServerOrder() async throws {
        let cache = try store()
        let projects = [project("/a/one"), project("/a/two", count: 5), project("/a/three")]
        try await cache.saveProjects(projects, scope: scopeA)

        let loaded = try await cache.loadProjects(scope: scopeA)
        XCTAssertEqual(loaded.map(\.id), ["/a/one", "/a/two", "/a/three"])
        XCTAssertEqual(loaded.map(\.label), ["label-/a/one", "label-/a/two", "label-/a/three"])
        XCTAssertEqual(loaded.first(where: { $0.id == "/a/two" })?.sessionCount, 5)
    }

    func testSaveProjectsIsFullListWriteThroughDroppingStaleRows() async throws {
        let cache = try store()
        try await cache.saveProjects([project("/a/one"), project("/a/two")], scope: scopeA)
        // A later refresh where /a/two no longer exists server-side.
        try await cache.saveProjects([project("/a/one")], scope: scopeA)

        let loaded = try await cache.loadProjects(scope: scopeA)
        XCTAssertEqual(loaded.map(\.id), ["/a/one"], "stale project must not linger")
    }

    func testProjectsPartitionedByScope() async throws {
        let cache = try store()
        try await cache.saveProjects([project("/a/one")], scope: scopeA)

        XCTAssertEqual(try await cache.loadProjects(scope: scopeA).map(\.id), ["/a/one"])
        XCTAssertTrue(
            try await cache.loadProjects(scope: scopeB).isEmpty,
            "another (server, profile) partition must not see scopeA's projects"
        )
    }

    func testLoadProjectsEmptyWhenNothingPersisted() async throws {
        let cache = try store()
        XCTAssertTrue(try await cache.loadProjects(scope: scopeA).isEmpty)
    }

    // MARK: - project_session_cache (detail)

    func testSaveLoadProjectSessionsRoundTrip() async throws {
        let cache = try store()
        let sessions = [
            summary("s1", cwd: "/a/one/wt-a"),
            summary("s2", cwd: "/a/one/wt-b"),
        ]
        try await cache.saveProjectSessions(sessions, scope: scopeA, projectId: "/a/one")

        let loaded = try await cache.loadProjectSessions(scope: scopeA, projectId: "/a/one")
        XCTAssertEqual(loaded?.map(\.id), ["s1", "s2"])
        XCTAssertEqual(loaded?.first?.cwd, "/a/one/wt-a")
    }

    func testLoadProjectSessionsNilWhenNoSnapshot() async throws {
        let cache = try store()
        let loaded = try await cache.loadProjectSessions(scope: scopeA, projectId: "/never/saved")
        XCTAssertNil(loaded, "a missing snapshot is nil, distinct from an empty []")
    }

    func testSaveProjectSessionsUpsertsSnapshot() async throws {
        let cache = try store()
        try await cache.saveProjectSessions(
            [summary("old", cwd: "/a/one")], scope: scopeA, projectId: "/a/one"
        )
        try await cache.saveProjectSessions(
            [summary("new1", cwd: "/a/one"), summary("new2", cwd: "/a/one")],
            scope: scopeA, projectId: "/a/one"
        )
        let loaded = try await cache.loadProjectSessions(scope: scopeA, projectId: "/a/one")
        XCTAssertEqual(loaded?.map(\.id), ["new1", "new2"])
    }

    func testProjectSessionsPartitionedByScopeAndProject() async throws {
        let cache = try store()
        try await cache.saveProjectSessions(
            [summary("s1", cwd: "/a/one")], scope: scopeA, projectId: "/a/one"
        )
        XCTAssertNil(try await cache.loadProjectSessions(scope: scopeB, projectId: "/a/one"))
        XCTAssertNil(try await cache.loadProjectSessions(scope: scopeA, projectId: "/a/other"))
    }
}
