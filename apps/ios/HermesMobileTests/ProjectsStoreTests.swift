import XCTest
import GRDB
@testable import HermesMobile

/// Contract tests for the single stock-gateway Projects path.
@MainActor
final class ProjectsStoreTests: XCTestCase {
    private let scope = CacheScope(serverId: "https://gw.example", profileId: "all")

    private func json(_ source: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    }

    private func makeCache() throws -> CacheStore {
        try CacheStore(testDB: DatabaseQueue())
    }

    private func project(_ id: String, count: Int = 1) -> Project {
        Project(id: id, label: "Project", root: "/Volumes/MainData/Project", sessionCount: count)
    }

    private func waitForProjects(in cache: CacheStore) async throws -> [Project] {
        for _ in 0..<50 {
            let loaded = try await cache.loadProjects(scope: scope)
            if !loaded.isEmpty { return loaded }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try await cache.loadProjects(scope: scope)
    }

    private func waitForProjectSessions(
        in cache: CacheStore,
        id: String
    ) async throws -> [SessionSummary]? {
        for _ in 0..<50 {
            if let loaded = try await cache.loadProjectSessions(scope: scope, projectId: id) {
                return loaded
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try await cache.loadProjectSessions(scope: scope, projectId: id)
    }

    func testOverviewUsesStockProjectsTree() async throws {
        let store = ProjectsStore()
        var calls: [(String, JSONValue)] = []
        store.gatewayRequest = { method, params in
            calls.append((method, params))
            return try self.json(
                #"{"projects":[{"id":"p1","label":"Hermes Mobile","path":"/Volumes/MainData/Developer/products/hermes-mobile","session_count":72,"repos":[]}]}"#
            )
        }

        await store.refresh()

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "projects.tree")
        XCTAssertEqual(calls[0].1, .object(["preview_limit": .number(3)]))
        XCTAssertEqual(
            store.projects,
            [Project(
                id: "p1",
                label: "Hermes Mobile",
                root: "/Volumes/MainData/Developer/products/hermes-mobile",
                sessionCount: 72
            )]
        )
        XCTAssertNil(store.loadError)
    }

    func testDetailUsesStockProjectOwnershipNotLocalPathPrefix() async throws {
        let store = ProjectsStore()
        var calls: [(String, JSONValue)] = []
        store.gatewayRequest = { method, params in
            calls.append((method, params))
            return try self.json(
                """
                {
                  "project": {
                    "id": "p1",
                    "label": "Hermes Mobile",
                    "path": "/Volumes/MainData/Developer/products/hermes-mobile",
                    "session_count": 1,
                    "repos": [{
                      "path": "/Volumes/MainData/Developer/products/hermes-mobile",
                      "groups": [{
                        "sessions": [{
                          "id": "s1",
                          "title": "Device session",
                          "message_count": 3,
                          "cwd": "/Users/abbhinnav/Developer/products/hermes-mobile"
                        }]
                      }]
                    }]
                  }
                }
                """
            )
        }
        let target = project("p1")

        await store.refreshSessions(for: target)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "projects.project_sessions")
        XCTAssertEqual(calls[0].1, .object(["project_id": .string("p1")]))
        XCTAssertEqual(store.sessions(for: target).map(\.id), ["s1"])
        XCTAssertNil(store.sessionsError(for: target))
    }

    func testDetailDoesNotLeakSessionsFromAnotherProject() async throws {
        let store = ProjectsStore()
        store.gatewayRequest = { _, _ in
            try self.json(
                #"{"project":{"id":"p1","label":"One","path":"/one","session_count":1,"repos":[{"groups":[{"sessions":[{"id":"owned","title":"Owned","message_count":2,"cwd":"/one"}]}]}]}}"#
            )
        }
        let target = project("p1")

        await store.refreshSessions(for: target)

        XCTAssertEqual(store.sessions(for: target).map(\.id), ["owned"])
        XCTAssertTrue(store.sessions(for: project("p2")).isEmpty)
    }

    func testCreateUsesStockProjectsCreateThenRefreshesTree() async throws {
        let store = ProjectsStore()
        var methods: [String] = []
        store.gatewayRequest = { method, params in
            methods.append(method)
            if method == "projects.create" {
                XCTAssertEqual(
                    params,
                    .object([
                        "name": .string("New Project"),
                        "primary_path": .string("/tmp/new-project"),
                    ])
                )
                return try self.json(
                    #"{"project":{"id":"new-id","name":"New Project","primary_path":"/tmp/new-project","folders":[]}}"#
                )
            }
            return try self.json(
                #"{"projects":[{"id":"new-id","label":"New Project","path":"/tmp/new-project","session_count":0,"repos":[]}]}"#
            )
        }

        let result = await store.createProject(name: " New Project ", root: " /tmp/new-project ")

        XCTAssertEqual(
            result,
            .created(Project(
                id: "new-id",
                label: "New Project",
                root: "/tmp/new-project",
                sessionCount: 0
            ))
        )
        XCTAssertEqual(methods, ["projects.create", "projects.tree"])
    }

    func testOfflineOverviewPaintsCache() async throws {
        let cache = try makeCache()
        let cached = Project(id: "p1", label: "Cached", root: "/cached", sessionCount: 2)
        try await cache.saveProjects([cached], scope: scope)
        let store = ProjectsStore()
        store.attachCache(cache, scope: { [scope] in scope })

        await store.refresh()

        XCTAssertEqual(store.projects, [cached])
        XCTAssertNil(store.loadError)
    }

    func testSuccessfulOverviewWritesCache() async throws {
        let cache = try makeCache()
        let store = ProjectsStore()
        store.attachCache(cache, scope: { [scope] in scope })
        store.gatewayRequest = { _, _ in
            try self.json(
                #"{"projects":[{"id":"p1","label":"Fresh","path":"/fresh","session_count":4,"repos":[]}]}"#
            )
        }

        await store.refresh()

        let cached = try await waitForProjects(in: cache)
        XCTAssertEqual(cached.map(\.id), ["p1"])
    }

    func testOfflineDetailPaintsCache() async throws {
        let cache = try makeCache()
        let target = project("p1")
        let session = try XCTUnwrap(
            try json(
                #"{"id":"cached","title":"Cached","message_count":2,"cwd":"/cached"}"#
            ).decoded(as: SessionSummary.self)
        )
        try await cache.saveProjectSessions([session], scope: scope, projectId: target.id)
        let store = ProjectsStore()
        store.attachCache(cache, scope: { [scope] in scope })

        await store.refreshSessions(for: target)

        XCTAssertEqual(store.sessions(for: target).map(\.id), ["cached"])
        XCTAssertNil(store.sessionsError(for: target))
    }

    func testSuccessfulDetailWritesCache() async throws {
        let cache = try makeCache()
        let target = project("p1")
        let store = ProjectsStore()
        store.attachCache(cache, scope: { [scope] in scope })
        store.gatewayRequest = { _, _ in
            try self.json(
                #"{"project":{"id":"p1","label":"One","path":"/one","session_count":1,"repos":[{"groups":[{"sessions":[{"id":"fresh","title":"Fresh","message_count":2,"cwd":"/one"}]}]}]}}"#
            )
        }

        await store.refreshSessions(for: target)

        let cached = try await waitForProjectSessions(in: cache, id: target.id)
        XCTAssertEqual(cached?.map(\.id), ["fresh"])
    }
}
