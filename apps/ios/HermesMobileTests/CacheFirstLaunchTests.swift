import XCTest
import Foundation
import GRDB
@testable import HermesMobile

// MARK: - CacheFirstLaunchTests
//
// The CACHE-FIRST architecture flip (WhatsApp bar). Covers:
//   - Cache-first launch: the cold cache read paints the drawer UNCONDITIONALLY of
//     connection state (the offline-launch empty-drawer hole), via the lifted
//     `SessionStore.paintFromCache()`.
//   - RootView gate discriminators: a previously-paired user (saved config) earns
//     the shell in `.offline`/`.connecting`/`.reconnecting`; a genuinely-
//     unconfigured / failed-configure install does NOT (validation-bypass intact).
//   - Prefetch: top-N warm happy-path + cancellation + skip-fresh.
//
// All hermetic: in-memory CacheStore, injected fetch seams, no live gateway.

@MainActor
final class CacheFirstLaunchTests: XCTestCase {

    // The RootView gate reads `UserDefaults.standard` for the persisted server
    // URL; the shared test process (and a prior app install on the sim) may have
    // it set. Save + clear it before each test so `hasSavedConfiguration` reflects
    // ONLY what the test sets, then restore it after.
    private var savedServerURL: String?

    override func setUp() {
        super.setUp()
        savedServerURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
    }

    override func tearDown() {
        if let savedServerURL {
            UserDefaults.standard.set(savedServerURL, forKey: DefaultsKeys.serverURL)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
        }
        super.tearDown()
    }

    // MARK: Harness

