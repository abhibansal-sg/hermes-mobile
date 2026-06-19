import Foundation
#if DEBUG
import os
import DebugBridgeCore  // @Snapshotable marker for the gstack debug bridge (UI-G)

/// DEBUG-only logger for SessionStore open→painted latency instrumentation
/// (WhatsApp bar). Absent in Release.
private let sessionLog = Logger(subsystem: "ai.hermes.HermesMobile", category: "SessionStore")
#endif

/// Observable owner of the session list and the active-session pointers.
///
/// Talks to the gateway via `ConnectionStore.client` and seeds the transcript
/// into `ChatStore` whenever a session is opened, created, or resumed. The
/// back-references to the other stores are set once in ``attach(connection:chat:)``
/// and live for the lifetime of the app; the resulting reference cycle is
/// intentional (the store graph is never torn down).
@MainActor
@Observable
final class SessionStore {
    /// Sessions as returned by `session.list`, newest-first as the server orders them.
    var sessions: [SessionSummary] = []

    /// Total session count as reported by the most recent `GET /api/sessions` response.
    /// `nil` until at least one REST fetch returns the wrapper's `total` field. Used by
    /// the drawer's "N of TOTAL" count affordance (ABH-86 item 6).
    private(set) var totalSessions: Int? = nil

    // MARK: - Pagination (UX1)

    /// The offset of the next page to fetch, i.e. the number of rows already loaded
    /// from the server. Reset to 0 on every first-page refresh; advanced by each
    /// successful `loadMore()` call. Thread-safe: always mutated on `@MainActor`.
    private(set) var loadedOffset: Int = 0

    /// Number of rows loaded from the server (first-page + any appended pages).
    /// Equivalent to `sessions.count` *before* working-set survivors are prepended —
    /// but we track it separately so `filteredCount`/`loadedCount` are honest even
    /// when working-set survivors inflate the array. Resets on every first-page fetch.
    private(set) var loadedCount: Int = 0

    /// True while a `loadMore()` page fetch is in flight (distinct from `isLoading`
    /// which gates the first-page spinner). Drives the sentinel loading row.
    private(set) var isLoadingMore: Bool = false

    /// Number of sessions currently visible after all client-side filters
    /// (`hideCron`, profile scope). The drawer uses this together with
    /// `loadedCount` / `totalSessions` to produce the filter-honest header copy.
    var filteredCount: Int { visibleSessions.count }

    // MARK: - Heartbeat timer (UX1)

    /// The foreground heartbeat task that refreshes the first page every 30 s while
    /// `scenePhase == .active`. Cancelled when the scene goes to background or the
    /// store is torn down. Storm-proof: each tick calls `refresh()` which already
    /// bumps `refreshToken`, so a slow prior response is discarded by the stale-token
    /// guard before it can overwrite a newer list.
    private var heartbeatTask: Task<Void, Never>?

    /// Interval between foreground heartbeat ticks (30 s, matching the user spec).
    static let heartbeatInterval: TimeInterval = 30

    /// iOS page size for grow-limit pagination (mirrors desktop's
    /// `SIDEBAR_SESSIONS_PAGE_SIZE = 50` from `store/layout.ts:20`).
    private static let pageSize: Int = 50

    /// Minimum number of non-cron, non-filtered sessions to show after a cold
    /// launch. After the first-page merge, `refresh()` keeps fetching with
    /// growing limits (reusing `loadMore()`-exact semantics) until either this
    /// many visible sessions are present OR the server is exhausted. The loop
    /// respects `hideCron`/profile filters because `visibleSessions` already
    /// applies them, so the target is always "30 the user can actually see".
    static let initialVisibleTarget: Int = 30

    /// Minimum number of NEWLY-VISIBLE sessions a single `loadMore()` should add
    /// before it stops paging. User spec: infinite scroll must auto-load "at least
    /// thirty" sessions as the user nears the bottom — not the one-visible-row
    /// minimum the old loop stopped at. Under a dense cron-heavy server window +
    /// `hideCron`, breaking at the first new visible row surfaced as little as +1
    /// per page and felt like "it only loads a few". The loop now keeps growing the
    /// limit until it has added this many visible rows OR the server is exhausted.
    static let loadMorePageVisibleTarget: Int = 30

    /// Sources excluded from the human-chat Recents list (drawer bifurcation).
    /// Automation RUNS (`source == "cron"`) live in their own Automation-runs feed,
    /// not the chat list — so the server filters them via `exclude_sources` and the
    /// client never fetches OR caches them (no more cron-dense windows / cache
    /// bloat). The automation-runs surface fetches `source: "cron"` separately.
    static let recentsExcludeSources = ["cron"]

    /// Latches `true` ONLY when the initial fill has *successfully completed* —
    /// the target was met OR the server was proven exhausted. An aborted /
    /// cancelled / errored attempt leaves this `false` so the next `refresh()`
    /// re-kicks the fill (the old bug latched this at the START of the loop, so a
    /// fill aborted by a sibling `refresh()`'s token bump was gated off forever).
    /// Reset to `false` on disconnect so the next cold-connect re-runs the fill.
    private var initialFillDone: Bool = false

    /// Single in-flight flag for ``ensureInitialFill()``. Guarantees NO two fills
    /// ever run concurrently: a second kick while one is in flight is a no-op.
    /// Mutated only on `@MainActor`, so no atomics are needed.
    private var isFillingInitial: Bool = false

    /// The dedicated initial-fill task, with its OWN lifecycle independent of the
    /// per-request ``refreshToken``. A sibling `refresh()` (connect / gateway.ready
    /// / drawer-open / heartbeat) bumping `refreshToken` does NOT touch this task —
    /// that decoupling is the whole fix. Cancelled (and the fill un-latched) by
    /// ``resetInitialFill()`` on a server change so a fresh cold-connect re-fills.
    private var initialFillTask: Task<Void, Never>?

    /// Cancellation generation for ``initialFillTask``. Bumped by
    /// ``resetInitialFill()``; the fill loop re-checks it after every `await` and
    /// bails if it no longer matches, so a stale fill from a previous server can
    /// never append onto the new server's freshly-reset list.
    private var fillGeneration: Int = 0

    /// High-water mark of the server-row window the initial fill expanded to
    /// (i.e. the largest `loadedCount` the fill reached). Every FIRST-PAGE refresh
    /// fetches `max(100, loadedFloor, loadedCount)` rows so a heartbeat /
    /// gateway.ready replace AFTER the fill completes never collapses the window
    /// back to ~100 (which dropped the drawer from 39 visible to ~8). Without this
    /// floor the fill is one-shot: a single post-fill replace undoes it, because
    /// `initialFillDone` is latched and the fill won't re-run. Reset to 0 by
    /// ``resetInitialFill()`` on a server change. Mutated only on `@MainActor`.
    private var loadedFloor: Int = 0

    /// Monotonic counter incremented before each `refresh()` call. A response
    /// decoded from an earlier request (identified by a smaller token value) is
    /// discarded so a slow prior response can never overwrite a newer list.
    /// Protected entirely on `@MainActor` — no atomics needed.
    private var refreshToken: Int = 0
    /// Runtime `session_id` for the session bound to the current connection.
    var activeRuntimeId: String?
    /// Persistent `stored_session_id` for the active session (survives reconnects).
    #if DEBUG
    @Snapshotable
    #endif
    var activeStoredId: String?
    /// The summary for the active session, if it's present in the loaded list.
    /// Used by app-side glue (e.g. the Live Activity title); `nil` for a session
    /// not yet in `sessions` (a brand-new create the list hasn't refreshed onto).
    var activeSummary: SessionSummary? {
        guard let id = activeStoredId else { return nil }
        return sessions.first { $0.id == id }
    }
    /// True while a list/open/create RPC is in flight.
    #if DEBUG
    @Snapshotable
    #endif
    var isLoading: Bool = false
    /// Last human-readable error from a session operation, for the UI to surface.
    var lastError: String?

    /// Set when a session mutation (delete/archive/rename) fails, for the drawer
    /// to surface as a transient toast/alert. nil when there is nothing to show.
    ///
    /// This is the dedicated, observed surface for mutation failures (ABH-73):
    /// ``lastError`` is a catch-all that nothing in the drawer watches, so a
    /// failed delete used to vanish silently. The drawer binds a system `.alert`
    /// to this value (`DrawerView`); ``lastError`` is still written too for the
    /// other call sites that read it. `nil` = nothing to show / silent success.
    #if DEBUG
    @Snapshotable
    #endif
    var sessionActionError: SessionActionError?

    /// `true` while the app is sitting on a *draft* chat: a fresh, empty
    /// transcript with no backing session created server-side yet (no
    /// `activeRuntimeId`/`activeStoredId`). The first prompt the user sends
    /// materializes the real session (see ``createDraftSession()`` /
    /// `ChatStore.send`). Lets the app land on a clean chat at launch and on
    /// "New chat" without littering the session list with empty sessions.
    private(set) var isDraft: Bool = false

    // MARK: - Search

    /// Current search query bound to the list's `.searchable`. Empty when not
    /// searching; a value of two-plus characters triggers a debounced fetch.
    var searchQuery: String = ""
    /// Results of the latest `/api/sessions/search`, newest match first as the
    /// server orders them.
    var searchResults: [SessionSearchResult] = []
    /// True while a search request is in flight (after the debounce fires).
    var isSearching: Bool = false
    /// True while a load-more page fetch is in flight.
    var isSearchLoadingMore: Bool = false
    /// `true` when the last fetched page was full (== limit), meaning more
    /// results may exist. `false` once a short page (< limit) is received or
    /// when offset would exceed the server cap (500).
    var searchHasMore: Bool = false
    /// Current page offset for the active query. Reset to 0 on each new query.
    /// `internal` (not `private(set)`) so unit tests can prime state directly.
    var searchOffset: Int = 0
    /// Monotonically-increasing generation counter. Incremented on every new
    /// query so a stale load-more page from a prior query can be discarded.
    /// `internal` for unit-test assertion (SearchPaginationTests).
    var searchGeneration: Int = 0
    /// Page size used for both the initial fetch and load-more pages. The stock
    /// endpoint caps at 100; the plugin does not paginate (offset not forwarded
    /// there), so this only applies to the stock path.
    static let searchPageLimit: Int = 20
    /// Server-enforced offset cap. Requests with offset >= this value return [].
    static let searchOffsetCap: Int = 500
    /// `true` once `searchQuery` is long enough to be an active search — the view
    /// swaps the normal list for `searchResults` while this holds.
    var isSearchActive: Bool { searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 }

    /// Role scope for search. `all` (default), `messages` (user + assistant
    /// prose), or `code` (tool output). Changing it re-runs the current query.
    enum SearchScope: String, CaseIterable, Sendable {
        case all, messages, code
        var label: String {
            switch self {
            case .all: return "All"
            case .messages: return "Messages"
            case .code: return "Code"
            }
        }
    }
    var searchScope: SearchScope = .all

    /// The query text whose first transcript occurrence the next-opened session
    /// should scroll to (search jump-to-match). Consumed + cleared by ChatView
    /// once it has scrolled. `nil` for a normal open.
    var pendingSearchScroll: String?

    // MARK: - Pins / archive / cron filter (persisted)

    /// Pinned `stored_session_id`s; pinned rows float to a section on top.
    private(set) var pinnedIds: Set<String> = []
    /// When `true`, sessions whose `source == "cron"` are hidden from the list.
    var hideCron: Bool {
        didSet {
            guard hideCron != oldValue else { return }
            UserDefaults.standard.set(hideCron, forKey: DefaultsKeys.hideCron)
        }
    }

    /// When `true`, the drawer's Recents list is grouped by workspace (`cwd`)
    /// instead of shown flat (UI Batch H2). Default `false`. The cron filter
    /// (``hideCron``) still applies *inside* groups because grouping reads from
    /// ``unpinnedSessions``, which is already cron-filtered. Persisted.
    var groupByWorkspace: Bool {
        didSet {
            guard groupByWorkspace != oldValue else { return }
            UserDefaults.standard.set(groupByWorkspace, forKey: DefaultsKeys.groupByWorkspace)
        }
    }

    /// Workspace keys whose groups are currently collapsed in the grouped Recents
    /// list. A key's presence means collapsed; absence means expanded. Persisted
    /// across restarts (``DefaultsKeys/collapsedWorkspaces``).
    private(set) var collapsedWorkspaces: Set<String> = []

    /// Toggle the collapsed state of a workspace group and persist it.
    func toggleCollapsed(workspaceKey: String) {
        if collapsedWorkspaces.contains(workspaceKey) {
            collapsedWorkspaces.remove(workspaceKey)
        } else {
            collapsedWorkspaces.insert(workspaceKey)
        }
        persistCollapsedWorkspaces()
    }

    private func persistCollapsedWorkspaces() {
        UserDefaults.standard.set(
            Array(collapsedWorkspaces),
            forKey: DefaultsKeys.collapsedWorkspaces
        )
    }

    /// Workspace keys that are pinned to the top of the grouped Recents list.
    /// Within the pinned tier, recency order is preserved (pinned groups are
    /// sorted the same way as regular groups, just hoisted above them).
    /// Persisted across restarts (``DefaultsKeys/pinnedWorkspaces``).
    private(set) var pinnedWorkspaceKeys: Set<String> = []

    /// Toggle the pinned state of a workspace group and persist it.
    func togglePinnedWorkspace(_ key: String) {
        if pinnedWorkspaceKeys.contains(key) {
            pinnedWorkspaceKeys.remove(key)
        } else {
            pinnedWorkspaceKeys.insert(key)
        }
        persistPinnedWorkspaces()
    }

    private func persistPinnedWorkspaces() {
        UserDefaults.standard.set(
            Array(pinnedWorkspaceKeys),
            forKey: DefaultsKeys.pinnedWorkspaces
        )
    }

    // MARK: - Multi-profile scope (F4b — DORMANT unless capability available)

    /// The active multi-profile SCOPE driving the rail (F4b). The sentinel
    /// ``DefaultsKeys/allProfilesScope`` (`"all"`) or empty = the cross-profile
    /// aggregate view; any other value = that profile's name. Persisted (mirrors
    /// `hideCron`/`groupByWorkspace`). It gates the rail fetch and the
    /// ``visibleSessions`` filter, but ONLY has effect when the server's `profiles`
    /// capability is `.available` AND the switcher is shown (count > 1) — so a
    /// stale value on a stock / pre-multi-profile gateway is inert and the dormant
    /// single-profile path is byte-for-byte unchanged.
    #if DEBUG
    @Snapshotable
    #endif
    var activeProfile: String {
        didSet {
            guard activeProfile != oldValue else { return }
            UserDefaults.standard.set(activeProfile, forKey: DefaultsKeys.activeProfile)
        }
    }

    /// The fetched profile list backing the switcher (F4b). Populated by
    /// ``loadProfiles()`` ONLY when `profiles == .available`; empty otherwise, so
    /// the switcher visibility gate (`profiles == .available && count > 1`) is
    /// never satisfied on a stock gateway. Reset to empty when the capability is
    /// not available (a disconnect / stock reconnect).
    private(set) var profiles: [ProfileSummary] = []

    /// Whether the multi-profile switcher should render: the server supports the
    /// endpoints AND there is more than one profile (the desktop's
    /// `profiles.length > 1` gate). This double gate IS the dormancy guarantee —
    /// a single-profile supporting server still hides the switcher, and a stock
    /// gateway (no route → `.unavailable`) hides it regardless.
    var isMultiProfileAvailable: Bool {
        Self.shouldShowSwitcher(
            capability: connection?.capabilities.profiles ?? .unknown,
            profileCount: profiles.count
        )
    }

    /// Pure switcher-visibility gate (the dormancy guarantee): show the switcher
    /// ONLY when the `profiles` capability is `.available` AND there is more than
    /// one profile (the desktop's `profiles.length > 1`). `.unavailable`/`.unknown`
    /// — or a supporting server with a single profile — hides it. Factored out
    /// (and `internal`) so the gate is unit-testable without a live connection.
    static func shouldShowSwitcher(
        capability: ServerCapabilities.State,
        profileCount: Int
    ) -> Bool {
        capability == .available && profileCount > 1
    }

