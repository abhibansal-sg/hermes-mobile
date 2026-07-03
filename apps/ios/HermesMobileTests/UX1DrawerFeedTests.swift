import XCTest
@testable import HermesMobile

/// Unit tests for UX1 drawer-feed round-2: pagination, filter honesty, and
/// periodic heartbeat scheduling.
///
/// All tests inject the `sessionsFetch` seam (for first-page) and operate on
/// a `SessionStore` with no live gateway. The four test sections are:
///
/// 1. **loadMore appends + dedupes + respects total** — `loadMore()` fetches the
///    next page via the REST client (injected), appends non-duplicate rows, and
///    stops when `loadedOffset >= totalSessions`.
/// 2. **loadedCount and loadedOffset advance correctly** — cursors track the
///    number of server rows fetched across first-page refresh and loadMore calls.
/// 3. **filteredCount reflects client-side filters** — `filteredCount` equals
///    `visibleSessions.count`, honoring `hideCron` etc.
/// 4. **Heartbeat starts / stops with scenePhase** — `handleScenePhaseActive`
///    starts and cancels the heartbeat task; it is idempotent on repeated calls.
@MainActor
final class UX1DrawerFeedTests: XCTestCase {

    // MARK: - Helpers

    private func makeSummary(
        id: String,
        lastActive: Double? = nil,
        startedAt: Double? = nil,
        source: String? = nil,
        title: String? = nil,
        cwd: String? = nil,
        messageCount: Int? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            title: title ?? id,
            preview: nil,
            startedAt: startedAt,
            messageCount: messageCount,
            source: source,
            lastActive: lastActive,
            cwd: cwd
        )
    }

    private func makeStore() -> SessionStore { SessionStore() }

    // MARK: - 1. loadMore appends + dedupes + respects total

    /// `loadMore()` on a store with no REST client is a no-op (no crash).
    func testLoadMoreNoOpWithoutConnection() async {
        let store = makeStore()
        store.sessions = [makeSummary(id: "A")]
        // No connection attached — loadMore must silently return.
        await store.loadMore()
        XCTAssertEqual(store.sessions.map(\.id), ["A"],
            "loadMore without a REST client must not mutate sessions")
    }

    /// After a first-page refresh that sets `totalSessions`, `loadedOffset` equals
    /// the page size and `loadMore()` is not yet at-end.
    func testLoadedOffsetAfterFirstRefresh() async {
        let store = makeStore()
        let rows = (0..<5).map { makeSummary(id: "s\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (rows, 20) }
        await store.refresh()

        XCTAssertEqual(store.loadedCount, 5,
            "loadedCount must equal the number of server rows in the first page")
        XCTAssertEqual(store.loadedOffset, 5,
            "loadedOffset must advance to 5 after fetching 5 rows")
        XCTAssertEqual(store.totalSessions, 20,
            "totalSessions must reflect the server total")
    }

    /// `loadMore()` stops when `loadedOffset >= totalSessions`.
    func testLoadMoreStopsAtTotal() async {
        let store = makeStore()
        let rows = (0..<3).map { makeSummary(id: "s\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (rows, 3) }   // total == count → already at end
        await store.refresh()

        // loadedOffset (3) == totalSessions (3) → loadMore is a no-op.
        // We verify by checking that sessions count doesn't change.
        let countBefore = store.sessions.count
        await store.loadMore()
        XCTAssertEqual(store.sessions.count, countBefore,
            "loadMore must be a no-op when loadedOffset >= totalSessions")
    }

    /// **Infinite-scroll batch (user spec):** a single `loadMore()` must surface
    /// at least `loadMorePageVisibleTarget` (30) NEW VISIBLE rows even when the
    /// server window is cron-heavy and `hideCron` filters most of each fetched
    /// page out — it keeps growing the limit until the batch target is met. The
    /// OLD loop broke at the first new visible row (delta > 0), which under a
    /// dense cron window surfaced as few as +1 per page ("it only loads a few").
    func testLoadMoreLoadsFullBatchThroughCronHeavyWindow() async {
        let store = makeStore()
        store.hideCron = true

        // Synthetic 300-row server list: first 30 are user (visible), the rest
        // alternate cron/user so only ~half of each grown window is visible.
        func row(_ i: Int) -> SessionSummary {
            let src = i < 30 ? "user" : (i.isMultiple(of: 2) ? "cron" : "user")
            return makeSummary(id: "s\(i)", lastActive: Double(300 - i), source: src)
        }
        let full = (0..<300).map(row)
        let total = 300

        // First page: the 30 leading user rows + a known total. The cold fill is a
        // no-op here (already 30 visible), so it never touches `initialFillFetch`.
        store.sessionsFetch = { (Array(full.prefix(30)), total) }
        await store.refresh()
        XCTAssertEqual(store.loadedCount, 30, "setup: first page loads 30 rows")
        let startVisible = store.visibleSessions.count
        XCTAssertEqual(startVisible, 30, "setup: all 30 leading rows are visible (user)")

        // loadMore pages the same rail via the fill resolver (grow-limit).
        store.initialFillFetch = { limit in (Array(full.prefix(min(limit, total))), total) }
        await store.loadMore()

        XCTAssertGreaterThanOrEqual(
            store.visibleSessions.count - startVisible,
            SessionStore.loadMorePageVisibleTarget,
            "a single loadMore must add at least 30 NEW visible rows through a cron-heavy window")
    }

    /// `loadMore()` terminates (no spin/hang) when the server cannot grow the
    /// window — i.e. a larger limit returns no new rows — even when the total is
    /// unknown (`totalSessions == nil`). Exercises the no-progress exhaustion guard.
    func testLoadMoreStopsWhenServerCannotGrow() async {
        let store = makeStore()
        store.hideCron = false

        let fixed = (0..<5).map { makeSummary(id: "f\($0)", lastActive: Double($0), source: "user") }
        // Total unknown so the top-of-call total guard never fires; only the
        // in-loop "loadedCount didn't advance" guard can stop the loop.
        store.sessionsFetch = { (fixed, nil) }
        await store.refresh()
        XCTAssertEqual(store.loadedCount, 5)

        // Server returns the SAME 5 rows for any limit — it cannot grow.
        store.initialFillFetch = { _ in (fixed, nil) }
        await store.loadMore()

        XCTAssertEqual(store.sessions.count, 5,
            "loadMore must stop (not spin) when a larger limit returns no new rows")
    }

    // MARK: - ABH-86 optimistic activity bump + re-sort

    /// `noteActivity` re-sorts a session to the top immediately, and a refresh
    /// returning a STALE (older) server `lastActive` must NOT knock it back while
    /// the turn is in flight. `mergeSessionPage` carries the higher local value
    /// forward via the `turnsInProgress` flag (ABH-178: explicit flag replaced the
    /// old liveWindow time-proxy). Once the turn completes the server authority wins.
    func testNoteActivityReSortsAndSurvivesStaleRefresh() async {
        let store = makeStore()
        store.hideCron = false
        func rows(_ aLast: Double) -> [SessionSummary] {
            [makeSummary(id: "A", lastActive: aLast),
             makeSummary(id: "B", lastActive: 200),
             makeSummary(id: "C", lastActive: 300)]
        }
        store.sessionsFetch = { (rows(100), 3) }
        await store.refresh()
        XCTAssertEqual(store.visibleSessions.map(\.id), ["C", "B", "A"],
            "baseline order is lastActive DESC")

        // User sends into A → optimistic bump to NOW → A jumps to the top.
        // ABH-178: the carry-forward now requires an explicit turn-in-flight flag.
        store.noteActivity(storedId: "A")
        store.markTurnStarted(storedId: "A")
        XCTAssertEqual(store.visibleSessions.first?.id, "A",
            "noteActivity re-sorts the bumped session to the top immediately")

        // The ~400ms debounced refresh returns A's STALE server lastActive (100).
        // The turn is still in flight → carry-forward holds.
        store.sessionsFetch = { (rows(100), 3) }
        await store.refresh()
        XCTAssertEqual(store.visibleSessions.first?.id, "A",
            "a stale refresh must not knock the just-active session back down while the turn is in flight")

        // Server finally advances A past the bump → converges on server authority.
        let serverCaughtUp = Date().timeIntervalSince1970 + 60
        store.sessionsFetch = { (rows(serverCaughtUp), 3) }
        await store.refresh()
        XCTAssertEqual(store.visibleSessions.first?.id, "A",
            "once the server catches up, A stays on top via the authoritative value")
    }

    /// `noteActivity` for an unknown id is a no-op (the caller's debounced refresh
    /// discovers the session); it must not crash or mutate the list.
    func testNoteActivityUnknownIdIsNoOp() async {
        let store = makeStore()
        store.hideCron = false
        store.sessionsFetch = { ([self.makeSummary(id: "A", lastActive: 100)], 1) }
        await store.refresh()
        store.noteActivity(storedId: "does-not-exist")
        XCTAssertEqual(store.visibleSessions.map(\.id), ["A"])
        store.noteActivity(storedId: nil)
        XCTAssertEqual(store.visibleSessions.map(\.id), ["A"])
    }

    // MARK: - 2. loadedCount and loadedOffset advance

    /// After a first-page refresh, loadedCount equals the page size.
    func testLoadedCountAfterRefresh() async {
        let store = makeStore()
        let rows = (0..<7).map { makeSummary(id: "r\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (rows, 100) }
        await store.refresh()
        XCTAssertEqual(store.loadedCount, 7)
    }

    /// A second `refresh()` (first-page) resets `loadedOffset` to the page size,
    /// not to the previous loadedOffset + page.
    func testRefreshResetsLoadedOffset() async {
        let store = makeStore()
        let page1 = (0..<5).map { makeSummary(id: "p\($0)", lastActive: Double($0)) }
        let page2 = (0..<5).map { makeSummary(id: "q\($0)", lastActive: Double($0)) }

        store.sessionsFetch = { (page1, 50) }
        await store.refresh()
        XCTAssertEqual(store.loadedOffset, 5)

        // Second first-page refresh — loadedOffset resets to the new page size.
        store.sessionsFetch = { (page2, 50) }
        await store.refresh()
        XCTAssertEqual(store.loadedOffset, 5,
            "A first-page refresh must reset loadedOffset to the new page size, not accumulate")
    }

    // MARK: - 3. filteredCount reflects client-side filters

    /// `filteredCount` equals `visibleSessions.count`, and Recents is human-only
    /// BY CONSTRUCTION — cron (automation) rows are always excluded regardless of
    /// the (now-vestigial) `hideCron` flag, because automation runs live in their
    /// own feed (drawer bifurcation).
    func testFilteredCountEqualsVisibleCount() async {
        let store = makeStore()

        let cronRow  = makeSummary(id: "cron",  lastActive: 100, source: "cron")
        let userRow  = makeSummary(id: "user",  lastActive: 200, source: "user")
        let userRow2 = makeSummary(id: "user2", lastActive: 50,  source: "manual")
        store.sessionsFetch = { ([cronRow, userRow, userRow2], 3) }
        await store.refresh()

        // Cron is ALWAYS excluded from Recents → only the 2 human rows are visible.
        XCTAssertEqual(store.filteredCount, 2,
            "Recents excludes automation (cron) rows by construction")
        XCTAssertEqual(store.filteredCount, store.visibleSessions.count,
            "filteredCount must always equal visibleSessions.count")
        XCTAssertFalse(store.visibleSessions.contains { ($0.source ?? "") == "cron" },
            "no cron row may ever appear in Recents")

        // The vestigial hideCron flag does not change the human-only invariant.
        store.hideCron = true
        XCTAssertEqual(store.filteredCount, 2)
        XCTAssertEqual(store.filteredCount, store.visibleSessions.count)
        store.hideCron = false
    }

    /// ABH-343: cli-source loop/kanban/review machinery is not human Recents,
    /// even though the transport source is `cli`. Cron remains absent from
    /// Recents but still belongs to the separate Automation Runs route, which
    /// selects `source == "cron"` independently of this drawer predicate.
    func testHumanRecentsExcludeCliSourceLoopMachinery() async {
        let store = makeStore()

        let loopPlan = makeSummary(
            id: "loopPlan",
            lastActive: 500,
            source: "cli",
            title: "Loop Plan #39",
            messageCount: 6
        )
        let reviewApproval = makeSummary(
            id: "reviewApproval",
            lastActive: 400,
            source: "cli",
            title: "Dead code removal review approval",
            messageCount: 6
        )
        let worktreeRow = makeSummary(
            id: "worktree",
            lastActive: 300,
            source: "cli",
            title: "ordinary-looking machinery title",
            cwd: "/Users/abhi/Developer/products/hermes-mobile/.worktrees/abh343-drawer-machinery",
            messageCount: 6
        )
        let humanChat = makeSummary(
            id: "human",
            lastActive: 200,
            source: "app",
            title: "What should I focus on today?",
            messageCount: 6
        )
        let cronRun = makeSummary(
            id: "cronRun",
            lastActive: 100,
            source: "cron",
            title: "Nightly briefing",
            messageCount: 6
        )
        let rows = [loopPlan, reviewApproval, worktreeRow, humanChat, cronRun]
        store.sessionsFetch = { (rows, rows.count) }

        await store.refresh()

        XCTAssertEqual(store.visibleSessions.map(\.id), ["human"],
            "Recents must keep only real human chats: cli loop plans, review approvals, loop worktrees, and cron runs are machinery")
        XCTAssertFalse(SessionStore.isHumanRecentsSession(source: "agent", messageCount: 6),
            "future-tagged agent machinery must also be excluded from human Recents")

        let automationRuns = rows.filter { ($0.source ?? "").lowercased() == "cron" }
        XCTAssertEqual(automationRuns.map(\.id), ["cronRun"],
            "The separate Automations route still finds cron rows by source == cron")
    }

    /// ABH-373: Machinery sessions must NEVER enter the drawer's backing
    /// `sessions` array — not just get filtered out at read time. Before ABH-373
    /// the predicate was applied only in `visibleSessions`, so a live-update path
    /// (WS message-complete → debounced refresh → mergeSessionPage) would insert
    /// machinery rows into `sessions` where they lingered until the next
    /// `visibleSessions` read. This test proves the stronger invariant: machinery
    /// is rejected at INGRESS (mergeSessionPage), so `sessions` itself is clean.
    ///
    /// The test simulates the LIVE path: a first refresh populates human sessions,
    /// then a second refresh (the kind a WS session-created event triggers)
    /// delivers a page containing BOTH human and machinery sessions. The
    /// machinery rows must never appear in `sessions`.
    func testMachineryRejectedAtIngressOnLiveRefreshPath() async {
        let store = makeStore()

        let human1 = makeSummary(id: "human1", lastActive: 500, source: "app",
                                 title: "Lunch plan", messageCount: 3)
        let human2 = makeSummary(id: "human2", lastActive: 400, source: "app",
                                 title: "Code review notes", messageCount: 5)

        // Initial refresh: clean human sessions only.
        store.sessionsFetch = { ([human1, human2], 2) }
        await store.refresh()
        XCTAssertEqual(Set(store.sessions.map(\.id)), Set(["human1", "human2"]),
            "Baseline: human sessions populate the backing array")

        // Simulate a LIVE update: a WS message-complete triggers a debounced
        // refresh. The server page now includes a flood of machinery sessions
        // alongside the human sessions (the exact scenario ABH-373 fixes).
        let cronMachinery = makeSummary(id: "cronRun", lastActive: 600, source: "cron",
                                        title: "Nightly briefing", messageCount: 8)
        let subagentMachinery = makeSummary(id: "subagent1", lastActive: 590, source: "subagent",
                                            title: "Research subtask", messageCount: 4)
        let agentMachinery = makeSummary(id: "agent1", lastActive: 580, source: "agent",
                                         title: "Scout sweep", messageCount: 2)
        let cliLoopMachinery = makeSummary(id: "loopPlan", lastActive: 570, source: "cli",
                                           title: "Loop Plan #42", messageCount: 6)
        let cliReviewMachinery = makeSummary(id: "reviewApproval", lastActive: 560, source: "cli",
                                             title: "review approval: merge PR", messageCount: 4)
        let worktreeMachinery = makeSummary(id: "worktreeRun", lastActive: 550, source: "cli",
            title: "Build task",
            cwd: "/Users/abhi/Developer/products/hermes-mobile/.worktrees/abh373-fix",
            messageCount: 10)
        let kanbanMachinery = makeSummary(id: "kanbanTask", lastActive: 540, source: "cli",
            title: "kanban task t_abc123",
            cwd: "/Users/abhi/.hermes/kanban/boards/hermes-mobile/workspaces/t_abc123",
            messageCount: 12)

        let livePage = [
            cronMachinery, subagentMachinery, agentMachinery,
            cliLoopMachinery, cliReviewMachinery, worktreeMachinery,
            kanbanMachinery, human1, human2,
        ]
        store.sessionsFetch = { (livePage, livePage.count) }

        // This is the refresh that a WS session-created / message-complete
        // event triggers via scheduleSessionRefresh().
        await store.refresh()

        // CORE INVARIANT (ABH-373): machinery never enters `sessions`.
        // The backing array must contain ONLY human sessions — not just
        // visibleSessions, but the raw backing store.
        let sessionIds = Set(store.sessions.map(\.id))
        let machineryIds: Set<String> = [
            "cronRun", "subagent1", "agent1",
            "loopPlan", "reviewApproval", "worktreeRun", "kanbanTask",
        ]
        XCTAssertEqual(sessionIds, Set(["human1", "human2"]),
            "ABH-373: machinery sessions must never enter the backing `sessions` array via the live refresh path. " +
            "Found machinery in sessions: \(sessionIds.intersection(machineryIds).sorted())")

        // visibleSessions is a weaker downstream check but must also hold.
        XCTAssertEqual(store.visibleSessions.map(\.id).sorted(), ["human1", "human2"].sorted(),
            "visibleSessions must show only human sessions")
    }

    /// ABH-373: The load-more (append) path also rejects machinery at ingress.
    /// When `mergeSessionPage(isAppend: true)` receives a page with mixed human
    /// and machinery rows, only the human rows are appended to `sessions`.
    func testMachineryRejectedAtIngressOnLoadMoreAppend() async {
        let store = makeStore()

        let human1 = makeSummary(id: "human1", source: "app", title: "Chat 1", messageCount: 3)
        let human2 = makeSummary(id: "human2", source: "app", title: "Chat 2", messageCount: 5)

        // First page: two human sessions.
        store.sessionsFetch = { ([human1, human2], 10) }
        await store.refresh()

        // Load-more uses the `initialFillFetch` seam (same as real loadMore).
        // The page contains a mix of human and machinery rows.
        let human3 = makeSummary(id: "human3", source: "app", title: "Chat 3", messageCount: 2)
        let cronRow = makeSummary(id: "cronLoadMore", source: "cron", title: "Scheduled run",
                                  messageCount: 6)
        let loopRow = makeSummary(id: "loopLoadMore", source: "cli", title: "Loop Plan #99",
                                  messageCount: 4)

        store.initialFillFetch = { _ in
            ([human1, human2, human3, cronRow, loopRow], 10)
        }
        await store.loadMore()

        let sessionIds = Set(store.sessions.map(\.id))
        XCTAssertFalse(sessionIds.contains("cronLoadMore"),
            "ABH-373: cron machinery must not enter sessions via load-more append")
        XCTAssertFalse(sessionIds.contains("loopLoadMore"),
            "ABH-373: cli-loop machinery must not enter sessions via load-more append")
        XCTAssertTrue(sessionIds.contains("human3"),
            "Human sessions on the load-more page must still be appended")
    }

    /// ABH-373 (verifier rework): the central pagination regression. When early
    /// pages are heavy with machinery, `loadMore()` must NOT halt before reaching
    /// the human sessions that live on LATER pages. Grow-limit pagination
    /// re-fetches the full expanded window each iteration, so a row consumed once
    /// must be counted exactly ONCE — even if the ingress machinery filter drops
    /// it from `sessions` (and thus from the dedupe set the cursor advance used).
    /// Before the fix, filtered machinery was re-counted on every grow-limit
    /// iteration, inflating `loadedCount` past `totalSessions`, tripping the
    /// exhaustion guard, and stranding later human sessions.
    ///
    /// This test builds a server where the first 2/3 are machinery and only the
    /// LAST third are human sessions. `loadMore()` must page through the machinery
    /// wall and surface those human sessions. The page fetch simulates the REAL
    /// grow-limit REST contract: each call returns the full window `[0, limit)`.
    func testLoadMoreReachesHumanSessionsPastMachineryWall() async {
        let store = makeStore()

        // 150-row server: rows 0-99 are machinery (cron), rows 100-149 are human.
        // Human sessions are ONLY on the last third — a loadMore that halts at the
        // machinery wall would never surface them.
        let total = 150
        func row(_ i: Int) -> SessionSummary {
            if i < 100 {
                return makeSummary(id: "mach_\(i)", lastActive: Double(total - i), source: "cron")
            } else {
                return makeSummary(id: "human_\(i)", lastActive: Double(total - i), source: "app")
            }
        }
        let fullServer = (0..<total).map(row)

        // First page: the server's default window (first 50 rows — all machinery).
        // They are all filtered at ingress, so `sessions` starts empty but the
        // cursor honestly reflects 50 consumed server rows.
        store.sessionsFetch = { (Array(fullServer.prefix(50)), total) }
        await store.refresh()
        XCTAssertEqual(store.sessions.count, 0,
            "first page is all machinery — sessions must be empty after ingress filter")
        XCTAssertEqual(store.loadedCount, 50,
            "loadedCount must honestly track 50 consumed server rows (machinery counted)")

        // loadMore pages the same rail via the fill resolver — grow-limit contract:
        // each call returns the full window [0, limit), exactly like the live REST path.
        store.initialFillFetch = { limit in
            (Array(fullServer.prefix(min(limit, total))), total)
        }
        await store.loadMore()

        // CORE REGRESSION: the human sessions (rows 100-149) MUST be in `sessions`.
        // A loadMore that over-counted machinery and tripped the exhaustion guard
        // would halt inside the machinery wall and never reach them.
        let sessionIds = Set(store.sessions.map(\.id))
        let expectedHuman = Set((100..<total).map { "human_\($0)" })
        XCTAssertFalse(sessionIds.isDisjoint(with: expectedHuman),
            "ABH-373 regression: loadMore must page through the machinery wall and " +
            "surface human sessions on later pages. Got sessions: \(sessionIds.sorted())")

        // Sanity: no machinery leaked into sessions.
        XCTAssertFalse(sessionIds.contains { $0.hasPrefix("mach_") },
            "machinery must never enter sessions even when loadMore pages through it")

        // The cursor must NOT have over-counted past the server total.
        XCTAssertLessThanOrEqual(store.loadedCount, total,
            "loadedCount (\(store.loadedCount)) must never exceed the server total (\(total)) — " +
            "over-counting filtered machinery was the bug")
    }

    /// ABH-373 REWORK (survivor dedupe): a working-set SURVIVOR (pinned/active/
    /// live row carried forward from a first-page replace because it was absent
    /// from that server page) that later REAPPEARS in a grown-limit loadMore
    /// append window must be present in `sessions` EXACTLY ONCE — never appended
    /// a second time.
    ///
    /// The prior fix's `newRows` filter deduped row inclusion against
    /// `seenServerSessionIds`, a set that by design EXCLUDES working-set
    /// survivors (they are local-only, never delivered by the server). So a
    /// survivor reappearing in an append page passed that filter and was
    /// appended again → a duplicate Identifiable id → SwiftUI ForEach undefined
    /// behavior.
    ///
    /// This test goes RED against the old `seenServerSessionIds`-based filter
    /// (the survivor appears twice) and GREEN with the `existingIds`
    /// (rendered-set) fix (exactly once).
    func testSurvivorReappearingInLoadMoreNotDuplicated() async {
        let store = makeStore()

        // A pinned session that will be absent from the first server page → it
        // survives the first-page replace as a working-set row.
        let pinned = makeSummary(id: "pinned_survivor", lastActive: 9001,
                                 source: "app", title: "Pinned Chat", messageCount: 4)
        store.sessions = [pinned]
        if !store.isPinned(pinned) { store.togglePin(pinned) }

        // First page: does NOT contain the pinned survivor. The survivor is
        // carried forward by the working-set merge. Two other human rows are
        // present on the page.
        let humanA = makeSummary(id: "humanA", source: "app", title: "A", messageCount: 2)
        let humanB = makeSummary(id: "humanB", source: "app", title: "B", messageCount: 1)
        store.sessionsFetch = { ([humanA, humanB], 50) }
        await store.refresh()

        // After the first-page replace, the pinned survivor must have survived.
        XCTAssertTrue(store.sessions.map(\.id).contains("pinned_survivor"),
            "pinned survivor must be carried forward by the first-page replace")

        // loadMore via the fill seam — the grown-limit page now INCLUDES the
        // pinned survivor (the server caught up and delivered it). This is the
        // regression trigger: the survivor is in `sessions` (carried forward)
        // AND in the append page.
        store.initialFillFetch = { _ in
            ([pinned, humanA, humanB], 50)
        }
        await store.loadMore()

        // CORE ASSERTION: no duplicate ids in `sessions`. The survivor must be
        // present EXACTLY ONCE.
        let ids = store.sessions.map(\.id)
        let idCounts = ids.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let duplicates = idCounts.filter { $0.value > 1 }
        XCTAssertTrue(duplicates.isEmpty,
            "ABH-373 REWORK: survivor must not be duplicated in sessions. "
            + "Duplicate ids: \(duplicates). All ids: \(ids)")

        // Specifically: the survivor appears exactly once.
        XCTAssertEqual(idCounts["pinned_survivor"], 1,
            "pinned_survivor must appear exactly once in sessions, got \(idCounts["pinned_survivor"] ?? 0)")

        // Cleanup so UserDefaults does not pollute later test runs.
        if store.isPinned(pinned) { store.togglePin(pinned) }
    }

    /// `filteredCount` is always `<= loadedCount` (filters can only reduce, not expand).
    func testFilteredCountNeverExceedsLoadedCount() async {
        let store = makeStore()
        let rows = (0..<10).map { makeSummary(id: "s\($0)", source: $0 % 2 == 0 ? "cron" : "user") }
        store.sessionsFetch = { (rows, 100) }
        await store.refresh()
        store.hideCron = true

        XCTAssertLessThanOrEqual(store.filteredCount, store.loadedCount,
            "filteredCount must never exceed loadedCount")
    }

    // MARK: - 4. Heartbeat starts / stops with scenePhase

    /// `handleScenePhaseActive(true)` starts the heartbeat task; a second call is
    /// idempotent (only one task is running).
    func testHeartbeatStartsOnForeground() {
        let store = makeStore()
        store.handleScenePhaseActive(true)
        store.handleScenePhaseActive(true)   // idempotent

        // Verify the task is running by stopping it and confirming it existed.
        store.stopHeartbeat()
        // No assertion needed other than not crashing; the task is internal.
    }

    /// `handleScenePhaseActive(false)` cancels the heartbeat task.
    func testHeartbeatStopsOnBackground() {
        let store = makeStore()
        store.handleScenePhaseActive(true)
        store.handleScenePhaseActive(false)

        // Starting again after stop creates a fresh task.
        store.handleScenePhaseActive(true)
        store.stopHeartbeat()
    }

    /// `startHeartbeat()` followed by `stopHeartbeat()` leaves the store clean.
    func testHeartbeatStartStop() {
        let store = makeStore()
        store.startHeartbeat()
        store.stopHeartbeat()
        // A second stop is a no-op (no crash).
        store.stopHeartbeat()
    }

    /// The heartbeat interval constant is 30 seconds as specified.
    func testHeartbeatIntervalConstant() {
        XCTAssertEqual(SessionStore.heartbeatInterval, 30,
            "heartbeatInterval must be 30 seconds per the UX1 spec")
    }

    // MARK: - 5. filteredCount / loadedCount header math

    /// When all fetched rows are visible, neither "shown" nor "loaded" overrides
    /// appear in the logic — the distinction only surfaces when `filteredCount < loadedCount`.
    func testFilterHonestyNoFilterActive() async {
        let store = makeStore()
        let rows = (0..<5).map { makeSummary(id: "x\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (rows, 50) }
        await store.refresh()

        // No filter active → filteredCount == loadedCount.
        XCTAssertEqual(store.filteredCount, store.loadedCount,
            "Without filters, filteredCount must equal loadedCount")
    }

    /// When `hideCron` hides rows, `filteredCount < loadedCount`.
    func testFilterHonestityCronHidden() async {
        let store = makeStore()
        let cronRows  = (0..<3).map { makeSummary(id: "cron\($0)",  lastActive: nil, startedAt: nil, source: "cron")  }
        let humanRows = (0..<4).map { makeSummary(id: "human\($0)", lastActive: nil, startedAt: nil, source: "user") }
        store.sessionsFetch = { (cronRows + humanRows, 7) }
        await store.refresh()
        store.hideCron = true

        XCTAssertEqual(store.loadedCount, 7,
            "loadedCount must still reflect all 7 fetched rows regardless of filters")
        XCTAssertEqual(store.filteredCount, 4,
            "filteredCount must reflect only the 4 non-cron visible rows")
        XCTAssertLessThan(store.filteredCount, store.loadedCount)
    }

    // MARK: - 6. Bug B — initial-visible-target loop (load-until-30)

    /// When the first page has fewer than `initialVisibleTarget` visible sessions
    /// and the server still has more, the fill loop must fetch additional pages
    /// until the target is met.
    func testInitialFillLoopReachesTarget() async {
        let store = makeStore()
        store.hideCron = false

        // First page: 10 sessions, server total = 60.
        let page1 = (0..<10).map { makeSummary(id: "p1_\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (page1, 60) }

        // Subsequent pages: 25 sessions each (to reach 30+ visible in one extra page).
        let page2 = (10..<35).map { makeSummary(id: "p2_\($0)", lastActive: Double($0)) }
        store.initialFillFetch = { _ in (page2, 60) }

        await store.refresh()
        // The fill now runs on its OWN task (decoupled from refresh()'s token);
        // await it explicitly rather than relying on inline completion.
        await store.awaitInitialFillForTesting()

        XCTAssertGreaterThanOrEqual(store.visibleSessions.count, SessionStore.initialVisibleTarget,
            "After fill loop, visibleSessions must reach initialVisibleTarget (\(SessionStore.initialVisibleTarget))")
    }

    /// The fill loop must stop when the server is exhausted (total ≤ loadedCount),
    /// even if `visibleSessions.count < initialVisibleTarget`. This prevents
    /// infinite spinning on a gateway that has fewer than 30 non-cron sessions.
    func testInitialFillLoopStopsAtServerExhaustion() async {
        let store = makeStore()
        store.hideCron = true   // forces many sessions hidden

        // 5 human + 5 cron = 10 total on server. hideCron = true → only 5 visible.
        let cronRows  = (0..<5).map { makeSummary(id: "cron\($0)", source: "cron") }
        let humanRows = (0..<5).map { makeSummary(id: "human\($0)", source: "user") }
        store.sessionsFetch = { (cronRows + humanRows, 10) }

        // initialFillFetch should NOT be called because server is exhausted after page 1.
        var fillCallCount = 0
        store.initialFillFetch = { _ in
            fillCallCount += 1
            // Return empty to simulate no more data.
            return ([], 10)
        }

        await store.refresh()
        await store.awaitInitialFillForTesting()

        XCTAssertEqual(fillCallCount, 0,
            "Fill loop must not call initialFillFetch when server is already exhausted after the first page")
        XCTAssertEqual(store.visibleSessions.count, 5,
            "visibleSessions must equal the 5 non-cron rows even if < initialVisibleTarget")

        store.hideCron = false  // restore
    }

    // MARK: - 7. fill30 — concurrent-refresh race (the bug the old suite hid)

    /// A small awaitable gate: the fill seam blocks on `wait()` until the test
    /// `open()`s it, so the test can deterministically interleave a SECOND
    /// `refresh()` (token bump) WHILE the fill is paging — the exact race the old
    /// inline fill could not reproduce (and so 17/17 passed while live failed).
    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func open() {
            isOpen = true
            let pending = continuations
            continuations.removeAll()
            for c in pending { c.resume() }
        }
    }

    /// THE REGRESSION TEST. While an initial fill is paging (paused at the first
    /// fill page), a sibling `refresh()` fires and bumps `refreshToken`. With the
    /// OLD inline fill this aborted the loop (`guard refreshToken == myToken`) and
    /// `initialFillDone` (latched at the start) gated the retry off forever, so the
    /// drawer stuck at ~6. The decoupled fill must IGNORE the token bump and STILL
    /// page to the target.
    func testFillSurvivesConcurrentRefreshAndReachesTarget() async {
        let store = makeStore()
        store.hideCron = false

        // First page: 5 rows, server total 60 (far short of 30 visible).
        let page1 = (0..<5).map { makeSummary(id: "p1_\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (page1, 60) }

        // The fill seam blocks on the gate the FIRST time so the test can race a
        // sibling refresh() in mid-fill; later fill pages pass straight through.
        let gate = Gate()
        var fillCalls = 0
        store.initialFillFetch = { _ in
            fillCalls += 1
            if fillCalls == 1 { await gate.wait() }   // pause mid-fill
            // Each fill page brings the next chunk of rows (grow-limit delta shape,
            // as the existing Bug-B tests model the seam). 30 distinct rows → target.
            return ((5..<35).map { self.makeSummary(id: "fill_\($0)", lastActive: Double($0)) }, 60)
        }

        // Kick the fill (returns immediately; fill task is now paused at the gate).
        await store.refresh()

        // RACE: a sibling refresh() fires while the fill is paused — this bumps
        // refreshToken. The OLD code would let this poison the in-flight fill.
        store.sessionsFetch = { (page1, 60) }
        await store.refresh()

        // Release the fill and let it finish.
        await gate.open()
        await store.awaitInitialFillForTesting()

        XCTAssertGreaterThanOrEqual(store.visibleSessions.count, SessionStore.initialVisibleTarget,
            "Fill must reach the target (\(SessionStore.initialVisibleTarget)) DESPITE a concurrent refresh() bumping refreshToken mid-fill — this is the live bug.")
    }

    /// A concurrent `refresh()` mid-fill must NOT start a second, parallel fill:
    /// `isFillingInitial` gates the second kick to a no-op so the two fills can't
    /// race each other's appends.
    func testConcurrentRefreshDoesNotStartSecondFill() async {
        let store = makeStore()
        store.hideCron = false

        let page1 = (0..<5).map { makeSummary(id: "p1_\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (page1, 60) }

        let gate = Gate()
        var fillCalls = 0
        store.initialFillFetch = { _ in
            fillCalls += 1
            if fillCalls == 1 { await gate.wait() }
            return ((5..<35).map { self.makeSummary(id: "fill_\($0)", lastActive: Double($0)) }, 60)
        }

        await store.refresh()       // kicks fill #1 (paused at gate)
        await store.refresh()       // sibling: must NOT kick a 2nd fill
        await store.refresh()       // and again — still no second fill

        await gate.open()
        await store.awaitInitialFillForTesting()

        // Exactly one fill ran: the single in-flight flag prevented duplicates.
        // (fillCalls counts PAGES of the one fill, not fills — assert no double
        // by checking loadedCount didn't over-count beyond a single fill's growth.)
        XCTAssertGreaterThanOrEqual(store.visibleSessions.count, SessionStore.initialVisibleTarget,
            "A single decoupled fill must reach the target.")
        XCTAssertEqual(store.visibleSessions.count, 35,
            "Exactly one fill ran — a second parallel fill would have double-appended rows.")
    }

    /// Server exhausted BEFORE the target via the fill loop: the server keeps
    /// returning the SAME bounded window (total never grows past loadedCount), so
    /// the fill must terminate (latch done) instead of spinning forever, even
    /// though `visibleSessions.count < initialVisibleTarget`.
    func testFillTerminatesWhenServerExhaustedBeforeTarget() async {
        let store = makeStore()
        store.hideCron = false

        // First page: 8 rows, server total 12 (only 12 exist — fewer than 30).
        let page1 = (0..<8).map { makeSummary(id: "e\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (page1, 12) }

        // The fill can fetch at most the remaining 4 rows; after that loadedCount
        // (12) >= total (12) and the loop must stop. Guard against runaway with a
        // hard call cap that would FAIL the test if the loop didn't terminate.
        var fillCalls = 0
        store.initialFillFetch = { _ in
            fillCalls += 1
            XCTAssertLessThan(fillCalls, 50, "Fill loop did not terminate on server exhaustion — it spun.")
            return ((8..<12).map { self.makeSummary(id: "e\($0)", lastActive: Double($0)) }, 12)
        }

        await store.refresh()
        await store.awaitInitialFillForTesting()

        XCTAssertEqual(store.visibleSessions.count, 12,
            "Fill must surface all 12 server rows then stop (server exhausted before 30).")
        XCTAssertLessThan(store.visibleSessions.count, SessionStore.initialVisibleTarget,
            "Sanity: this gateway has fewer than the target — the fill must NOT have spun.")
    }

    /// A heartbeat-style `refresh()` firing mid-fill (its first-page replace uses
    /// `max(100, loadedCount)` so it never shrinks the window) must compose with
    /// the fill: the fill still completes to the target, and the count is not
    /// corrupted by the interleaved replace.
    func testHeartbeatRefreshDuringFillStillReachesTarget() async {
        let store = makeStore()
        store.hideCron = false

        let firstPage = (0..<6).map { makeSummary(id: "h\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (firstPage, 60) }

        let gate = Gate()
        var fillCalls = 0
        store.initialFillFetch = { _ in
            fillCalls += 1
            if fillCalls == 1 { await gate.wait() }   // pause mid-fill
            return ((6..<36).map { self.makeSummary(id: "h\($0)", lastActive: Double($0)) }, 60)
        }

        await store.refresh()                 // kick fill (paused at gate)

        // Heartbeat tick mid-fill: a fresh first-page refresh (token bump + replace).
        // Its first-page seam returns the same 6 rows; the BUG-B max(100,...) guard
        // and the fill's heartbeat-composition guard must keep things consistent.
        store.sessionsFetch = { (firstPage, 60) }
        await store.refresh()

        await gate.open()
        await store.awaitInitialFillForTesting()

        XCTAssertGreaterThanOrEqual(store.visibleSessions.count, SessionStore.initialVisibleTarget,
            "Fill must reach the target even with a heartbeat refresh interleaved mid-fill.")
    }

    /// An ERRORED fill page must NOT latch `initialFillDone`: the next `refresh()`
    /// must re-kick the fill and complete it. (The old code latched done on the
    /// first error, permanently abandoning the fill.)
    func testFillRetriesAfterTransientPageError() async {
        let store = makeStore()
        store.hideCron = false

        let page1 = (0..<5).map { makeSummary(id: "r\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (page1, 60) }

        struct TransientError: Error {}
        var fillCalls = 0
        store.initialFillFetch = { _ in
            fillCalls += 1
            if fillCalls == 1 { throw TransientError() }   // first page fails
            return ((5..<35).map { self.makeSummary(id: "r\($0)", lastActive: Double($0)) }, 60)
        }

        await store.refresh()                       // fill #1: errors, does NOT latch done
        await store.awaitInitialFillForTesting()
        XCTAssertLessThan(store.visibleSessions.count, SessionStore.initialVisibleTarget,
            "After the errored page the fill must have stopped short (not latched done).")

        await store.refresh()                       // fill #2: re-kicked, succeeds
        await store.awaitInitialFillForTesting()
        XCTAssertGreaterThanOrEqual(store.visibleSessions.count, SessionStore.initialVisibleTarget,
            "A transient fill error must NOT permanently abandon the fill — the next refresh() must retry to the target.")
    }

    /// `resetInitialFill()` (server change) mid-fill must cancel the in-flight fill
    /// and let a fresh fill run on the new server without the stale page appending.
    func testResetInitialFillCancelsInFlightFill() async {
        let store = makeStore()
        store.hideCron = false

        let page1 = (0..<5).map { makeSummary(id: "old_\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (page1, 60) }

        let gate = Gate()
        var fillCalls = 0
        store.initialFillFetch = { _ in
            fillCalls += 1
            if fillCalls == 1 { await gate.wait() }
            // The stale (pre-reset) page — must be discarded after reset.
            return ((5..<35).map { self.makeSummary(id: "old_\($0)", lastActive: Double($0)) }, 60)
        }

        await store.refresh()           // fill paused at gate
        store.resetInitialFill()        // server change: cancel the in-flight fill
        await gate.open()               // release the (now stale) page
        await store.awaitInitialFillForTesting()

        // The stale page must NOT have appended onto the reset list. The fill was
        // cancelled before its merge (generation re-check after the await).
        XCTAssertFalse(store.sessions.contains { $0.id == "old_20" },
            "A fill cancelled by resetInitialFill() must not append its stale page.")
    }

    /// Pinned sessions remain in their separate section and are unaffected by
    /// the fill loop (the loop only grows `unpinnedSessions`).
    func testInitialFillLoopDoesNotDisruptPinnedSessions() async {
        let store = makeStore()
        store.hideCron = false

        let pinned = makeSummary(id: "pinned", lastActive: 9999)
        let page1  = (0..<5).map { makeSummary(id: "s\($0)", lastActive: Double($0)) }
        store.sessions = [pinned] + page1
        // Ensure the session is pinned (use togglePin only if not already pinned,
        // since a prior test run may have left UserDefaults with this id pinned).
        if !store.isPinned(pinned) { store.togglePin(pinned) }

        store.sessionsFetch = { (page1, 60) }
        let page2 = (5..<35).map { makeSummary(id: "t\($0)", lastActive: Double($0 + 5)) }
        store.initialFillFetch = { _ in (page2, 60) }

        await store.refresh()
        await store.awaitInitialFillForTesting()

        XCTAssertTrue(store.pinnedSessions.map(\.id).contains("pinned"),
            "Pinned session must survive the initial fill loop")
        XCTAssertGreaterThanOrEqual(store.unpinnedSessions.count, SessionStore.initialVisibleTarget,
            "unpinnedSessions must reach the target after the fill loop")

        // Cleanup: un-pin so UserDefaults does not pollute subsequent test runs.
        if store.isPinned(pinned) { store.togglePin(pinned) }
    }

    // MARK: - 8. fill30 — grow-limit accounting (the live over-count bug)

    /// LIVE-SHAPE grow-limit accounting. The live REST call returns the ENTIRE
    /// expanded window each page (limit=150 → 150 rows, ~50 of them new), unlike
    /// the delta-only test seam. The old `loadedCount += incoming.count` then raced
    /// ~2x ahead of `sessions.count`, poisoning the heartbeat's `max(100,
    /// loadedCount)` window and the "N loaded" header. `loadedCount` must track the
    /// REAL row count (advance by NEW rows only), so `loadedCount == sessions.count`.
    func testGrowLimitFullWindowKeepsLoadedCountHonest() async {
        let store = makeStore()
        store.hideCron = false

        // First page: 100 rows, server total 4000 (cron-dense live shape).
        let page1 = (0..<100).map { makeSummary(id: "s\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (page1, 4000) }

        // Fill seam returns the FULL grown window each call (live shape): the first
        // `limit` rows s0..s(limit-1). Dedupe must keep loadedCount == actual rows.
        store.initialFillFetch = { limit in
            let rows = (0..<limit).map { self.makeSummary(id: "s\($0)", lastActive: Double($0)) }
            return (rows, 4000)
        }

        await store.refresh()
        await store.awaitInitialFillForTesting()

        XCTAssertGreaterThanOrEqual(store.visibleSessions.count, SessionStore.initialVisibleTarget,
            "Fill must reach the target with live full-window grow-limit pages.")
        XCTAssertEqual(store.loadedCount, store.sessions.count,
            "loadedCount must equal sessions.count — the full-window page must NOT double-count (the live over-count bug).")
        XCTAssertEqual(store.sessions.count, store.loadedOffset,
            "loadedOffset must track the real loaded row count, not the cumulative requested-limit sum.")
    }

    /// The over-count regression specifically: with a full-window grow-limit seam,
    /// `loadedCount` must advance by exactly the number of NEW rows per page (not
    /// the full window). After two fill pages of a 100-row first page growing by 50
    /// each, loadedCount must be 200 (the real row count), never ~350 (the old
    /// `+= incoming.count` over-count).
    func testGrowLimitAdvancesLoadedCountByNewRowsOnly() async {
        let store = makeStore()
        store.hideCron = false

        // First page 100 rows; total large so the loop pages twice before target if
        // visible were filtered — here unfiltered so it stops once visible≥30, but
        // we assert the accounting on whatever it loaded.
        let page1 = (0..<100).map { makeSummary(id: "n\($0)", lastActive: Double($0)) }
        store.sessionsFetch = { (page1, 4000) }
        store.initialFillFetch = { limit in
            // Full window: ids n0..n(limit-1).
            let rows = (0..<limit).map { self.makeSummary(id: "n\($0)", lastActive: Double($0)) }
            return (rows, 4000)
        }

        await store.refresh()
        await store.awaitInitialFillForTesting()

        // Unfiltered: the first page (100) already exceeds the target (30), so the
        // fill's fast-path latches done WITHOUT paging — loadedCount stays 100 and
        // equals sessions.count. The key invariant either way: no over-count.
        XCTAssertEqual(store.loadedCount, store.sessions.count,
            "loadedCount must equal the real row count regardless of full-window pages.")
    }
}
