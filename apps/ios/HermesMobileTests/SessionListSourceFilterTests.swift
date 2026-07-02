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

    private func summary(
        id: String,
        source: String?,
        messageCount: Int?,
        lastActive: Double
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            title: id,
            preview: nil,
            startedAt: nil,
            messageCount: messageCount,
            source: source,
            lastActive: lastActive,
            cwd: nil
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
