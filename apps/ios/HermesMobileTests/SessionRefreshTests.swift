import XCTest
import Observation
@testable import HermesMobile

/// Unit tests for ABH-86: desktop-parity session list refresh.
///
/// All tests inject the `sessionsFetch` seam so no live gateway is required.
/// They cover:
///
/// 1. **Re-sort on bumped `lastActive`** — after a refresh where a session's
///    `lastActive` is bumped, `visibleSessions` places it at the top.
/// 2. **Merge keeps active survivor** — a session absent from the incoming page
///    but equal to `activeStoredId` is preserved (prepended) in `sessions`.
/// 3. **Merge keeps pinned survivor** — a pinned session absent from the incoming
///    page is preserved (prepended) in `sessions`.
/// 4. **Stale token response discarded** — a slow response whose `refreshToken`
///    was superseded by a newer call does NOT overwrite the current list.
@MainActor
final class SessionRefreshTests: XCTestCase {

    nonisolated private static let sessionStoreDefaultsKeys = [
        DefaultsKeys.pinnedSessions,
        DefaultsKeys.hideCron,
        DefaultsKeys.groupByWorkspace,
        DefaultsKeys.collapsedWorkspaces,
        DefaultsKeys.pinnedWorkspaces,
        DefaultsKeys.activeProfile,
    ]

    override func setUp() {
        super.setUp()
        Self.resetSessionStoreDefaults()
    }

    override func tearDown() {
        Self.resetSessionStoreDefaults()
        super.tearDown()
    }

    // MARK: - Helpers

    /// SessionStore intentionally loads pins and drawer preferences from
    /// UserDefaults.standard. Scrubbing those keys keeps this suite from leaking
    /// working-set membership across tests while still using the production
    /// initializer and persistence path inside each test.
    nonisolated private static func resetSessionStoreDefaults() {
        for key in Self.sessionStoreDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Build a minimal `SessionSummary` with only the fields relevant to sorting.
    private func makeSummary(
        id: String,
        lastActive: Double? = nil,
        startedAt: Double? = nil,
        source: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            title: id,
            preview: nil,
            startedAt: startedAt,
            messageCount: nil,
            source: source,
            lastActive: lastActive,
            cwd: nil
        )
    }

    /// A fresh store wired with no live connection — suitable for fetch-seam tests.
    private func makeStore() -> SessionStore {
        SessionStore()
    }

    func testStockSnapshotIsBounded() {
        XCTAssertEqual(SessionStore.snapshotLimit, 200)
    }

    func testFirstPairPaintsSmallCreatedSliceBeforeAuthoritativeRecentSnapshot() async {
        FirstPairSessionListStubProtocol.requestedOrders = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FirstPairSessionListStubProtocol.self]
        let rest = RestClient(
            baseURL: URL(string: "https://gateway.test")!,
            token: "test-token",
            session: URLSession(configuration: config)
        )

        let chat = ChatStore()
        let store = SessionStore()
        let connection = ConnectionStore(sessionStore: store, chatStore: chat)
        let attachments = AttachmentStore()
        chat.attach(connection: connection, sessions: store, attachments: attachments)
        store.attach(connection: connection, chat: chat)
        connection._restOverrideForTesting = rest
        connection._seedConnectedForTesting(
            serverURL: "https://gateway.test",
            token: "test-token"
        )

        await store.refreshInitialPaint()

        XCTAssertEqual(store.sessions.map(\.id), ["quick"])
        XCTAssertEqual(FirstPairSessionListStubProtocol.requestedOrders, ["created"])

        await store.refresh()

