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
    private var savedActiveProfile: String?

    override func setUp() {
        super.setUp()
        savedServerURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        savedActiveProfile = UserDefaults.standard.string(forKey: DefaultsKeys.activeProfile)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
        UserDefaults.standard.set(
            DefaultsKeys.allProfilesScope,
            forKey: DefaultsKeys.activeProfile
        )
    }

    override func tearDown() {
        if let savedServerURL {
            UserDefaults.standard.set(savedServerURL, forKey: DefaultsKeys.serverURL)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)
        }
        if let savedActiveProfile {
            UserDefaults.standard.set(savedActiveProfile, forKey: DefaultsKeys.activeProfile)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.activeProfile)
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
        id: String, lastActive: Double? = 100, source: String? = nil, profile: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id, title: "T-\(id)", preview: nil, startedAt: 1_000,
            messageCount: 3, source: source, lastActive: lastActive, cwd: nil, profile: profile
        )
    }

    private let serverURL = "https://test.example:9443"

    private func cacheIdentity(_ sessionId: String) -> CacheIdentity {
        CacheIdentity(serverId: serverURL, profileId: "default", sessionId: sessionId)
    }

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

    /// A1(i): the persisted `activeProfile` is network-mutated (confirmActiveProfile
    /// adopts the server-echoed profile), so an OFFLINE cold-open can land on a
    /// stale concrete profile whose scoped read filters to zero rows. The paint
    /// must fall back to a serverId-only aggregate read so the drawer is never
    /// blank when the disk holds the user's chats.
    func testOfflineColdOpenPaintsUnderStaleConcreteProfile() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = serverURL
        // Rows stored under the user's real "default" profile.
        try await cache.saveSessionList(
            [makeSummary(id: "s1", lastActive: 200, profile: "default"),
             makeSummary(id: "s2", lastActive: 100, profile: "default")],
            scope: CacheScope(serverId: serverURL, profileId: "default"))
        // The persisted active profile drifted to a concrete profile with no rows.
        sessions.activeProfile = "ghost"

        XCTAssertTrue(sessions.sessions.isEmpty)
        await sessions.paintFromCache()

        XCTAssertEqual(Set(sessions.sessions.map(\.id)), ["s1", "s2"],
            "offline cold-open falls back to an aggregate read under a stale profile")
    }

    /// A1(iii): a row left on disk by an older build, mis-stamped with the literal
    /// "all" selector, must still paint under a concrete-profile cold-open. The
    /// aggregate fallback read selects every non-legacy row, so the mis-stamped
    /// row is recovered without a data migration.
    func testOfflineColdOpenPaintsRowMisStampedAll() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = serverURL
        try await cache._writeRawSessionRowForTesting(
            makeSummary(id: "legacy", lastActive: 150, profile: "default"),
            serverId: serverURL, profileId: CacheScope.allProfilesKey)
        sessions.activeProfile = "default"

        XCTAssertTrue(sessions.sessions.isEmpty)
        await sessions.paintFromCache()

        XCTAssertEqual(sessions.sessions.map(\.id), ["legacy"],
            "a row mis-stamped \"all\" still paints under a concrete-profile cold-open")
    }

    /// Cold-open frame-0 paint (build125): `paintDrawerCacheFirst()` must paint the
    /// drawer from disk WITHOUT any network step — proving the cache paint precedes
    /// (and does not depend on) the connection bootstrap. hasConnected stays false
    /// and the phase never leaves `.connecting`, yet the rows are on screen.
    func testPaintDrawerCacheFirstPaintsBeforeNetwork() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection._skipEnvironmentBootstrapForTesting = true

        let savedURL = "https://frame0-\(UUID().uuidString).example"
        UserDefaults.standard.set(savedURL, forKey: DefaultsKeys.serverURL)
        defer { UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL) }
        let scope = CacheScope(serverId: savedURL, profileId: DefaultsKeys.allProfilesScope)
        try await cache.saveSessionList(
            [makeSummary(id: "c1", lastActive: 200), makeSummary(id: "c2", lastActive: 100)],
            scope: scope)

        XCTAssertTrue(sessions.sessions.isEmpty)
        XCTAssertFalse(connection.hasConnected)

        await connection.paintDrawerCacheFirst()

        XCTAssertEqual(Set(sessions.sessions.map(\.id)), ["c1", "c2"],
            "the drawer paints from cache at frame 0, before any network bootstrap")
        XCTAssertEqual(connection.serverURLString, savedURL,
            "the cache scope is bound from the saved URL without a network probe")
        XCTAssertFalse(connection.hasConnected,
            "frame-0 paint must not perform a network connect")
        guard case .connecting = connection.phase else {
            return XCTFail("frame-0 paint must not advance the connection phase")
        }
    }

    /// A fresh install (no saved URL, dev env skipped) leaves the frame-0 paint a
    /// no-op — byte-identical to today's onboarding path.
    func testPaintDrawerCacheFirstNoOpWithoutSavedURL() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection._skipEnvironmentBootstrapForTesting = true
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.serverURL)

        await connection.paintDrawerCacheFirst()

        XCTAssertTrue(sessions.sessions.isEmpty,
            "no saved URL ⇒ nothing to paint")
        XCTAssertEqual(connection.serverURLString, "")
    }

    func testPaintFromCacheNoOpWithoutCache() async throws {
        // No cache wired (previews/tests) ⇒ byte-identical to the network-only path.
        let (connection, sessions, _) = makeGraph()
        connection.serverURLString = serverURL
        await sessions.paintFromCache()
        XCTAssertTrue(sessions.sessions.isEmpty)
    }

    func testUnavailableCacheFetchesHistoryOnceAndCannotPaintPriorSession() async {
        let (_, sessions, chat) = makeGraph() // deliberately no CacheStore
        chat.seed(from: [stubStored("SESSION A")])
        var fetched: [String] = []
        sessions.transcriptFetch = { sessionID in
            fetched.append(sessionID)
            return [stubStored("SESSION B")]
        }

        sessions.open(makeSummary(id: "stored-B"), bindRuntime: false)
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(fetched, ["stored-B"], "a cold cache miss gets one authoritative read")
        XCTAssertEqual(chat.messages.map(\.text), ["SESSION B"])
        XCTAssertFalse(chat.messages.contains { $0.text == "SESSION A" },
                       "the miss reset must not retain another session's rows")
    }

    func testCachePaintRetriesAfterPreBootstrapCallGetsNoScope() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)

        // This must not consume the cold-read latch: bootstrap has not yet
        // supplied a server identity, so no cache partition is valid.
        await sessions.paintFromCache()

        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        try await cache.saveSessionList([makeSummary(id: "after-bind")], scope: scope)
        await sessions.paintFromCache()

        XCTAssertEqual(sessions.sessions.map(\.id), ["after-bind"])
    }

    func testHydratingUsesCachedShellButEmptyScopeUsesLoader() {
        XCTAssertTrue(RootContentPolicy.showsCachedShell(
            phase: .hydrating, hasCachedContent: true
        ))
        XCTAssertFalse(RootContentPolicy.showsCachedShell(
            phase: .hydrating, hasCachedContent: false
        ))
        XCTAssertFalse(RootContentPolicy.showsCachedShell(
            phase: .connected, hasCachedContent: true
        ))
    }

    func testCachePaintRestoresLastOpenedSelectionAndTranscript() async throws {
        let (connection, sessions, chat) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        chat.attachCache(cache)
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        let identity = CacheIdentity(serverId: serverURL, profileId: "default", sessionId: "remembered")
        try await cache.saveSessionList([makeSummary(id: "remembered")], scope: scope)
        try await cache.saveTranscript(identity: identity, messages: [stubStored("from disk")])
        try await cache.saveLastOpenedSession(identity, manifestScope: scope)

        await sessions.paintFromCache()
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(sessions.activeStoredId, "remembered")
        XCTAssertEqual(chat.messages.last?.text, "from disk")
    }

    /// Cold-launch RESUME regression (#208 follow-up): the last-active session's
    /// transcript must paint from cache on cold launch even though the connection
    /// work generation is advanced BETWEEN the frame-0 `open(bindRuntime:false)`
    /// (scheduled by `paintFromCache`) and the moment its async seed Task drains.
    ///
    /// The real launch order is: `paintDrawerCacheFirst()` schedules the transcript
    /// seed under the pre-bootstrap generation, then `bootstrap()`'s
    /// `advanceConnectionGeneration()` bumps `connectionWorkGeneration`. The old
    /// phase-1 guard (`isCurrentTranscriptSelection`, generation-keyed) then treated
    /// the LOCAL cache paint as stale and skipped BOTH the paint and the miss-path
    /// `reset()`, stranding the transcript on its launch skeleton (isLoading:false,
    /// no error) even though the cache existed — while a manual drawer re-tap (which
    /// captures a settled generation) painted it instantly. This test bumps the
    /// generation exactly as bootstrap does, with ZERO network, and proves both the
    /// drawer AND the transcript paint from persisted identity alone.
    func testColdLaunchResumePaintsTranscriptAcrossGenerationAdvance() async throws {
        let (connection, sessions, chat) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        chat.attachCache(cache)
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        let identity = CacheIdentity(serverId: serverURL, profileId: "default", sessionId: "remembered")
        try await cache.saveSessionList([makeSummary(id: "remembered")], scope: scope)
        try await cache.saveTranscript(identity: identity, messages: [stubStored("cold-resume")])
        try await cache.saveLastOpenedSession(identity, manifestScope: scope)

        // No transcript fetch seam is wired: this is a pure offline cold launch, so
        // the ONLY way the transcript can paint is the local cache seed.
        await sessions.paintFromCache()

        // Mirror ConnectionStore.advanceConnectionGeneration() landing at
        // bootstrap-start, AFTER the frame-0 open() scheduled the seed but BEFORE it
        // drains — the exact reorder that stranded the transcript.
        sessions.transportDidBecomeUnavailable()
        sessions.invalidateConnectionWork()

        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(sessions.sessions.map(\.id), ["remembered"],
                       "the drawer paints from cache with zero network")
        XCTAssertEqual(sessions.activeStoredId, "remembered",
                       "the last-opened session is restored as active")
        XCTAssertEqual(chat.messages.last?.text, "cold-resume",
                       "the cached transcript paints on cold-launch resume despite the generation advance")
    }

    func testCacheRestoreSelectsAndPaintsWithoutStartingResume() async throws {
        let (connection, sessions, chat) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        chat.attachCache(cache)
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        let identity = CacheIdentity(serverId: serverURL, profileId: "default", sessionId: "remembered")
        try await cache.saveSessionList([makeSummary(id: "remembered")], scope: scope)
        try await cache.saveTranscript(identity: identity, messages: [stubStored("offline")])
        try await cache.saveLastOpenedSession(identity, manifestScope: scope)

        let resumeCalls = TestActorBox<Int>(0)
        sessions.resumeRPC = { _, _ in
            await resumeCalls.increment()
            throw GatewayError.notConnected
        }

        await sessions.paintFromCache()
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(sessions.activeStoredId, "remembered")
        XCTAssertEqual(chat.messages.last?.text, "offline")
        let calls = await resumeCalls.value
        XCTAssertEqual(calls, 0,
                       "cold cache restoration is local paint only; no RPC may start before readiness")
        XCTAssertNil(sessions.sessionActionError)
    }

    func testAllProfilesRestoreRequiresExactSavedProfile() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)
        let defaultIdentity = CacheIdentity(serverId: serverURL, profileId: "default", sessionId: "shared")
        let workIdentity = CacheIdentity(serverId: serverURL, profileId: "work", sessionId: "shared")
        try await cache.saveSessionList([
            makeSummary(id: "shared", lastActive: 200, profile: "default"),
            makeSummary(id: "shared", lastActive: 100, profile: "work"),
        ], scope: scope)
        try await cache.saveLastOpenedSession(workIdentity, manifestScope: scope)

        await sessions.paintFromCache()
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(sessions.activeStoredId, "shared")
        XCTAssertEqual(sessions.activeStoredProfile, "work")
        XCTAssertTrue(sessions.isActive(makeSummary(id: "shared", profile: "work")))
        XCTAssertFalse(sessions.isActive(makeSummary(id: "shared", profile: "default")))
        XCTAssertNotEqual(
            makeSummary(id: "shared", profile: "work").scopedIdentity,
            makeSummary(id: "shared", profile: "default").scopedIdentity
        )
        // Exact-profile selection is observable through the persisted identity:
        // opening the default duplicate would overwrite this with default.
        let restored = try await cache.loadLastOpenedSession(scope: scope)
        XCTAssertEqual(restored?.profileId, "work")
        XCTAssertNotEqual(defaultIdentity.profileId, restored?.profileId)
    }

    func testNamedProfileCacheTreatsUntaggedLegacyRowsAsSelectedScope() {
        let legacy = makeSummary(id: "legacy-work", profile: nil)
        let filtered = SessionStore.filterCachedSessions(
            [legacy],
            activeProfile: "work",
            untaggedProfile: "work"
        )

        XCTAssertEqual(filtered.map(\.id), ["legacy-work"])
    }

    func testProfileSwitchFencesInFlightRefreshPublicationAndCacheScope() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = serverURL
        sessions.sessions = [makeSummary(id: "existing")]

        let gate = ResumeGate()
        sessions.sessionsFetch = {
            await gate.suspend()
            return ([self.makeSummary(id: "old-profile")], 1)
        }
        let refreshTask = Task { await sessions.refresh() }
        await gate.waitUntilEntered()

        sessions.activeProfile = "work"
        await gate.release()
        await refreshTask.value

        XCTAssertEqual(sessions.sessions.map(\.id), ["existing"])
        let workRows = try await cache.loadSessionList(
            scope: CacheScope(serverId: serverURL, profileId: "work")
        )
        XCTAssertNil(workRows.first(where: { $0.id == "old-profile" }))
    }

    func testCachedRowUsesSummaryProfileWhenNetworkProfileThreadingIsUnavailable() async throws {
        let (connection, sessions, chat) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        chat.attachCache(cache)
        connection.serverURLString = serverURL
        sessions.profileThreadingAvailableForTesting = false

        let row = makeSummary(id: "work-row", lastActive: 100, profile: "work")
        sessions.sessions = [row]
        let workIdentity = CacheIdentity(serverId: serverURL, profileId: "work", sessionId: row.id)
        try await cache.saveSessionList([row], scope: CacheScope(serverId: serverURL, profileId: "all"))
        try await cache.saveTranscript(identity: workIdentity, messages: [stubStored("cached work")])
        sessions.transcriptFetchWithProfile = { _, profile in
            XCTAssertNil(profile, "network profile params remain capability-gated")
            throw GatewayError.notConnected
        }

        sessions.open(row, bindRuntime: false)
        await sessions.waitForPendingOpenForTesting()

        XCTAssertEqual(chat.messages.last?.text, "cached work")
    }

    func testTranscriptPublishAndCacheWriteAreFencedByTransportReplacement() async throws {
        let (connection, sessions, chat) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        chat.attachCache(cache)
        connection.serverURLString = serverURL
        connection._seedConnectedForTesting(serverURL: serverURL, token: "token")

        let gate = ResumeGate()
        let row = makeSummary(id: "transport-row", lastActive: 100)
        sessions.sessions = [row]
        sessions.transcriptFetchWithProfile = { _, _ in
            await gate.suspend()
            return [stubStored("stale transport response")]
        }
        sessions.open(row, bindRuntime: false)
        await gate.waitUntilEntered()

        // Replacing the same gateway transport invalidates the old transcript
        // task without changing the user's selected stored session.
        connection._seedConnectedForTesting(serverURL: serverURL, token: "token")
        await gate.release()
        await sessions.waitForPendingOpenForTesting()

        XCTAssertNil(chat.messages.last?.text)
        let hasStaleTranscript = try await cache.hasTranscript(
            CacheIdentity(serverId: serverURL, profileId: "default", sessionId: row.id)
        )
        XCTAssertFalse(hasStaleTranscript)
    }

    func testSupersededOpenCannotPersistOlderLastOpenedSelection() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)
        connection.serverURLString = serverURL
        let scope = CacheScope(serverId: serverURL, profileId: DefaultsKeys.allProfilesScope)

        sessions.open(makeSummary(id: "A"), bindRuntime: false)
        sessions.open(makeSummary(id: "B"), bindRuntime: false)
        await sessions.waitForPendingOpenForTesting()

        let last = try await cache.loadLastOpenedSession(scope: scope)
        XCTAssertEqual(last?.sessionId, "B")
    }

    func testLateResumeForOlderSelectionCannotReplaceNewestRuntime() async {
        let (_, sessions, _) = makeGraph()
        let gate = ResumeGate()
        sessions.resumeRPC = { stored, _ in
            if stored == "A" { await gate.suspend() }
            return JSONValue.object([
                "session_id": .string("runtime-\(stored)"),
                "resumed": .string(stored),
            ]).decoded(as: SessionOpenResult.self)!
        }

        sessions.open(makeSummary(id: "A"))
        await sessions.waitForPendingOpenForTesting()
        let lateA = Task { await sessions.ensureActiveRuntime() }
        await gate.waitUntilEntered()
        sessions.open(makeSummary(id: "B"))
        await sessions.waitForPendingOpenForTesting()
        let runtimeB = await sessions.ensureActiveRuntime()
        XCTAssertEqual(sessions.activeStoredId, "B")
        XCTAssertEqual(runtimeB, "runtime-B")
        XCTAssertEqual(sessions.activeRuntimeId, "runtime-B")

        await gate.release()
        _ = await lateA.value
        XCTAssertEqual(sessions.activeStoredId, "B")
        XCTAssertEqual(sessions.activeRuntimeId, "runtime-B",
                       "a late A resume must be fenced by B's selection token")
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

    func testBootstrapWithSavedURLWithoutTokenKeepsCachedShellAvailable() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)

        let savedURL = "https://cache-only-\(UUID().uuidString).example"
        UserDefaults.standard.set(savedURL, forKey: DefaultsKeys.serverURL)
        connection._skipEnvironmentBootstrapForTesting = true
        let scope = CacheScope(serverId: savedURL, profileId: DefaultsKeys.allProfilesScope)
        try await cache.saveSessionList([makeSummary(id: "cached")], scope: scope)

        await connection.bootstrap()

        XCTAssertEqual(connection.serverURLString, savedURL)
        XCTAssertTrue(connection.hasSavedConfiguration)
        XCTAssertFalse(connection.isBootstrapping)
        guard case .offline = connection.phase else {
            return XCTFail("saved URL without a token should remain in the cached offline shell")
        }
        XCTAssertEqual(sessions.sessions.map(\.id), ["cached"])
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

    /// STR-249/STR-248 (CUJ-01 regression): a cold launch with NO gateway
    /// reachable stranded a returning (saved-config) user on the "No
    /// conversation" placeholder instead of the composer.
    ///
    /// Root cause: `configure()` returns at the REST probe with
    /// `phase = .offline` BEFORE `startHydration()` ever runs — so
    /// `finishHydration()`'s `enterDraftIfNoActiveSession()` never fires.
    /// `hasConnected` also stays false in this path, so `startReconnectLoop()`
    /// (the other call site) never starts either. `hasSavedConfiguration`
    /// still earns the shell (RootView), but with no session active and no
    /// draft entered, `chatStack` falls to the placeholder.
    func testBootstrapOfflineEntersDraftWhenNoActiveSession() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)

        let savedURL = "http://127.0.0.1:1"  // nothing listens: probe fails fast
        UserDefaults.standard.set(savedURL, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken("stored-device-token", server: savedURL)
        defer { KeychainService.deleteToken(server: savedURL) }
        connection._skipEnvironmentBootstrapForTesting = true

        XCTAssertNil(sessions.activeStoredId)
        XCTAssertFalse(sessions.isDraft)

        await connection.bootstrap()

        guard case .offline = connection.phase else {
            return XCTFail("an unreachable saved gateway must leave phase .offline, got \(connection.phase)")
        }
        XCTAssertFalse(connection.isBootstrapping)
        XCTAssertTrue(sessions.isDraft,
                      "an offline cold launch for a returning user must land on the draft composer, not the empty-state placeholder")
    }

    /// The other half of the same fix: an offline bootstrap must NOT clobber a
    /// session that was already made active before bootstrap ran (defensive —
    /// mirrors the reconnect-loop non-clobber guarantee).
    func testBootstrapOfflineDoesNotClobberActiveSession() async throws {
        let (connection, sessions, _) = makeGraph()
        let cache = try makeInMemoryCache()
        sessions.attachCache(cache)

        let savedURL = "http://127.0.0.1:1"
        UserDefaults.standard.set(savedURL, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken("stored-device-token", server: savedURL)
        defer { KeychainService.deleteToken(server: savedURL) }
        connection._skipEnvironmentBootstrapForTesting = true
        sessions.activeStoredId = "already-active-session"

        await connection.bootstrap()

        XCTAssertEqual(sessions.activeStoredId, "already-active-session",
                       "an already-active session must survive an offline-bootstrap draft-entry call")
        XCTAssertFalse(sessions.isDraft)
    }

}

// MARK: - Test helpers

private func stubStored(_ text: String, wireId: Int? = nil) -> StoredMessage {
    StoredMessage(role: "assistant", content: .string(text), timestamp: 1, wireId: wireId)
}

private actor TestActorBox<T: Sendable> {
    private(set) var value: T
    init(_ initial: T) { self.value = initial }
    func set(_ v: T) { value = v }
}

private extension TestActorBox where T == Int {
    func increment() { value += 1 }
}

private actor ResumeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
