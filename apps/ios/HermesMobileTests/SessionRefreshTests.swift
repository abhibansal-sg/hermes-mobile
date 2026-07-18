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
/// 5. **Coalescing collapses rapid triggers** — calling `scheduleSessionRefresh()`
///    rapidly (via the `sessionsFetch` seam) results in one refresh, not N.
/// 6. **Total decoded and exposed** — `totalSessions` is populated from the fetch
///    result; `nil` total preserves the previously-known value.
/// 7. **Plugin cursor deltas** — empty, changed-row, tombstone, and request-shape
///    behavior preserve the loaded working set and compatibility fallbacks.
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

    // MARK: - STR-1208 plugin cursor deltas

    func testBackgroundFlushedCursorRestoresAcrossRelaunch() async throws {
        let suiteName = "SessionCursorFlush-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = SessionStore(defaults: defaults)
        first.sessionListDeltaFetch = { _, _ in
            SessionListDeltaResult(
                sessions: [self.makeSummary(id: "A", lastActive: 100)],
                tombstones: [],
                cursor: "persisted-cursor",
                total: 1
            )
        }
        first.initialFillFetch = { _ in ([], 1) }
        await first.refresh()
        first.flushSessionListDeltaCursors(defaults: defaults)

        let relaunched = SessionStore(defaults: defaults)
        var observedCursor: String?
        relaunched.sessionListDeltaFetch = { cursor, _ in
            observedCursor = cursor
            return SessionListDeltaResult(
                sessions: [], tombstones: [], cursor: cursor ?? "missing", total: 1
            )
        }
        relaunched.initialFillFetch = { _ in ([], 1) }
        await relaunched.refresh()

        XCTAssertEqual(observedCursor, "persisted-cursor")
    }

    func testEmptyCursorDeltaLeavesExistingWindowAndOrderUntouched() async {
        let store = makeStore()
        let a = makeSummary(id: "A", lastActive: 100)
        let b = makeSummary(id: "B", lastActive: 200)
        var seenCursors: [String?] = []

        // The seed intentionally keeps a backing order that differs from recency.
        // An empty delta must not sort or replace that loaded window.
        store.sessionListDeltaFetch = { cursor, _ in
            seenCursors.append(cursor)
            if cursor == nil {
                return SessionListDeltaResult(
                    sessions: [a, b], tombstones: [], cursor: "c1", total: 500
                )
            }
            return SessionListDeltaResult(
                sessions: [], tombstones: [], cursor: "c2", total: 500
            )
        }
        // Terminate the detached fill deterministically without changing rows.
        store.initialFillFetch = { _ in ([], 500) }

        await store.refresh()
        await store.awaitInitialFillForTesting()
        XCTAssertEqual(store.sessions.map(\.id), ["A", "B"])

        store.setPaginationForTesting(loadedCount: 250, loadedOffset: 250, total: 500)
        let before = store.sessions
        await store.refresh()

        XCTAssertEqual(seenCursors, [nil, "c1"])
        XCTAssertEqual(store.sessions, before,
            "an up-to-date empty delta must not rebuild, sort, or clear the current list")
        XCTAssertEqual(store.loadedCount, 250,
            "delta heartbeats must preserve the grow-limit pagination window")
        XCTAssertEqual(store.loadedOffset, 250,
            "delta heartbeats must not reset the pagination offset")
        XCTAssertEqual(store.totalSessions, 500)
    }

    func testChangedCursorDeltaMergesAndResortsByLastActive() async {
        let store = makeStore()
        let a = makeSummary(id: "A", lastActive: 100)
        let b = makeSummary(id: "B", lastActive: 50)
        store.sessionListDeltaFetch = { cursor, _ in
            if cursor == nil {
                return SessionListDeltaResult(
                    sessions: [a, b], tombstones: [], cursor: "seed", total: 2
                )
            }
            return SessionListDeltaResult(
                sessions: [self.makeSummary(id: "B", lastActive: 400)],
                tombstones: [],
                cursor: "next",
                total: 2
            )
        }

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.sessions.map(\.id), ["B", "A"])
        XCTAssertEqual(store.sessions.first?.lastActive, 400)
    }

    /// A2: after a reconnect (transport generation advances), the FIRST session-
    /// list refresh must bypass the persisted delta cursor and do a FULL first-page
    /// re-seed + fill-to-target, so an under-populated drawer (hydration cut short)
    /// is repaired without a process restart. Same-generation refreshes still resume
    /// incremental deltas.
    func testReconnectForcesFullReseedBeforeDeltasResume() async {
        let store = makeStore()
        var generation: UInt64 = 1
        store.reconnectGenerationProvider = { generation }
        var seenCursors: [String?] = []
        let fullPage = (0..<40).map { makeSummary(id: "s\($0)", lastActive: Double(1000 - $0)) }
        store.sessionListDeltaFetch = { cursor, _ in
            seenCursors.append(cursor)
            if cursor == nil {
                return SessionListDeltaResult(
                    sessions: fullPage, tombstones: [], cursor: "cur-\(generation)", total: 40)
            }
            // A non-nil cursor is an incremental heartbeat: only change-sets, never
            // the full list — so it can never by itself repair a partial drawer.
            return SessionListDeltaResult(
                sessions: [], tombstones: [], cursor: "cur-\(generation)", total: 40)
        }
        store.initialFillFetch = { _ in (fullPage, 40) }

        // Cold connect: full seed populates the drawer and sets the cursor.
        await store.refresh()
        await store.awaitInitialFillForTesting()
        XCTAssertGreaterThanOrEqual(store.sessions.count, SessionStore.initialVisibleTarget)
        XCTAssertEqual(seenCursors, [nil], "the first connect seeds with a nil cursor")

        // A same-generation heartbeat resumes incremental deltas (non-nil cursor).
        await store.refresh()
        XCTAssertEqual(seenCursors.last, "cur-1",
            "a same-generation refresh uses the persisted delta cursor")

        // The drawer regresses to a partial state with the cursor STILL set — the
        // exact wedge: incremental deltas alone can never refill it.
        store.sessions = Array(fullPage.prefix(3))
        store.setPaginationForTesting(loadedCount: 3, loadedOffset: 3, total: 40)

        // Reconnect: the transport generation advances.
        generation = 2
        await store.refresh()
        await store.awaitInitialFillForTesting()

        XCTAssertNil(seenCursors.last!,
            "the first refresh after a reconnect must FULL-seed with a nil cursor")
        XCTAssertGreaterThanOrEqual(store.sessions.count, SessionStore.initialVisibleTarget,
            "after reconnect the drawer is restored to a full list, not left partial")

        // Deltas resume on the new generation's cursor for subsequent refreshes.
        await store.refresh()
        XCTAssertEqual(seenCursors.last, "cur-2",
            "after the reconnect reseed, incremental deltas resume from the new cursor")
    }

    func testCursorDeltaTombstonesDropOnlyNonWorkingSetRows() async {
        let store = makeStore()
        let old = makeSummary(id: "old", lastActive: 10)
        let active = makeSummary(id: "active", lastActive: 20)
        let pinned = makeSummary(id: "pinned", lastActive: 30)
        let live = makeSummary(id: "live", lastActive: 40)
        store.activeStoredId = "active"
        store.togglePin(pinned)

        store.sessionListDeltaFetch = { cursor, _ in
            switch cursor {
            case nil:
                return SessionListDeltaResult(
                    sessions: [live, pinned, active, old],
                    tombstones: [],
                    cursor: "seed",
                    total: 4
                )
            case "seed":
                return SessionListDeltaResult(
                    sessions: [],
                    tombstones: [old, active, pinned, live].map {
                        SessionListTombstone(id: $0.id)
                    },
                    cursor: "tombstoned",
                    total: 0
                )
            default:
                return SessionListDeltaResult(
                    sessions: [], tombstones: [], cursor: "settled", total: 0
                )
            }
        }

        await store.refresh()
        store.noteActivity(storedId: "live")
        await store.refresh()

        var ids = Set(store.sessions.map(\.id))
        XCTAssertFalse(ids.contains("old"),
            "a tombstoned non-working-set row must be removed")
        XCTAssertTrue(ids.contains("active"),
            "active rows survive tombstones until the active working set changes")
        XCTAssertTrue(ids.contains("pinned"),
            "pinned rows survive tombstones")
        XCTAssertTrue(ids.contains("live"),
            "recent live rows survive tombstones")

        // The server advances past a tombstone once. Deferred removals must be
        // re-evaluated after local protection ends rather than persisting forever.
        store.activeStoredId = nil
        store.togglePin(pinned)
        await store.refresh()
        ids = Set(store.sessions.map(\.id))
        XCTAssertFalse(ids.contains("active"))
        XCTAssertFalse(ids.contains("pinned"))
        XCTAssertTrue(ids.contains("live"),
            "a still-live row remains protected while deferred tombstones settle")
    }

    func testCursorDeltaTombstonesRewindGrowLimitCursor() async {
        let store = makeStore()
        let allRows = (0..<150).map {
            makeSummary(id: "row-\($0)", lastActive: Double(150 - $0))
        }
        let seedRows = Array(allRows.prefix(100))
        let removedRows = Array(allRows.prefix(60))
        let remainingRows = Array(allRows.dropFirst(60))

        store.sessionListDeltaFetch = { cursor, _ in
            if cursor == nil {
                return SessionListDeltaResult(
                    sessions: seedRows, tombstones: [], cursor: "seed", total: 150
                )
            }
            return SessionListDeltaResult(
                sessions: [],
                tombstones: removedRows.map { SessionListTombstone(id: $0.id) },
                cursor: "tombstoned",
                total: 90
            )
        }

        await store.refresh()
        XCTAssertEqual(store.loadedCount, 100, "setup: the first server window is consumed")
        await store.refresh()

        XCTAssertEqual(store.sessions.count, 40, "the sixty loaded tombstones leave forty rows")
        XCTAssertEqual(store.loadedCount, 40,
            "tombstoned server rows must stop counting as consumed grow-limit rows")
        XCTAssertEqual(store.loadedOffset, 40,
            "the load-more at-end guard must use the rewound server cursor")

        await store.refresh()
        XCTAssertEqual(store.loadedCount, 40,
            "replayed tombstones must not rewind an already-removed seen id twice")
        XCTAssertEqual(store.loadedOffset, 40)

        var requestedLimits: [Int] = []
        store.initialFillFetch = { limit in
            requestedLimits.append(limit)
            return (Array(remainingRows.prefix(limit)), remainingRows.count)
        }
        await store.loadMore()

        XCTAssertEqual(requestedLimits, [90],
            "loadMore must request the remaining current universe instead of stopping at a stale offset")
        XCTAssertEqual(store.sessions.count, 90)
        XCTAssertEqual(store.loadedCount, 90)
        XCTAssertEqual(store.loadedOffset, 90)
    }

    func testCursorDeltaInvalidatesStaleInitialFillPage() async {
        let store = makeStore()
        let seedRows = (0..<5).map {
            makeSummary(id: "seed-\($0)", lastActive: Double(100 - $0))
        }
        let futureTombstone = makeSummary(id: "future", lastActive: 90)
        let currentTail = (5..<35).map {
            makeSummary(id: "current-\($0)", lastActive: Double(100 - $0))
        }

        store.sessionListDeltaFetch = { cursor, _ in
            if cursor == nil {
                return SessionListDeltaResult(
                    sessions: seedRows, tombstones: [], cursor: "seed", total: 60
                )
            }
            return SessionListDeltaResult(
                sessions: [],
                tombstones: [SessionListTombstone(id: futureTombstone.id)],
                cursor: "tombstoned",
                total: 59
            )
        }

        let gate = SessionRefreshGate()
        var fillCalls = 0
        store.initialFillFetch = { _ in
            fillCalls += 1
            if fillCalls == 1 {
                await gate.wait()
                // This grow-window response was computed before the delta removed
                // `future`, so it is stale even though loadedCount did not change.
                return (seedRows + [futureTombstone] + currentTail, 60)
            }
            return (seedRows + currentTail, 59)
        }

        await store.refresh()
        await gate.waitUntilEntered()
        await store.refresh()
        XCTAssertFalse(store.sessions.contains { $0.id == futureTombstone.id },
            "the delta removes the unseen row from the list universe")

        await gate.open()
        await store.awaitInitialFillForTesting()

        XCTAssertGreaterThanOrEqual(fillCalls, 2,
            "the pre-delta grow-window page must be discarded and fetched again")
        XCTAssertFalse(store.sessions.contains { $0.id == futureTombstone.id },
            "a page started before the tombstone must never resurrect that row")
        XCTAssertGreaterThanOrEqual(store.sessions.count, SessionStore.initialVisibleTarget)
    }

    func testProfileScopeChangeRequiresCursorlessSeed() async {
        let store = makeStore()
        let row = makeSummary(id: "row", lastActive: 1)
        var seenCursors: [String?] = []
        store.sessionListDeltaFetch = { cursor, _ in
            seenCursors.append(cursor)
            return SessionListDeltaResult(
                sessions: cursor == nil ? [row] : [],
                tombstones: [],
                cursor: cursor == nil ? "seed" : "next",
                total: 1
            )
        }

        await store.refresh()
        await store.refresh()
        store.activeProfile = "work"
        await store.refresh()

        XCTAssertEqual(seenCursors, [nil, "seed", nil],
            "a cursor from one profile rail must never suppress another rail's seed")
    }

    func testPluginSessionListDeltaQueryUsesCursorOnlyAfterSeed() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionListDeltaQueryProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let rest = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: session,
            pathStyle: .plugin
        )

        let seedResult = await rest.sessionListDelta(
            limit: 125,
            minMessages: 1,
            excludeSource: SessionStore.recentsExcludeSources
        )
        let seed = try XCTUnwrap(seedResult)
        XCTAssertEqual(seed.cursor, "seed+cursor")

        let nextResult = await rest.sessionListDelta(
            limit: 125,
            minMessages: 1,
            excludeSource: SessionStore.recentsExcludeSources,
            updatedSince: seed.cursor
        )
        let next = try XCTUnwrap(nextResult)
        XCTAssertEqual(next.cursor, "next")

        let malformed = await rest.sessionListDelta(
            limit: 125,
            minMessages: 1,
            excludeSource: SessionStore.recentsExcludeSources,
            updatedSince: "malformed"
        )
        XCTAssertNil(malformed,
            "a malformed delta must return nil so SessionStore uses the full REST list")

        let legacy = RestClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: "test-token",
            session: session,
            pathStyle: .legacy
        )
        let legacyResult = await legacy.sessionListDelta(
            limit: 125,
            minMessages: 1,
            excludeSource: SessionStore.recentsExcludeSources,
            updatedSince: seed.cursor
        )
        XCTAssertNil(legacyResult,
            "legacy pathStyle must not call the plugin session-list endpoint")
    }
}