    /// `true` when the active scope is the cross-profile aggregate ("All
    /// profiles"): the sentinel `"all"` or an empty/blank pref. Drives the rail's
    /// choice between `GET /api/profiles/sessions?profile=all` (aggregate) and the
    /// existing `GET /api/sessions` (single/default).
    var isAllProfilesScope: Bool {
        let trimmed = activeProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == DefaultsKeys.allProfilesScope
    }

    /// The active SPECIFIC profile name when a non-aggregate, non-default scope is
    /// selected — the value threaded onto create/resume/PATCH/DELETE/GET. `nil`
    /// for the aggregate ("all") scope OR the default profile (the default's
    /// sessions live in the shared/launch home, so no `profile` param is needed —
    /// threading it would be a no-op the WS path silently swallows). This is the
    /// single source of "should we attach a `profile` param?" for every call site.
    var activeProfileName: String? {
        let trimmed = activeProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != DefaultsKeys.allProfilesScope,
              trimmed != Self.defaultProfileName else { return nil }
        return trimmed
    }

    /// The reserved name of the default/launch profile (`profiles.py:604-628`).
    static let defaultProfileName = "default"

    /// Whether the rail should fetch the cross-profile aggregate
    /// (`GET /api/profiles/sessions?profile=all`) instead of the existing
    /// `GET /api/sessions`. True only when multi-profile is available AND the scope
    /// is NOT the default profile: both the aggregate ("all") scope and a specific
    /// named scope fetch the aggregate (so rows carry their `profile` tag) and
    /// ``visibleSessions`` filters a named scope client-side. The DEFAULT profile
    /// scope (and every dormant / stock-gateway case) keeps the existing
    /// `GET /api/sessions` path byte-for-byte.
    var usesAggregateRail: Bool {
        guard isMultiProfileAvailable else { return false }
        let trimmed = activeProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != Self.defaultProfileName
    }

    // MARK: - Live-activity registry

    /// Most-recent broadcast-activity timestamp per *stored* session id, stamped
    /// by ``noteActivity(storedSessionId:)`` from `ConnectionStore`'s event router
    /// on streaming frames. The drawer reads it via ``isLive(_:)`` to show a
    /// pulsing dot next to a row whose conversation moved in the last few
    /// seconds (driven by this device or another client over the broadcast).
    private(set) var lastActivityAt: [String: Date] = [:]
    /// FIX 6a — un-observed shadow of the most-recent stamp time per id, used purely
    /// to COALESCE the per-delta `lastActivityAt` write (skip a re-stamp within
    /// ``liveStampCoalesce``). `@ObservationIgnored` so consulting/updating it never
    /// invalidates the always-mounted drawer; the observed `lastActivityAt` is the
    /// drawer's actual live-dot source and is written at most once per coalesce window.
    @ObservationIgnored private var lastActivityStampAt: [String: Date] = [:]
    /// Minimum gap between observed `lastActivityAt` writes for one id. Far below the
    /// ``liveWindow`` so the live dot is never wrong — only the redundant per-delta
    /// re-stamps (which would change nothing observable) are dropped.
    private static let liveStampCoalesce: TimeInterval = 0.1
    /// A row counts as "live" if it was stamped within this window.
    private static let liveWindow: TimeInterval = 10
    /// Periodic prune of stale entries so the registry can't grow unbounded and
    /// so a dot fades out even with no further events. Runs only while at least
    /// one entry exists; cancelled when the registry empties.
    private var liveCleanupTask: Task<Void, Never>?

    // MARK: - Turn-in-progress registry (ABH-178)

    /// Stored session ids whose turn is currently in flight. A row with a local
    /// `lastActive` bump is carried forward over a server refresh IFF its id is
    /// present here — so the carry-forward is gated on a REAL per-turn lifecycle
    /// event rather than the 10s time-proxy. Cleared by every turn-end path
    /// (complete/error/cancel/disconnect) so a stuck flag can never revive the
    /// old infinite-carry-forward bug.
    /// `@ObservationIgnored` so writes never trigger a drawer invalidation on
    /// their own; the carry-forward effect lands via `mergeSessionPage`.
    @ObservationIgnored private var turnsInProgress: Set<String> = []

    /// Mark a turn started for `storedId`. Called by `ConnectionStore` on
    /// `message.start`. A `nil`/empty id is a no-op.
    func markTurnStarted(storedId: String?) {
        guard let id = storedId, !id.isEmpty else { return }
        turnsInProgress.insert(id)
    }

    /// Mark a turn completed (or failed/cancelled) for `storedId`. Called by
    /// `ConnectionStore` on `message.complete`, the gateway `error` terminal,
    /// and every turn-abort path. A `nil`/empty id is a no-op.
    func markTurnCompleted(storedId: String?) {
        guard let id = storedId, !id.isEmpty else { return }
        turnsInProgress.remove(id)
    }

    /// Clear ALL in-progress turn flags. Belt-and-suspenders: called on
    /// disconnect/reconnect so a mid-turn transport drop can never leave a flag
    /// stuck, which would revive the infinite-carry-forward bug.
    func clearAllTurnsInProgress() {
        turnsInProgress.removeAll()
    }

    #if DEBUG
    /// Test-only: the set of stored session ids currently flagged as having a
    /// turn in flight. Exposed so wiring tests can assert that every abandon path
    /// (socket drop, foreground-reconnect `dead` branch, dead-probe branch) leaves
    /// the set empty — proving the anti-stuck-flag invariant without relying on
    /// carry-forward timing.
    var turnsInProgressIds: Set<String> { turnsInProgress }
    #endif

    private var connection: ConnectionStore?
    private var chat: ChatStore?

    // MARK: - Runtime self-heal (queue "No active session" escape edge)

    /// Wired by ``AppEnvironment`` to drain the offline outbox the moment a resume
    /// binds a live runtime. The composer queues prompts whenever `activeRuntimeId`
    /// is nil (`ChatView.isConnected == false`); on an idle desktop-driven session
    /// whose resume took the gateway cold path, no turn-completion ever fires to
    /// trigger a drain, so those prompts would sit forever. Firing this on a
    /// successful bind flushes them automatically. Mirrors `ChatStore.onTurnComplete`.
    var onActiveRuntimeBound: (() -> Void)?

    /// Wired by ``AppEnvironment`` to re-stamp queued prompts when a resume follows
    /// a compression chain tip (parent stored id → continuation). Queue affinity is
    /// keyed on the stored id, so without this a prompt queued under the parent is
    /// skipped by `drain` forever after the swap.
    var onStoredIdMigrated: ((String, String) -> Void)?

    /// Coalesces concurrent on-demand re-resumes (a live send and a queue drain
    /// racing) onto a single `session.resume` RPC.
    private var ensureRuntimeTask: Task<String?, Never>?
    /// Per-session attempt budget for ``ensureActiveRuntime()`` so a genuinely
    /// unresumable session can't spin. Reset on a fresh ``open(_:revealOnFirstPaint:)``
    /// (new user intent) or a successful bind.
    private var ensureRuntimeAttempts = 0
    private var ensureRuntimeTargetId: String?
    private static let maxEnsureRuntimeAttempts = 3

    /// Injectable `session.resume` RPC (tests). Defaults to the live gateway
    /// request; a test stages a `SessionOpenResult` so the supersession guard in
    /// ``resumeActiveAfterReconnect()`` is exercisable without a network.
    var resumeRPC: ((_ storedId: String, _ params: [String: JSONValue]) async throws -> SessionOpenResult)?

    /// Supersede any in-flight on-demand re-resume (``ensureActiveRuntime()``) so a
    /// stale result can't bind a runtime into a session the user has navigated away
    /// from, and a later ``ensureActiveRuntime()`` for a different target can't
    /// coalesce onto it. The supersession guard in ``resumeActiveAfterReconnect()``
    /// is the correctness backstop; this also avoids the wasted RPC.
    private func cancelEnsureRuntime() {
        ensureRuntimeTask?.cancel()
        ensureRuntimeTask = nil
    }

    // MARK: - Offline cache (P3 read-through / write-through)

    /// The offline-first local cache (P1/P2 layer). Optional and defaulting to
    /// `nil` so existing call sites — and every unit test that never injects one —
    /// compile and behave EXACTLY as before: a `nil` cache means the network-only
    /// path is taken verbatim (cache-miss == today's behavior, byte-for-byte).
    /// Wired once by `AppEnvironment.attachCache(_:)`.
    private var cacheStore: CacheStore?

    /// Latches `true` after the first `refresh()` has run the cold-launch cache
    /// read. The read only fires when `sessions` is still empty (cold launch),
    /// so a warm in-memory list is never overwritten by a (possibly older) disk
    /// snapshot.
    private var didColdReadCache = false

    /// Inject the offline cache. Separate from `attach(connection:chat:)` so the
    /// frozen `attach` signature — called by every store-graph test — is untouched
    /// and the cache stays a purely-additive accelerator behind `sessions`.
    func attachCache(_ cache: CacheStore) {
        self.cacheStore = cache
    }

    /// The active cache partition key (P4): (serverId, profileId).
    ///   - serverId  = the trimmed saved gateway URL (`ConnectionStore.serverURLString`),
    ///                 the SAME identity used for the Keychain token + device-id map.
    ///   - profileId = the normalized `activeProfile` (blank → "all").
    /// All scoped cache reads/writes are partitioned by this. `nil` when there is
    /// no connection yet (the cold-read/write-through paths then no-op, leaving
    /// behavior byte-identical to today).
    private var currentCacheScope: CacheScope? {
        guard let serverURL = connection?.serverURLString, !serverURL.isEmpty else { return nil }
        return CacheScope(serverId: serverURL, profileId: activeProfile)
    }

    /// The serverId the cache cold-read was last partitioned by, so a SERVER
    /// switch (new gateway) can be detected at the top of `refresh()` and trigger
    /// the clear-other-servers policy + a fresh cold read for the new server.
    /// A PROFILE switch (same serverId) does NOT clear — `selectProfile` simply
    /// re-arms the cold read so the next refresh re-paints from the other
    /// profile's coexisting rows.
    private var lastColdReadServerId: String?

    /// Outbound RPC sender, injected for tests so the close→delete sequence can
    /// be exercised without a live gateway (mirrors ``transcriptFetch``). The
    /// default resolves the live `connection?.client.requestRaw`; a test injects
    /// a recorder that captures `(method, params)` and answers success/error.
    var rpcSend: ((String, JSONValue) async throws -> JSONValue)?

    /// Interrupt seam for the actively-streaming session (ABH-73 RIDER). In the
    /// app this calls the EXISTING `ChatStore.interrupt()` (which routes to the
    /// STREAM's own runtime, R1 #2) so deleting a live session stops the
    /// orphaned runtime from spending tokens. Injected for tests so the
    /// interrupt→close→delete ORDER is assertable on a shared recorder; the
    /// default forwards to `chat?.interrupt()` verbatim.
    var interruptActive: (() async -> Void)?

    /// Debounce handle for `.searchable` input → search fetch.
    private var searchTask: Task<Void, Never>?
    /// In-flight load-more handle. At most one load-more runs at a time.
    private var searchLoadMoreTask: Task<Void, Never>?

    #if DEBUG
    /// Injectable search fetch for unit tests. When set, replaces the live
    /// `fetchSearch(query:offset:api:)` call in both `searchQueryChanged` and
    /// `loadMoreSearchResults` — mirrors the `sessionsFetch` / `transcriptFetch`
    /// seam pattern so tests drive the real Task-based methods without a gateway.
    ///
    /// Signature: `(query, offset) async throws -> (results, servedByPlugin)`.
    var searchFetch: ((String, Int) async throws -> ([SessionSearchResult], Bool))?
    #endif

