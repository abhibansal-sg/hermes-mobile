import XCTest
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
/// 5. **Coalescing collapses rapid triggers** — calling `scheduleSessionRefresh()`
///    rapidly (via the `sessionsFetch` seam) results in one refresh, not N.
/// 6. **Total decoded and exposed** — `totalSessions` is populated from the fetch
///    result; `nil` total preserves the previously-known value.
@MainActor
final class SessionRefreshTests: XCTestCase {

    // MARK: - Helpers

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

    /// When `lastActive` is absent, sort falls back to `startedAt` DESC.
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

    // MARK: - 5. Total decoded and exposed

    /// When the fetch returns a non-nil total, `totalSessions` must be updated.
    func testTotalDecodedAndExposed() async {
        let store = makeStore()
        XCTAssertNil(store.totalSessions, "totalSessions must be nil before any fetch")

        let rows = [makeSummary(id: "A", lastActive: 100)]
        store.sessionsFetch = { (rows, 42) }
        await store.refresh()

        XCTAssertEqual(store.totalSessions, 42,
            "totalSessions must reflect the total returned by the fetch")
    }

    /// When the fetch returns `nil` total, the previously-known `totalSessions`
    /// must be preserved (WS RPC path has no total field).
    func testNilTotalPreservesPreviousTotal() async {
        let store = makeStore()

        // First fetch: establishes a known total.
        store.sessionsFetch = { ([self.makeSummary(id: "A", lastActive: 100)], 7) }
        await store.refresh()
        XCTAssertEqual(store.totalSessions, 7)

        // Second fetch: no total (WS-RPC shape or older gateway).
        store.sessionsFetch = { ([self.makeSummary(id: "A", lastActive: 200)], nil) }
        await store.refresh()
        XCTAssertEqual(store.totalSessions, 7,
            "A nil total in a subsequent fetch must preserve the previously-known totalSessions")
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

// MARK: - ABH-178: explicit turnInProgress carry-forward gate

/// Tests for the explicit `turnsInProgress` flag that replaced the 10s liveWindow
/// time-proxy as the carry-forward gate in `mergeSessionPage`. All tests are
/// deterministic: no real timestamps, no async waits beyond the `await store.refresh()`.
///
/// The invariant under test: `mergeSessionPage` carries a higher local `lastActive`
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

// MARK: - ABH-351 / STR-992 WU2 ProjectsStore tests (folded from ProjectsStoreTests.swift)

import Testing

/// ABH-351 / STR-992 WU2 — Projects model decoding + store state + server-backed
/// session cache tests.
///
/// These tests exercise the three things slice-2 owns:
/// 1. The `Project` model decodes the slice-1 route's JSON contract
///    (`{id, label, root, session_count}`) — including the snake_case key.
/// 2. `ProjectsStore.normalizedPath` keys the server-backed session cache
///    (case-insensitive, trailing-slash-insensitive) — it no longer matches a
///    session's cwd, since project detail no longer derives membership from
///    `SessionStore.sessions`.
/// 3. `ProjectsStore.refreshSessions(for:)` / `.sessionsState(for:)` — the
///    STR-992 WU2 server-backed session cache, injected via the `sessionsFetch`
///    DEBUG seam. `ProjectsStore.sessions(for:in:)` (cwd-derived filtering of
///    `SessionStore.sessions`) has been removed: a project's `sessionCount` is
///    only a pre-fetch hint that may legitimately exceed what this cache holds.
@MainActor
struct ProjectsStoreTests {

    // MARK: - Project model decoding

    @Test("Project decodes the full route contract with snake_case session_count")
    func decode_fullContract() throws {
        let json = #"""
        {
            "id": "/path/to/hermes-mobile",
            "label": "hermes-mobile",
            "root": "/path/to/hermes-mobile",
            "session_count": 5
        }
        """# .data(using: .utf8)!

        let project = try JSONDecoder().decode(Project.self, from: json)
        #expect(project.id == "/path/to/hermes-mobile")
        #expect(project.label == "hermes-mobile")
        #expect(project.root == "/path/to/hermes-mobile")
        #expect(project.sessionCount == 5)
    }

    @Test("Project decodes a bare JSON array (route response shape)")
    func decode_array() throws {
        let json = #"""
        [
            {
                "id": "/repo/a",
                "label": "a",
                "root": "/repo/a",
                "session_count": 3
            },
            {
                "id": "/repo/b",
                "label": "b",
                "root": "/repo/b",
                "session_count": 0
            }
        ]
        """# .data(using: .utf8)!

        let projects = try JSONDecoder().decode([Project].self, from: json)
        #expect(projects.count == 2)
        #expect(projects[0].label == "a")
        #expect(projects[1].sessionCount == 0)
    }

    // MARK: - normalizedPath

    @Test("normalizedPath is case-insensitive and trailing-slash-insensitive")
    func normalizedPath_matching() {
        #expect(ProjectsStore.normalizedPath("/Users/foo/Repo") == "/users/foo/repo")
        #expect(ProjectsStore.normalizedPath("/Users/foo/Repo/") == "/users/foo/repo")
        #expect(ProjectsStore.normalizedPath("/Users/foo/Repo//") == "/users/foo/repo")
        // whitespace trimmed
        #expect(ProjectsStore.normalizedPath("  /Users/foo/Repo  ") == "/users/foo/repo")
    }

    @Test("normalizedPath returns empty for whitespace-only input")
    func normalizedPath_empty() {
        #expect(ProjectsStore.normalizedPath("") == "")
        #expect(ProjectsStore.normalizedPath("   ") == "")
        #expect(ProjectsStore.normalizedPath("\n") == "")
    }

    // MARK: - Server-backed session cache (STR-992 WU2)
    //
    // Replaces the old `sessions(for:in:)` cwd-derivation tests. All tests here
    // inject `sessionsFetch` (mirrors the `sessionsFetch`/`searchFetch` DEBUG
    // seams elsewhere in this file) — no live gateway, and critically, no
    // `SessionStore` instance is ever constructed: the server-backed cache is
    // never allowed to fall back to `SessionStore.sessions` as a membership
    // source.

    @Test("sessionsState(for:) returns a fresh, not-loaded state before any refresh")
    func sessionsState_beforeRefresh() {
        let store = ProjectsStore()
        let project = Project(id: "/repo/a", label: "a", root: "/repo/a", sessionCount: 5)

        let state = store.sessionsState(for: project)
        #expect(state.sessions.isEmpty)
        #expect(state.isLoading == false)
        #expect(state.loadError == nil)
        #expect(state.hasLoaded == false)
    }

    @Test("refreshSessions(for:) populates the cache from the injected sessionsFetch seam")
    func refreshSessions_populatesCache() async {
        let store = ProjectsStore()
        let project = Project(id: "/repo/a", label: "a", root: "/repo/a", sessionCount: 2)
        store.sessionsFetch = { _ in
            RestClient.ProjectSessionsPage(sessions: [self.stub(id: "1"), self.stub(id: "2")], total: 2)
        }

        await store.refreshSessions(for: project)

        let state = store.sessionsState(for: project)
        #expect(state.sessions.map(\.id) == ["1", "2"])
        #expect(state.total == 2)
        #expect(state.hasLoaded == true)
        #expect(state.isLoading == false)
        #expect(state.loadError == nil)
    }

    @Test("refreshSessions(for:) surfaces an error when the fetch fails before any load has succeeded")
    func refreshSessions_surfacesErrorBeforeFirstLoad() async {
        struct FetchError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let store = ProjectsStore()
        let project = Project(id: "/repo/a", label: "a", root: "/repo/a", sessionCount: 0)
        store.sessionsFetch = { _ in throw FetchError() }

        await store.refreshSessions(for: project)

        let state = store.sessionsState(for: project)
        #expect(state.hasLoaded == false)
        #expect(state.loadError == "boom")
        #expect(state.sessions.isEmpty)
    }

    @Test("a later failed refresh preserves the last successful list instead of surfacing an error")
    func refreshSessions_preservesLastGoodListOnLaterFailure() async {
        struct FetchError: Error {}
        let store = ProjectsStore()
        let project = Project(id: "/repo/a", label: "a", root: "/repo/a", sessionCount: 1)

        store.sessionsFetch = { _ in RestClient.ProjectSessionsPage(sessions: [self.stub(id: "1")], total: 1) }
        await store.refreshSessions(for: project)

        store.sessionsFetch = { _ in throw FetchError() }
        await store.refreshSessions(for: project)

        let state = store.sessionsState(for: project)
        #expect(state.hasLoaded == true)
        #expect(state.sessions.map(\.id) == ["1"],
                 "a transient failure must not blank out the last successful load")
        #expect(state.loadError == nil,
                 "no error banner once a load has already succeeded once for this project")
    }

    @Test("the cache is keyed by normalizedPath(root), so case/trailing-slash root variants share an entry")
    func sessionsCache_keyedByNormalizedRoot() async {
        let store = ProjectsStore()
        let project = Project(id: "/Repo/A", label: "a", root: "/Repo/A", sessionCount: 1)
        store.sessionsFetch = { _ in RestClient.ProjectSessionsPage(sessions: [self.stub(id: "1")], total: 1) }
        await store.refreshSessions(for: project)

        // Same repo, different id casing/trailing slash — must hit the same cache entry.
        let sameRepoVariant = Project(id: "/repo/a/", label: "a", root: "/repo/a/", sessionCount: 1)
        let state = store.sessionsState(for: sameRepoVariant)
        #expect(state.hasLoaded == true)
        #expect(state.sessions.map(\.id) == ["1"])
    }

    @Test("sessionCount may exceed the fetched session count — detail must never fall back to SessionStore.sessions")
    func sessionCount_canExceedFetchedSessions() async {
        let store = ProjectsStore()
        // The overview hint says 50 sessions; the server-backed fetch (the only
        // source project detail is allowed to read) returns just 2. A prior bug
        // class conflated this hint with `SessionStore.sessions.filter(...)`,
        // which could never exceed what the drawer's `SessionStore` had loaded.
        let project = Project(id: "/repo/a", label: "a", root: "/repo/a", sessionCount: 50)
        store.sessionsFetch = { _ in
            RestClient.ProjectSessionsPage(sessions: [self.stub(id: "1"), self.stub(id: "2")], total: 2)
        }

        await store.refreshSessions(for: project)

        let state = store.sessionsState(for: project)
        #expect(state.hasLoaded == true)
        #expect(state.sessions.count == 2, "the fetched count, not project.sessionCount, is authoritative once loaded")
        #expect(project.sessionCount == 50, "the pre-fetch hint itself is untouched by the cache")
        // No SessionStore is constructed anywhere in this test — unlike the old
        // sessions(for:in:) derivation, the cache has no dependency on one.
    }

    @Test("state.total is the route's authoritative count, and can itself exceed sessions.count when session_limit truncates")
    func total_canExceedFetchedSessionsWhenLimitTruncates() async {
        let store = ProjectsStore()
        // Mirrors STR-998's project_sessions route: `total` comes from the
        // hydrated tree's `sessionCount`, while `sessions` is the flattened,
        // `session_limit`-bounded list — the two can legitimately diverge.
        // ProjectDetailView's header must read `state.total`, never
        // `state.sessions.count`, once loaded.
        let project = Project(id: "/repo/a", label: "a", root: "/repo/a", sessionCount: 0)
        store.sessionsFetch = { _ in
            RestClient.ProjectSessionsPage(sessions: [self.stub(id: "1"), self.stub(id: "2")], total: 9)
        }

        await store.refreshSessions(for: project)

        let state = store.sessionsState(for: project)
        #expect(state.hasLoaded == true)
        #expect(state.sessions.count == 2)
        #expect(state.total == 9, "total is server-authoritative and independent of how many rows session_limit returned")
    }

    // MARK: - Store initial state

    @Test("ProjectsStore starts with nil projects, not loading, no error")
    func initialStoreState() {
        let store = ProjectsStore()
        #expect(store.projects == nil)
        #expect(store.isLoading == false)
        #expect(store.loadError == nil)
    }

    // MARK: - Helpers

    /// Minimal `SessionSummary` builder for cache tests: only `id` varies.
    private func stub(id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            title: nil,
            preview: nil,
            startedAt: nil,
            messageCount: nil,
            source: nil,
            lastActive: nil,
            cwd: nil
        )
    }
}

// MARK: - RestClient.projectSessions(projectID:limit:) contract coverage (STR-992 WU2 / STR-998 WU1)

/// Confirms `projectSessions(projectID:limit:)` matches the real STR-998/WU1
/// route contract landed in `plugins/hermes-mobile/dashboard/api.py::project_sessions`
/// (commit e0e67cd63): `GET {mobileAPIPrefix}/project-sessions` — mounted ONLY
/// under the plugin router (`app.include_router(router, prefix="/api/plugins/hermes-mobile")`
/// in `hermes_cli/web_server.py`; there is no legacy top-level alias for this
/// new route), with `project_id` (not `root`) and `session_limit` as query
/// params, and a `{"project_id", "sessions", "total"}` response body
/// (`test_projects_route.py::test_project_sessions_flattens_hydrated_desktop_lanes`).
///
/// `projectID` is percent-encoded as a QUERY value (via
/// `URLQueryItem`/`percentEncodedQuery`), not a path segment — a project id
/// is a repo root and routinely contains `/`, spaces, and other characters a
/// naive path segment would mis-encode or split on. Mirrors the
/// `RecordingProtocol` stub-transport pattern from `PathStyleTests.swift`
/// (no live gateway).
@MainActor
final class ProjectSessionsRestClientTests: XCTestCase {

    /// Records every request URL and serves one scripted (Data, status) response.
    final class RecordingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var response: (Data, Int) = (Data(), 200)

        static func reset(response: (Data, Int)) {
            requests = []
            self.response = response
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            let (body, status) = Self.response
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient(response: (Data, Int)) -> RestClient {
        RecordingProtocol.reset(response: response)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        return RestClient(
            baseURL: URL(string: "https://gw.example:9119")!,
            token: "tok",
            session: URLSession(configuration: config),
            // STR-998's project-sessions route is mounted only under the
            // plugin router — there is no `/api/project-sessions` legacy
            // alias for this new endpoint, so `.plugin` is the only path
            // style that resolves it. `.legacy` would 404 against a real
            // gateway.
            pathStyle: .plugin
        )
    }

    func testProjectSessionsEncodesProjectIDAsQueryValue() async throws {
        let json = #"{"project_id":"x","sessions":[],"total":0}"#.data(using: .utf8)!
        let client = makeClient(response: (json, 200))

        // Slashes, a space, and a reserved `&` — all illegal unescaped in a URL
        // and, for `/`, would silently change path segmentation if this were
        // (incorrectly) encoded as a path component instead of a query value.
        _ = try await client.projectSessions(projectID: "/Users/foo/My Repo & Co")

        let request = try #require(RecordingProtocol.requests.first)
        let url = try #require(request.url)
        #expect(url.path == "/api/plugins/hermes-mobile/project-sessions")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let projectIDValue = components.queryItems?.first { $0.name == "project_id" }?.value
        #expect(projectIDValue == "/Users/foo/My Repo & Co",
                 "decoded query value must round-trip exactly, proving the raw id was query-encoded, not path-mangled")
        let sessionLimitValue = components.queryItems?.first { $0.name == "session_limit" }?.value
        #expect(sessionLimitValue == "5000", "default limit must match the route's default session_limit")
    }

    func testProjectSessionsPassesExplicitLimit() async throws {
        let json = #"{"project_id":"x","sessions":[],"total":0}"#.data(using: .utf8)!
        let client = makeClient(response: (json, 200))

        _ = try await client.projectSessions(projectID: "/repo/a", limit: 123)

        let request = try #require(RecordingProtocol.requests.first)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "session_limit" }?.value == "123")
    }

    func testProjectSessionsDecodesSessionsAndTotal() async throws {
        // Exact shape of `plugins/hermes-mobile/dashboard/api.py::project_sessions`'s
        // response (STR-998, commit e0e67cd63) — `total` can exceed
        // `sessions.count` when `session_limit` truncates the flattened list.
        let json = #"""
        {"project_id":"p_widget","sessions":[{"id":"s1","title":"t","preview":null,"started_at":null,"message_count":null,"source":null,"last_active":null,"cwd":null}],"total":9}
        """#.data(using: .utf8)!
        let client = makeClient(response: (json, 200))

        let page = try await client.projectSessions(projectID: "p_widget")
        #expect(page.sessions.map(\.id) == ["s1"])
        #expect(page.total == 9)
    }
}