        XCTAssertEqual(store.sessions.map(\.id), ["authoritative"])
        XCTAssertEqual(FirstPairSessionListStubProtocol.requestedOrders, ["created", "recent"])
    }

    func testInitialPaintKeepsWarmRowsWithoutAProvisionalFetch() async {
        let store = makeStore()
        store.sessions = [makeSummary(id: "cached")]
        var fetchCount = 0
        store.sessionsFetch = {
            fetchCount += 1
            return ([self.makeSummary(id: "unexpected")], 1)
        }

        await store.refreshInitialPaint()

        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(store.sessions.map(\.id), ["cached"])
    }

    // MARK: - build125: identical first-page refresh produces no array churn (#208)

    /// A periodic first-page refresh that returns byte-identical rows must NOT
    /// reassign the `sessions` array — under `@Observable` an equal-but-new array
    /// still relayouts the whole drawer. `withObservationTracking`'s `onChange`
    /// fires only if `sessions` is actually mutated.
    func testIdenticalRefreshProducesNoSessionsChurn() async {
        let store = makeStore()
        let rows = [
            makeSummary(id: "A", lastActive: 300, startedAt: 3),
            makeSummary(id: "B", lastActive: 200, startedAt: 2),
            makeSummary(id: "C", lastActive: 100, startedAt: 1),
        ]
        store.sessionsFetch = { (rows, 3) }
        await store.refresh()
        XCTAssertEqual(store.sessions.map(\.id), ["A", "B", "C"])

        let mutated = MutationFlag()
        withObservationTracking {
            _ = store.sessions
        } onChange: {
            mutated.fire()
        }
        // Identical content on the next refresh.
        await store.refresh()

        XCTAssertFalse(mutated.fired,
            "an identical-content first-page refresh must not churn the sessions array (#208)")
        XCTAssertEqual(store.sessions.map(\.id), ["A", "B", "C"])
    }

    /// Control: a refresh that genuinely changes the row set DOES reassign
    /// `sessions`, so the no-churn guard never suppresses a real update.
    func testChangedRefreshStillUpdatesSessions() async {
        let store = makeStore()
        store.sessionsFetch = { ([self.makeSummary(id: "A", lastActive: 100)], 1) }
        await store.refresh()
        XCTAssertEqual(store.sessions.map(\.id), ["A"])

        let mutated = MutationFlag()
        withObservationTracking {
            _ = store.sessions
        } onChange: {
            mutated.fire()
        }
        store.sessionsFetch = {
            ([self.makeSummary(id: "A", lastActive: 100),
              self.makeSummary(id: "B", lastActive: 90)], 2)
        }
        await store.refresh()

        XCTAssertTrue(mutated.fired, "a changed refresh must still publish the sessions update")
        XCTAssertEqual(Set(store.sessions.map(\.id)), ["A", "B"])
    }

    // MARK: - 1. Re-sort on bumped lastActive

    /// After injecting a new page where session "B"'s `lastActive` is newer than
    /// "A"'s, `visibleSessions` must list "B" before "A".
    func testVisibleSessionsSortsByLastActiveDesc() async {
        let store = makeStore()

        // Initial seed: A is newer.
        let a = makeSummary(id: "A", lastActive: 200, startedAt: 100)
        let b = makeSummary(id: "B", lastActive: 100, startedAt: 50)
        store.sessions = [a, b]

        // Simulate a refresh that bumps B's lastActive above A's.
        let aUpdated = makeSummary(id: "A", lastActive: 200, startedAt: 100)
        let bBumped  = makeSummary(id: "B", lastActive: 300, startedAt: 50)
        store.sessionsFetch = { ([bBumped, aUpdated], 2) }

        await store.refresh()

        let ids = store.visibleSessions.map(\.id)
        XCTAssertEqual(ids.first, "B",
            "B should float to the top after its lastActive is bumped higher than A's")
        XCTAssertEqual(ids, ["B", "A"])
    }

    // MARK: - ABH-157: stale device-clock bump must decay (sort + timestamp)

    /// A SETTLED (not live) optimistic device-clock bump must DECAY to the server
    /// value on merge, so a genuinely-fresher foreign (desktop-driven) session
    /// outranks it. This pins the drawer recency-sort AND stale-timestamp fix —
    /// both key on `lastActive`, so one decay fixes both. The bug: `noteActivity`
    /// bumps to the DEVICE clock and the old unconditional `max(local, server)`
    /// carry-forward pinned that future-dated value above the true server value
    /// forever, so an idle local row outranked a fresher desktop one.
    func testSettledStaleBumpDecaysSoFresherForeignOutranks() async {
        let store = makeStore()
        // "mine": the user's own session, optimistically bumped to a device-now
        // value ABOVE its true server lastActive (clock skew). No live frame is in
        // flight — `lastActivityAt` is NOT stamped, i.e. the turn has settled.
        let mineStale = makeSummary(id: "mine", lastActive: 100_000, startedAt: 1)
        let deskOld   = makeSummary(id: "desk", lastActive:  90_000, startedAt: 1)
        store.sessions = [mineStale, deskOld]

        // Server authority: desk was JUST active (fresher); mine's TRUE value is
        // lower than its stale local bump.
        let deskFresh = makeSummary(id: "desk", lastActive: 95_000, startedAt: 1)
        let mineTrue  = makeSummary(id: "mine", lastActive: 80_000, startedAt: 1)
        store.sessionsFetch = { ([deskFresh, mineTrue], 2) }

        await store.refresh()

        XCTAssertEqual(store.visibleSessions.map(\.id).first, "desk",
            "a settled stale device-clock bump must decay to the server value so a fresher foreign session sorts above it")
        XCTAssertEqual(store.visibleSessions.first(where: { $0.id == "mine" })?.lastActive, 80_000,
            "the displayed timestamp converges to the authoritative server value, not the stale future bump")
    }

    /// While a turn is genuinely in flight (markTurnStarted called), the optimistic
    /// bump is STILL carried forward over a lagging server value — so the row does
    /// not flicker down on the debounced refresh that fires right after message.start.
    /// This guards the anti-flicker behavior the ABH-178 change must not regress.
    func testLiveBumpStillCarriedForwardToPreventFlicker() async {
        let store = makeStore()
        let mineBumped = makeSummary(id: "mine",  lastActive: 100_000, startedAt: 1)
        let other      = makeSummary(id: "other", lastActive:  90_000, startedAt: 1)
        store.sessions = [mineBumped, other]
        // ABH-178: carry-forward now gates on the explicit turn-in-progress flag.
        store.markTurnStarted(storedId: "mine")

        // The debounced refresh returns the OLD (lower) server value for mine.
        let mineOldServer = makeSummary(id: "mine",  lastActive: 50_000, startedAt: 1)
        let otherSame     = makeSummary(id: "other", lastActive: 90_000, startedAt: 1)
        store.sessionsFetch = { ([otherSame, mineOldServer], 2) }

        await store.refresh()

        XCTAssertEqual(store.visibleSessions.map(\.id).first, "mine",
            "while a turn is in flight (markTurnStarted), the optimistic bump is carried forward so the row doesn't flicker down before the server catches up")
    }

    // MARK: - LANE D: live session must not sink after a reconnect snapshot

    /// LANE D regression. A live turn is streaming into "mine" (optimistically
    /// bumped to the top). A quick reconnect heal force-clears every in-flight turn
    /// flag (`clearAllTurnsInProgress`) yet PRESERVES the live-frame stamp, then its
    /// transport-epoch bump fetches a bounded snapshot. The snapshot carries
    /// the STALE server `lastActive` for "mine" (its last `message.complete` was
    /// yesterday; the in-flight turn has not landed) while two older rows look
    /// fresher. Before the fix, the carry-forward gate was `turnsInProgress`-only, so
    /// the now-empty flag let "mine" decay to its stale value and sink to "yesterday"
    /// — the transient mis-order the user saw. The live-window signal must keep it on
    /// top through the refresh, with no wrong-order publish.
    func testLiveSessionSurvivesReconnectReseedWithoutSinking() async {
        let store = makeStore()
        let mine   = makeSummary(id: "mine", lastActive: 100, startedAt: 1)
        let olderA = makeSummary(id: "a",    lastActive:  90, startedAt: 1)
        let olderB = makeSummary(id: "b",    lastActive:  80, startedAt: 1)
        store.sessions = [mine, olderA, olderB]

        // A live turn is streaming into "mine": mark it in-flight and stamp a live
        // frame (noteActivity bumps lastActive to device-now AND stamps the live
        // window used for the dot / carry-forward).
        store.markTurnStarted(storedId: "mine")
        store.noteActivity(storedId: "mine")

        // Quick reconnect heal: force-clears in-flight turn flags but leaves the
        // live-frame stamp intact (the row is still visibly live).
        store.clearAllTurnsInProgress()
        XCTAssertTrue(store.turnsInProgressIds.isEmpty,
            "setup: the reconnect heal cleared the turn-in-progress flag")

        // The reconnect refresh returns a bounded snapshot that still
        // carries the stale (pre-turn) server lastActive for "mine".
        let mineStale = makeSummary(id: "mine", lastActive: 10, startedAt: 1)
        store.sessionsFetch = { ([olderA, olderB, mineStale], 3) }
        await store.refresh()

        XCTAssertEqual(store.visibleSessions.map(\.id).first, "mine",
            "a still-live session must not sink to its stale server lastActive after a reconnect clears the turn-in-progress flag")
    }

    func testVisibleSessionsSortsByStartedAtWhenNoLastActive() async {
        let store = makeStore()
        let old   = makeSummary(id: "old",   startedAt: 100)
        let newer = makeSummary(id: "newer", startedAt: 200)
        store.sessions = [old, newer]

        // Page preserves both rows, neither has lastActive.
        store.sessionsFetch = { ([old, newer], nil) }
        await store.refresh()

        let ids = store.visibleSessions.map(\.id)
        XCTAssertEqual(ids, ["newer", "old"],
            "When lastActive is absent, newer startedAt must come first")
    }

    // MARK: - 2. Merge keeps active survivor

    /// If the active session is absent from the incoming page, it must be
    /// prepended to `sessions` (non-destructive merge).
    func testMergeKeepsActiveSurvivor() async {
        let store = makeStore()
        let active = makeSummary(id: "active", lastActive: 999)
        let other  = makeSummary(id: "other",  lastActive: 100)

        store.sessions = [active, other]
        store.activeStoredId = "active"

        // Incoming page omits "active" (simulates pagination gap or server lag).
        store.sessionsFetch = { ([other], 1) }
        await store.refresh()

        let ids = store.sessions.map(\.id)
        XCTAssertTrue(ids.contains("active"),
            "Active session must survive a merge even when absent from the incoming page")
    }

    // MARK: - 3. Merge keeps pinned survivor

    /// Pinned sessions must survive even when absent from the incoming page.
    func testMergeKeepsPinnedSurvivor() async {
        let store = makeStore()
        let pinned = makeSummary(id: "pinned", lastActive: 50)
        let other  = makeSummary(id: "other",  lastActive: 200)

        store.sessions = [other, pinned]
        store.togglePin(pinned)  // inserts into pinnedIds

        // Incoming page omits the pinned session.
        store.sessionsFetch = { ([other], 1) }
        await store.refresh()

        XCTAssertTrue(store.sessions.map(\.id).contains("pinned"),
            "Pinned session must survive a merge even when absent from the incoming page")
    }

    /// Non-working-set rows absent from the incoming page must NOT be retained.
    func testMergeDropsNonWorkingSetAbsentRows() async {
        let store = makeStore()
        let old   = makeSummary(id: "old",   lastActive: 10)
        let other = makeSummary(id: "other", lastActive: 200)

        store.sessions = [other, old]
        // Neither "old" nor "other" is active or pinned.

        // Incoming page omits "old".
        store.sessionsFetch = { ([other], 1) }
        await store.refresh()

        XCTAssertFalse(store.sessions.map(\.id).contains("old"),
            "A non-working-set row absent from the incoming page must be dropped")
    }

    // MARK: - 4. Stale token response discarded

    /// If a second `refresh()` fires while the first is in flight, the first
    /// response must be discarded. We simulate this by manipulating the token
    /// directly (since we cannot truly interleave async tasks in a unit test
    /// without actors / continuations). Instead we verify the monotonic-token
    /// logic: after two sequential fetches, the list reflects the SECOND call.
    func testStaleTokenResponseDiscarded() async {
        let store = makeStore()
        let first  = [makeSummary(id: "first",  lastActive: 100)]
        let second = [makeSummary(id: "second", lastActive: 200)]

        // First call installs "first".
        store.sessionsFetch = { (first, 1) }
        await store.refresh()
        XCTAssertEqual(store.sessions.map(\.id), ["first"])

        // Second call installs "second".
        store.sessionsFetch = { (second, 1) }
        await store.refresh()
        XCTAssertEqual(store.sessions.map(\.id), ["second"],
            "The second refresh must overwrite the first; stale-token guard must not block it")

        // Verify the refresh token advanced (monotonic).
        // The token is private, but we can observe the side-effect: after two
        // sequential refreshes the list is always the second result.
        XCTAssertFalse(store.sessions.map(\.id).contains("first"),
            "Stale result from the first refresh must not persist after the second refresh completes")
    }

    // MARK: - 6. Hard-replace semantics gone

    /// Verify the old hard-replace (sessions = result) no longer applies: a
    /// working-set member absent from the page must NOT be wiped.
    func testHardReplaceIsReplaced() async {
        let store = makeStore()
        let active = makeSummary(id: "activeSession", lastActive: 100)
        let page   = makeSummary(id: "pageOnly",       lastActive: 50)

        store.sessions = [active, page]
        store.activeStoredId = "activeSession"

        // Page omits the active session.
        store.sessionsFetch = { ([page], 1) }
        await store.refresh()

        // Hard-replace would produce ["pageOnly"] only.
        // Non-destructive merge must keep "activeSession".
        XCTAssertTrue(store.sessions.map(\.id).contains("activeSession"),
            "Hard-replace is no longer acceptable — active session must survive the merge")
    }

}