    /// In-flight transcript prefetch sweep (WhatsApp bar — coverage). Cancelled on
    /// disconnect/background so a paced background fetch never outlives the
    /// connection it was started under. At most one sweep runs at a time.
    private var prefetchTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: DefaultsKeys.pinnedSessions) as? [String] {
            pinnedIds = Set(stored)
        }
        hideCron = defaults.bool(forKey: DefaultsKeys.hideCron)
        groupByWorkspace = defaults.bool(forKey: DefaultsKeys.groupByWorkspace)
        if let collapsed = defaults.array(forKey: DefaultsKeys.collapsedWorkspaces) as? [String] {
            collapsedWorkspaces = Set(collapsed)
        }
        if let pinned = defaults.array(forKey: DefaultsKeys.pinnedWorkspaces) as? [String] {
            pinnedWorkspaceKeys = Set(pinned)
        }
        // Default to the aggregate ("all") scope when unset — matching the
        // desktop's default "All profiles" view. Inert until the switcher is shown.
        activeProfile = defaults.string(forKey: DefaultsKeys.activeProfile)
            ?? DefaultsKeys.allProfilesScope
    }

    /// Wire up the store graph. Called exactly once by `AppEnvironment`.
    func attach(connection: ConnectionStore, chat: ChatStore) {
        self.connection = connection
        self.chat = chat
    }

    /// Reset the initial-fill guard so the next `refresh()` re-runs the
    /// fill-to-30 loop. Call this whenever the gateway URL / token changes
    /// so a fresh cold-connect on a new server re-populates the drawer.
    ///
    /// Cancels any in-flight ``ensureInitialFill()`` and bumps ``fillGeneration``
    /// so a stale fill that resumes after an `await` cannot append onto the new
    /// server's reset list, and drops ``isFillingInitial`` so the next kick is
    /// free to start.
    func resetInitialFill() {
        initialFillDone = false
        fillGeneration &+= 1
        initialFillTask?.cancel()
        initialFillTask = nil
        isFillingInitial = false
        loadedFloor = 0
    }

    private var client: HermesGatewayClient? { connection?.client }

    /// A ``RestClient`` for the session-management endpoints (search / rename /
    /// archive / export — now ``RestClient`` extension members), resolved from the
    /// active connection. The token comes from the dev env override first
    /// (`HERMES_TOKEN`, which never touches the Keychain) and the Keychain second,
    /// mirroring how ``ConnectionStore`` bootstraps a connection.
    private var restAPI: RestClient? {
        guard let connection else { return nil }
        let urlString = connection.serverURLString
        guard !urlString.isEmpty, let url = URL(string: urlString), url.scheme != nil else {
            return nil
        }
        let env = ProcessInfo.processInfo.environment
        let token: String?
        if let envURL = env["HERMES_URL"], envURL == urlString,
           let envToken = env["HERMES_TOKEN"], !envToken.isEmpty {
            token = envToken
        } else {
            token = KeychainService.loadToken(server: urlString)
        }
        guard let token, !token.isEmpty else { return nil }
        return RestClient(
            baseURL: url, token: token,
            pathStyle: connection.capabilities.resolvedPathStyle
        )
    }

    // MARK: - Derived list slices

    /// Sessions after the cron filter AND the multi-profile scope filter, sorted
    /// by `(lastActive ?? startedAt) DESC` (desktop parity: ABH-86 item 2).
    /// The view renders pinned and unpinned sections from these — it is the single
    /// funnel pinned/unpinned/grouped read through.
    ///
    /// The sort is stable (Swift's `sort` is stable). The server's recency order
    /// is close but not authoritative: the REST `order=recent` endpoint is already
    /// good for a cold load, but after a `message.complete` triggers a refresh the
    /// active session's `lastActive` may have advanced in the response and should
    /// float to the top immediately without waiting for the *next* pull.
    ///
    /// The profile filter is DORMANT unless multi-profile is available (no stale
    /// `activeProfile` can hide rows on a stock gateway). When available and a
    /// SPECIFIC profile scope is active, only rows whose `profile` matches survive;
    /// the aggregate ("all") scope keeps every row. The cron filter still applies
    /// in every case.
    var visibleSessions: [SessionSummary] {
        var rows = sessions
        // Recents is human-chat-only BY CONSTRUCTION (drawer bifurcation):
        // automation runs (source == "cron") live in the Automation Runs feed,
        // never the chat list. The server also filters them via `exclude_sources`
        // for efficiency (no cron fetched/cached); this client-side filter
        // guarantees the invariant even against a gateway that predates that param.
        rows = rows.filter { ($0.source ?? "").lowercased() != "cron" }
        rows = Self.filterByProfile(rows, scope: activeProfile, multiAvailable: isMultiProfileAvailable)
        // Client-side re-sort by lastActive DESC, falling back to startedAt.
        // Nil timestamps sink to the bottom. The sort is stable so rows with
        // equal timestamps keep the server's original recency ordering.
        rows.sort { lhs, rhs in
            let l = lhs.lastActive ?? lhs.startedAt ?? -.greatestFiniteMagnitude
            let r = rhs.lastActive ?? rhs.startedAt ?? -.greatestFiniteMagnitude
            return l > r
        }
        return rows
    }

    /// Pure profile-scope filter applied by ``visibleSessions``. DORMANT unless
    /// `multiAvailable` (no stale `scope` can hide rows on a stock gateway). When
    /// available and a SPECIFIC profile scope is active, only rows whose `profile`
    /// matches survive; the aggregate ("all") / default scope keeps every row.
    /// Factored out (and `internal`) so the filter is unit-testable without a
    /// live connection.
    static func filterByProfile(
        _ rows: [SessionSummary],
        scope: String,
        multiAvailable: Bool
    ) -> [SessionSummary] {
        guard let name = profileParam(scope: scope, multiAvailable: multiAvailable) else {
            return rows
        }
        return rows.filter { $0.profile == name }
    }

    /// Pinned sessions (in list order) — rendered in a section above the rest.
    var pinnedSessions: [SessionSummary] {
        visibleSessions.filter { pinnedIds.contains($0.id) }
    }

    /// Non-pinned sessions, in list order.
    var unpinnedSessions: [SessionSummary] {
        visibleSessions.filter { !pinnedIds.contains($0.id) }
    }

    func isPinned(_ summary: SessionSummary) -> Bool { pinnedIds.contains(summary.id) }

    // MARK: - Workspace grouping (H2)

    /// One workspace section for the grouped Recents list: a stable group `id`
    /// (the trimmed `cwd`, or `"__no_workspace__"`), a display `label` (the
    /// basename, or "No workspace"), and the section's sessions.
    struct WorkspaceGroup: Identifiable, Equatable {
        let id: String
        let label: String
        let sessions: [SessionSummary]
    }

    /// Group ``unpinnedSessions`` by workspace (`cwd`), replicating the desktop
    /// sidebar's `workspaceGroupsFor` (apps/desktop/src/app/chat/sidebar/index.tsx).
    ///
    /// Ordering semantics:
    /// - **Pinned groups first.** Groups whose workspace key is in
    ///   ``pinnedWorkspaceKeys`` float to the top tier, preserving recency order
    ///   among themselves. Unpinned groups follow in the same recency order.
    /// - **Group order = recency.** Within each tier (pinned / unpinned), groups
    ///   appear in *first-seen* order of the recency-sorted input
    ///   (``unpinnedSessions`` is already in REST `order=recent` order), so a
    ///   workspace with fresh activity floats to the top of its tier.
    /// - **Rows within a group = `startedAt` DESC, stably.** Newest-created on
    ///   top, but a stable sort means rows don't reshuffle when a message lands
    ///   (preserving muscle memory). A `nil` `startedAt` sorts to the bottom.
    ///
    /// Pinned sessions are intentionally absent: they live in the drawer's
    /// Pinned section regardless of grouping. The cron filter already applies
    /// because the input is ``unpinnedSessions`` (derived from
    /// ``visibleSessions``).
    func workspaceGroups() -> [WorkspaceGroup] {
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]

        for session in unpinnedSessions {
            let key = session.workspaceKey
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)            // first-seen → recency order
            }
            buckets[key]?.append(session)
        }

        // Build groups in first-seen / recency order.
        let allGroups: [WorkspaceGroup] = order.map { key in
            let rows = (buckets[key] ?? []).sorted { lhs, rhs in
                // startedAt DESC; nil sinks to the bottom. Swift's sort is
                // stable, so equal timestamps keep their recency order.
                (lhs.startedAt ?? -.greatestFiniteMagnitude)
                    > (rhs.startedAt ?? -.greatestFiniteMagnitude)
            }
            return WorkspaceGroup(
                id: key,
                label: rows.first?.workspaceLabel ?? Self.labelForKey(key),
                sessions: rows
            )
        }

        // Hoist pinned groups to the front, preserving recency order within
        // each tier. The split is stable: a pinned group at recency position 2
        // stays at position 0 among pinned but never reorders relative to other
        // pinned groups. Deterministic: tie (same key appears once) never arises.
        let pinned   = allGroups.filter { pinnedWorkspaceKeys.contains($0.id) }
        let unpinned = allGroups.filter { !pinnedWorkspaceKeys.contains($0.id) }
        return pinned + unpinned
    }

    /// Fallback label for a group key when the bucket is somehow empty (it
    /// never is in practice). The sentinel key maps to "No workspace"; any other
    /// key is a real path, so derive its basename.
    private static func labelForKey(_ key: String) -> String {
        guard key != SessionSummary.noWorkspaceKey else {
            return SessionSummary.noWorkspaceLabel
        }
        return SessionSummary.basename(of: key) ?? key
    }

    // MARK: - Cache-first paint (WhatsApp bar)

    /// CACHE-FIRST cold read: paint `sessions` from the local cache, UNCONDITIONALLY
    /// of connection state, so the drawer renders from disk the instant the app
    /// launches — exactly as WhatsApp shows the chat list before any network round
    /// trip. Lifted out of ``refresh()`` (where it only ran once a `refresh()` was
    /// reached, which the offline-launch early-return path NEVER did — the empty-
    /// drawer hole) so it can be driven directly from `ConnectionStore.bootstrap()`
    /// BEFORE the REST probe.
    ///
    /// Idempotent and self-gating, preserving the exact `didColdReadCache`
    /// semantics the network merge relies on:
    ///   - fires at most once per (server) binding — the `didColdReadCache` latch;
    ///   - paints ONLY while `sessions` is still empty, so a warm in-memory list
    ///     (or a network refresh that already populated it) is never clobbered by a
    ///     disk snapshot;
    ///   - records `lastColdReadServerId` so a later SERVER switch is detected at
    ///     the top of `refresh()` (the clear-other-servers policy).
    ///
    /// No cache (tests/previews) or no scope yet (unconfigured) ⇒ a no-op, so the
    /// network-only path stays byte-identical to today. Safe to call repeatedly:
    /// `refresh()` still calls it on every invocation, and `bootstrap()` calls it
    /// once up front — the latch collapses both to a single disk read.
    func paintFromCache() async {
        guard !didColdReadCache else { return }
        didColdReadCache = true
        if sessions.isEmpty, let cacheStore, let scope = currentCacheScope {
            lastColdReadServerId = scope.serverId
            if let cached = try? await cacheStore.loadSessionList(scope: scope), !cached.isEmpty {
                // Re-check emptiness after the await: a concurrent network
                // refresh may have populated the list while we were reading
                // disk — never overwrite fresher server data with the cache.
                if sessions.isEmpty {
                    sessions = cached
                    // The cold cache paint is a real first page for the
                    // pagination cursors and the initial-fill fast-path.
                    loadedCount = cached.count
                    loadedOffset = cached.count
                }
            }
        } else if let scope = currentCacheScope {
            // Even when we skip the disk read (warm list already populated),
            // record the server we're now bound to so a later server switch
            // is detected.
            lastColdReadServerId = scope.serverId
        }
    }

    // MARK: - Transcript prefetch (WhatsApp bar — coverage)

    /// How many most-recent non-cron sessions the post-hydration sweep warms.
    private static let prefetchSessionCount = 30
    /// Concurrency ceiling for the prefetch sweep — gentle pacing so it never
    /// contends with a live turn or the user's own open. 3 in flight at a time.
    private static let prefetchConcurrency = 3

    /// Background-prefetch transcripts for the top ~30 most-recent non-cron
    /// sessions so nearly every drawer tap is a DISK hit (cache-first open paints
    /// instantly). Called after connect + hydration settles and after a reconnect.
    ///
    /// Discipline (per the WhatsApp-bar spec):
    ///   - skips sessions already cached FRESH for their current `lastActive`
    ///     (`CacheStore.transcriptIsFresh`), so a warm cache costs zero network;
    ///   - skips cron sessions (never transcript-cached) and the actively-open one
    ///     (its own open path owns the fetch);
    ///   - paces at `prefetchConcurrency` (3) in flight, LOW priority;
    ///   - cancels on disconnect/background via ``cancelPrefetch()``;
    ///   - writes through the existing `saveTranscript` (cron-guarded in CacheStore).
    ///
    /// A no-op when there is no cache or no REST client (tests/previews/offline) —
    /// purely additive coverage, never a correctness dependency. At most one sweep
    /// runs at a time; a new call supersedes any in-flight sweep.
    func prefetchRecentTranscripts() {
        guard let cacheStore, let fetch = resolvedPrefetchFetch else { return }

        // Snapshot the prefetch targets on the main actor (newest-first, non-cron,
        // excluding the open session). `visibleSessions` already excludes cron and
        // sorts by recency, so it is the right source. Map to a Sendable tuple so
        // the detached sweep captures plain values, not SessionSummary state.
        let openId = activeStoredId
        let targets: [(id: String, lastActive: Double?)] = visibleSessions
            .filter { $0.id != openId }
            .prefix(Self.prefetchSessionCount)
            .map { ($0.id, $0.lastActive) }
        guard !targets.isEmpty else { return }

        let concurrency = Self.prefetchConcurrency
        prefetchTask?.cancel()
        // The sweep captures only Sendable values: the `@Sendable` fetch closure,
        // the `CacheStore` actor, and the (id, lastActive) tuples. No MainActor
        // store state crosses the boundary, so it is Swift-6 strict-concurrency
        // clean without hopping back per session.
        prefetchTask = Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for target in targets {
                    if Task.isCancelled { break }
                    // Skip a session whose disk copy is already current.
                    if (try? await cacheStore.transcriptIsFresh(
                        target.id, lastActive: target.lastActive)) == true {
                        continue
                    }
                    if inFlight >= concurrency {
                        await group.next()
                        inFlight -= 1
                    }
                    let sessionId = target.id
                    group.addTask(priority: .utility) {
                        if Task.isCancelled { return }
                        guard let stored = try? await fetch(sessionId) else { return }
                        if Task.isCancelled { return }
                        try? await cacheStore.saveTranscript(
                            sessionId: sessionId, messages: stored)
                    }
                    inFlight += 1
                }
                await group.waitForAll()
            }
        }
    }

    /// Injectable `@Sendable` transcript fetch for the prefetch sweep (tests stage
    /// a recorder without a live gateway). Distinct from ``transcriptFetch`` (the
    /// open-path seam, MainActor-bound and non-Sendable) because the prefetch runs
    /// in a detached task group where every captured value must be Sendable. `nil`
    /// (default) resolves the live REST client below.
    var prefetchFetch: (@Sendable (String) async throws -> [StoredMessage])?

    /// The injected ``prefetchFetch``, or a `@Sendable` closure built from the live
    /// `RestClient` (a Sendable value struct — safe to capture across the task-group
    /// boundary). `nil` when unconfigured/offline, which makes the whole sweep a
    /// no-op (purely additive coverage, never a correctness dependency).
    private var resolvedPrefetchFetch: (@Sendable (String) async throws -> [StoredMessage])? {
        if let prefetchFetch { return prefetchFetch }
        guard let rest = connection?.rest else { return nil }
        return { sessionId in try await rest.messages(sessionId: sessionId) }
    }

    /// Cancel any in-flight prefetch sweep (WhatsApp bar). Called on disconnect /
    /// background so a paced background fetch never outlives its connection.
    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// Run the daily-throttled transcript eviction sweep (WhatsApp bar hygiene).
    /// Fire-and-forget, OFF the UI path; CacheStore self-throttles to once/24h, so
    /// this is safe to call on every connect. A no-op without a cache.
    func runEvictionIfNeeded() {
        guard let cacheStore else { return }
        Task(priority: .utility) {
            _ = try? await cacheStore.evictStaleTranscriptsIfNeeded()
        }
    }

    // MARK: - Listing

    /// Refresh the session list via `session.list` (limit 100).
    ///
    /// **Non-destructive merge (ABH-86 item 3):** after the fetch resolves, rows
    /// missing from the incoming page are dropped UNLESS their id belongs to the
    /// working set: the active session, any live/working ids (sessions with recent
    /// broadcast activity still within the live window), and pinned sessions.
    /// Survivors are prepended so they stay visible in the drawer while the
    /// server catches up. Incoming page wins for everything else.
    ///
    /// **Stale-token guard (ABH-86 item 3):** a monotonic `refreshToken` is
    /// captured before the await and re-checked after. A response from a prior
    /// request (token value smaller than the one that ran last) is discarded so
    /// a slow response can never overwrite a newer list.
    ///
    /// When multi-profile is available and the active scope is not the default
    /// profile, the rail fetches the cross-profile aggregate
    /// (`GET /api/profiles/sessions?profile=all`) so each row carries its `profile`
    /// tag (a named scope then filters client-side via ``visibleSessions``).
    /// Otherwise — the dormant single-profile case AND the default-profile scope —
    /// it uses the existing `GET /api/sessions` path, byte-for-byte unchanged.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // P3 cold-launch read-through: on the FIRST refresh, before any network
        // fetch, paint `sessions` from the local cache so the drawer renders
        // instantly from disk on a remote-Tailscale cold start. Guarded so it
        // fires at most once and ONLY while `sessions` is still empty — a warm
        // in-memory list (already populated by an earlier refresh) is never
        // clobbered by a disk snapshot. The subsequent network fetch below runs
        // unchanged and `mergeSessionPage` reconciles server authority over the
        // cached rows. No cache (tests/previews) ⇒ this is a no-op and the path
        // is byte-identical to today.
        // P4 SERVER-switch policy: if the active server changed since the last
        // cold read (a new gateway), CLEAR the other servers' cached rows
        // (transcripts cascade via FK) and repopulate the active server from the
        // network below. A PROFILE switch (same server, different profileId) does
        // NOT clear — both profiles coexist; `selectProfile` re-arms the cold read
        // and the scoped read below simply re-filters to the new profile's rows.
        // Architected as the SOLE clear site: dropping the server-clear later
        // (full coexist-all-servers) is deleting this one call — no migration.
        if let cacheStore, let scope = currentCacheScope,
           let previous = lastColdReadServerId, previous != scope.serverId {
            _ = try? await cacheStore.clearSessionsForOtherServers(keepingServerId: scope.serverId)
            // A different server's list is showing — drop the stale in-memory rows
            // and re-arm the cold paint so the new server repaints from its own
            // (now sole) cached rows rather than leaving the prior server's list
            // on screen while the network refetches.
            sessions = []
            loadedCount = 0
            loadedOffset = 0
            didColdReadCache = false
        }

        await paintFromCache()

        // Bump and capture the token for this request. Any response that arrives
        // with a smaller captured value was superseded and is discarded.
        refreshToken &+= 1
        let myToken = refreshToken

        // Use the injected seam when present (unit tests, no live gateway).
        if let fetch = sessionsFetch {
            do {
                let (fetched, total) = try await fetch()
                guard refreshToken == myToken else { return }
                mergeSessionPage(fetched, total: total)
                persistSessionListToCache()  // P3 write-through (fire-and-forget)
                lastError = nil

                // Kick the decoupled initial-fill (idempotent; survives a sibling
                // refresh()'s token bump). It runs to the target / server-exhaust
                // on its OWN task, independent of `myToken`.
                ensureInitialFill()

                SpotlightIndexer.index(sessions: sessions)
            } catch {
                guard refreshToken == myToken else { return }
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            return
        }

        // Multi-profile aggregate rail (F4b): only when the capability is
        // available AND the scope is not the default profile. The default scope
        // and every stock-gateway case skip this entirely → the existing fetch.
        if usesAggregateRail, let rest = connection?.rest {
            do {
                // fill30: the aggregate rail is just as cron-dense as the single
                // rail, so it needs the SAME fill-to-target treatment. Floor the
                // first-page window at what the fill reached (so a post-fill
                // heartbeat / drawer-open can't collapse it back to 100) and kick
                // the decoupled `ensureInitialFill()` — which pages this rail via
                // `profileSessions` (routed inside `resolvedInitialFillFetch`).
                // Previously this branch fetched a HARDCODED limit=100 and `return`ed
                // BEFORE the fill, so on a multi-profile gateway the drawer was stuck
                // at ~6 non-cron regardless of the single-rail fix.
                let fetchLimit = max(100, loadedFloor, loadedCount)
                let result = try await rest.profileSessions(
                    profile: DefaultsKeys.allProfilesScope, limit: fetchLimit,
                    excludeSource: Self.recentsExcludeSources
                )
                guard refreshToken == myToken else { return }
                mergeSessionPage(result.sessions, total: result.total)
                persistSessionListToCache()  // P3 write-through (fire-and-forget)
                lastError = nil
                ensureInitialFill()
                SpotlightIndexer.index(sessions: sessions)
                return
            } catch {
                guard refreshToken == myToken else { return }
                // Fall through to the single-profile fetch below (defensive — a
                // transient aggregate failure still shows the recents list).
            }
        }

        // Prefer REST: order=recent is compression-chain aware and surfaces
        // old sessions with fresh activity (the WS RPC is creation-ordered,
        // which buries them under high-volume cron sessions).
        // UX1: min_messages=1 matches desktop's listAllProfileSessions(limit, 1)
        // so scaffold/empty sessions never clutter the drawer.
        // BUG B (heartbeat-reset guard): use `max(100, loadedCount)` so the
        // heartbeat's first-page re-fetch never shrinks a window that the
        // initial-fill loop already expanded to reach `initialVisibleTarget`.
        if let rest = connection?.rest {
            do {
                // Floor the first-page window at what the initial fill reached so a
                // post-fill heartbeat / gateway.ready replace can't collapse the
                // drawer back to ~100 rows (fill30): `max(100, loadedFloor, loadedCount)`.
                let fetchLimit = max(100, loadedFloor, loadedCount)
                let result = try await rest.sessionsWithTotal(
                    limit: fetchLimit, minMessages: 1,
                    excludeSource: Self.recentsExcludeSources
                )
                guard refreshToken == myToken else { return }
                mergeSessionPage(result.sessions, total: result.total)
                persistSessionListToCache()  // P3 write-through (fire-and-forget)
                lastError = nil

                // BUG B FIX (re-architected — fill30): ensure at least
                // `initialVisibleTarget` VISIBLE sessions after cold-connect, robust
                // against the concurrent-refresh race. The fill no longer runs inline
                // under `myToken` (a sibling refresh() bumping the token used to abort
                // it after one ~100-row page and `initialFillDone` then gated the retry
                // off forever). Instead it runs on a DEDICATED, idempotent task with
                // its own lifecycle (`ensureInitialFill()`), pages with grow-limit +
                // dedupe-append until the target is met or the server is exhausted, and
                // latches `initialFillDone` ONLY on successful completion — so an
                // aborted attempt is retried by the next refresh().
                ensureInitialFill()

                // Republish the session list into Spotlight (fire-and-forget).
                SpotlightIndexer.index(sessions: sessions)
                return
            } catch {
                guard refreshToken == myToken else { return }
                // Fall through to the WS RPC below.
            }
        }

        guard let client else { return }
        do {
            let raw = try await client.requestRaw(
                "session.list",
                params: .object(["limit": .number(100)])
            )
            guard refreshToken == myToken else { return }
            let fetched = Self.parseSessions(from: raw)
            // WS RPC shape has no total; preserve whatever was last known.
            mergeSessionPage(fetched, total: nil)
            persistSessionListToCache()  // P3 write-through (fire-and-forget)
            lastError = nil
            // Republish the session list into Spotlight (fire-and-forget).
            SpotlightIndexer.index(sessions: sessions)
        } catch {
            guard refreshToken == myToken else { return }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Non-destructive merge of an incoming page into `sessions` (ABH-86 item 3,
    /// desktop parity with `store/session.ts:mergeSessionPage`).
    ///
    /// Semantics:
    /// - Build the incoming id set.
    /// - Find rows in the **current** list that are absent from the incoming page
    ///   but belong to the working set: the active stored session, any session
    ///   that has live broadcast activity within the liveness window, and pinned
    ///   sessions. These are the "survivors".
    /// - Prepend survivors to the incoming page (they float to the top briefly,
    ///   then fall into place on the next refresh once the server catches up).
    /// - Incoming page wins for all other rows.
    /// - When `total` is non-nil, update ``totalSessions``.
    ///
    /// UX1: `isAppend` mode merges an additional page on top of the existing
    /// `sessions` array rather than replacing it. Deduplication is by `id`.
    /// Working-set survivor logic is skipped on appended pages (the first-page
    /// already carries those survivors). `loadedCount` is advanced accordingly.
    private func mergeSessionPage(_ incoming: [SessionSummary], total: Int?, isAppend: Bool = false) {
        // Update the total count when the server provides it.
        if let total { totalSessions = total }

        if isAppend {
            // Append path: dedupe by id, preserve recency order of prior list.
            let existingIds = Set(sessions.map(\.id))
            let newRows = incoming.filter { !existingIds.contains($0.id) }
            sessions.append(contentsOf: newRows)
            // Advance `loadedCount` by the number of GENUINELY NEW rows, not the
            // full incoming window. With grow-limit pagination the live REST call
            // returns the ENTIRE expanded window each time (e.g. limit=150 returns
            // 150 rows, ~50 of them new); blindly adding `incoming.count` made
            // `loadedCount` race ~2x ahead of the real `sessions.count`. That
            // over-count then poisoned the heartbeat's `max(100, loadedCount)`
            // first-page window and the header's "N loaded" copy. Counting new rows
            // keeps `loadedCount == sessions.count` (minus working-set survivors),
            // which is the honest, stable invariant. (Test seams return delta-only
            // pages, so `newRows.count == incoming.count` there — unchanged.)
            loadedCount += newRows.count
            return
        }

        // First-page (replace) path — original ABH-86 merge semantics.
        let incomingIds = Set(incoming.map(\.id))

        // Working-set: active session + live/working + pinned. These survive
        // even if the server's current page window omits them.
        var workingIds = pinnedIds
        if let active = activeStoredId { workingIds.insert(active) }
        // Any session that has had broadcast activity in the live window counts
        // as "working" — it is being actively used and the server will include
        // it on the very next refresh.
        let now = Date()
        for (id, at) in lastActivityAt {
            if now.timeIntervalSince(at) < Self.liveWindow { workingIds.insert(id) }
        }

        // Survivors: current rows absent from the incoming page but in the working set.
        let survivors = sessions.filter { !incomingIds.contains($0.id) && workingIds.contains($0.id) }

        // ABH-86: carry a HIGHER local `lastActive` forward over the incoming
        // server value. `noteActivity` optimistically bumps a session to NOW on a
        // live frame so it re-sorts to the top immediately; but the server only
        // advances `lastActive` on message.complete, so the debounced refresh that
        // fires ~400ms after message.start returns the OLD value and would knock
        // the row back down (visible flicker). Server `lastActive` is monotonic,
        // so `max(local, server)` keeps the optimistic position until the server
        // genuinely catches up, then converges to the authoritative value.
        let priorLastActive: [String: Double] = sessions.reduce(into: [:]) { acc, s in
            if let la = s.lastActive { acc[s.id] = la }
        }
        // ABH-178 — gate the carry-forward on an EXPLICIT per-turn flag
        // (turnsInProgress) instead of the 10s liveWindow time-proxy. The
        // time-proxy worked well for the common case (frequent delta frames keep
        // lastActivityAt fresh) but opened a residual flicker window when a turn
        // had a >liveWindow silent inter-frame gap: the carry-forward decayed mid-turn
        // and a refresh would temporarily drop the row to server authority. The
        // explicit flag is toggled on message.start (set) and cleared on every
        // turn-end path: message.complete, gateway error, user cancel, and — as a
        // belt-and-suspenders — disconnect/reconnect (clearAllTurnsInProgress).
        // That final path ensures a mid-turn socket drop can NEVER leave the flag
        // stuck, which would bring back the infinite-carry-forward bug from ABH-157.
        // NOTE: `lastActivityAt` / `liveWindow` are PRESERVED for the live-dot
        // (the pulsing row indicator) — only this carry-forward gate has changed.
        let reconciled = incoming.map { row -> SessionSummary in
            guard let prior = priorLastActive[row.id],
                  turnsInProgress.contains(row.id),
                  prior > (row.lastActive ?? -.greatestFiniteMagnitude) else { return row }
            var bumped = row
            bumped.lastActive = prior
            return bumped
        }

        // Merge: survivors first (they have the most up-to-date local state),
        // then the incoming page (server authority for everything else).
        sessions = survivors + reconciled

        // Reset pagination cursors on a first-page refresh.
        loadedCount = incoming.count
        loadedOffset = incoming.count
    }

    /// ABH-86: optimistically bump a session's activity to NOW so a live frame
    /// (the user sending into it, or a foreign turn) re-sorts it to the top of the
    /// drawer IMMEDIATELY — without waiting for the server's `lastActive` (which
    /// only advances on message.complete) to round-trip. `visibleSessions` sorts
    /// by `lastActive DESC` and is computed, so mutating the row here triggers an
    /// instant re-sort; `mergeSessionPage` carries this higher value forward over
    /// the next (stale) refresh until the server catches up. No-op when the id is
    /// unknown (the caller's debounced `scheduleSessionRefresh` discovers it).
    func noteActivity(storedId: String?) {
        guard let id = storedId,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let now = Date().timeIntervalSince1970
        if (sessions[idx].lastActive ?? -.greatestFiniteMagnitude) < now {
            sessions[idx].lastActive = now
        }
        // ABH-157 — the optimistic bump and the LIVE WINDOW are the same signal: a
        // row is only "ahead of the server" while it is actively being driven.
        // Stamp `lastActivityAt` here too so `mergeSessionPage`'s carry-forward
        // (gated on the live window) keeps this bump until the turn SETTLES, then
        // lets it decay to the authoritative server value. Without this unifying
        // stamp the bump would be carried forward FOREVER (device-clock skew →
        // never converges: stale sort + stale timestamp).
        lastActivityAt[id] = Date()
    }

    /// P3 write-through: persist the current `sessions` array into the local
    /// cache, fire-and-forget, OFF the UI path. Called after every successful
    /// `mergeSessionPage` so the cache tracks the freshest list. `saveSessionList`
    /// is an upsert (never deletes rows absent from the batch) and preserves
    /// `isPinned`/`lastAccessedAt`/transcript cursors on existing rows, so a
    /// partial-page refresh can never evict an unseen session or drop a cached
    /// transcript. No cache (tests/previews) ⇒ this is a no-op.
    private func persistSessionListToCache() {
        guard let cacheStore, let scope = currentCacheScope else { return }
        let snapshot = sessions
        Task { try? await cacheStore.saveSessionList(snapshot, scope: scope) }
    }

    /// Decode the `session.list` result, which is `{ sessions: [...] }`.
    private static func parseSessions(from raw: JSONValue) -> [SessionSummary] {
        guard let rows = raw["sessions"]?.arrayValue else { return [] }
        return rows.compactMap { $0.decoded(as: SessionSummary.self) }
    }

    // MARK: - Load more (UX1 grow-limit pagination)

    /// Load the next page of sessions and append them to the existing list.
    ///
    /// **Pagination contract (UX1 — grow-limit, desktop-exact):**
    /// - Uses GROW-THE-LIMIT semantics (desktop-controller.tsx:290): the new
    ///   request is `limit = loadedCount + PAGE_SIZE, offset=0, min_messages=1`.
    ///   The server window expands; we deduplicate the overlap by id so rows
    ///   already in the list are not duplicated.
    /// - A patched gateway server-filters cron via `exclude_sources` (plural — the
    ///   real FastAPI param, see `RestClient.sessionsWithTotal`), so the window is
    ///   already cron-free and this loop converges fast. The client-side `hideCron`
    ///   filter remains the hard invariant guarantee against a STOCK/older gateway
    ///   that ignores the param and returns a dense cron-heavy window: `loadMore`
    ///   keeps fetching in a loop until `visibleSessions` grows OR there are no more
    ///   server rows — so the user is never stranded at a wall of hidden cron rows.
    /// - A fetch is a no-op when already at the server total, already loading, or
    ///   when a first-page refresh is in flight (`isLoading`).
    /// - The same `refreshToken` / stale-response guard from `refresh()` protects
    ///   against a slow prior loadMore response overwriting a newer list.
    ///
    /// Injectable seam: when `sessionsFetch` is set, `loadMore()` is a no-op
    /// (unit tests drive pagination via `sessionsFetch` with `refresh()`).
    func loadMore() async {
        // Guard: nothing to do if we're at the known total, or a load is already in flight.
        if let total = totalSessions, loadedOffset >= total { return }
        guard !isLoadingMore, !isLoading else { return }
        // A fetch source is required: the injected fill seam (`initialFillFetch`,
        // unit tests) or a live REST client. Without either, silently no-op
        // (mirrors the prior `connection?.rest` guard so the no-connection tests
        // still see loadMore as a no-op).
        guard initialFillFetch != nil || connection?.rest != nil else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        // Keep fetching with a growing limit until we have added at least
        // `loadMorePageVisibleTarget` (30) NEWLY-VISIBLE rows since this call
        // started, OR the server is exhausted. Measuring the delta from the
        // call's starting visible count (not the prior iteration) is what
        // guarantees a full ~30-row batch per auto-load even when a dense
        // cron-heavy window + `hideCron` filters most of each fetched page out.
        //
        // The page is fetched via `resolvedInitialFillFetch` — the SAME resolver
        // the cold-launch fill uses — so loadMore pages the identical rail the
        // list was populated from (on the aggregate "All profiles" rail that is
        // `profileSessions`, not `sessionsWithTotal`). This keeps loadMore
        // consistent with refresh()/fill and makes the loop unit-testable via the
        // `initialFillFetch` seam.
        let startVisibleCount = visibleSessions.count
        repeat {
            let newLimit = loadedCount + Self.pageSize
            refreshToken &+= 1
            let myToken = refreshToken

            do {
                let result = try await resolvedInitialFillFetch(limit: newLimit)
                guard refreshToken == myToken else { return }
                let loadedBefore = loadedCount
                mergeSessionPage(result.sessions, total: result.total, isAppend: true)
                loadedOffset = loadedCount  // grow-limit: offset advances with loadedCount
                // Server returned no new rows despite a larger limit — it is
                // exhausted even if `totalSessions` is unknown/stale. Bail to
                // avoid spinning forever on a window that can't grow.
                if loadedCount == loadedBefore { break }
            } catch {
                guard refreshToken == myToken else { return }
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }

            // Stop if we've reached the known server total.
            if let total = totalSessions, loadedOffset >= total { break }
            // Stop once this call has surfaced a full batch of new visible rows.
            if visibleSessions.count - startVisibleCount >= Self.loadMorePageVisibleTarget { break }
        } while true
    }

    // MARK: - Initial fill (fill30 — cold-launch fill-to-target, race-robust)

    /// Kick the cold-launch initial fill: page (grow-limit) until at least
    /// ``initialVisibleTarget`` sessions are VISIBLE after the user's current
    /// filters (`hideCron` / profile — `visibleSessions` already applies them) OR
    /// the server is exhausted. Idempotent and concurrency-safe; the safe entry
    /// point every `refresh()` calls.
    ///
    /// ## Why a dedicated task (the fill30 fix)
    /// The old fill ran *inline* in `refresh()` under that call's `refreshToken`.
    /// At cold launch `refresh()` fires several times in quick succession (connect
    /// hydration, `gateway.ready`, drawer-open, the 30 s heartbeat); each bumps the
    /// token. When a sibling bumped the token mid-fill, the in-flight loop's
    /// `guard refreshToken == myToken` aborted it after the first ~100-row page —
    /// and because `initialFillDone` was latched at the *start*, the later refresh()
    /// never retried it. Net: the drawer stuck at ~6 visible with `hideCron`.
    ///
    /// This entry point decouples the fill from the per-request token:
    /// - **No two fills ever run concurrently** — `isFillingInitial` gates a second
    ///   kick to a no-op while one is in flight.
    /// - **Survives a sibling `refresh()`** — the loop pages on its OWN task and
    ///   does NOT check `refreshToken`; a token bump can't abort it. It is bound
    ///   only to ``fillGeneration`` (bumped solely by ``resetInitialFill()`` on a
    ///   server change), so a stale fill can't append onto a new server's list.
    /// - **Retried until it actually completes** — `initialFillDone` latches `true`
    ///   ONLY when the loop terminates by meeting the target or proving the server
    ///   exhausted. An aborted / errored / cancelled attempt leaves it `false`, so
    ///   the next `refresh()` re-kicks the fill.
    /// - **Terminates cleanly** — stops the instant `loadedCount >= totalSessions`
    ///   (a gateway with < 30 non-cron rows never spins) and bounds itself with a
    ///   no-progress guard so a server that returns the same window forever can't
    ///   loop.
    func ensureInitialFill() {
        // Already satisfied or already running → nothing to kick.
        guard !initialFillDone, !isFillingInitial else { return }
        // Fast path: the first page already meets the target. Latch done without
        // spinning up a task (and without a needless page fetch).
        if visibleSessions.count >= Self.initialVisibleTarget {
            initialFillDone = true
            return
        }
        // Fast path: the server is already exhausted (everything is loaded) but we
        // still fell short — there is nothing more to fetch, so the fill is "done"
        // in the only sense that matters (a <30 gateway must not spin).
        if let total = totalSessions, loadedCount >= total {
            initialFillDone = true
            return
        }

        isFillingInitial = true
        let myGeneration = fillGeneration
        initialFillTask = Task { [weak self] in
            guard let self else { return }
            await self.runInitialFill(generation: myGeneration)
        }
    }

    /// The decoupled fill loop body. Pages with grow-limit + dedupe-append until
    /// the target is met, the server is exhausted, no progress is made, or the
    /// fill is cancelled by a server change (``fillGeneration`` no longer matches).
    /// Latches ``initialFillDone`` ONLY on a clean terminal outcome.
    ///
    /// MainActor-isolated (the whole store is `@MainActor`), so every read/write of
    /// `loadedCount` / `loadedOffset` / `initialFillDone` / `isFillingInitial`
    /// happens on the actor — no data races under Swift 6 strict concurrency.
    private func runInitialFill(generation: Int) async {
        // Drop the in-flight flag on EVERY exit so a later refresh() can re-kick a
        // fill that ended without latching `initialFillDone` (abort / error / cancel).
        defer { isFillingInitial = false }

        while visibleSessions.count < Self.initialVisibleTarget {
            // Cancelled by resetInitialFill() (server change) or task cancellation:
            // bail WITHOUT latching done so a re-connect re-fills the new server.
            guard generation == fillGeneration, !Task.isCancelled else { return }
            // Server exhausted before the target: clean terminal outcome — latch
            // done so a <30-non-cron gateway never spins on every refresh().
            // An UNKNOWN total is NOT exhaustion (release audit): a payload
            // that omits `total` must keep paging — the no-progress guard
            // below is the reliable exhaustion signal in that case.
            if let total = totalSessions, loadedCount >= total {
                initialFillDone = true
                return
            }

            let priorLoaded = loadedCount
            let newLimit = loadedCount + Self.pageSize
            do {
                let page = try await resolvedInitialFillFetch(limit: newLimit)
                // Re-check the generation AFTER the await: a server change while the
                // page was in flight must discard it (never append onto the reset
                // list). A sibling refresh()'s `refreshToken` bump is deliberately
                // NOT checked — that is the whole point of decoupling the fill.
                guard generation == fillGeneration, !Task.isCancelled else { return }
                // Heartbeat-composition guard (BUG-B partner): a heartbeat /
                // gateway.ready refresh() may have run its FIRST-PAGE replace while
                // this page was in flight, resetting `loadedCount` (its window is
                // `max(100, loadedFloor, loadedCount)`, so it never shrinks below the
                // fill's progress — but it can land between our limit-compute and append).
                // If `loadedCount` no longer matches what we paged from, this page
                // is for a stale window: skip the append and re-loop to recompute a
                // fresh `newLimit` from the current `loadedCount`. Prevents a stale
                // large window double-counting on top of the replace.
                guard loadedCount == priorLoaded else { continue }
                mergeSessionPage(page.sessions, total: page.total, isAppend: true)
                loadedOffset = loadedCount
                // Raise the high-water floor so a later first-page refresh re-fetches
                // at least this many rows (keeps the target visible after the fill).
                loadedFloor = max(loadedFloor, loadedCount)
            } catch {
                // A mid-loop page failure is non-fatal and NOT terminal: surface the
                // error and stop, leaving `initialFillDone == false` so the next
                // refresh() re-kicks the fill (the old code latched done here, so a
                // single transient error abandoned the fill permanently).
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }

            // No-progress guard: a server that keeps returning the same window
            // (loadedCount didn't advance) would otherwise loop forever. Treat it
            // as exhausted and latch done.
            if loadedCount <= priorLoaded {
                initialFillDone = true
                return
            }
        }

        // Target met — clean terminal outcome.
        initialFillDone = true
    }

    /// Await the in-flight initial-fill task to completion. TEST SEAM ONLY: the
    /// fill now runs on its OWN task (decoupled from `refresh()`'s `refreshToken`),
    /// so `await refresh()` returns before the fill finishes. Tests call this to
    /// deterministically wait for the fill instead of polling. Re-awaits a re-kicked
    /// fill (detected via the still-in-flight flag) so a retry is waited out too.
    func awaitInitialFillForTesting() async {
        // `Task` is a value type (no identity), so loop on the in-flight flag: await
        // the current task, and if a fresh fill is still running afterward (a re-kick
        // replaced the task while we awaited), await that one too. Bounded: each
        // settled fill either latches `initialFillDone` or drops `isFillingInitial`.
        while let task = initialFillTask {
            await task.value
            if !isFillingInitial { break }
        }
    }

    /// Resolve the page fetch for ``runInitialFill(generation:)``: the injected
    /// ``initialFillFetch`` seam in tests, else the live grow-limit fetch on the
    /// SAME rail the first page used — the aggregate `profileSessions` rail when
    /// multi-profile is active (fill30), otherwise the single `sessionsWithTotal`
    /// rail. `nil` REST (unconfigured) throws so the loop surfaces an error and
    /// unlatches rather than silently latching done.
    private func resolvedInitialFillFetch(limit: Int) async throws
        -> (sessions: [SessionSummary], total: Int?) {
        if let filler = initialFillFetch {
            return try await filler(limit)
        }
        guard let rest = connection?.rest else { throw GatewayError.notConnected }
        if usesAggregateRail {
            // Grow-limit on the aggregate rail so the fill pages the SAME list the
            // first-page replace populated (otherwise the fill's appended single-rail
            // rows would not match the aggregate window and dedupe would misbehave).
            let result = try await rest.profileSessions(
                profile: DefaultsKeys.allProfilesScope, limit: limit,
                excludeSource: Self.recentsExcludeSources
            )
            return (result.sessions, result.total)
        }
        return try await rest.sessionsWithTotal(
            limit: limit, minMessages: 1, excludeSource: Self.recentsExcludeSources
        )
    }

    // MARK: - Heartbeat (UX1)

    /// Start the 30-second foreground heartbeat. A no-op if already running.
    /// Safe to call multiple times (idempotent via the `heartbeatTask` guard).
    /// Each tick calls `refresh()`, which bumps `refreshToken` and uses the
    /// ABH-86 stale-token guard — so a slow prior response is always discarded.
    func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    /// Stop the foreground heartbeat (called when the scene goes background or inactive).
    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// React to a scene-phase change: start the heartbeat when the scene is active
    /// (`isActive == true`), stop it otherwise.
    ///
    /// Pass `isActive: scenePhase == .active` from the caller. The `SessionStore`
    /// is Foundation-only and does not import SwiftUI, so `ScenePhase` is not
    /// directly referenced here — the caller resolves it.
    ///
    /// Called by the app root's `.onChange(of: scenePhase)` handler.
    func handleScenePhaseActive(_ isActive: Bool) {
        if isActive {
            startHeartbeat()
        } else {
            stopHeartbeat()
        }
    }

    /// Trigger an immediate first-page refresh when the drawer opens. Reuses the
    /// ABH-86 coalescing seam (bumps `refreshToken`, discards stale responses) so
    /// a rapid drawer-open + heartbeat tick within 30s collapses to one fetch.
    func drawerOpenRefresh() {
        Task { [weak self] in await self?.refresh() }
    }

    // MARK: - Profiles (F4b — switcher data, feature-detected)

    /// Fetch the profile list backing the switcher (`GET /api/profiles`) WHEN the
    /// `profiles` capability is `.available`; clears the cache (hiding the
    /// switcher) when it isn't, so a stock / pre-multi-profile gateway shows none
    /// of the switcher chrome. Fire-and-forget; a fetch failure leaves the prior
    /// cache untouched rather than flickering the switcher away.
    ///
    /// Called after the capability probe settles (post-connect / reconnect). On a
    /// stock gateway this short-circuits to clearing the cache without a network
    /// call (the probe already proved the route absent).
    func loadProfiles() async {
        guard connection?.capabilities.profiles == .available, let rest = connection?.rest else {
            profiles = []
            return
        }
        do {
            profiles = try await rest.profiles()
        } catch {
            // Keep the prior cache on a transient failure; don't flicker the gate.
        }
    }

    /// Select a profile scope from the switcher: persist ``activeProfile`` and
    /// refetch the rail so it reflects the new scope. Pass
    /// ``DefaultsKeys/allProfilesScope`` for the aggregate view or a profile name
    /// for a specific scope. A no-op when the value is unchanged.
    func selectProfile(_ scope: String) {
        guard scope != activeProfile else { return }
        activeProfile = scope
        // P4 PROFILE-switch policy: both profiles coexist in the cache, isolated
        // by profileId. Clear the in-memory list and re-arm the cold read so the
        // next refresh re-paints INSTANTLY from the new profile's cached rows
        // (option 1 — no clear, instant paint preserved) before the network
        // re-fetch reconciles. Without clearing `sessions`, the cold read's
        // `sessions.isEmpty` guard would skip the disk re-paint and the user
        // would see the OLD profile's rows until the network returns.
        sessions = []
        loadedCount = 0
        loadedOffset = 0
        loadedFloor = 0  // ABH review P2: don't carry the prior profile's high-water
                         // window into the new profile's first-page fetch (over-fetch).
        didColdReadCache = false
        Task { [weak self] in await self?.refresh() }
    }

    // MARK: - Activation

    /// Open (resume) an existing session: `session.resume` then seed the
    /// transcript into `ChatStore` from the full REST history.
    /// Monotonic token for the most recent `open()`; background work from a
    /// superseded open (the user tapped another session) checks it and bails.
    private var openToken = UUID()

    #if DEBUG
    /// DEBUG-only handle to the most recent open-seed Task. Stored so tests can
    /// `await` it without depending on wall-clock `settle()`. Set by `open()`
    /// before the seed Task is spawned; `nil` when no open is in flight.
    /// Never compiled into Release.
    private(set) var lastOpenSeedTask: Task<Void, Never>?

    /// DEBUG-only: await the most recently spawned open-seed Task, then yield
    /// once so any main-actor mutations it enqueued have a chance to propagate.
    /// Call this in tests INSTEAD OF (or after) `settle()` to deterministically
    /// wait for the seed to land without a wall-clock timeout.
    func waitForPendingOpenForTesting() async {
        await lastOpenSeedTask?.value
        // One additional cooperative yield so `@Observable` write propagations
        // that happen synchronously inside the seed Task's final await have
        // settled before the test asserts.
        await Task.yield()
    }
    #endif

    /// - Parameter revealOnFirstPaint: SMOOTHNESS R40 (Defect: "the transcript
    ///   moves before the chat-view layer on close"). When the drawer hands off a
    ///   row tap it passes its close here instead of firing it itself. We invoke
    ///   it exactly once, on the main actor, the moment the new transcript's FIRST
    ///   frame is painted (cache hit = the cached rows; miss = the empty skeleton)
    ///   — see ``seedTranscriptCacheFirst``. So the rigid close-slide uncovers
    ///   settled content instead of reconciling mid-slide. The prior order (FIX 4:
    ///   close on frame 0, async cache paint lands a frame later) let the content
    ///   swap land while the card was already moving — the reported desync.
    ///   Guarded by `openToken`, so a newer open()/draft that supersedes this tap
    ///   in the same window never fires a stale close. `nil` (the default, every
    ///   non-drawer caller) preserves the exact prior behavior.
    func open(_ summary: SessionSummary, revealOnFirstPaint: (@MainActor () -> Void)? = nil) {
        // Leaving any draft: opening a stored session is no longer a draft.
        isDraft = false
        // Per-session state belongs to the PREVIOUS session — clear it now so the
        // pill falls back to the global default instead of showing the last chat's
        // hot-swap (build-27 QA), and an abandoned draft's pended pick can't leak in.
        // The resume echo below re-seeds the truth. Kept SYNCHRONOUS on the tap tick:
        // it is only 6 cheap @Observable writes on the composer chip, and the build-27
        // contract (ModelVisibilityTests.testOpenClearsPreviousSessionPillState)
        // requires the pill to never flash the previous model — far cheaper than the
        // LazyVStack teardown, so it is NOT the switch-hitch cost FIX 4 targets.
        connection?.clearSessionState()
        // Activate instantly — the chat view can present right away with a loading
        // transcript instead of blocking navigation on the gateway. These pointers are
        // CHEAP and drive the drawer selection highlight + gate the composer + resolve
        // the seed's stored id, so they MUST land synchronously on the tap tick.
        let token = UUID()
        openToken = token
        activeRuntimeId = nil          // gates the composer until resume lands
        activeStoredId = summary.id
        // Fresh user intent to use this session: supersede any in-flight on-demand
        // re-resume (it was for the PREVIOUS session — its result must not bind
        // here) and reset the budget so a session that exhausted its retries
        // earlier can self-heal again.
        cancelEnsureRuntime()
        ensureRuntimeTargetId = summary.id
        ensureRuntimeAttempts = 0

        // FIX 4 — DEFER the heavy transcript teardown off the drawer-tap runloop tick
        // so the drawer-close spring (.spring response 0.40, RootView) owns the first
        // frame ALONE. `chat.reset()` is a WHOLESALE LazyVStack teardown — it empties
        // `messages`, dismantling every realized MessageBubble in one diff — which,
        // run synchronously, collided head-on with the spring's frame 0 and hitched
        // the switch (S2 dominant cost / ROOT B). Run it on the NEXT main-actor tick
        // instead: the spring's first frames render against the still-intact
        // (offscreen-displacing) OLD transcript rather than an emptied stack, and the
        // teardown + seed land a tick later when the spring is already moving. The
        // whole block is guarded by `openToken` so a newer open()/draft that
        // superseded this one in the same tick cancels the stale teardown+seed
        // (R1 #28/#43 — the existing supersession gate).
        //
        // CACHE-FIRST OPEN (WhatsApp bar — kills the white void): the cache read is
        // now the FIRST operation, and for a CACHE HIT it seeds the cached content
        // as a single in-place reconcile WITHOUT a preceding `reset()`. So the first
        // painted frame of the new session is the cached transcript — never the
        // empty stack the old `reset()`-then-seed ordering flashed (the open-race
        // that, combined with the network fetch, produced the 2.5–4s white void).
        // For a CACHE MISS the transcript IS reset to empty (so a stale prior
        // session's rows can't linger), which is the state ChatView renders as the
        // skeleton/placeholder until the network seed lands. The deferred network
        // fetch then reconciles in place over either starting point.
        let seedTask = Task { [weak self] in
            guard let self, self.openToken == token else { return }
            await self.seedTranscriptCacheFirst(
                storedId: summary.id, token: token, onFirstPaint: revealOnFirstPaint)
        }
        #if DEBUG
        lastOpenSeedTask = seedTask
        #endif

        // Slow path: gateway resume — spins up the agent server-side; only
        // prompt submission depends on it.
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                // Thread the active profile scope so a profile-scoped resume lands
                // in the right per-profile home. Omitted for the default/all scope
                // (and every dormant case) — byte-for-byte the shipped resume.
                var resumeParams: [String: JSONValue] = ["session_id": .string(summary.id)]
                self.applyProfileScope(to: &resumeParams)
                let result: SessionOpenResult = try await client.request(
                    "session.resume",
                    params: .object(resumeParams),
                    timeout: .seconds(120)
                )
                guard self.openToken == token else { return }  // superseded
                self.activeRuntimeId = result.sessionId
                // Confirm/seed the active-profile pref from the server's echo: the
                // WS path silently falls back to the launch profile on an unknown
                // name, so trust the echo over the requested scope.
                self.confirmActiveProfile(from: result.info)
                // Seed the composer pill (model/provider/reasoning/fast) from
                // the resume echo — the session's ACTUAL state (build-27 QA:
                // the pill showed the previous session's model until the
                // picker was opened).
                if let info = result.info { self.connection?.applyRuntimeInfo(info) }
                // Compression-chain projection: the gateway may resume a
                // newer continuation of this conversation — follow it.
                if let chainTip = result.storedSessionId, chainTip != summary.id {
                    // Re-stamp prompts queued under the parent id to the
                    // continuation BEFORE the swap, so drain's affinity guard
                    // doesn't skip them forever once activeStoredId moves.
                    self.onStoredIdMigrated?(summary.id, chainTip)
                    self.activeStoredId = chainTip
                    // Same token: the chain-tip seed's REST await is just as
                    // outrunnable by a newer open() as the fast path (R1 #43).
                    await self.seedTranscript(storedId: chainTip, token: token)
                    // Surface the chain-tip row in the drawer NOW rather than
                    // on the next 30s heartbeat (release audit P2).
                    Task { [weak self] in await self?.refresh() }
                }
                self.lastError = nil
                // Runtime bound: clear the self-heal budget and flush anything the
                // composer queued during this resume window (an idle desktop-driven
                // session emits no turn-completion to trigger a drain otherwise).
                // The drain no-ops while a foreign turn streams and is re-entrancy
                // guarded, so this is safe to fire unconditionally on a bind.
                self.ensureRuntimeAttempts = 0
                self.onActiveRuntimeBound?()
                // Seed the context-window meter from session.status so a resumed
                // session shows occupancy before its first new turn (H1). Runs
                // after the resume lands the runtime id; guarded against a newer
                // open inside ChatStore via the runtime-id check.
                await self.chat?.seedContextUsageFromStatus(runtimeId: result.sessionId)
            } catch {
                guard self.openToken == token else { return }
                self.lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Enter a fresh **draft** chat: drop the active session pointers, mark the
    /// store as drafting, and reset the transcript to empty. No RPC — the real
    /// session is created lazily on the first prompt (see ``createDraftSession()``
    /// / `ChatStore.send`). This is what "New chat" and launch land on, so an
    /// abandoned draft never litters the session list with an empty session.
    func startDraft() {
        // Supersede any in-flight `open()` so its resume can't reactivate, and any
        // on-demand re-resume so its result can't bind into this fresh draft.
        openToken = UUID()
        cancelEnsureRuntime()
        isDraft = true
        activeRuntimeId = nil
        activeStoredId = nil
        chat?.reset()
        chat?.seed(from: [])  // empty IS the (draft) transcript
        // A draft has NO session: drop the previous session's hot-swap state
        // (else the pill shows the LAST chat's model) and any stale draft pick.
        connection?.clearSessionState()
        lastError = nil
    }

    /// Materialize the current draft into a real session (`session.create`,
    /// 96 cols), activate it, and clear the draft flag. Called by `ChatStore.send`
    /// on the first prompt of a draft. Idempotent-ish: when not drafting (a real
    /// session is already active) it is a no-op success. Throws on RPC failure so
    /// the caller can keep the user's text and surface the error.
    ///
    /// Unlike `open`/`refresh`, this does NOT reset the transcript: the caller
    /// (`send`) has already appended the user's bubble, and a brand-new session's
    /// empty server history would otherwise wipe it.
    func createDraftSession() async throws {
        guard isDraft else { return }
        guard let client else { throw GatewayError.notConnected }
        isLoading = true
        defer { isLoading = false }
        do {
            // Attach the active profile scope so a new session is created in the
            // selected per-profile home. Omitted for the default/all scope (and
            // every dormant case) — byte-for-byte the shipped create.
            var createParams: [String: JSONValue] = ["cols": .number(96)]
            applyProfileScope(to: &createParams)
            let result: SessionOpenResult = try await client.request(
                "session.create",
                params: .object(createParams),
                timeout: .seconds(120)
            )
            activeRuntimeId = result.sessionId
            activeStoredId = result.storedSessionId ?? result.sessionId
            isDraft = false
            confirmActiveProfile(from: result.info)
            // Seed the pill from the create echo (the fresh session's actual
            // defaults) — the draft pick below then overrides via config.set
            // + the session.info event.
            if let info = result.info { connection?.applyRuntimeInfo(info) }
            // Apply any model pick made while drafting BEFORE the caller
            // (`ChatStore.send`) submits the first prompt — `config.set
            // key=model` builds the session agent, so even the FIRST turn runs
            // on the chosen model (ABH-84 draft-mode pick). Best-effort: a
            // failure must not block the message.
            await connection?.applyDraftSelection(sessionId: result.sessionId)
            lastError = nil
            // Refresh the list in the background so the new row appears in the
            // drawer; don't block the prompt submission on it.
            Task { [weak self] in await self?.refresh() }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    /// Eagerly create a brand-new session **now** and activate it with an empty
    /// transcript, so `activeRuntimeId` is non-nil the instant this returns.
    ///
    /// - Important: **Programmatic flows only.** Interactive "New chat" must use
    ///   ``startDraft()`` so an abandoned new chat doesn't litter the session
    ///   list with an empty session (`ChatStore.send` materializes the draft on
    ///   the first prompt). This eager entry point exists for *programmatic*
    ///   create-then-immediately-send callers — App Intents `.ask`/`.newSession`,
    ///   the share-extension drainer, Quick Capture — that depend on
    ///   `activeRuntimeId` being set right after the call. It is built on
    ///   ``startDraft()`` + ``createDraftSession()`` so it shares one create path.
    func createSessionNow() async throws {
        startDraft()
        try await createDraftSession()
    }

    /// Branch-in-new-chat (F4A-A2): create a brand-new session SEEDED with the
    /// given history (`messages[]`), activate it, and seed the transcript from
    /// the server's coerced echo so the new chat opens showing the history up to
    /// the branch point.
    ///
    /// There is NO server fork RPC; this rides the EXISTING `session.create` seed
    /// path (`server.py:3022`). The gateway's `_coerce_seed_history`
    /// (`server.py:2917`) accepts only `{role ∈ user/assistant/system, non-empty
    /// content}` items and normalizes them to `{role, content}` — the caller
    /// (`ChatStore.branchSeed`) already produced that exact shape, so every item
    /// survives. The response echoes the coerced `messages`, which we seed so the
    /// transcript matches what the agent will actually see.
    ///
    /// - Parameters:
    ///   - seed: the `messages[]` array from `ChatStore.branchSeed(upToMessageId:)`.
    ///   - cwd: optional working directory to start the branch in (defaults to
    ///     the gateway's `TERMINAL_CWD`/cwd when nil).
    /// - Returns: the new runtime/stored ids so the caller can land the UI.
    @discardableResult
    func branchSession(seed: [JSONValue], cwd: String?) async throws
        -> (runtimeId: String, storedId: String) {
        guard let client else { throw GatewayError.notConnected }
        isLoading = true
        defer { isLoading = false }
        var params: [String: JSONValue] = [
            "cols": .number(96),
            "messages": .array(seed),
        ]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        // Branch into the active profile scope (same conditional spot as `cwd`).
        applyProfileScope(to: &params)
        do {
            // Use the raw result so we can read the coerced `messages` echo
            // alongside the ids (the typed `SessionOpenResult` drops `messages`).
            let response = try await client.requestRaw(
                "session.create",
                params: .object(params),
                timeout: .seconds(120)
            )
            guard let runtimeId = response["session_id"]?.stringValue else {
                throw GatewayError.notConnected
            }
            let storedId = response["stored_session_id"]?.stringValue ?? runtimeId
            // Activate the new branch.
            activeRuntimeId = runtimeId
            activeStoredId = storedId
            isDraft = false
            // Branching is reachable while the OLD session's adopted foreign
            // mirror is still live ("does not interrupt the current turn"),
            // and `seed()` rightly refuses to wipe a live mirror (R1 #61) —
            // but the mirror belongs to the session we just LEFT. Reset first
            // (mirrors `open()`'s reset-then-seed) so the branch's transcript
            // actually lands instead of the old mirror squatting under the
            // new session's ids.
            chat?.reset()
            // Seed the transcript from the server's coerced echo (falls back to an
            // empty seed if the response omitted `messages`).
            let seeded = response["messages"]?.arrayValue?
                .compactMap(StoredMessage.init(json:)) ?? []
            chat?.seed(from: seeded)
            lastError = nil
            Task { [weak self] in await self?.refresh() }
            return (runtimeId, storedId)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    /// Land the UI on a session that was just created+sent-into programmatically
    /// (the share-extension drainer / quick capture). This is the **non-destructive**
    /// counterpart to ``open(_:)``: when the target is *already* the active session
    /// — the normal case after a serial create-then-send batch — it leaves the live
    /// transcript and any in-flight stream untouched (no `chat.reset()` / re-seed
    /// that would clobber the just-submitted prompt). Only when the active pointer
    /// has drifted away (e.g. a concurrent push tap opened something else mid-drain)
    /// does it fall back to a full resume via ``open(_:)``, refreshing the list to
    /// resolve the summary if the brand-new row hasn't synced yet.
    ///
    /// Pass the ids captured from the create (``activeStoredId`` / ``activeRuntimeId``
    /// right after ``createSessionNow()``). A `nil`/empty `storedId` is a no-op.
    func land(storedId: String?, runtimeId: String?) {
        guard let storedId, !storedId.isEmpty else { return }
        // Already parked on it (serial drain, last-write-wins): do nothing so the
        // live transcript / streaming response is preserved.
        if storedId == activeStoredId {
            isDraft = false
            // Refresh the runtime pointer if the caller has a newer one (it won't
            // normally differ, but keep them consistent without touching the chat).
            if let runtimeId, !runtimeId.isEmpty { activeRuntimeId = runtimeId }
            return
        }
        // Drifted elsewhere — resume the target through the standard open path.
        if let summary = sessions.first(where: { $0.id == storedId }) {
            open(summary)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            if let summary = self.sessions.first(where: { $0.id == storedId }) {
                self.open(summary)
            }
        }
    }

    /// Delete a session (`session.delete`). Clears the active pointers and the
    /// transcript if the deleted session was active.
    ///
    /// ABH-73 fix — three correctness changes over the old swallow-the-throw body:
    /// 1. **Interrupt + close the app's own live session first.** Every session
    ///    the app opens is registered live server-side (via `session.resume`), so
    ///    a plain `session.delete` used to hit the server's `4023` "active
    ///    session" guard and fail. If the row being deleted is the one this app
    ///    holds open, we (a) interrupt the in-flight turn (RIDER — stop an
    ///    orphaned runtime from spending tokens) and (b) send `session.close`
    ///    (RUNTIME id) to evict it cleanly, THEN delete. `session.close` is
    ///    best-effort: the server now auto-evicts regardless, so a close failure
    ///    does not block the delete.
    /// 2. **Failures are surfaced, not swallowed.** On a `session.delete` error
    ///    the row stays put and ``sessionActionError`` is populated so the drawer
    ///    can show an alert.
    /// 3. The `session.delete` payload keys on the STORED id (`summary.id`); the
    ///    `session.close` payload keys on the RUNTIME id (`activeRuntimeId`).
    func delete(_ summary: SessionSummary) async {
        guard let send = resolvedRPCSend else { return }

        // (1) For the session this app holds open, interrupt the in-flight turn
        //     then evict it server-side so the delete doesn't trip the live
        //     guard. Best-effort: the server auto-evicts even if these are
        //     skipped, so neither blocks the delete attempt.
        let isActive = summary.id == activeStoredId || summary.id == activeRuntimeId
        if isActive {
            // RIDER: stop the actively-streaming runtime before tearing it down.
            await resolvedInterruptActive()
            if let runtimeId = activeRuntimeId, !runtimeId.isEmpty {
                do {
                    _ = try await send(
                        "session.close",
                        .object(["session_id": .string(runtimeId)])
                    )
                } catch {
                    // Best-effort close; the server still auto-evicts on delete.
                    lastError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            // Drop the local pointers now: the runtime is being torn down and
            // the transcript belongs to a session about to be deleted.
            clearActive()
        }

        // (2) Delete keys on the STORED id.
        do {
            _ = try await send(
                "session.delete",
                .object(["session_id": .string(summary.id)])
            )
            sessions.removeAll { $0.id == summary.id }
            if pinnedIds.remove(summary.id) != nil { persistPins() }
            // `clearActive()` already ran above for the active case; this covers
            // the rare drift where only the runtime id matched.
            if summary.id == activeStoredId || summary.id == activeRuntimeId {
                clearActive()
            }
            lastError = nil
            sessionActionError = nil
        } catch {
            // Do NOT remove the row; surface the failure so the user sees it.
            let message = errorMessage(from: error)
            lastError = message
            sessionActionError = SessionActionError(action: "Delete", message: message)
        }
    }

    /// Detach from the active session locally (no RPC). Used when the active
    /// session disappears or the user backs out to the list.
    func closeActive() async {
        clearActive()
    }

    // MARK: - Reconnect support

    /// Re-resume the active session after a reconnect, refreshing the runtime
    /// id (a new connection assigns a new `session_id`). Returns the new runtime
    /// id on success, or `nil` if there is no active session to resume.
    @discardableResult
    func resumeActiveAfterReconnect() async -> String? {
        guard let storedId = activeStoredId, client != nil || resumeRPC != nil else { return nil }
        do {
            // Re-resume into the same profile scope so a reconnect keeps the
            // session in its per-profile home. Omitted for the default/all scope.
            var resumeParams: [String: JSONValue] = ["session_id": .string(storedId)]
            applyProfileScope(to: &resumeParams)
            let result: SessionOpenResult
            if let resumeRPC {
                result = try await resumeRPC(storedId, resumeParams)
            } else if let client {
                result = try await client.request(
                    "session.resume",
                    params: .object(resumeParams),
                    timeout: .seconds(120)
                )
            } else {
                return nil
            }
            // SUPERSESSION GUARD: the active session may have changed across the
            // (up to 120 s) resume await — the user tapped another drawer row
            // (`open`), started a draft, or cleared the active session. Do NOT
            // clobber the now-active session's pointers with this stale resume's
            // result; otherwise a live send would misroute into the resumed
            // session (the R1 #17 class, on the un-affinity-guarded live path).
            // Mirrors open()'s `openToken` re-check after its own resume await.
            guard activeStoredId == storedId else { return nil }
            activeRuntimeId = result.sessionId
            // A resume can follow a compression chain tip (parent → continuation);
            // re-stamp queued prompts so affinity-stamped ones aren't skipped forever.
            let newStored = result.storedSessionId ?? storedId
            if newStored != storedId { onStoredIdMigrated?(storedId, newStored) }
            activeStoredId = newStored
            confirmActiveProfile(from: result.info)
            // Keep the composer pill session-true on this resume path too.
            if let info = result.info { connection?.applyRuntimeInfo(info) }
            return result.sessionId
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Ensure the active session has a live runtime id, re-resuming on demand when
    /// a prior resume failed/timed-out and left `activeRuntimeId` nil. This is the
    /// escape edge out of the "No active session" trap: a desktop-driven session
    /// whose gateway resume took the slow cold path (or timed out) leaves every
    /// `ChatStore.send` AND queue `drain` wedged with no path back to a runtime —
    /// nothing on the send/drain path re-attempts the resume. `ChatStore.send`
    /// calls this before surfacing "No active session", so the session self-heals
    /// instead of staying stuck. Concurrent callers (a live send and a drain
    /// racing) coalesce onto one RPC; bounded per session so it can't spin.
    /// Returns the bound runtime id, or `nil` if there is nothing to resume or the
    /// attempt budget is exhausted.
    @discardableResult
    func ensureActiveRuntime() async -> String? {
        if let rid = activeRuntimeId { return rid }
        if let task = ensureRuntimeTask { return await task.value }
        guard client != nil || resumeRPC != nil, let target = activeStoredId else { return nil }
        // Reset the budget when the target session changes; cap per session.
        if ensureRuntimeTargetId != target {
            ensureRuntimeTargetId = target
            ensureRuntimeAttempts = 0
        }
        guard ensureRuntimeAttempts < Self.maxEnsureRuntimeAttempts else { return nil }
        ensureRuntimeAttempts += 1
        let task = Task { [weak self] () -> String? in
            // resumeActiveAfterReconnect re-resumes `activeStoredId`, binds the
            // runtime, follows the chain tip (re-stamping the queue), and seeds the
            // pill — exactly the work needed here.
            await self?.resumeActiveAfterReconnect()
        }
        ensureRuntimeTask = task
        let rid = await task.value
        ensureRuntimeTask = nil
        if rid != nil {
            ensureRuntimeAttempts = 0
            // A runtime just bound — flush anything the composer queued while it
            // was nil (the drain re-entrancy guard makes a redundant call a no-op).
            onActiveRuntimeBound?()
        }
        return rid
    }

    // MARK: - Search

    /// React to a change in `searchQuery` from the `.searchable` field. Debounces
    /// 300ms, then tries the plugin endpoint first with graceful fallback to the
    /// stock `/api/sessions/search` on 404 (older gateways without the plugin).
    /// Queries under two characters clear the results immediately.
    /// Call from the view's `onChange(of:)`.
    func searchQueryChanged() {
        searchTask?.cancel()
        // Cancel any in-flight load-more from the previous query.
        searchLoadMoreTask?.cancel()
        searchLoadMoreTask = nil

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            isSearching = false
            searchOffset = 0
            searchHasMore = false
            return
        }
        #if DEBUG
        let apiOrNil: RestClient? = restAPI
        // Allow the seam to bypass the restAPI requirement in tests.
        guard apiOrNil != nil || searchFetch != nil else {
            searchResults = []
            return
        }
        #else
        guard let api = restAPI else {
            searchResults = []
            return
        }
        #endif

        // Reset pagination state for the new query and bump the generation so
        // any stale load-more page from the prior query is discarded on arrival.
        searchOffset = 0
        searchHasMore = false
        searchGeneration &+= 1
        let generation = searchGeneration

        searchTask = Task { [weak self] in
            // Debounce.
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            guard let self else { return }
            self.isSearching = true
            defer { self.isSearching = false }
            do {
                #if DEBUG
                let (results, servedByPlugin): ([SessionSearchResult], Bool)
                if let seam = self.searchFetch {
                    (results, servedByPlugin) = try await seam(trimmed, 0)
                } else if let api = apiOrNil {
                    (results, servedByPlugin) = try await self.fetchSearch(
                        query: trimmed, offset: 0, api: api
                    )
                } else {
                    return
                }
                #else
                let (results, servedByPlugin) = try await self.fetchSearch(
                    query: trimmed, offset: 0, api: api
                )
                #endif
                if Task.isCancelled { return }
                // Guard against a stale response landing after the user typed on.
                guard self.searchGeneration == generation else { return }
                self.searchResults = results
                self.searchOffset = results.count
                // Plugin path does not support load-more (no offset param); force
                // false so the DrawerView sentinel never fires load-more there.
                // Stock path: a full page means more may exist; short = done.
                self.searchHasMore = !servedByPlugin
                    && results.count == Self.searchPageLimit
                    && self.searchOffset < Self.searchOffsetCap
                self.lastError = nil
            } catch {
                if Task.isCancelled { return }
                self.searchResults = []
                self.lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Append the next page of search results for the active query.
    ///
    /// No-op when: already loading more, last page was short, offset has reached
    /// the server cap, or no active query. Guards against stale pages from a
    /// prior query via the `searchGeneration` counter.
    func loadMoreSearchResults() {
        guard searchHasMore,
              !isSearchLoadingMore,
              !isSearching,
              searchOffset < Self.searchOffsetCap else { return }
        #if DEBUG
        let apiForMore: RestClient? = restAPI
        guard apiForMore != nil || searchFetch != nil else { return }
        #else
        guard let api = restAPI else { return }
        #endif
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        let offset = searchOffset
        let generation = searchGeneration

        searchLoadMoreTask?.cancel()
        searchLoadMoreTask = Task { [weak self] in
            guard let self else { return }
            self.isSearchLoadingMore = true
            defer { self.isSearchLoadingMore = false }
            do {
                #if DEBUG
                let (page, servedByPlugin): ([SessionSearchResult], Bool)
                if let seam = self.searchFetch {
                    (page, servedByPlugin) = try await seam(trimmed, offset)
                } else if let api = apiForMore {
                    (page, servedByPlugin) = try await self.fetchSearch(
                        query: trimmed, offset: offset, api: api
                    )
                } else {
                    return
                }
                #else
                let (page, servedByPlugin) = try await self.fetchSearch(
                    query: trimmed, offset: offset, api: api
                )
                #endif
                if Task.isCancelled { return }
                // Discard if the user changed the query while this was in flight.
                guard self.searchGeneration == generation else { return }
                // Append, deduplicating by session id in case the result window
                // shifted between the first and second page requests.
                let existingIds = Set(self.searchResults.map(\.id))
                let fresh = page.filter { !existingIds.contains($0.id) }
                self.searchResults.append(contentsOf: fresh)
                self.searchOffset = offset + page.count
                // Same plugin-guard as the initial fetch: force false on plugin path.
                self.searchHasMore = !servedByPlugin
                    && page.count == Self.searchPageLimit
                    && self.searchOffset < Self.searchOffsetCap
            } catch {
                if Task.isCancelled { return }
                // Leave existing results intact; a load-more failure is silent
                // (the user can scroll back up and the list is still readable).
            }
        }
    }

    /// Execute the search against the best available endpoint: plugin first (richer
    /// results + role-scoped), stock on 404 (older gateways). Only falls back on a
    /// true 404/not-found — real 500/transport errors are re-thrown so they surface
    /// as `lastError` and are not silently masked.
    ///
    /// `offset` is forwarded only to the stock endpoint — the plugin does not yet
    /// support pagination, so it always fetches from offset 0.
    ///
    /// Returns `(results, servedByPlugin)` so callers can gate `searchHasMore`
    /// correctly: the plugin path does not support load-more, so `searchHasMore`
    /// must be forced to `false` when `servedByPlugin` is true regardless of page
    /// size. This prevents the DrawerView sentinel from spinning on the plugin path.
    ///
    /// Extracted so tests can call it directly without spinning a Task.
    func fetchSearch(
        query: String, offset: Int = 0, api: RestClient
    ) async throws -> (results: [SessionSearchResult], servedByPlugin: Bool) {
        let roles = Self.roles(for: searchScope)
        do {
            // Plugin path: no offset support — always fetches page 1 at limit 20.
            // Unified limit matches searchPageLimit so the hasMore comparison is
            // coherent if pagination is ever added to the plugin later.
            let results = try await api.searchSessionsPlugin(
                query: query, limit: Self.searchPageLimit, roles: roles
            )
            return (results, true)
        } catch RestError.badStatus(404, _) {
            // Plugin endpoint not available on this gateway — fall back to stock.
            let results = try await api.searchSessions(
                query: query, limit: Self.searchPageLimit, offset: offset,
                scope: searchScope.rawValue
            )
            return (results, false)
        }
        // Any other error (500, transport, decode) propagates to the caller.
    }

    /// Map the UI search scope to a list of `role` values for the plugin endpoint.
    /// `all` sends no filter (server returns every role); `messages` returns user +
    /// assistant prose; `code` returns tool output.
    static func roles(for scope: SearchScope) -> [String] {
        switch scope {
        case .all:      return []
        case .messages: return ["user", "assistant"]
        case .code:     return ["tool"]
        }
    }

    /// Open a session from a search result. If the session is already in the
    /// loaded list, prefer its richer row; otherwise synthesize one from the
    /// result. Clears the search UI so the chat takes over.
    func open(searchResult result: SessionSearchResult) {
        let summary = sessions.first(where: { $0.id == result.id }) ?? result.asSessionSummary
        // Remember the query so ChatView scrolls to its first occurrence once
        // the transcript loads (jump-to-match). Captured BEFORE clearSearch()
        // wipes searchQuery.
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        clearSearch()
        pendingSearchScroll = q.isEmpty ? nil : q
        open(summary)
    }

    /// Cancel any in-flight search (and load-more) and reset the search UI state.
    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchLoadMoreTask?.cancel()
        searchLoadMoreTask = nil
        searchQuery = ""
        searchResults = []
        isSearching = false
        isSearchLoadingMore = false
        searchHasMore = false
        searchOffset = 0
    }

    // MARK: - Pins

    /// Toggle the pinned state of a session and persist the pin set.
    func togglePin(_ summary: SessionSummary) {
        if pinnedIds.contains(summary.id) {
            pinnedIds.remove(summary.id)
        } else {
            pinnedIds.insert(summary.id)
        }
        persistPins()
    }

    private func persistPins() {
        UserDefaults.standard.set(Array(pinnedIds), forKey: DefaultsKeys.pinnedSessions)
    }

    // MARK: - Rename

    /// Rename a session via `PATCH {title}` and update the row in place with the
    /// title the server actually stored. An empty `title` clears it server-side.
    func rename(_ summary: SessionSummary, to title: String) async {
        guard let api = restAPI else {
            lastError = "Not connected."
            sessionActionError = SessionActionError(action: "Rename", message: "Not connected.")
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let stored = try await api.renameSession(id: summary.id, title: trimmed)
            replaceRow(id: summary.id) { current in
                // Carry `current.profile` through the rebuild (F4b polish) so a
                // rename doesn't drop the row's profile tag in the aggregate view
                // before the next rail re-fetch re-tags it.
                SessionSummary(
                    id: current.id,
                    title: stored.isEmpty ? nil : stored,
                    preview: current.preview,
                    startedAt: current.startedAt,
                    messageCount: current.messageCount,
                    source: current.source,
                    lastActive: current.lastActive,
                    cwd: current.cwd,
                    profile: current.profile
                )
            }
            lastError = nil
            sessionActionError = nil
        } catch {
            let message = errorMessage(from: error)
            lastError = message
            sessionActionError = SessionActionError(action: "Rename", message: message)
        }
    }

    // MARK: - Archive

    /// Archive a session via `PATCH {archived: true}` and drop it from the list
    /// (and the active pointers if it was open). The default list query excludes
    /// archived sessions, so the removal also survives the next refresh.
    func archive(_ summary: SessionSummary) async {
        guard let api = restAPI else {
            lastError = "Not connected."
            sessionActionError = SessionActionError(action: "Archive", message: "Not connected.")
            return
        }
        do {
            try await api.setSessionArchived(id: summary.id, archived: true)
            sessions.removeAll { $0.id == summary.id }
            if pinnedIds.remove(summary.id) != nil { persistPins() }
            if summary.id == activeStoredId || summary.id == activeRuntimeId {
                clearActive()
            }
            lastError = nil
            sessionActionError = nil
        } catch {
            let message = errorMessage(from: error)
            lastError = message
            sessionActionError = SessionActionError(action: "Archive", message: message)
        }
    }

    // MARK: - Archived sessions (ABH-80 item 5)

    /// The most-recently-loaded archived sessions, backing ``ArchivedSessionsView``.
    /// Populated by ``loadArchived(limit:)``; empty until that is called. Not
    /// persisted — the view re-fetches on appear. Exposed as `var` (not
    /// `private(set)`) so unit tests can inspect / seed it directly.
    var archivedSessions: [SessionSummary] = []

    /// Injectable seam for the `GET /api/sessions?archived=only` fetch. Mirrors
    /// ``transcriptFetch``'s injection idiom: `nil` resolves the live `restAPI`;
    /// tests inject a closure that answers with a preset list or throws.
    var archivedFetch: ((Int) async throws -> [SessionSummary])?

    /// Fetch `GET /api/sessions?archived=only` and store the result in
    /// ``archivedSessions``. A failure clears the list and surfaces the error
    /// message via ``lastError`` (non-destructive — the main session list is
    /// untouched). Mirroring ``refresh()``'s fire-and-forget approach: callers
    /// can `await` this directly or wrap it in `Task {}` for `.task` modifiers.
    func loadArchived(limit: Int = 100) async {
        guard let fetch = resolvedArchivedFetch else {
            lastError = "Not connected."
            archivedSessions = []
            return
        }
        do {
            archivedSessions = try await fetch(limit)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            archivedSessions = []
        }
    }

    /// The injected ``archivedFetch``, or the default that resolves the live REST
    /// client. `nil` when there is no configured connection (unconfigured store).
    private var resolvedArchivedFetch: ((Int) async throws -> [SessionSummary])? {
        if let archivedFetch { return archivedFetch }
        guard let api = restAPI else { return nil }
        return { limit in try await api.archivedSessions(limit: limit) }
    }

    /// Unarchive (restore) a session from the Archived Chats surface: PATCH
    /// `{ archived: false }` and remove the row from ``archivedSessions``. On
    /// failure the row stays and ``sessionActionError`` is populated, mirroring
    /// the archive/rename/delete error surface (ABH-73 pattern).
    func unarchive(_ summary: SessionSummary) async {
        guard let api = restAPI else {
            lastError = "Not connected."
            sessionActionError = SessionActionError(action: "Unarchive", message: "Not connected.")
            return
        }
        do {
            try await api.setSessionArchived(id: summary.id, archived: false)
            archivedSessions.removeAll { $0.id == summary.id }
            lastError = nil
            sessionActionError = nil
            // Re-surface the session in the main list on the next refresh.
            Task { [weak self] in await self?.refresh() }
        } catch {
            let message = errorMessage(from: error)
            lastError = message
            sessionActionError = SessionActionError(action: "Unarchive", message: message)
        }
    }

    // MARK: - Export

    /// Fetch `/api/sessions/{id}/export` and render it to a Markdown transcript
    /// for `ShareLink` / share sheet. Returns `nil` (and sets `lastError`) on
    /// failure so the caller can skip presenting the share UI.
    func exportMarkdown(_ summary: SessionSummary) async -> String? {
        guard let api = restAPI else {
            lastError = "Not connected."
            return nil
        }
        do {
            let markdown = try await api.exportSessionMarkdown(id: summary.id)
            lastError = nil
            return markdown
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Live-activity registry

    /// Stamp "now" against a *stored* session id, marking its row live for the
    /// next ``liveWindow`` seconds. Called by `ConnectionStore`'s event router on
    /// streaming frames (`message.start`/`message.delta`/…). The caller resolves
    /// the stored id: it's the frame's `stored_session_id` for broadcast/mirror
    /// frames, or — for our own active runtime turn — `activeStoredId`. A `nil`
    /// or empty id is ignored. Starts the prune task on the first entry.
    func noteActivity(storedSessionId: String?) {
        guard let id = storedSessionId, !id.isEmpty else { return }
        // FIX 6a — COALESCE the per-delta stamp. `lastActivityAt` is a TRACKED
        // @Observable property and the drawer is ALWAYS mounted behind the chat card
        // (RootView), reading it per visible row via `isLive(_:)`. Writing it on every
        // streaming delta (a long turn is ~168 frames) therefore invalidated the whole
        // drawer body ~25×/sec for the entire turn — pure main-actor load that deepens
        // the S1/S4 contention. A delta only needs to keep the row's "live" dot lit,
        // and the live window is 10s, so a sub-`liveStampCoalesce` re-stamp changes
        // nothing observable: SKIP the write when the last stamp for this id is within
        // the coalesce interval. This is a WRITE-SKIP (a value compare, not a timer):
        // the FIRST delta of a turn stamps immediately (dot lights at once) and only
        // the high-frequency repeats are dropped. `message.start`/`message.complete`
        // re-stamp regardless (they are ≥ the interval apart in practice). The skip
        // map is @ObservationIgnored so consulting it never itself triggers a
        // drawer invalidation.
        let now = Date()
        if let last = lastActivityStampAt[id],
           now.timeIntervalSince(last) < Self.liveStampCoalesce {
            return
        }
        lastActivityStampAt[id] = now
        lastActivityAt[id] = now
        startLiveCleanupIfNeeded()
    }

    /// Whether `summary`'s row should pulse: its conversation saw broadcast
    /// activity within the last ``liveWindow`` seconds.
    func isLive(_ summary: SessionSummary) -> Bool {
        isLive(storedSessionId: summary.id)
    }

    /// Whether a stored session id is currently within the live window.
    func isLive(storedSessionId id: String) -> Bool {
        guard let at = lastActivityAt[id] else { return false }
        return Date().timeIntervalSince(at) < Self.liveWindow
    }

    /// Run a lightweight repeating prune (every ``liveWindow`` seconds) that
    /// drops expired entries so dots fade out and the dictionary stays small.
    /// Self-cancels when the registry empties; restarted on the next stamp.
    private func startLiveCleanupIfNeeded() {
        guard liveCleanupTask == nil else { return }
        liveCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.liveWindow))
                guard let self, !Task.isCancelled else { return }
                let cutoff = Date().addingTimeInterval(-Self.liveWindow)
                self.lastActivityAt = self.lastActivityAt.filter { $0.value > cutoff }
                // Keep the coalesce shadow in lock-step so it cannot grow unbounded
                // and a re-activated id past the window stamps immediately (FIX 6a).
                self.lastActivityStampAt = self.lastActivityStampAt.filter { $0.value > cutoff }
                if self.lastActivityAt.isEmpty {
                    self.liveCleanupTask = nil
                    return
                }
            }
        }
    }

    // MARK: - Profile threading helpers (F4b)

    /// Add the `"profile"` param to a `session.create`/`session.resume` params dict
    /// ONLY when a specific non-default profile scope is active AND multi-profile
    /// is available. For the default/all scope — and every dormant / stock-gateway
    /// case — this is a no-op, so the WS create/resume payload is byte-for-byte the
    /// shipped single-profile shape. The single gate for create/resume threading.
    private func applyProfileScope(to params: inout [String: JSONValue]) {
        if let name = Self.profileParam(scope: activeProfile, multiAvailable: isMultiProfileAvailable) {
            params["profile"] = .string(name)
        }
    }

    /// Pure decision for create/resume profile threading: the `profile` value to
    /// attach, or `nil` to omit it. Returns a name ONLY when multi-profile is
    /// available AND the scope is a specific non-default, non-aggregate profile —
    /// the default/all scope and every dormant case omit the param (byte-for-byte
    /// the shipped single-profile payload). Factored out (and `internal`) so the
    /// threading gate is unit-testable without a live connection.
    static func profileParam(scope: String, multiAvailable: Bool) -> String? {
        guard multiAvailable else { return nil }
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != DefaultsKeys.allProfilesScope,
              trimmed != defaultProfileName else { return nil }
        return trimmed
    }

    /// Confirm/seed the active-profile pref from a create/resume `info` echo. The
    /// WS path silently falls back to the launch profile on an unknown name
    /// (`_profile_home` swallows resolver failures), so the server's echoed
    /// `profileName` is the authority over the requested scope. Only adopts a
    /// non-empty, non-`default` echo when multi-profile is available and the value
    /// actually differs, so a default-home session never clobbers an "all" scope.
    private func confirmActiveProfile(from info: SessionRuntimeInfo?) {
        guard isMultiProfileAvailable,
              let echoed = info?.profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !echoed.isEmpty,
              echoed != Self.defaultProfileName,
              echoed != activeProfile else { return }
        activeProfile = echoed
    }

    // MARK: - Helpers

    /// Replace a row in `sessions` in place, preserving its position.
    private func replaceRow(id: String, _ transform: (SessionSummary) -> SessionSummary) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index] = transform(sessions[index])
    }

    private func clearActive() {
        // Supersede any in-flight on-demand re-resume so it can't re-bind a runtime
        // into a session we're detaching from.
        cancelEnsureRuntime()
        isDraft = false
        activeRuntimeId = nil
        activeStoredId = nil
        chat?.reset()
    }

    /// Injectable seam for the session-list fetch. `nil` resolves the live
    /// `connection?.rest` path (same as the existing `refresh()` body); tests
    /// inject a closure that answers with a preset list (or throws) without a
    /// live gateway. The closure returns a tuple of `(sessions, total?)` so
    /// tests can also verify that `totalSessions` is decoded and exposed.
    var sessionsFetch: (() async throws -> (sessions: [SessionSummary], total: Int?))?

    /// Injectable seam for the initial-fill grow-limit loop (Bug B). Each call
    /// pops the next page from the array, letting tests stage multiple pages
    /// without a live REST client. `nil` = live REST path. The closure receives
    /// the requested `limit` so tests can assert on grow-limit semantics.
    var initialFillFetch: ((Int) async throws -> (sessions: [SessionSummary], total: Int?))?

    /// REST fetch backing ``seedTranscript(storedId:token:)``, injected for
    /// tests (mirrors `ChatStore.backfillFetch`). In the app it resolves the
    /// live `connection?.rest` lazily on each call.
    var transcriptFetch: ((String) async throws -> [StoredMessage])?

    /// CACHE-FIRST session open (WhatsApp bar — kills the white void).
    ///
    /// The cold-open seed for ``open(_:)``. It reads the local cache FIRST and:
    ///   - CACHE HIT → seeds the cached transcript as a single in-place reconcile
    ///     with NO preceding `reset()`, so the cached content is the FIRST painted
    ///     frame of the new session (no empty-stack flash — the open-race that fed
    ///     the 2.5–4s white void). The drawer-close spring renders against the
    ///     displaced old transcript, then snaps to the cached content atomically.
    ///   - CACHE MISS → `reset()`s to an empty transcript (so a stale prior
    ///     session's rows can't linger), which ChatView renders as the
    ///     theme-consistent skeleton until the network seed lands. NEVER white.
    ///
    /// Then it runs the network fetch and reconciles in place over either starting
    /// point (identity-preserving — no remount, no flicker). `token` is the
    /// ``openToken`` re-checked after every await so a newer open/draft supersedes
    /// a stale seed (R1 #28/#43).
    private func seedTranscriptCacheFirst(
        storedId: String, token: UUID, onFirstPaint: (@MainActor () -> Void)? = nil
    ) async {
        // R40 reveal-on-paint: fire the caller's reveal (drawer close) exactly
        // once, after phase 1 lands the first frame — even on the early-out paths
        // below, so a missing `chat` can never strand the drawer open.
        var firstPaintSignalled = false
        func signalFirstPaint() {
            guard !firstPaintSignalled else { return }
            firstPaintSignalled = true
            if openToken == token { onFirstPaint?() }
        }
        guard let chat else { signalFirstPaint(); return }

        #if DEBUG
        // OPEN→PAINTED LATENCY instrumentation (WhatsApp bar): measure where the
        // open cost goes — disk read vs REST round-trip vs paint — so the 2.5–4s
        // white void is quantified, not guessed. DEBUG-only; absent in Release.
        let openClock = ContinuousClock.now
        #endif

        // Phase 1 — cache paint (or reset on miss). The cron-only sessions are
        // never transcript-cached (CacheStore guards the write), so this misses
        // for them and the network fetch is the sole seed. No cache (tests/
        // previews) ⇒ treated as a miss (reset), network-only path preserved.
        var paintedFromCache = false
        if let cacheStore {
            // `touchSession` bumps `lastAccessedAt` so an actively-opened session
            // never ages out of the eviction horizon.
            try? await cacheStore.touchSession(storedId)
            if openToken == token,           // not superseded while reading disk
               (try? await cacheStore.hasTranscript(storedId)) == true,
               openToken == token,
               let cached = try? await cacheStore.loadTranscript(storedId),
               openToken == token {          // re-check after every await
                // ARCH37 STEP 2 — normalize the cached rows OFF main, hop to main
                // only for the in-place reconcile (the FIRST painted frame).
                let normalized = await Self.normalizeOffMain(cached)
                guard openToken == token else { return }
                chat.seed(normalized: normalized)  // in-place reconcile — FIRST frame
                paintedFromCache = true
            }
        }
        if !paintedFromCache, openToken == token {
            // Cache miss (or no cache): empty the transcript so ChatView shows the
            // skeleton, not a stale prior session's rows, while the network loads.
            chat.reset()
        }
        #if DEBUG
        Self.logOpenLatency(
            phase: paintedFromCache ? "cache-paint(HIT)" : "cache-miss(reset)",
            storedId: storedId, since: openClock)
        #endif

        // Phase 1 done — the new session's first frame is on screen. Reveal it:
        // the drawer (if it handed us its close) slides away NOW, uncovering
        // settled content rather than reconciling mid-slide (R40).
        signalFirstPaint()

        // Phase 2 — authoritative network seed, reconciled in place.
        guard let fetch = resolvedTranscriptFetch else { return }
        do {
            // ARCH37 STEP 3 — skip the redundant network seed when the cache copy
            // is FRESH. A fresh cache paint is the ONLY seed on open; the existing
            // reconnect/foreground `backfill()` reconciles any later drift. This
            // halves the open-time normalize cost AND removes the second async
            // @Observable write the scroll machinery used to race against (the
            // double-seed mid-conversation-landing window). Staleness is proven
            // against the session's `lastActive`; a nil `lastActive` is treated as
            // STALE (Step 3 / CacheStore change), so "fresh" is never over-broad.
            if paintedFromCache, let cacheStore,
               let lastActive = sessions.first(where: { $0.id == storedId })?.lastActive,
               (try? await cacheStore.transcriptIsFresh(storedId, lastActive: lastActive)) == true {
                guard openToken == token else { return }
                #if DEBUG
                Self.logOpenLatency(
                    phase: "network-seed-skipped(fresh)", storedId: storedId, since: openClock)
                #endif
                return
            }
            let stored = try await fetch(storedId)
            guard openToken == token else { return }  // superseded (R1 #28/#43)
            // ARCH37 STEP 2 — normalize OFF the main actor (the pure `toChatMessages`
            // transform), hop to main only for the in-place reconcile assignment with
            // a fresh openToken re-check (a superseded open's normalize is dropped).
            let normalized = await Self.normalizeOffMain(stored)
            guard openToken == token else { return }  // superseded during normalize
            chat.seed(normalized: normalized)
            #if DEBUG
            Self.logOpenLatency(
                phase: "network-painted", storedId: storedId, since: openClock)
            #endif
            // P3 write-through: persist the freshly-fetched transcript so the
            // next open paints it from disk. Fire-and-forget, OFF the UI path.
            if let cacheStore {
                Task { try? await cacheStore.saveTranscript(sessionId: storedId, messages: stored) }
            }
        } catch {
            guard openToken == token else { return }  // superseded (R1 #28/#43)
            // History fetch failed. If the cache already painted, KEEP it (offline-
            // with-cache is a fully usable read) and stay silent. Only an EMPTY
            // transcript needs the recoverable error state — never an infinite
            // "Loading…" spinner (R1 #79).
            if !paintedFromCache {
                chat.reset()
                let description = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                chat.noteTranscriptLoadFailure(description)
            }
        }
    }

    /// Load full history over REST and seed it into the chat transcript.
    ///
    /// The compression-chain-tip seed (a resume that projected onto a newer
    /// continuation) reuses this: it reconciles cache-then-network in place over
    /// whatever ``seedTranscriptCacheFirst`` already painted for the original id,
    /// so there is no `reset()` here — `seed(from:)` is identity-preserving.
    ///
    /// `token` is the ``openToken`` re-checked AFTER the REST await (R1 #28/#43):
    /// a newer `open()`/`startDraft()` may have activated a different session while
    /// the fetch was in flight, and the stale result must be dropped.
    private func seedTranscript(storedId: String?, token: UUID) async {
        guard let chat else { return }
        guard let storedId, let fetch = resolvedTranscriptFetch else {
            chat.reset()
            return
        }

        // Cache read-through first (identical to the cold-open phase 1, minus the
        // reset-on-miss: a chain-tip seed reconciles over already-painted content,
        // so a miss simply leaves it for the network fetch below).
        if let cacheStore {
            try? await cacheStore.touchSession(storedId)
            if openToken == token,
               (try? await cacheStore.hasTranscript(storedId)) == true,
               openToken == token,
               let cached = try? await cacheStore.loadTranscript(storedId),
               openToken == token {
                let normalized = await Self.normalizeOffMain(cached)
                guard openToken == token else { return }
                chat.seed(normalized: normalized)
            }
        }

        do {
            let stored = try await fetch(storedId)
            guard openToken == token else { return }  // superseded (R1 #28/#43)
            let normalized = await Self.normalizeOffMain(stored)
            guard openToken == token else { return }  // superseded during normalize
            chat.seed(normalized: normalized)
            if let cacheStore {
                Task { try? await cacheStore.saveTranscript(sessionId: storedId, messages: stored) }
            }
        } catch {
            guard openToken == token else { return }  // superseded (R1 #28/#43)
            // History fetch failed: an empty transcript is acceptable as the
            // interim render, but the failure must be recoverable — surface it
            // so ChatView shows error + retry instead of an infinite
            // "Loading conversation…" spinner (R1 #79).
            chat.reset()
            let description = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            chat.noteTranscriptLoadFailure(description)
        }
    }

    #if DEBUG
    /// DEBUG-only open→painted latency log (WhatsApp bar instrumentation). Emits
    /// one line per phase so the device console reveals where the open cost lives
    /// (disk read vs REST round-trip vs paint). Never compiled into Release.
    private static func logOpenLatency(
        phase: String, storedId: String, since start: ContinuousClock.Instant
    ) {
        let d = ContinuousClock.now - start
        let comps = d.components
        let ms = Double(comps.seconds) * 1000
            + Double(comps.attoseconds) / 1_000_000_000_000_000
        sessionLog.debug(
            "open-latency \(phase, privacy: .public) session=\(storedId, privacy: .public) +\(ms, format: .fixed(precision: 1))ms")
    }
    #endif

    /// ARCH37 STEP 2 — run the pure `toChatMessages` seed normalize OFF the main
    /// actor. `SessionStore` is `@MainActor`, so a bare call would normalize on
    /// main; `Task.detached` hops to a background executor for the transform (the
    /// largest unyielded main-actor block on the open/backfill path — the rare-
    /// freeze root) and `await` brings the Sendable `[ChatMessage]` result back.
    /// The caller re-checks `openToken` after this await and applies via
    /// `chat.seed(normalized:)` (the single main-actor mutation hop).
    nonisolated static func normalizeOffMain(_ stored: [StoredMessage]) async -> [ChatMessage] {
        await Task.detached(priority: .userInitiated) {
            ChatStore.toChatMessages(stored)
        }.value
    }

    /// The injected `transcriptFetch`, or the default that resolves the live
    /// REST client (mirrors `ChatStore.resolvedBackfillFetch`).
    private var resolvedTranscriptFetch: ((String) async throws -> [StoredMessage])? {
        if let transcriptFetch { return transcriptFetch }
        guard let rest = connection?.rest else { return nil }
        // Phase 3: fetch only the tail beyond the cache cursor when the plugin
        // mount serves the delta route; falls back to the full fetch otherwise.
        // Returns the full StoredMessage list either way (delta invisible downstream).
        return { [cacheStore] sessionId in
            try await fetchTranscriptDeltaAware(rest: rest, cacheStore: cacheStore, sessionId: sessionId)
        }
    }

    /// The injected ``rpcSend``, or the default that forwards to the live gateway
    /// client (mirrors ``resolvedTranscriptFetch``). `nil` when there is no
    /// client at all (unconfigured) — the caller no-ops, as before.
    private var resolvedRPCSend: ((String, JSONValue) async throws -> JSONValue)? {
        if let rpcSend { return rpcSend }
        guard let client else { return nil }
        return { method, params in try await client.requestRaw(method, params: params) }
    }

    /// The injected ``interruptActive``, or the default that forwards to the
    /// EXISTING `ChatStore.interrupt()` (R1 #2 routing preserved verbatim).
    private func resolvedInterruptActive() async {
        if let interruptActive {
            await interruptActive()
        } else {
            await chat?.interrupt()
        }
    }

    /// Human-readable message for a surfaced mutation failure. Prefers the
    /// gateway's own server message for an RPC error frame (per contract),
    /// falling back to the `LocalizedError` description.
    private func errorMessage(from error: Error) -> String {
        if case let GatewayError.rpc(_, message) = error, !message.isEmpty {
            return message
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// A surfaced failure from a session-list mutation (delete/archive/rename).
///
/// Owned by ``SessionStore`` and published via ``SessionStore/sessionActionError``
/// for the drawer to present as a system alert (ABH-73 — failures used to be
/// swallowed into the unobserved `lastError`). `Identifiable` so the view can
/// bind a value-presenting `.alert`; `Equatable` for `@Observable` change
/// tracking and tests.
struct SessionActionError: Identifiable, Equatable {
    let id = UUID()
    /// The verb shown in the alert title ("Delete", "Archive", "Rename").
    let action: String
    /// Human-readable detail — the gateway error message where available.
    let message: String
}
