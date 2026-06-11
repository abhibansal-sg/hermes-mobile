import Foundation
#if DEBUG
import DebugBridgeCore  // @Snapshotable marker for the gstack debug bridge (UI-G)
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
    /// not the chat list — so the server filters them via `exclude_source` and the
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
    /// A row counts as "live" if it was stamped within this window.
    private static let liveWindow: TimeInterval = 10
    /// Periodic prune of stale entries so the registry can't grow unbounded and
    /// so a dot fades out even with no further events. Runs only while at least
    /// one entry exists; cancelled when the registry empties.
    private var liveCleanupTask: Task<Void, Never>?

    private var connection: ConnectionStore?
    private var chat: ChatStore?

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
        // never the chat list. The server also filters them via `exclude_source`
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

        if !didColdReadCache {
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
        let reconciled = incoming.map { row -> SessionSummary in
            guard let prior = priorLastActive[row.id],
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
    /// - No server-side source/cron filter exists (investigated: `/api/sessions`
    ///   has `min_messages` and `offset` but no `source` param). Client-side
    ///   `hideCron` filter is therefore applied after fetch. Because the server
    ///   returns a dense cron-heavy window, `loadMore` keeps fetching in a loop
    ///   until `visibleSessions` grows OR there are no more server rows — so the
    ///   user is never stranded at a wall of hidden cron rows.
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

    func open(_ summary: SessionSummary) {
        // Leaving any draft: opening a stored session is no longer a draft.
        isDraft = false
        // Per-session state belongs to the PREVIOUS session — clear it now so
        // the pill falls back to the global default instead of showing the
        // last chat's hot-swap (build-27 QA), and an abandoned draft's pended
        // pick can't leak in. The resume echo below re-seeds the truth.
        connection?.clearSessionState()
        // Activate instantly — the chat view can present right away with a
        // loading transcript instead of blocking navigation on the gateway.
        let token = UUID()
        openToken = token
        activeRuntimeId = nil          // gates the composer until resume lands
        activeStoredId = summary.id
        chat?.reset()

        // Fast path: the stored transcript over REST (local-network quick).
        // Threads the open token so a fetch outlived by a newer open()/draft
        // can never seed over the newer session's transcript (R1 #28).
        Task { [weak self] in
            guard let self else { return }
            await self.seedTranscript(storedId: summary.id, token: token)
        }

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
                    self.activeStoredId = chainTip
                    // Same token: the chain-tip seed's REST await is just as
                    // outrunnable by a newer open() as the fast path (R1 #43).
                    await self.seedTranscript(storedId: chainTip, token: token)
                    // Surface the chain-tip row in the drawer NOW rather than
                    // on the next 30s heartbeat (release audit P2).
                    Task { [weak self] in await self?.refresh() }
                }
                self.lastError = nil
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
        // Supersede any in-flight `open()` so its resume can't reactivate.
        openToken = UUID()
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
        guard let client, let storedId = activeStoredId else { return nil }
        do {
            // Re-resume into the same profile scope so a reconnect keeps the
            // session in its per-profile home. Omitted for the default/all scope.
            var resumeParams: [String: JSONValue] = ["session_id": .string(storedId)]
            applyProfileScope(to: &resumeParams)
            let result: SessionOpenResult = try await client.request(
                "session.resume",
                params: .object(resumeParams),
                timeout: .seconds(120)
            )
            activeRuntimeId = result.sessionId
            activeStoredId = result.storedSessionId ?? storedId
            confirmActiveProfile(from: result.info)
            // Keep the composer pill session-true on this resume path too.
            if let info = result.info { connection?.applyRuntimeInfo(info) }
            return result.sessionId
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Search

    /// React to a change in `searchQuery` from the `.searchable` field. Debounces
    /// 300ms, then fetches `/api/sessions/search`; queries under two characters
    /// clear the results immediately. Call from the view's `onChange(of:)`.
    func searchQueryChanged() {
        searchTask?.cancel()

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        guard let api = restAPI else {
            searchResults = []
            return
        }

        searchTask = Task { [weak self] in
            // Debounce.
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            guard let self else { return }
            self.isSearching = true
            defer { self.isSearching = false }
            do {
                let results = try await api.searchSessions(
                    query: trimmed, scope: self.searchScope.rawValue
                )
                if Task.isCancelled { return }
                // Guard against a stale response landing after the user typed on.
                guard self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else {
                    return
                }
                self.searchResults = results
                self.lastError = nil
            } catch {
                if Task.isCancelled { return }
                self.searchResults = []
                self.lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
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

    /// Cancel any in-flight search and reset the search UI state.
    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchResults = []
        isSearching = false
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
        lastActivityAt[id] = Date()
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

    /// Load full history over REST and seed it into the chat transcript.
    ///
    /// `token` is the ``openToken`` captured by the `open()` that started this
    /// seed. It is re-checked AFTER the REST await (R1 #28/#43): a newer
    /// `open()`/`startDraft()` may have activated a different session while
    /// the fetch was in flight, and the stale result — fast-path or
    /// compression-chain-tip alike — must be dropped, never seeded over the
    /// newer session's transcript.
    private func seedTranscript(storedId: String?, token: UUID) async {
        guard let chat else { return }
        guard let storedId, let fetch = resolvedTranscriptFetch else {
            chat.reset()
            return
        }

        // P3 warm-open read-through: SEED the transcript from the local cache
        // FIRST — before the (remote-Tailscale) REST fetch — so the chat paints
        // instantly from disk on open. This is the earliest seed in the open
        // path: it runs ahead of the network round-trip so `ChatStore.seed` /
        // `transcriptGeneration` fire with cached content present, and the later
        // live fetch reconciles in place via the existing `reconcileMessages`
        // (identity-preserving — no remount, no flicker). The cron-only sessions
        // are never transcript-cached (CacheStore guards the write), so this read
        // simply misses for them and the live fetch is the sole seed. No cache
        // (tests/previews) ⇒ skipped, network-only path unchanged byte-for-byte.
        if let cacheStore {
            // `touchSession` bumps `lastAccessedAt` so an actively-opened session
            // never ages out of the eviction horizon.
            try? await cacheStore.touchSession(storedId)
            if openToken == token,           // not superseded while reading disk
               (try? await cacheStore.hasTranscript(storedId)) == true,
               openToken == token,
               let cached = try? await cacheStore.loadTranscript(storedId),
               openToken == token {          // re-check after every await
                chat.seed(from: cached)
            }
        }

        do {
            let stored = try await fetch(storedId)
            guard openToken == token else { return }  // superseded (R1 #28/#43)
            chat.seed(from: stored)
            // P3 write-through: persist the freshly-fetched transcript so the
            // next open paints it from disk. Fire-and-forget, OFF the UI path.
            // CacheStore no-ops for cron sessions (cron is never transcript
            // cached, per the decided scope). `wireIds` is nil: the wire `id`
            // global cursor is not parsed into `StoredMessage`, so v1
            // (full-fetch-diff) leaves `maxMessageId` nil — the cursor is only
            // consumed by the OUT-OF-CONTRACT v2 delta path.
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

    /// The injected `transcriptFetch`, or the default that resolves the live
    /// REST client (mirrors `ChatStore.resolvedBackfillFetch`).
    private var resolvedTranscriptFetch: ((String) async throws -> [StoredMessage])? {
        if let transcriptFetch { return transcriptFetch }
        guard let rest = connection?.rest else { return nil }
        return { sessionId in try await rest.messages(sessionId: sessionId) }
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
