import XCTest
@testable import HermesMobile

/// ABH-316 — Recents must be human-chat-only by default on cron/subagent-heavy
/// gateways. These tests pin the client-side invariant (old caches / old gateways)
/// and the REST query shape the live drawer path uses for fresh pages.
@MainActor
final class SessionListSourceFilterTests: XCTestCase {
    private let hideCronKey = DefaultsKeys.hideCron

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: hideCronKey)
        super.tearDown()
    }

    func testHideCronDefaultsOnForHumanRecentsWhenUnset() {
        UserDefaults.standard.removeObject(forKey: hideCronKey)

        let store = SessionStore()

        XCTAssertTrue(store.hideCron,
            "A fresh install must default human Recents away from automation firehose rows")
    }

    func testExplicitHideCronPreferenceStillWins() {
        UserDefaults.standard.set(false, forKey: hideCronKey)

        let store = SessionStore()

        XCTAssertFalse(store.hideCron,
            "An explicit persisted preference should not be overwritten by the default")
    }

    func testVisibleSessionsExcludeCronSubagentAndEmptyRowsByDefault() async {
        UserDefaults.standard.removeObject(forKey: hideCronKey)
        let store = SessionStore()

        let mixedRows = [
            summary(id: "cron", source: "cron", messageCount: 4, lastActive: 500),
            summary(id: "subagent", source: "subagent", messageCount: 4, lastActive: 400),
            summary(id: "emptyTelegram", source: "telegram", messageCount: 0, lastActive: 300),
            summary(id: "emptyTui", source: "tui", messageCount: 0, lastActive: 250),
            summary(id: "telegram", source: "telegram", messageCount: 2, lastActive: 200),
            summary(id: "tui", source: "tui", messageCount: 1, lastActive: 100),
            summary(id: "cliUnknownCount", source: "cli", messageCount: nil, lastActive: 50),
        ]
        store.sessionsFetch = { (mixedRows, mixedRows.count) }

        await store.refresh()

        XCTAssertEqual(store.visibleSessions.map(\.id), ["telegram", "tui", "cliUnknownCount"],
            "Recents should show only human-facing non-empty rows; nil count is kept because old gateways may omit it")
        XCTAssertEqual(store.filteredCount, 3)
        XCTAssertEqual(SessionStore.recentsExcludeSources, ["cron", "subagent"],
            "Fresh drawer pages must ask the server to omit both autonomous sources")
    }

    func testDrawerSourceGroupsSplitReachableChatsAndTelegramInStaticOrder() {
        UserDefaults.standard.removeObject(forKey: hideCronKey)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedSessions)
        let store = SessionStore()
        store.sessions = [
            summary(id: "telegram", source: "telegram", messageCount: 3, lastActive: 400),
            summary(id: "human", source: "app", messageCount: 2, lastActive: 300),
            summary(id: "cliMachinery", source: "cli", title: "Loop Plan #51", messageCount: 5, lastActive: 200),
            summary(id: "emptyTelegram", source: "telegram", messageCount: 0, lastActive: 100),
        ]

        let groups = store.drawerSourceGroups()

        XCTAssertEqual(groups.map(\.kind), [.chats, .telegram],
            "Drawer sections must keep the desktop static source order, not global recency order")
        XCTAssertEqual(groups[0].sessions.map(\.id), ["human"],
            "Chats must reuse the human Recents predicate and exclude generated CLI machinery")
        XCTAssertEqual(groups[1].sessions.map(\.id), ["telegram"],
            "Telegram-source sessions belong in their own section, not mixed into Chats")
    }

    func testDrawerPinnedSessionsStayAboveAndOutOfEverySourceGroup() {
        UserDefaults.standard.removeObject(forKey: hideCronKey)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedSessions)
        let store = SessionStore()
        let pinnedTelegram = summary(id: "pinnedTelegram", source: "telegram", messageCount: 4, lastActive: 500)
        let chat = summary(id: "chat", source: "app", messageCount: 4, lastActive: 300)
        store.sessions = [pinnedTelegram, chat]
        store.togglePin(pinnedTelegram)

        XCTAssertEqual(store.drawerPinnedSessions.map(\.id), ["pinnedTelegram"],
            "Pinned Telegram rows must stay on top across source groups")
        XCTAssertEqual(store.drawerSourceGroups().flatMap { $0.sessions.map(\.id) }, ["chat"],
            "A pinned session must be removed from its source group so it appears exactly once")

        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedSessions)
    }

    func testDrawerSourceGroupsKeepDesignedEmptyTelegramState() {
        UserDefaults.standard.removeObject(forKey: hideCronKey)
        let store = SessionStore()
        store.sessions = [summary(id: "chat", source: "app", messageCount: 4, lastActive: 500)]

        let groups = store.drawerSourceGroups()

        XCTAssertEqual(groups.map(\.kind), [.chats, .telegram],
            "The drawer must always reserve only reachable source sections")
        XCTAssertEqual(groups.map(\.count), [1, 0],
            "Empty Telegram gets an honest zero-count empty state without inventing unreachable buckets")
        XCTAssertEqual(groups[1].emptyTitle, "No Telegram chats yet")
    }

    func testDrawerWorkspaceGroupsUseChatsOnlyAndPreservePinnedWorkspaceOrdering() throws {
        UserDefaults.standard.removeObject(forKey: hideCronKey)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedSessions)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedWorkspaces)
        let store = SessionStore()
        store.sessions = [
            summary(id: "telegram", source: "telegram", messageCount: 3, lastActive: 600, cwd: "/repo/chat"),
            summary(id: "chatA", source: "app", messageCount: 3, lastActive: 400, cwd: "/repo/a"),
            summary(id: "chatB", source: "app", messageCount: 3, lastActive: 300, cwd: "/repo/b"),
        ]
        store.togglePinnedWorkspace("/repo/b")

        let chats = try XCTUnwrap(store.drawerSourceGroups().first { $0.kind == .chats })
        let workspaceGroups = store.drawerWorkspaceGroups(for: chats)

        XCTAssertEqual(workspaceGroups.map(\.id), ["/repo/b", "/repo/a"],
            "Workspace grouping must apply within the Chats source group only, with pinned workspace ordering preserved")
        XCTAssertEqual(workspaceGroups.flatMap { $0.sessions.map(\.id) }, ["chatB", "chatA"],
            "Telegram rows must stay in their own source section, not leak into Chats workspace groups")

        UserDefaults.standard.removeObject(forKey: DefaultsKeys.pinnedWorkspaces)
    }

    func testRecentsRestQueryExcludesCronSubagentAndEmptySessions() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = (
            data: #"{"sessions":[],"total":0}"#.data(using: .utf8)!,
            status: 200
        )
        SessionListSourceFilterStubProtocol.requestedURL = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionListSourceFilterStubProtocol.self]
        let rest = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )

        _ = try await rest.sessionsWithTotal(
            limit: 100,
            minMessages: 1,
            excludeSource: SessionStore.recentsExcludeSources
        )

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(SessionListSourceFilterStubProtocol.requestedURL), resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(components.path, "/api/sessions")
        XCTAssertEqual(queryItems["min_messages"], "1")
        XCTAssertEqual(queryItems["exclude_sources"], "cron,subagent")
        XCTAssertNil(queryItems["exclude_source"], "The singular param is ignored by the gateway and must not regress")
    }

    func testSessionExportFetchesFullMessagesRouteAndRendersMarkdown() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = (
            data: #"{"messages":[{"id":1,"role":"user","content":"Hello"},{"id":2,"role":"assistant","content":"Hi there"}]}"#.data(using: .utf8)!,
            status: 200
        )
        SessionListSourceFilterStubProtocol.requestedURL = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionListSourceFilterStubProtocol.self]
        let rest = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )

        let markdown = try await rest.exportSessionMarkdown(summary: summary(
            id: "session 1",
            source: "cli",
            title: "Export me",
            messageCount: 2,
            lastActive: 123
        ))

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(SessionListSourceFilterStubProtocol.requestedURL), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/sessions/session%201/messages")
        XCTAssertFalse(components.path.contains("/export"), "iOS export must use the full transcript messages route, not the desktop-only export route")
        XCTAssertTrue(markdown.contains("# Export me"))
        let userHeading = try XCTUnwrap(markdown.range(of: "## User")?.lowerBound)
        let assistantHeading = try XCTUnwrap(markdown.range(of: "## Assistant")?.lowerBound)
        XCTAssertLessThan(userHeading, assistantHeading)
        XCTAssertTrue(markdown.contains("Hello"))
        XCTAssertTrue(markdown.contains("Hi there"))
    }

    func testSessionExportRejectsEmptyTranscript() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = (
            data: #"{"messages":[]}"#.data(using: .utf8)!,
            status: 200
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionListSourceFilterStubProtocol.self]
        let rest = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )

        do {
            _ = try await rest.exportSessionMarkdown(summary: summary(
                id: "empty",
                source: "cli",
                messageCount: 0,
                lastActive: 123
            ))
            XCTFail("empty exports should fail instead of presenting a half-file")
        } catch let error as RestError {
            XCTAssertTrue(error.localizedDescription.contains("No messages"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func summary(
        id: String,
        source: String?,
        title: String? = nil,
        messageCount: Int?,
        lastActive: Double,
        cwd: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            title: title ?? id,
            preview: nil,
            startedAt: nil,
            messageCount: messageCount,
            source: source,
            lastActive: lastActive,
            cwd: cwd
        )
    }
}

private final class SessionListSourceFilterStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (data: Data, status: Int)?
    nonisolated(unsafe) static var requestedURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedURL = request.url
        guard let (data, status) = Self.nextResponse else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