/// Deterministic rendezvous for interleaving a cursor delta with an in-flight
/// initial-fill request. `waitUntilEntered()` proves the fetch is blocked before
/// the test advances the cursor, avoiding scheduler-order false greens.
private actor SessionRefreshGate {
    private var isOpen = false
    private var didEnter = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var entered: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        didEnter = true
        let observers = entered
        entered.removeAll()
        for observer in observers { observer.resume() }
        if isOpen { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entered.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = blocked
        blocked.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Stateless transport proof for the plugin session-list request contract.
/// Every unexpected request receives a valid-but-distinct delta, so assertions
/// fail if the client sends the wrong path/filter/cursor or performs legacy I/O.
private final class SessionListDeltaQueryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let queryItems = Dictionary(uniqueKeysWithValues: components.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [])
        let filtersMatch = url.path == "/api/plugins/hermes-mobile/sessions"
            && queryItems["limit"] == "125"
            && queryItems["order"] == "recent"
            && queryItems["archived"] == "exclude"
            && queryItems["min_messages"] == "1"
            && queryItems["exclude_sources"] == "cron,subagent"
            && queryItems["source"] == nil

        let body: String
        switch queryItems["updated_since"] {
        case nil where filtersMatch:
            body = #"{"sessions":[],"tombstones":[],"cursor":"seed+cursor","total":0}"#
        case "seed+cursor" where filtersMatch
                && components.percentEncodedQuery?.contains(
                    "updated_since=seed%2Bcursor"
                ) == true:
            body = #"{"sessions":[],"tombstones":[],"cursor":"next","total":0}"#
        case "malformed" where filtersMatch:
            body = #"{"sessions":[42],"tombstones":[],"cursor":"bad","total":0}"#
        default:
            body = #"{"sessions":[],"tombstones":[],"cursor":"unexpected","total":0}"#
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

// MARK: - ABH-351 ProjectsStore tests (folded from ProjectsStoreTests.swift)

import Testing

/// ABH-351 — Projects model decoding + store state + session-filter tests.
///
/// These tests exercise the three things slice-2 owns:
/// 1. The `Project` model decodes the slice-1 route's JSON contract
///    (`{id, label, root, session_count}`) — including the snake_case key.
/// 2. `ProjectsStore.normalizedPath` matches a session's cwd to a project's
///    root (case-insensitive, trailing-slash-insensitive).
/// 3. `ProjectsStore.sessions(for:in:)` correctly filters a session list to
///    the ones whose cwd resolves to the project root.
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

    // MARK: - sessions(for:in:)

    @Test("sessions(for:in:) filters sessions whose cwd matches project root")
    func sessionFilter_matches() {
        let store = ProjectsStore()
        let project = Project(
            id: "/repo/a",
            label: "a",
            root: "/Repo/A",
            sessionCount: 2
        )

        let sessions = SessionStore()
        sessions.sessions = [
            SessionSummary.stub(id: "1", cwd: "/repo/a"),
            SessionSummary.stub(id: "2", cwd: "/repo/a/"),
            SessionSummary.stub(id: "3", cwd: "/repo/b"),
            SessionSummary.stub(id: "4", cwd: nil),
        ]

        let result = store.sessions(for: project, in: sessions)
        #expect(result.count == 2)
        #expect(result.contains { $0.id == "1" })
        #expect(result.contains { $0.id == "2" })
    }

    @Test("sessions(for:in:) returns empty when no cwds match")
    func sessionFilter_noMatch() {
        let store = ProjectsStore()
        let project = Project(
            id: "/repo/x",
            label: "x",
            root: "/repo/x",
            sessionCount: 0
        )

        let sessions = SessionStore()
        sessions.sessions = [
            SessionSummary.stub(id: "1", cwd: "/repo/a"),
            SessionSummary.stub(id: "2", cwd: nil),
        ]

        let result = store.sessions(for: project, in: sessions)
        #expect(result.isEmpty)
    }

    // MARK: - Store initial state

    @Test("ProjectsStore starts with nil projects, not loading, no error")
    func initialStoreState() {
        let store = ProjectsStore()
        #expect(store.projects == nil)
        #expect(store.isLoading == false)
        #expect(store.loadError == nil)
    }

    // MARK: - refreshSessions(for:) / sessions(for:) server-scoped fetch (ABH-407)

    @Test("refreshSessions(for:) fetches scoped to the project's root and sessions(for:) returns exactly the server rows")
    func refreshSessions_usesProjectRootAndRendersServerRows() async {
        let store = ProjectsStore()
        let project = Project(id: "/repo/a", label: "a", root: "/Repo/A", sessionCount: 2)
        let serverRows = [
            SessionSummary.stub(id: "server-1", cwd: "/Repo/A"),
            SessionSummary.stub(id: "server-2", cwd: "/Repo/A/sub"),
        ]
        var requestedRoot: String?
        store.sessionsFetch = { requestedProject in
            requestedRoot = requestedProject.root
            return (serverRows, serverRows.count)
        }

        await store.refreshSessions(for: project)

        #expect(requestedRoot == "/Repo/A",
            "refreshSessions must fetch scoped to the project's own root (the cwd_prefix value)")
        #expect(store.sessions(for: project).map(\.id) == ["server-1", "server-2"])
        #expect(store.isLoadingSessions(for: project) == false)
        #expect(store.sessionsError(for: project) == nil)
    }

    @Test("sessions(for:) trusts only the server-scoped response — a matching-cwd row in the global SessionStore must not leak in")
    func refreshSessions_falseGreenGuard_globalSessionStoreCwdMatchIsIgnored() async {
        let store = ProjectsStore()
        let project = Project(id: "/repo/a", label: "a", root: "/Repo/A", sessionCount: 2)

        // The global SessionStore (drawer Recents) happens to hold rows whose cwd
        // matches the project root. Pre-ABH-407, Project detail derived its list by
        // scanning exactly this list — a test that only checked "does the detail
        // list contain the matching rows" would go green even if the server-scoped
        // fetch were never wired up. Prove the opposite: the server's cwd_prefix
        // response — here, empty — is authoritative, so these rows must NOT appear.
        let sessionStore = SessionStore()
        sessionStore.sessions = [
            SessionSummary.stub(id: "stale-1", cwd: "/repo/a"),
            SessionSummary.stub(id: "stale-2", cwd: "/repo/a"),
        ]
        store.sessionsFetch = { _ in ([], 0) }

        await store.refreshSessions(for: project)

        #expect(store.sessions(for: project).isEmpty,
            "Project detail must render the server's cwd_prefix response, not a client-side scan of SessionStore.sessions")
        // Sanity: the old client-side helper WOULD have matched these rows —
        // confirming the false-green guard actually exercises a real divergence.
        #expect(!store.sessions(for: project, in: sessionStore).isEmpty)
    }

    @Test("refreshSessions(for:) surfaces a fetch failure without corrupting the global SessionStore")
    func refreshSessions_failurePreservesGlobalSessionStore() async {
        let store = ProjectsStore()
        let project = Project(id: "/repo/a", label: "a", root: "/Repo/A", sessionCount: 0)
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        store.sessionsFetch = { _ in throw StubError() }

        let sessionStore = SessionStore()
        sessionStore.sessions = [SessionSummary.stub(id: "untouched", cwd: "/repo/a")]

        await store.refreshSessions(for: project)

        #expect(store.sessions(for: project).isEmpty)
        #expect(store.sessionsError(for: project) == "boom")
        #expect(sessionStore.sessions.map(\.id) == ["untouched"],
            "a failed project-scoped fetch must never mutate the global drawer Recents list")
    }

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

/// Minimal stub for ProjectsStoreTests: id + optional cwd, everything else nil.
extension SessionSummary {
    static func stub(id: String, cwd: String?) -> SessionSummary {
        SessionSummary(
            id: id,
            title: nil,
            preview: nil,
            startedAt: nil,
            messageCount: nil,
            source: nil,
            lastActive: nil,
            cwd: cwd
        )
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