    private func makeInMemoryCache() throws -> CacheStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        return try CacheStore(testDB: queue)
    }

    private func makeGraph() -> (ConnectionStore, SessionStore, ChatStore) {
        let chat = ChatStore()
        let sessions = SessionStore()
        let connection = ConnectionStore(sessionStore: sessions, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: sessions, attachments: attachments)
        sessions.attach(connection: connection, chat: chat)
        return (connection, sessions, chat)
    }

    private func makeSummary(
        id: String, lastActive: Double? = 100, source: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id, title: "T-\(id)", preview: nil, startedAt: 1_000,
            messageCount: 3, source: source, lastActive: lastActive, cwd: nil
        )
    }

    private let serverURL = "https://test.example:9443"

    // MARK: - Cache-first launch (kills the empty drawer / Welcome-when-offline)

    func testPaintFromCacheRendersDrawerWithoutNetwork() async throws {
        // The crux of the fix: paintFromCache reads the disk list with NO network
        // fetch and NO refresh(), so an offline cold launch shows the drawer.
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        // Bind the scope (what bootstrap()'s paintCacheFirst does before the probe).
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        try await cache.saveSessionList(
            [makeSummary(id: "s1", lastActive: 200), makeSummary(id: "s2", lastActive: 100)],
            scope: scope)

        XCTAssertTrue(sessions.sessions.isEmpty)
        await sessions.paintFromCache()

        XCTAssertEqual(Set(sessions.sessions.map(\.id)), ["s1", "s2"],
                       "drawer paints from disk with no network")
    }

    func testPaintFromCacheIsIdempotent() async throws {
        // refresh() also calls paintFromCache(); the latch must collapse the two
        // (bootstrap + hydration-refresh) to a single disk read and never re-clobber.
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        try await cache.saveSessionList([makeSummary(id: "s1")], scope: scope)

        await sessions.paintFromCache()
        XCTAssertEqual(sessions.sessions.map(\.id), ["s1"])

        // A second paint after the list was warmed must NOT re-read / clobber.
        sessions.sessions = [makeSummary(id: "warm")]
        await sessions.paintFromCache()
        XCTAssertEqual(sessions.sessions.map(\.id), ["warm"],
                       "second paint is latched — never clobbers a warm list")
    }

    func testPaintFromCacheNoOpWithoutCache() async throws {
        // No cache wired (previews/tests) ⇒ byte-identical to the network-only path.
        let (connection, sessions, _) = makeGraph()
        connection.serverURLString = serverURL
        await sessions.paintFromCache()
        XCTAssertTrue(sessions.sessions.isEmpty)
    }

    // MARK: - RootView gate (paired+offline → mainUI, not Welcome)

    func testHasSavedConfigurationTrueAfterInMemoryBinding() {
        // The cache-first early set (paintCacheFirst sets serverURLString before any
        // persistence) is the in-memory fallback the gate reads on the first frames.
        let (connection, _, _) = makeGraph()
        XCTAssertFalse(connection.hasSavedConfiguration,
                       "a fresh store has no saved configuration")
        connection.serverURLString = serverURL
        XCTAssertTrue(connection.hasSavedConfiguration,
                      "an in-memory server binding satisfies the gate")
    }

    func testFailedConfigureLeavesGateClosed() async {
        // VALIDATION-BYPASS GUARANTEE (preserved): a garbage manual configure
        // persists nothing and leaves serverURLString empty, so the paired-user
        // gate stays CLOSED — the user remains in onboarding (WelcomeView).
        let (connection, _, _) = makeGraph()
        _ = await connection.configure(urlString: "not a url", token: "tok")
        XCTAssertFalse(connection.hasConnected)
        XCTAssertFalse(connection.isBootstrapping)
        XCTAssertFalse(connection.hasSavedConfiguration,
                       "a failed configure must not open the paired-user shell gate")
        XCTAssertEqual(connection.serverURLString, "")
    }

    // MARK: - Prefetch (happy path + cancellation + skip-fresh)

    func testPrefetchWarmsUncachedRecentSessions() async throws {
        let (_, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        // Two visible (non-cron) sessions, neither transcript-cached yet.
        let rows = [makeSummary(id: "p1", lastActive: 200), makeSummary(id: "p2", lastActive: 100)]
        try await cache.saveSessionList(rows, scope: scope)
        sessions.sessions = rows

        let fetched = TestActorBox<Set<String>>([])
        sessions.prefetchFetch = { @Sendable id in
            await fetched.insert(id)
            return [stubStored("hello-\(id)")]
        }

        sessions.prefetchRecentTranscripts()
        // Drain the sweep deterministically.
        try await Self.poll { await fetched.value.count == 2 }

        let got = await fetched.value
        XCTAssertEqual(got, ["p1", "p2"])
        let hasP1 = try await cache.hasTranscript("p1")
        let hasP2 = try await cache.hasTranscript("p2")
        XCTAssertTrue(hasP1 && hasP2, "prefetch wrote both transcripts through to disk")
    }

    func testPrefetchSkipsActiveSessionAndFreshCache() async throws {
        let (_, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        let rows = [
            makeSummary(id: "open", lastActive: 300),
            makeSummary(id: "fresh", lastActive: 100),
            makeSummary(id: "stale", lastActive: 200),
            makeSummary(id: "cronjob", lastActive: 250, source: "cron"),
        ]
        try await cache.saveSessionList(rows, scope: scope)
        // `fresh` already has a current transcript on disk → must be skipped.
        try await cache.saveTranscript(sessionId: "fresh", messages: [stubStored("cached")])
        sessions.sessions = rows
        sessions.activeStoredId = "open"  // the open session owns its own fetch

        let fetched = TestActorBox<Set<String>>([])
        sessions.prefetchFetch = { @Sendable id in
            await fetched.insert(id)
            return [stubStored("net-\(id)")]
        }

        sessions.prefetchRecentTranscripts()
        try await Self.poll { await fetched.value == ["stale"] }

        let got = await fetched.value
        XCTAssertEqual(got, ["stale"],
                       "skips the open session, the fresh-cached one, and cron")
    }

    func testPrefetchDefaultFetchUsesDeltaCursorForCachedStaleSession() async throws {
        let (_, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        // Nil freshness means "stale/unknown" so prefetch must reconcile, but the
        // cached transcript has a durable cursor and an unchanged server tail.
        let rows = [makeSummary(id: "unchanged", lastActive: nil)]
        try await cache.saveSessionList(rows, scope: scope)
        try await cache.saveTranscript(
            sessionId: "unchanged",
            messages: [stubStored("cached-1", wireId: 101), stubStored("cached-2", wireId: 102)],
            wireIds: [101, 102]
        )
        sessions.sessions = rows

        PrefetchDeltaStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrefetchDeltaStubProtocol.self]
        sessions.prefetchRestClientForTesting = RestClient(
            baseURL: URL(string: serverURL)!,
            token: "test-token",
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )

        sessions.prefetchRecentTranscripts()
        try await Self.poll {
            PrefetchDeltaStubProtocol.sawDelta || PrefetchDeltaStubProtocol.sawFullMessages
        }

        XCTAssertTrue(PrefetchDeltaStubProtocol.sawDelta,
                      "unchanged cached prefetch should pay only the delta cursor check")
        XCTAssertFalse(PrefetchDeltaStubProtocol.sawFullMessages,
                       "unchanged cached prefetch must not re-download the full transcript")
        let cached = try await cache.loadTranscript("unchanged") ?? []
        XCTAssertEqual(cached.map(\.text), ["cached-1", "cached-2"],
                       "empty delta leaves the cached transcript hydrated")
    }

    func testPrefetchDefaultFetchMergesChangedSessionDelta() async throws {
        let (_, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        let rows = [makeSummary(id: "changed", lastActive: nil)]
        try await cache.saveSessionList(rows, scope: scope)
        try await cache.saveTranscript(
            sessionId: "changed",
            messages: [stubStored("cached-1", wireId: 201), stubStored("cached-2", wireId: 202)],
            wireIds: [201, 202]
        )
        sessions.sessions = rows

        PrefetchDeltaStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrefetchDeltaStubProtocol.self]
        sessions.prefetchRestClientForTesting = RestClient(
            baseURL: URL(string: serverURL)!,
            token: "test-token",
            session: URLSession(configuration: config),
            pathStyle: .plugin
        )

        sessions.prefetchRecentTranscripts()
        try await Self.poll { PrefetchDeltaStubProtocol.sawDelta }

        let cached = try await cache.loadTranscript("changed") ?? []
        XCTAssertEqual(cached.map(\.text), ["cached-1", "cached-2", "tail-3"],
                       "changed prefetch hydrates by appending the delta tail")
        let cursor = try await cache.maxMessageId(for: "changed")
        XCTAssertEqual(cursor, 203,
                       "merged changed prefetch advances the durable cursor")
        XCTAssertFalse(PrefetchDeltaStubProtocol.sawFullMessages,
                       "changed cursor prefetch should not fall back to the full transcript")
    }

    func testCancelPrefetchStopsTheSweep() async throws {
        let (_, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        let rows = (0..<10).map { makeSummary(id: "c\($0)", lastActive: Double(100 - $0)) }
        try await cache.saveSessionList(rows, scope: scope)
        sessions.sessions = rows

        let started = TestActorBox<Int>(0)
        let gate = TestActorBox<Bool>(false)
        sessions.prefetchFetch = { @Sendable id in
            await started.increment()
            // Block until released so cancellation can land mid-sweep.
            while await gate.value == false {
                if Task.isCancelled { throw CancellationError() }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return []
        }

        sessions.prefetchRecentTranscripts()
        // Let the concurrency window (3) spin up, then cancel.
        try await Self.poll { await started.value >= 1 }
        sessions.cancelPrefetch()
        await gate.set(true)  // release any blocked fetches so they can observe cancel

        // No more than the concurrency window ever started; nothing past it ran.
        let count = await started.value
        XCTAssertLessThanOrEqual(count, 3,
                                 "cancellation stops the sweep within the concurrency window")
    }

    // MARK: - Poll helper

    /// Spin until `condition` is true or a generous deadline elapses (hermetic —
    /// no live gateway, so the closures resolve immediately; this just yields the
    /// detached sweep enough turns to drain).
    private static func poll(
        timeout: Duration = .seconds(3),
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("poll timed out")
    }
}

// MARK: - Test helpers

/// Free `@Sendable` StoredMessage factory for the prefetch seams (a MainActor
/// XCTestCase method can't be called from inside a `@Sendable` closure).
private func stubStored(_ text: String, wireId: Int? = nil) -> StoredMessage {
    StoredMessage(role: "assistant", content: .string(text), timestamp: 1, wireId: wireId)
}

/// A tiny Sendable box so the `@Sendable` prefetch seams can record their calls
/// from the detached task group without data races.
private actor TestActorBox<T: Sendable> {
    private(set) var value: T
    init(_ initial: T) { self.value = initial }
    func set(_ v: T) { value = v }
}

private extension TestActorBox where T == Set<String> {
    func insert(_ s: String) { value.insert(s) }
}

private extension TestActorBox where T == Int {
    func increment() { value += 1 }
}

private final class PrefetchDeltaStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var sawDelta = false
    nonisolated(unsafe) static var sawFullMessages = false
    nonisolated(unsafe) static var requestedPaths: [String] = []

    static func reset() {
        sawDelta = false
        sawFullMessages = false
        requestedPaths = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        Self.requestedPaths.append(query.isEmpty ? path : "\(path)?\(query)")

        let body: String
        let status: Int
        if path == "/api/plugins/hermes-mobile/sessions/unchanged/messages",
           query.contains("after_id=102"),
           query.contains("prefix_count=2") {
            Self.sawDelta = true
            status = 200
            body = #"{"is_delta":true,"prefix_count":2,"max_id":102,"messages":[]}"#
        } else if path == "/api/plugins/hermes-mobile/sessions/changed/messages",
                  query.contains("after_id=202"),
                  query.contains("prefix_count=2") {
            Self.sawDelta = true
            status = 200
            body = #"{"is_delta":true,"prefix_count":3,"max_id":203,"messages":[{"role":"assistant","content":"tail-3","timestamp":1,"id":203}]}"#
        } else if path == "/api/sessions/unchanged/messages" || path == "/api/sessions/changed/messages" {
            Self.sawFullMessages = true
            status = 500
            body = #"{"error":"full transcript should not be fetched"}"#
        } else {
            status = 404
            body = #"{"error":"unexpected prefetch request"}"#
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
