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
        XCTAssertEqual(store.visibleSessions.count, 3)
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

    // ABH-407 — Project detail's `cwd_prefix` REST query shape.
    func testProjectDetailRestQueryIncludesPercentEncodedCwdPrefixAndPreservesOtherParams() async throws {
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

        // Exercises space, slash, "+", "&", and "=" in one root: FastAPI/Starlette
        // decode a literal "+" as a space (application/x-www-form-urlencoded
        // convention), so a root containing "+" must wire as "%2B" or it silently
        // corrupts to a space server-side (STR-58 regression).
        let projectRoot = "/Users/abbhinnav/My Projects/hermes+mobile&a=b"
        _ = try await rest.sessionsWithTotal(cwdPrefix: projectRoot)

        let requestedURL = try XCTUnwrap(SessionListSourceFilterStubProtocol.requestedURL)
        let components = try XCTUnwrap(URLComponents(url: requestedURL, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(components.path, "/api/sessions")
        XCTAssertEqual(queryItems["cwd_prefix"], projectRoot,
            "cwd_prefix must round-trip the exact project root, including its spaces, slashes, +, &, and =")
        XCTAssertEqual(queryItems["order"], "recent",
            "Project detail must not regress the order=recent (compression-chain-aware) semantics")
        XCTAssertEqual(queryItems["archived"], "exclude",
            "Project detail must not regress the archived=exclude semantics")
        XCTAssertEqual(queryItems["min_messages"], "1",
            "Project detail must not regress the min_messages=1 scaffold/empty-session filter")

        let rawQuery = components.percentEncodedQuery ?? ""
        XCTAssertFalse(rawQuery.contains(" "),
            "the raw wire query must percent-encode the space in the project root, not send it literally")

        // Foundation's decoded queryItems (checked above) can't tell "%2B" apart
        // from a literal "+" — both decode back to "+". Only the raw wire string
        // proves which one was actually sent, so assert on it directly.
        let cwdPrefixSegment = try XCTUnwrap(
            rawQuery.components(separatedBy: "&").first { $0.hasPrefix("cwd_prefix=") },
            "cwd_prefix must appear as its own delimited query segment"
        )
        XCTAssertTrue(cwdPrefixSegment.contains("%2B"),
            "'+' in the project root must be escaped to %2B on the wire, not left as a literal '+' " +
            "(FastAPI/Starlette decode a literal '+' as a space)")
        XCTAssertFalse(cwdPrefixSegment.contains("+"),
            "the raw wire segment for cwd_prefix must not contain a literal '+'")
        let cwdPrefixValue = String(cwdPrefixSegment.dropFirst("cwd_prefix=".count))
        XCTAssertFalse(cwdPrefixValue.contains("&"),
            "'&' inside the cwd_prefix value must be escaped, not left literal (would split the query wrong)")
        XCTAssertFalse(cwdPrefixValue.contains("="),
            "'=' inside the cwd_prefix value must be escaped, not left literal (would corrupt the key=value pairing)")
    }

    func testLoadAutomationSessionsFetchesLiveCronSubagentIncludeChildrenAndFiltersRows() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = (
            data: #"""
            {"sessions":[
                {"id":"cronRun","title":"Nightly build","source":"cron","message_count":3,"last_active":500},
                {"id":"subagentRun","title":"Delegate","source":"subagent","message_count":2,"last_active":400},
                {"id":"leakedHuman","title":"Chat","source":"app","message_count":1,"last_active":300}
            ],"total":3}
            """#.data(using: .utf8)!,
            status: 200
        )
        SessionListSourceFilterStubProtocol.requestedURL = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionListSourceFilterStubProtocol.self]
        let rest = RestClient(baseURL: URL(string: "http://127.0.0.1:9119")!, token: "test-token", session: URLSession(configuration: config))
        let store = SessionStore()
        store.automationRestClientForTesting = rest

        await store.loadAutomationSessions()

        // Prove the rows came from the live RestClient request path (not a
        // hand-injected fixture): assert both the populated slice AND the
        // exact query the store issued to get there.
        XCTAssertEqual(store.automationSessions.map(\.id), ["cronRun", "subagentRun"],
            "The client-side defense filter must drop a leaked non-automation row even though the server claimed to have already scoped it")
        XCTAssertEqual(store.automationSessionsTotal, 2,
            "The slice's total must reflect the filtered row count (2), never the untrusted server total (3) — otherwise a leaked human row inflates the count without a matching visible row")
        XCTAssertNil(store.automationSessionsError)
        XCTAssertFalse(store.isLoadingAutomationSessions)

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(SessionListSourceFilterStubProtocol.requestedURL), resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        XCTAssertEqual(components.path, "/api/sessions")
        XCTAssertEqual(queryItems["source"], "cron,subagent")
        XCTAssertEqual(queryItems["include_children"], "true")
    }

    func testLoadAutomationSessionsAllLeakedRowsYieldHonestEmptyStateNotNonzeroTotal() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = (
            data: #"""
            {"sessions":[
                {"id":"leakedHuman1","title":"Chat","source":"app","message_count":1,"last_active":300},
                {"id":"leakedHuman2","title":"Telegram","source":"telegram","message_count":1,"last_active":200}
            ],"total":2}
            """#.data(using: .utf8)!,
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
        let store = SessionStore()
        store.automationRestClientForTesting = rest

        await store.loadAutomationSessions()

        XCTAssertTrue(store.automationSessions.isEmpty,
            "An older gateway that ignores source=cron,subagent and returns only human rows must yield an empty automation slice")
        XCTAssertEqual(store.automationSessionsTotal, 0,
            "The slice must never report a nonzero total while its row list is empty — that pairing would be a lie to the drawer/Settings empty state")
        XCTAssertNil(store.automationSessionsError)
    }

    func testLoadAutomationSessionsSurfacesErrorWithoutTouchingHumanRecents() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionListSourceFilterStubProtocol.self]
        let rest = RestClient(baseURL: URL(string: "http://127.0.0.1:9119")!, token: "test-token", session: URLSession(configuration: config))
        let store = SessionStore()
        store.automationRestClientForTesting = rest
        store.sessions = [summary(id: "human", source: "app", messageCount: 2, lastActive: 100)]

        await store.loadAutomationSessions()

        XCTAssertTrue(store.automationSessions.isEmpty)
        XCTAssertNotNil(store.automationSessionsError)
        XCTAssertFalse(store.isLoadingAutomationSessions)
        XCTAssertEqual(store.sessions.map(\.id), ["human"])
    }

    func testAutomationRunsUseAggregateProfileRailWhenMultiProfileAvailable() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = (
            data: """
            {
              "sessions":[
                {"id":"work-cron","title":"Nightly","source":"cron","profile":"work","last_active":200.0}
              ],
              "total":1,
              "profile_totals":{"work":1},
              "limit":100,
              "offset":0,
              "errors":[]
            }
            """.data(using: .utf8)!,
            status: 200
        )
        SessionListSourceFilterStubProtocol.requestedURL = nil
        let rest = makeStubbedRestClient()

        let runs = try await AutomationRunsLoader.fetch(
            rest: rest,
            multiProfileAvailable: true
        )

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(SessionListSourceFilterStubProtocol.requestedURL),
            resolvingAgainstBaseURL: false
        ))
        let queryItems = Self.queryItems(from: components)
        XCTAssertEqual(components.path, "/api/profiles/sessions")
        XCTAssertEqual(queryItems["profile"], DefaultsKeys.allProfilesScope)
        XCTAssertEqual(queryItems["source"], "cron")
        XCTAssertEqual(queryItems["order"], "recent")
        XCTAssertEqual(runs.map(\.id), ["work-cron"])
        XCTAssertEqual(runs.first?.profile, "work")
    }

    func testAutomationRunsUseSingleProfileSessionsRailWhenMultiProfileUnavailable() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = (
            data: #"{"sessions":[{"id":"default-cron","source":"cron"}],"total":1}"#.data(using: .utf8)!,
            status: 200
        )
        SessionListSourceFilterStubProtocol.requestedURL = nil
        let rest = makeStubbedRestClient()

        let runs = try await AutomationRunsLoader.fetch(
            rest: rest,
            multiProfileAvailable: false
        )

        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(SessionListSourceFilterStubProtocol.requestedURL),
            resolvingAgainstBaseURL: false
        ))
        let queryItems = Self.queryItems(from: components)
        XCTAssertEqual(components.path, "/api/sessions")
        XCTAssertNotEqual(components.path, "/api/profiles/sessions")
        XCTAssertEqual(queryItems["source"], "cron")
        XCTAssertEqual(queryItems["order"], "recent")
        XCTAssertEqual(runs.map(\.id), ["default-cron"])
        XCTAssertNil(runs.first?.profile)
    }

    func testAutomationRunsFilterOutNonCronRowsFromStaleServerResponse() async throws {
        SessionListSourceFilterStubProtocol.nextResponse = (
            data: """
            {
              "sessions":[
                {"id":"keep","title":"Cron","source":"CrOn","profile":"work"},
                {"id":"drop","title":"Chat","source":"cli","profile":"work"}
              ],
              "total":2,
              "profile_totals":{"work":2},
              "limit":100,
              "offset":0,
              "errors":[]
            }
            """.data(using: .utf8)!,
            status: 200
        )
        SessionListSourceFilterStubProtocol.requestedURL = nil
        let rest = makeStubbedRestClient()

        let runs = try await AutomationRunsLoader.fetch(
            rest: rest,
            multiProfileAvailable: true
        )

        XCTAssertEqual(runs.map(\.id), ["keep"])
        XCTAssertEqual(runs.first?.profile, "work")
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

    private func makeStubbedRestClient() -> RestClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionListSourceFilterStubProtocol.self]
        return RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )
    }

    private static func queryItems(from components: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
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