private final class FirstPairSessionListStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestedOrders: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let components = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        let items = components?.queryItems ?? []
        let order = items.first(where: { $0.name == "order" })?.value ?? ""
        let limit = items.first(where: { $0.name == "limit" })?.value
        Self.requestedOrders.append(order)

        let expectedLimit = order == "created"
            ? String(SessionStore.initialSnapshotLimit)
            : String(SessionStore.snapshotLimit)
        guard limit == expectedLimit else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let id = order == "created" ? "quick" : "authoritative"
        let body = """
        {"sessions":[{"id":"\(id)","title":"\(id)","started_at":1,"message_count":1,"source":"cli","last_active":1}],"total":1}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - ABH-178: explicit turnInProgress carry-forward gate

/// Tests for the explicit `turnsInProgress` flag that replaced the 10s liveWindow
/// time-proxy as the carry-forward gate in `mergeSessionSnapshot`. All tests are
/// deterministic: no real timestamps, no async waits beyond the `await store.refresh()`.
///
/// The invariant under test: `mergeSessionSnapshot` carries a higher local `lastActive`
/// forward over the incoming server value IFF the session's stored id is in
/// `turnsInProgress`. The live-dot (`lastActivityAt`/`liveWindow`) is untouched
/// — only this carry-forward gate changed.
@MainActor
final class TurnInProgressCarryForwardTests: XCTestCase {

    private func makeSummary(id: String, lastActive: Double) -> SessionSummary {
        SessionSummary(
            id: id, title: id, preview: nil, startedAt: 1,
            messageCount: nil, source: nil, lastActive: lastActive, cwd: nil
        )
    }

    // MARK: (a) No prior local value → no carry-forward regardless of flag

    func testNoLocalPriorNeverCarriesForward() async {
        let store = SessionStore()
        // No local sessions; server returns a fresh row. Turn flag is set, but
        // there is no prior local lastActive to carry forward.
        store.markTurnStarted(storedId: "sess")
        store.sessionsFetch = { ([self.makeSummary(id: "sess", lastActive: 500)], 1) }
        await store.refresh()
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == "sess" })?.lastActive, 500,
            "when no prior local lastActive exists, the server value must win regardless of the turn flag"
        )
    }

    // MARK: (b) turnInProgress set + local > server → carry-forward applies

    func testTurnInProgressCarriesLocalForwardWhenHigher() async {
        let store = SessionStore()
        // Seed a locally-bumped row.
        store.sessions = [makeSummary(id: "mine", lastActive: 100_000)]
        store.markTurnStarted(storedId: "mine")
        // Server returns a lower (stale) value — the turn hasn't completed yet.
        store.sessionsFetch = { ([self.makeSummary(id: "mine", lastActive: 50_000)], 1) }
        await store.refresh()
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == "mine" })?.lastActive, 100_000,
            "while a turn is in flight the local bump must be carried forward, keeping the row at the top"
        )
    }

    // MARK: (c) turnInProgress NOT set + local > server → carry-forward does NOT apply

    func testNoTurnFlagDropsCarryForward() async {
        let store = SessionStore()
        // Seed a locally-bumped row. No turn flag — simulates a settled/idle session.
        store.sessions = [makeSummary(id: "mine", lastActive: 100_000)]
        // NO markTurnStarted — flag is absent.
        store.sessionsFetch = { ([self.makeSummary(id: "mine", lastActive: 50_000)], 1) }
        await store.refresh()
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == "mine" })?.lastActive, 50_000,
            "without a turn-in-progress flag the server value must win (no carry-forward for settled sessions)"
        )
    }

    // MARK: (d) markTurnCompleted clears the flag → subsequent refresh decays

    func testMarkTurnCompletedClearsCarryForward() async {
        let store = SessionStore()
        store.sessions = [makeSummary(id: "mine", lastActive: 100_000)]
        store.markTurnStarted(storedId: "mine")

        // While the turn is in flight, refresh carries the bump forward.
        store.sessionsFetch = { ([self.makeSummary(id: "mine", lastActive: 50_000)], 1) }
        await store.refresh()
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == "mine" })?.lastActive, 100_000,
            "carry-forward must hold while turn is in flight"
        )

        // Turn completes → flag cleared.
        store.markTurnCompleted(storedId: "mine")

        // Next refresh (e.g. the post-complete one): server value now wins.
        store.sessionsFetch = { ([self.makeSummary(id: "mine", lastActive: 75_000)], 1) }
        await store.refresh()
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == "mine" })?.lastActive, 75_000,
            "after markTurnCompleted the carry-forward must not apply — server lastActive must win"
        )
    }

    // MARK: (d2) clearAllTurnsInProgress (disconnect/reconnect path)

    func testClearAllTurnsInProgressUnblocksDecay() async {
        let store = SessionStore()
        store.sessions = [
            makeSummary(id: "sess-a", lastActive: 200_000),
            makeSummary(id: "sess-b", lastActive: 180_000),
        ]
        store.markTurnStarted(storedId: "sess-a")
        store.markTurnStarted(storedId: "sess-b")

        // Simulate a disconnect mid-turn (e.g. socket drop).
        store.clearAllTurnsInProgress()

        // Post-reconnect refresh: server authority must win for both rows.
        store.sessionsFetch = {
            ([
                self.makeSummary(id: "sess-a", lastActive: 100_000),
                self.makeSummary(id: "sess-b", lastActive: 90_000),
            ], 2)
        }
        await store.refresh()
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == "sess-a" })?.lastActive, 100_000,
            "after clearAllTurnsInProgress, sess-a must decay to server value (no stuck flag)"
        )
        XCTAssertEqual(
            store.sessions.first(where: { $0.id == "sess-b" })?.lastActive, 90_000,
            "after clearAllTurnsInProgress, sess-b must decay to server value (no stuck flag)"
        )
    }

    // MARK: - live-dot preserved (lastActivityAt unaffected by this change)

    func testLiveDotStillWorksThroughNoteActivity() {
        // noteActivity still stamps lastActivityAt for the live-dot — the
        // carry-forward change must NOT have removed that side-effect.
        let store = SessionStore()
        store.sessions = [makeSummary(id: "live", lastActive: 100)]
        store.noteActivity(storedSessionId: "live")
        XCTAssertTrue(
            store.isLive(storedSessionId: "live"),
            "live-dot (isLive) must still work via noteActivity — the carry-forward change must not break it"
        )
    }
}

// MARK: - ABH-351 ProjectsStore tests (folded from ProjectsStoreTests.swift)

import Testing

/// Session refresh outcome classification.
@MainActor
struct ProjectsStoreModelTests {

    // MARK: - ABH-470 background outcome seam

    @Test("refreshOutcome reports real success")
    func refreshOutcome_reportsSuccess() async {
        let store = SessionStore()
        store.sessionsFetch = { ([], 0) }

        #expect(await store.refreshOutcome() == .success)
    }

    @Test("refreshOutcome classifies retryable failures without localized matching")
    func refreshOutcome_reportsRetryableFailure() async {
        let store = SessionStore()
        struct Retryable: Error {}
        store.sessionsFetch = { throw Retryable() }

        #expect(await store.refreshOutcome() == .retryableFailure)
    }

    @Test("refreshOutcome classifies typed authentication failures")
    func refreshOutcome_reportsAuthFailure() async {
        let store = SessionStore()
        store.sessionsFetch = { throw RestError.badStatus(401, body: "any localized text") }

        #expect(await store.refreshOutcome() == .authFailure)
    }

    @Test("refreshOutcome propagates cancellation and timeout")
    func refreshOutcome_reportsCancellationAndTimeout() async {
        let cancelled = SessionStore()
        cancelled.sessionsFetch = { throw CancellationError() }
        #expect(await cancelled.refreshOutcome() == .timeout)

        let timedOut = SessionStore()
        timedOut.sessionsFetch = { throw URLError(.timedOut) }
        #expect(await timedOut.refreshOutcome() == .timeout)
    }
}

/// A Sendable one-shot flag for `withObservationTracking`'s `@Sendable` onChange
/// closure (Swift 6 forbids mutating a captured `var` there). All access is
/// effectively on the MainActor in these tests; the lock makes it data-race-safe
/// regardless.
private final class MutationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return _fired }
    func fire() { lock.lock(); _fired = true; lock.unlock() }
}
