import Foundation
#if DEBUG
import os

/// DEBUG-only logger for SessionStore open→painted latency instrumentation
/// (WhatsApp bar). Absent in Release.
private let sessionLog = Logger(subsystem: "ai.hermes.HermesMobile", category: "SessionStore")

/// DEBUG-only signpost log for the open→paint fallback chain (QA-1 A7/B2).
private let sessionSignposts = OSLog(subsystem: "ai.hermes.HermesMobile", category: "SessionStore")
#endif

/// Pure prompt-history navigation matching desktop's per-session cursor +
/// draft-snapshot semantics. History is derived on demand from live messages;
/// this type never stores or persists the history entries themselves.
enum ComposerPromptHistory {
    struct State: Equatable {
        var cursorIndex: Int?
        var draftSnapshot: String = ""
    }

    static func deriveUserHistory(from messages: [ChatMessage]) -> [String] {
        messages.reversed().compactMap { message in
            guard message.role == .user else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    static func browseBackward(
        history: [String],
        currentDraft: String,
        state: inout State
    ) -> String? {
        guard !history.isEmpty else { return nil }

        let nextIndex: Int
        if let cursor = state.cursorIndex {
            guard cursor + 1 < history.count else { return nil }
            nextIndex = cursor + 1
        } else {
            state.draftSnapshot = currentDraft
            nextIndex = 0
        }

        state.cursorIndex = nextIndex
        return history[nextIndex]
    }

    static func browseForward(history: [String], state: inout State) -> String? {
        guard let cursor = state.cursorIndex else { return nil }

        if cursor > 0 {
            let nextIndex = cursor - 1
            guard nextIndex < history.count else { return nil }
            state.cursorIndex = nextIndex
            return history[nextIndex]
        }

        let snapshot = state.draftSnapshot
        state = State()
        return snapshot
    }
}

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

    /// ABH-373: Every server row id consumed across all pages — INCLUDING machinery
    /// that was filtered out at ingress and never entered `sessions`. Grow-limit
    /// pagination re-fetches the full expanded window each iteration (limit grows by
    /// `pageSize`), so deduping the `loadedCount` cursor advance against `sessions`
    /// (which excludes filtered machinery) would re-count those rows every iteration
    /// and inflate the cursor past `totalSessions` — halting `loadMore` before later
    /// human sessions. Tracking all-seen ids makes the ingress filter cursor-neutral:
    /// a row consumed from the server is counted exactly once regardless of whether it
    /// passes the machinery predicate. Reset alongside `sessions`/`loadedCount` on
    /// every list clear and rebuilt from the raw page on every first-page replace.
    private var seenServerSessionIds: Set<String> = []

    /// True while a `loadMore()` page fetch is in flight (distinct from `isLoading`
    /// which gates the first-page spinner). Drives the sentinel loading row.
    private(set) var isLoadingMore: Bool = false

    /// Number of sessions currently visible after all client-side filters
    /// (human-recents source/count gate, profile scope). The drawer uses this together with
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

    /// Minimum number of human-facing, non-empty sessions to show after a cold
    /// launch. After the first-page merge, `refresh()` keeps fetching with
    /// growing limits (reusing `loadMore()`-exact semantics) until either this
    /// many visible sessions are present OR the server is exhausted. The loop
    /// respects Recents/profile filters because `visibleSessions` already
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

    /// Sources excluded server-side from the human-chat Recents list (drawer
    /// bifurcation). Automation RUNS (`source == "cron"`) and agent-internal
    /// child sessions (`source == "subagent"`) do not belong in the human chat
    /// picker — so fresh REST pages ask the gateway to omit them via
    /// `exclude_sources` before the client caches them. The automation-runs
    /// surface fetches `source: "cron"` separately.
    nonisolated static let recentsExcludeSources = ["cron", "subagent"]

    /// Client-side machinery-source gate for Recents. Kept separate from
    /// ``recentsExcludeSources`` so the server query stays the stable
    /// channel-filter surface while the local ABH-343 predicate can reject newer
    /// future-tagged machinery rows (`agent`) even on old gateways.
    nonisolated private static let recentsMachinerySources = ["cron", "subagent", "agent"]

    /// Conservative title fragments that identify loop/review/kanban machinery,
    /// not user-authored human chats. These are intentionally narrow: ABH-343 is
    /// about keeping generated loop sessions out of Recents without hiding a real
    /// CLI conversation just because it came from the CLI channel.
    nonisolated private static let recentsMachineryTitleFragments = [
        "review approval",
        "kanban task",
        "loop:",
        "scout-",
        "verify:",
        "review:",
    ]

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

    /// Connection-lifecycle ownership for async session work. ConnectionStore
    /// invalidates this whenever a gateway generation changes, so a suspended
    /// refresh or session recovery cannot publish data from the prior gateway.
    private var connectionWorkGeneration: UInt64 = 0

    func invalidateConnectionWork() {
        connectionWorkGeneration &+= 1
        // Existing refresh paths already guard this token at every network
        // result publication. Bumping it discards an in-flight response.
        refreshToken &+= 1
        resetInitialFill()
        cancelEnsureRuntime()
        cancelRuntimeBinding()
    }

    /// A runtime id belongs to one WebSocket generation only. Keep the durable
    /// selection and its pending open intent, but make the old runtime unusable
    /// the instant that transport disappears.
    func transportDidBecomeUnavailable() {
        connectionWorkGeneration &+= 1
        activeRuntimeId = nil
        activeRuntimeEpoch = nil
        cancelEnsureRuntime()
        cancelRuntimeBinding()
    }

    /// A different gateway is a different cache and runtime namespace. Do not
    /// carry an old stored-session intent into the newly configured server.
    func invalidateGatewayScopeWork() {
        openToken = UUID()
        // A scope teardown replaces the drawer content: drop any pending
        // dismissal intent from a row that no longer exists (QA-1 B3).
        pendingDrawerReveal = nil
        cancelEnsureRuntime()
        cancelRuntimeBinding()
        activeRuntimeId = nil
        activeRuntimeEpoch = nil
        activeStoredId = nil
        activeStoredProfile = nil
        chat?.reset()
        transcriptPaintedStoredId = nil
    }

    /// Remove every in-memory surface owned by a forgotten gateway.
    ///
    /// Disk/cache deletion is coordinated by ``ConnectionStore.forgetGateway``.
    /// This companion reset is intentionally stronger than an ordinary
    /// disconnect: it prevents the old drawer and transcript from surviving in
    /// the long-lived store graph and reappearing during an immediate re-pair.
    func removeForgottenGatewayState() {
        invalidateConnectionWork()
        stopHeartbeat()
        cancelPrefetch()
        searchTask?.cancel()
        searchTask = nil
        searchLoadMoreTask?.cancel()
        searchLoadMoreTask = nil

        openToken = UUID()
        pendingDrawerReveal = nil
        cancelRuntimeBinding()
        warmOpenSnapshots.removeAll()
        warmOpenSnapshotOrder.removeAll()
        #if DEBUG
        lastOpenSeedTask?.cancel()
        lastOpenResumeTask?.cancel()
        #endif

        draftSaveTasks.values.forEach { $0.cancel() }
        draftSaveTasks.removeAll()
        composerDrafts.removeAll()
        composerHistoryBrowses.removeAll()
        composerDraftRevision &+= 1
        draftCwd = nil
        draftAttachments?.removeAll()

        clearActive()
        sessions.removeAll()
        archivedSessions.removeAll()
        automationSessions.removeAll()
        profiles.removeAll()
        totalSessions = nil
        automationSessionsTotal = nil
        loadedOffset = 0
        loadedCount = 0
        loadedFloor = 0
        seenServerSessionIds.removeAll()
        resetSessionListDeltaState()

        liveCleanupTask?.cancel()
        liveCleanupTask = nil
        lastActivityAt.removeAll()
        lastActivityStampAt.removeAll()
        turnsInProgress.removeAll()

        manifestFreshness = .cached
        manifestLastSyncedAt = nil
        manifestRevision = 0
        coldReadCacheScope = nil
        lastColdReadServerId = nil

        clearSearch()
        pendingSearchScroll = nil
        pendingMessageJump = nil
        pendingMessageJumpAttempts = 0
        pendingMessageJumpSnippet = nil
        pendingSearchScrollIsSnippet = false
        lastError = nil
        sessionActionError = nil
        isLoading = false
        isLoadingMore = false
        isLoadingAutomationSessions = false
        automationSessionsError = nil

        pinnedIds.removeAll()
        persistPins()
        activeProfile = Self.defaultProfileName
    }

    /// Revision of the server-side Recents universe represented by `sessions`.
    /// Unlike `refreshToken`, this does not cancel the dedicated initial fill on
    /// every heartbeat. It changes only when a first-page replacement or cursor
    /// delta can make an already-started grow-window response stale.
    private var sessionListUniverseRevision: Int = 0

    /// Identity of one server-side Recents list universe. Cursor state is never
    /// shared across gateways, path families, profile rails, or source filters.
    private struct SessionListDeltaScope: Hashable, Codable {
        let serverURL: String
        let pathStyle: String
        let activeProfile: String
        let rail: String
        let excludedSources: String
        let source: String
    }

    private struct PersistedSessionListCursor: Codable {
        let scope: SessionListDeltaScope
        let cursor: String
    }

    /// Opaque plugin session-list cursors partitioned by list universe.
    @ObservationIgnored
    private var sessionListDeltaCursors: [SessionListDeltaScope: String] = [:]

    /// The transport generation the delta rail last FULL-seeded under (A2). Every
    /// reconnect / foreground-recovery bumps `ConnectionStore.transportEpoch`, so
    /// comparing it here lets the FIRST session-list refresh on a new transport
    /// bypass the persisted delta cursor and do a full first-page re-seed +
    /// fill-to-target before incremental deltas resume — otherwise an
    /// under-populated drawer (initial hydration cut short by the 8s timeout) can
    /// never be repaired without a process restart. This single data-driven seam
    /// keys off the epoch that ALL recovery entry points already advance, so no
    /// per-path flag and no third recovery path is needed.
    @ObservationIgnored
    private var lastReseededTransportGeneration: UInt64?

    /// The current transport generation for the A2 reseed gate. The live path is
    /// `connection?.transportEpoch`; a test injects `reconnectGenerationProvider`
    /// to simulate a reconnect deterministically without a live socket.
    private var currentReconnectGeneration: UInt64? {
        #if DEBUG
        if let provider = reconnectGenerationProvider { return provider() }
        #endif
        return connection?.transportEpoch
    }

    #if DEBUG
    /// Test seam for the A2 reconnect full-reseed gate: overrides the transport
    /// generation the gate reads. Bumping the returned value between refreshes
    /// simulates a reconnect (which, in the app, bumps `transportEpoch`).
    var reconnectGenerationProvider: (() -> UInt64?)?
    #endif

    /// Tombstones deferred while a row belongs to the active/pinned/live working
    /// set. They are re-evaluated on every later delta so advancing the server
    /// cursor cannot leave a protected row behind forever after protection ends.
    @ObservationIgnored
    private var pendingSessionListTombstones: [SessionListDeltaScope: Set<String>] = [:]

    private func sessionListDeltaScope(
        excludeSource: [String],
        source: String? = nil
    ) -> SessionListDeltaScope? {
        let serverURL: String
        if let live = connection?.serverURLString, !live.isEmpty {
            serverURL = live
        } else if sessionListDeltaFetch != nil {
            serverURL = "__test__"
        } else {
            return nil
        }
        let pathStyle = connection?.rest?.pathStyle.rawValue
            ?? (sessionListDeltaFetch == nil ? "none" : "__test__")
        return SessionListDeltaScope(
            serverURL: serverURL,
            pathStyle: pathStyle,
            activeProfile: activeProfile.trimmingCharacters(in: .whitespacesAndNewlines),
            rail: usesAggregateRail ? "aggregate" : "single",
            excludedSources: excludeSource.joined(separator: ","),
            source: source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private func resetSessionListDeltaState() {
        sessionListDeltaCursors.removeAll()
        pendingSessionListTombstones.removeAll()
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.sessionListDeltaCursors)
    }

    func flushSessionListDeltaCursors(defaults: UserDefaults = .standard) {
        let persisted = sessionListDeltaCursors
            .map { PersistedSessionListCursor(scope: $0.key, cursor: $0.value) }
            .sorted {
                let left = [$0.scope.serverURL, $0.scope.pathStyle, $0.scope.activeProfile,
                            $0.scope.rail, $0.scope.excludedSources, $0.scope.source].joined(separator: "|")
                let right = [$1.scope.serverURL, $1.scope.pathStyle, $1.scope.activeProfile,
                             $1.scope.rail, $1.scope.excludedSources, $1.scope.source].joined(separator: "|")
                return left < right
            }
        if persisted.isEmpty {
            defaults.removeObject(forKey: DefaultsKeys.sessionListDeltaCursors)
        } else if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: DefaultsKeys.sessionListDeltaCursors)
        }
        _ = defaults.synchronize()
    }
    /// Runtime `session_id` for the session bound to the current connection.
    var activeRuntimeId: String?
    /// Persistent `stored_session_id` for the active session (survives reconnects).
    #if DEBUG
    #endif
    var activeStoredId: String?
    /// Profile component of the durable selection identity. Stored session ids
    /// are not globally unique across an aggregate multi-profile drawer.
    private(set) var activeStoredProfile: String?
    /// Key used for the local, not-yet-materialized chat draft. This intentionally
    /// matches ChatView's transcript `.id` fallback so the stable overlay composer
    /// and transcript agree on the draft-chat identity.
    static let composerDraftFallbackKey = "hermes.chat.draft"
    /// Per-session unsent composer text. Kept in the long-lived session store so
    /// ComposerView can explicitly swap visible text on `draftKey` changes instead
    /// of relying on a remount. Empty / whitespace-only drafts are removed instead
    /// of persisted as noise.
    private var composerDrafts: [String: String] = [:]
    private var workRepository: WorkRepository?
    private weak var draftAttachments: AttachmentStore?
    private var draftSaveTasks: [String: Task<Void, Never>] = [:]

    private struct ComposerDraftPersistenceSnapshot: Sendable {
        let repository: WorkRepository
        let scope: WorkScope
        let contextKey: String
        let storedSessionID: String?
        let text: String
        let cwd: String?
        let modelSelectionJSON: String?
        let assets: [WorkAssetInput]
    }

    /// Bumped whenever a composer draft is mutated outside the focused field's
    /// direct binding. ComposerView observes this to pull externally-recalled
    /// prompt-history text into its local @State.
    private(set) var composerDraftRevision = 0

    /// Runtime-only prompt-history browse state keyed by the same draft identity
    /// as ``composerDrafts``. This intentionally stores only cursor + original
    /// draft snapshot, never a persisted prompt ring.
    private var composerHistoryBrowses: [String: ComposerPromptHistory.State] = [:]
    /// The summary for the active session, if it's present in the loaded list.
    /// Used by app-side glue (e.g. the Live Activity title); `nil` for a session
    /// not yet in `sessions` (a brand-new create the list hasn't refreshed onto).
    var activeSummary: SessionSummary? {
        guard let id = activeStoredId else { return nil }
        return sessions.first {
            $0.id == id
                && (activeStoredProfile == nil
                    || selectedProfileID(for: $0) == activeStoredProfile)
        }
    }

    func isActive(_ summary: SessionSummary) -> Bool {
        guard summary.id == activeStoredId else { return false }
        guard let activeStoredProfile else { return true }
        return selectedProfileID(for: summary) == activeStoredProfile
    }

    var activeScopedIdentity: String? {
        guard let activeStoredId else { return nil }
        return "\(activeStoredProfile ?? Self.defaultProfileName)\u{1F}\(activeStoredId)"
    }

    /// Draft identity for a stored session id, using the exact fallback ChatView
    /// uses for the brand-new local chat.
    static func composerDraftKey(storedSessionId: String?) -> String {
        let trimmed = storedSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? composerDraftFallbackKey : trimmed
    }

    /// The draft key for the currently active chat context.
    var activeComposerDraftKey: String {
        Self.composerDraftKey(storedSessionId: activeStoredId)
    }

    /// Restore the unsent composer text for a session-scoped draft key.
    func composerDraft(for key: String) -> String {
        composerDrafts[key] ?? ""
    }

    /// Persist or clear the unsent composer text for a session-scoped draft key.
    func setComposerDraft(_ draft: String, for key: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerDrafts.removeValue(forKey: key)
        } else {
            composerDrafts[key] = draft
        }
        composerDraftRevision &+= 1
        scheduleComposerDraftSave(for: key)
    }

    func restoreComposerDraft(for key: String) {
        guard let repository = workRepository, let scope = durableWorkScope else { return }
        Task { [weak self] in
            guard let self, let snapshot = try? await repository.draft(scope: scope, contextKey: key) else { return }
            guard self.activeComposerDraftKey == key else { return }
            self.composerDrafts[key] = snapshot.draft.text
            self.draftCwd = snapshot.draft.cwd
            if let json = snapshot.draft.modelSelectionJSON,
               let data = json.data(using: .utf8),
               let selection = try? JSONDecoder().decode(DraftModelSelection.self, from: data) {
                self.connection?.draftSelection = selection
            }
            var bytes: [Data] = []
            for asset in snapshot.assets {
                if let data = try? await repository.assetData(asset) { bytes.append(data) }
            }
            self.draftAttachments?.restoreDraftAssets(bytes)
            self.composerDraftRevision &+= 1
        }
    }

    func flushComposerDraft() {
        let key = activeComposerDraftKey
        draftSaveTasks[key]?.cancel()
        draftSaveTasks[key] = nil
        persistComposerDraft(for: key)
    }

    func flushComposerDraftDurably() async {
        let key = activeComposerDraftKey
        draftSaveTasks[key]?.cancel()
        draftSaveTasks[key] = nil
        guard let snapshot = composerDraftPersistenceSnapshot(for: key) else { return }
        await Self.saveComposerDraft(snapshot)
    }

    var durableWorkScope: WorkScope? {
        guard let currentCacheScope else { return nil }
        return try? WorkScope(cacheScope: currentCacheScope)
    }

    private func scheduleComposerDraftSave(for key: String) {
        draftSaveTasks[key]?.cancel()
        draftSaveTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistComposerDraft(for: key)
        }
    }

    private func persistComposerDraft(for key: String) {
        guard let snapshot = composerDraftPersistenceSnapshot(for: key) else { return }
        Task { await Self.saveComposerDraft(snapshot) }
    }

    private func composerDraftPersistenceSnapshot(
        for key: String
    ) -> ComposerDraftPersistenceSnapshot? {
        guard let repository = workRepository, let scope = durableWorkScope else { return nil }
        let text = composerDrafts[key] ?? ""
        let storedID = key == Self.composerDraftFallbackKey ? nil : key
        let cwd = key == activeComposerDraftKey ? draftCwd : nil
        let modelJSON: String?
        if key == activeComposerDraftKey,
           let selection = connection?.draftSelection,
           let data = try? JSONEncoder().encode(selection) {
            modelJSON = String(data: data, encoding: .utf8)
        } else {
            modelJSON = nil
        }
        let assets = key == activeComposerDraftKey ? (draftAttachments?.draftAssetInputs() ?? []) : []
        return ComposerDraftPersistenceSnapshot(
            repository: repository,
            scope: scope,
            contextKey: key,
            storedSessionID: storedID,
            text: text,
            cwd: cwd,
            modelSelectionJSON: modelJSON,
            assets: assets
        )
    }

    private nonisolated static func saveComposerDraft(
        _ snapshot: ComposerDraftPersistenceSnapshot
    ) async {
        try? await snapshot.repository.saveDraft(
            scope: snapshot.scope,
            contextKey: snapshot.contextKey,
            storedSessionID: snapshot.storedSessionID,
            text: snapshot.text,
            cwd: snapshot.cwd,
            modelSelectionJSON: snapshot.modelSelectionJSON,
            assets: snapshot.assets
        )
    }

    /// Clear prompt-history cursor/snapshot state without changing the user's
    /// saved draft. Passing a key resets one composer; nil resets all runtime
    /// browse state for session switches and new chat.
    func resetComposerHistoryBrowse(for key: String? = nil) {
        if let key {
            composerHistoryBrowses.removeValue(forKey: key)
        } else {
            composerHistoryBrowses.removeAll()
        }
    }

    /// Browse backward through the active session's user prompt history.
    @discardableResult
    func recallPreviousComposerPrompt(messages: [ChatMessage]) -> Bool {
        let key = activeComposerDraftKey
        let history = ComposerPromptHistory.deriveUserHistory(from: messages)
        var state = composerHistoryBrowses[key] ?? ComposerPromptHistory.State()
        guard let recalled = ComposerPromptHistory.browseBackward(
            history: history,
            currentDraft: composerDraft(for: key),
            state: &state
        ) else {
            return false
        }

        composerHistoryBrowses[key] = state
        setComposerDraft(recalled, for: key)
        return true
    }

    /// Browse forward toward the present composer draft snapshot.
    @discardableResult
    func recallNextComposerPrompt(messages: [ChatMessage]) -> Bool {
        let key = activeComposerDraftKey
        let history = ComposerPromptHistory.deriveUserHistory(from: messages)
        var state = composerHistoryBrowses[key] ?? ComposerPromptHistory.State()
        guard let recalled = ComposerPromptHistory.browseForward(
            history: history,
            state: &state
        ) else {
            return false
        }

        if state.cursorIndex == nil {
            composerHistoryBrowses.removeValue(forKey: key)
        } else {
            composerHistoryBrowses[key] = state
        }
        setComposerDraft(recalled, for: key)
        return true
    }
    /// True while a list/open/create RPC is in flight.
    #if DEBUG
    #endif
    var isLoading: Bool = false
    /// Last human-readable error from a session operation, for the UI to surface.
    var lastError: String?

    /// Set when a session action (open/resume/delete/archive/rename) fails, for
    /// the drawer to surface as a transient toast/alert. nil when there is
    /// nothing to show.
    ///
    /// This is the dedicated, observed surface for session failures (ABH-73):
    /// ``lastError`` is a catch-all that nothing in the drawer watches, so a
    /// failed delete/open used to vanish silently. The drawer binds a system `.alert`
    /// to this value (`DrawerView`); ``lastError`` is still written too for the
    /// other call sites that read it. `nil` = nothing to show / silent success.
    #if DEBUG
    #endif
    var sessionActionError: SessionActionError?

    /// `true` while the app is sitting on a *draft* chat: a fresh, empty
    /// transcript with no backing session created server-side yet (no
    /// `activeRuntimeId`/`activeStoredId`). The first prompt the user sends
    /// materializes the real session (see ``createDraftSession()`` /
    /// `ChatStore.send`). Lets the app land on a clean chat at launch and on
    /// "New chat" without littering the session list with empty sessions.
    private(set) var isDraft: Bool = false

    /// ABH-351 — the cwd a draft session should start in. Set by
    /// ``startDraft(cwd:)`` (new-session-in-project) before the draft
    /// materializes; consumed by ``createDraftSession()`` which passes it as
    /// the `cwd` param to `session.create` (the gateway's session.create
    /// accepts an optional `cwd` — see server.py:4987). `nil` = no explicit
    /// cwd (the session lands in the gateway's default / launch directory,
    /// exactly as before). Cleared on every ``startDraft()`` entry.
    private(set) var draftCwd: String?

    // MARK: - Search

    /// Current search query bound to the list's `.searchable`. Empty when not
    /// searching; a value of two-plus characters triggers a debounced fetch.
    var searchQuery: String = ""
    /// Results of the latest `/api/sessions/search`, newest match first as the
    /// server orders them.
    var searchResults: [SessionSearchResult] = []
    /// True while a search request is in flight (after the debounce fires).
    var isSearching: Bool = false
    /// True while the active scope's bounded historical FTS backfill remains.
    var searchIsPartial: Bool = false
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

    /// Sort order for the plugin search endpoint. Stock fallback ignores this
    /// because `/api/sessions/search` does not expose sort.
    enum SearchSort: String, CaseIterable, Sendable {
        case newest, oldest, relevance
        var label: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .relevance: return "Relevance"
            }
        }
    }
    var searchSort: SearchSort = .newest

    /// The query text whose first transcript occurrence the next-opened session
    /// should scroll to (search jump-to-match). Consumed + cleared by ChatView
    /// once it has scrolled. `nil` for a normal open.
    var pendingSearchScroll: String?

    /// ABH-192 (jump-to-exact-message): the wire `message_id` the next-opened
    /// session should scroll its transcript to. Set by ``open(searchResult:)``
    /// when the tapped result carried a `messageId` (the per-message plugin
    /// search endpoint and the artifacts gallery both do; the stock FTS endpoint
    /// does not). Consumed + cleared by ChatView once the target row is visible.
    /// `nil` for a normal open. Takes precedence over ``pendingSearchScroll``
    /// when both are set (an exact-id jump is stricter than a query-text match).
    ///
    /// M1 (Opus review): the open path is CACHE-FIRST then NETWORK
    /// (``seedTranscriptCacheFirst``). A stale on-disk cache seed lands BEFORE
    /// the authoritative network seed, and the stale copy often does NOT contain
    /// the matched row. So `jumpToMessageIfNeeded` must NOT clear this on a
    /// miss — it survives the cache bump and resolves on the network bump.
    /// Bounded two ways so it can't live forever: (1) cleared on a successful
    /// scroll, (2) cleared on `activeStoredId` change (session switch — see
    /// ``open(_:)`` and ChatView's `.onChange(of: activeStoredSessionId)`), and
    /// (3) a small attempt cap (``pendingMessageJumpAttempts``) so a target that
    /// is genuinely absent on a fresh/cache-HIT single-phase seed is still
    /// consumed within one session (no infinite retention).
    var pendingMessageJump: Int?

    /// ABH-192 / M1: counts how many `transcriptGeneration` bumps
    /// `jumpToMessageIfNeeded` has inspected WITHOUT resolving the target row.
    /// The cache→network seed is at most a two-phase bump (cache paint, then
    /// network reconcile), plus the cache-fresh skip path is single-phase — so a
    /// target that has not appeared after a couple of hops is genuinely absent
    /// (coalesced turn / stock gateway / compressed-out row). Bounded at
    /// ``Self.pendingMessageJumpMaxAttempts``; on the cap the jump is consumed
    /// (and, when a snippet is available, falls back to the query-text scroll).
    var pendingMessageJumpAttempts = 0

    /// S2 (Opus review): the search snippet captured alongside an exact-id
    /// `pendingMessageJump` (from `open(searchResult:)`). When the exact-id
    /// lookup misses (coalesced assistant turn / stock gateway / compressed-out
    /// row), `jumpToMessageIfNeeded` falls back to a query-text scroll using
    /// this snippet via `pendingSearchScroll` — so the user lands inside the
    /// right turn instead of a silent no-op at the bottom. `nil` when the jump
    /// did not originate from a search result (e.g. the artifacts gallery, which
    /// carries no snippet) — then the miss is a graceful no-op.
    var pendingMessageJumpSnippet: String?

    /// BUG6 fix: when `true`, ``pendingSearchScroll`` was populated from a
    /// server-supplied snippet (prose slice that may contain newlines normalised
    /// to spaces via `plainSnippet`) and ``ChatView/jumpToSearchMatchIfNeeded``
    /// should collapse whitespace runs in BOTH the needle and each message's text
    /// before matching — so a snippet like "foo bar" (space-normalised from
    /// "foo\nbar") still finds "foo\nbar" in the raw transcript.
    ///
    /// When `false` (the default), the scroll was set from the user's literal
    /// drawer-search query and must be matched verbatim (literal substring, no
    /// collapse) — collapsing would widen the match, potentially scrolling to an
    /// EARLIER wrong message that happens to contain the same words once tabs /
    /// double-spaces / newlines are removed. Cleared alongside
    /// ``pendingSearchScroll``.
    var pendingSearchScrollIsSnippet: Bool = false

    /// M1: the cap after which an unresolved `pendingMessageJump` is abandoned.
    /// Two phases cover the cache-then-network seed; the third hop absorbs a
    /// late reconcile so a genuinely-present target is never wrongly dropped.
    static let pendingMessageJumpMaxAttempts = 3

    // MARK: - Pins / archive / Recents filters (persisted)

    /// Pinned `stored_session_id`s; pinned rows float to a section on top.
    private(set) var pinnedIds: Set<String> = []
    /// Historical preference for hiding cron rows. Recents is now human-chat-only
    /// by construction regardless of this vestigial toggle, but fresh installs keep
    /// the persisted value `true` so older empty-state / migration paths do not
    /// expose automation firehose rows.
    var hideCron: Bool {
        didSet {
            guard hideCron != oldValue else { return }
            UserDefaults.standard.set(hideCron, forKey: DefaultsKeys.hideCron)
        }
    }

    /// When `true`, the drawer's Recents list is grouped by workspace (`cwd`)
    /// instead of shown flat (UI Batch H2). Default `false`. The human-Recents
    /// filter still applies *inside* groups because grouping reads from
    /// ``unpinnedSessions``, which is already source/count-filtered. Persisted.
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

    /// Profile names whose All Profiles drawer groups are collapsed. Kept
    /// separate from workspace collapse state so `work` as a profile name cannot
    /// collide with `/.../work` as a workspace key.
    ///
    /// STR-1022: this now holds ONLY the user's EXPLICIT collapse decisions. The
    /// effective state is derived in ``isProfileGroupCollapsed(_:)`` by overlaying
    /// this set (and ``expandedProfiles``) on the default rule "collapse every
    /// group except the default/active profile" — so a fresh view opens with every
    /// non-default group collapsed (desktop parity) WITHOUT a one-shot seed, a
    /// profile discovered later still defaults to collapsed, and the user's
    /// expand/collapse choices survive restarts (persisted).
    private(set) var collapsedProfiles: Set<String> = []

    /// Profile names the user has explicitly EXPANDED beyond the collapsed-by-
    /// default rule, so a non-default group they opened does not snap back to
    /// collapsed on the next render/restart. Persisted alongside
    /// ``collapsedProfiles``. See ``isProfileGroupCollapsed(_:)``.
    private(set) var expandedProfiles: Set<String> = []

    /// How many most-recent rows a COLLAPSED All Profiles group previews before
    /// its "show more" expand affordance (STR-1022 desktop parity: collapsed-by-
    /// default + few-recent preview). The desktop web app has no equivalent — iOS
    /// already went further in STR-996 by grouping at all — so this is the
    /// mobile-chosen "few": compact enough that several collapsed groups fit the
    /// drawer, enough to preview recent activity. Tunable.
    static let drawerCollapsedProfilePreviewCount = 3

    /// Effective collapsed state for an All Profiles group. Derives from the
    /// default rule (collapse every group EXCEPT the default/active profile)
    /// overlaid with the user's explicit decisions, so the view never needs to
    /// know whether a profile was seeded vs toggled.
    func isProfileGroupCollapsed(_ profile: String) -> Bool {
        Self.isProfileGroupCollapsed(
            profile,
            collapsed: collapsedProfiles,
            expanded: expandedProfiles,
            profileMap: profileSummaryMap
        )
    }

    /// Pure collapse-state derivation (testable without an instance). Default
    /// rule: a group is collapsed unless it is the default profile. Explicit
    /// decisions win over the default.
    nonisolated static func isProfileGroupCollapsed(
        _ profile: String,
        collapsed: Set<String>,
        expanded: Set<String>,
        profileMap: [String: ProfileSummary]
    ) -> Bool {
        if expanded.contains(profile) { return false }
        if collapsed.contains(profile) { return true }
        return !isDefaultDrawerProfile(profile, profileMap: profileMap)
    }

    private var profileSummaryMap: [String: ProfileSummary] {
        Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
    }

    /// Toggle the collapsed state of a profile group. Records the EXPLICIT
    /// decision in ``collapsedProfiles`` / ``expandedProfiles`` so the default
    /// rule cannot undo it: expanding a default-collapsed group writes an
    /// explicit-expand, and collapsing the default group writes an explicit-
    /// collapse. Idempotent and independent of ``resetInitialFill()`` (the
    /// STR-991 teardown path never touches collapse state).
    func toggleCollapsed(profile: String) {
        if isProfileGroupCollapsed(profile) {
            collapsedProfiles.remove(profile)
            expandedProfiles.insert(profile)
        } else {
            expandedProfiles.remove(profile)
            collapsedProfiles.insert(profile)
        }
        persistCollapsedProfiles()
        persistExpandedProfiles()
    }

    private func persistCollapsedProfiles() {
        UserDefaults.standard.set(
            Array(collapsedProfiles),
            forKey: DefaultsKeys.collapsedProfiles
        )
    }

    private func persistExpandedProfiles() {
        UserDefaults.standard.set(
            Array(expandedProfiles),
            forKey: DefaultsKeys.expandedProfiles
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
    #endif
    var activeProfile: String {
        didSet {
            guard activeProfile != oldValue else { return }
            UserDefaults.standard.set(activeProfile, forKey: DefaultsKeys.activeProfile)
            // Fence a response before its suspended continuation can publish
            // rows or schedule a cache write for the old profile.
            refreshToken &+= 1
            coldReadCacheScope = nil
            resetInitialFill()
            resetSessionListDeltaState()
        }
    }

    #if DEBUG
    /// DEBUG-only override so unit tests can exercise profile-threaded open/delete
    /// call sites without standing up the full capability-probe + profile-list
    /// graph. `nil` in production/test-defaults means use the real switcher gate.
    var profileThreadingAvailableForTesting: Bool?
    #endif

    /// The fetched profile list backing the switcher (F4b). Populated by
    /// ``loadProfiles()`` ONLY when `profiles == .available`; empty otherwise, so
    /// the switcher visibility gate (`profiles == .available && count > 1`) is
    /// never satisfied on a stock gateway. Reset to empty when the capability is
    /// not available (a disconnect / stock reconnect).
    private(set) var profiles: [ProfileSummary] = []

    #if DEBUG
    /// DEBUG-only: set the profile list without a network `loadProfiles()`
    /// call, so UITestSeed can populate the multi-profile drawer offline.
    /// Pairs with `ServerCapabilities._seedProfilesCapabilityForTesting`.
    /// Never compiled into Release.
    func _seedProfilesForTesting(_ seeded: [ProfileSummary]) {
        profiles = seeded
    }
    #endif

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

    /// Gate for per-row profile threading on open/delete. In production this is
    /// the same dormancy gate as the switcher; tests may override it to assert the
    /// call-site wiring without a live profile-capable gateway.
    private var profileThreadingAvailable: Bool {
        #if DEBUG
        if let override = profileThreadingAvailableForTesting { return override }
        #endif
        return isMultiProfileAvailable
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
    func markTurnStarted(storedId: String?, runtimeId: String? = nil) {
        guard let id = storedId, !id.isEmpty else { return }
        guard let identity = scopedSessionIdentity(
            forStoredID: id,
            runtimeID: runtimeId
        ) else { return }
        turnsInProgress.insert(identity)
    }

    /// Mark a turn completed (or failed/cancelled) for `storedId`. Called by
    /// `ConnectionStore` on `message.complete`, the gateway `error` terminal,
    /// and every turn-abort path. A `nil`/empty id is a no-op.
    func markTurnCompleted(storedId: String?, runtimeId: String? = nil) {
        guard let id = storedId, !id.isEmpty else { return }
        guard let identity = scopedSessionIdentity(
            forStoredID: id,
            runtimeID: runtimeId
        ) else { return }
        turnsInProgress.remove(identity)
    }

    /// Clear ALL in-progress turn flags. Belt-and-suspenders: called on
    /// disconnect/reconnect so a mid-turn transport drop can never leave a flag
    /// stuck, which would revive the infinite-carry-forward bug.
    func clearAllTurnsInProgress() {
        turnsInProgress.removeAll()
        // This hook is called on every disconnect/reconnect path. A fresh
        // connection must seed its own cursor before requesting deltas.
        resetSessionListDeltaState()
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
    /// request; tests stage a `SessionOpenResult` or failure so `open()` and
    /// ``resumeActiveAfterReconnect()`` are exercisable without a network.
    var resumeRPC: ((_ storedId: String, _ params: [String: JSONValue]) async throws -> SessionOpenResult)?

    /// Identity of the one raw `session.resume` permitted for a selected session
    /// on a particular accepted transport. Both `open()` and reconnect recovery
    /// reach this same RPC, so keeping the key here prevents readiness from
    /// releasing an open task and recovery at the same time into duplicate work.
    private struct RuntimeBindingKey: Hashable {
        let openToken: UUID
        let storedId: String
        let profileId: String?
        let transportEpoch: UInt64
    }

    private var runtimeBindingKey: RuntimeBindingKey?
    private var runtimeBindingTask: Task<SessionOpenResult, Error>?

    private func cancelRuntimeBinding() {
        runtimeBindingTask?.cancel()
        runtimeBindingTask = nil
        runtimeBindingKey = nil
    }

    /// Test seams historically run without a configured `ConnectionStore`. Once
    /// a test has a real accepted epoch, though, they must obey the same fencing
    /// as the production client so a late epoch-N failure cannot publish in N+1.
    private func currentBindingEpoch(usingResumeTestSeam: Bool) async -> UInt64? {
        guard let connection else { return 0 }
        if usingResumeTestSeam, connection.transportEpoch == 0 {
            return 0
        }
        guard await connection.waitForTransportReady(timeout: .seconds(120)),
              connection.isTransportReady else { return nil }
        return connection.transportEpoch
    }

    private func isCurrentRuntimeBinding(
        token: UUID,
        storedId: String,
        profileId: String?,
        connectionWorkGeneration: UInt64,
        transportEpoch: UInt64,
        usingResumeTestSeam: Bool
    ) -> Bool {
        guard openToken == token,
              activeStoredId == storedId,
              activeStoredProfile == profileId,
              self.connectionWorkGeneration == connectionWorkGeneration else { return false }
        guard let connection else { return true }
        guard connection.transportEpoch == transportEpoch else { return false }
        // Epoch zero is the deliberately transport-free unit-test case above.
        return usingResumeTestSeam && transportEpoch == 0 || connection.isTransportReady
    }

    private func coalescedSessionResume(
        storedId: String,
        profileId: String?,
        params: [String: JSONValue],
        token: UUID,
        transportEpoch: UInt64
    ) async throws -> SessionOpenResult {
        let key = RuntimeBindingKey(
            openToken: token,
            storedId: storedId,
            profileId: profileId,
            transportEpoch: transportEpoch
        )
        if runtimeBindingKey == key, let runtimeBindingTask {
            return try await runtimeBindingTask.value
        }

        let resumeRPC = self.resumeRPC
        let client = self.client
        let task = Task<SessionOpenResult, Error> {
            if let resumeRPC {
                return try await resumeRPC(storedId, params)
            }
            guard let client else { throw GatewayError.notConnected }
            return try await client.request(
                "session.resume",
                params: .object(params),
                timeout: .seconds(120)
            )
        }
        runtimeBindingKey = key
        runtimeBindingTask = task
        do {
            return try await task.value
        } catch {
            // Retain a successful task for this selection/epoch: a sibling
            // recovery caller can still consume that one result. Failures must
            // be released so reconnect can retry the selected session.
            if runtimeBindingKey == key {
                runtimeBindingTask = nil
                runtimeBindingKey = nil
            }
            throw error
        }
    }

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

    /// The last atomically committed manifest state, restored with the drawer.
    /// It is the shared freshness source for compact and split shells.
    private(set) var manifestFreshness: ManifestFreshness = .cached
    private(set) var manifestLastSyncedAt: Date?
    private(set) var manifestRevision: Int64 = 0

    /// Latches `true` after the first `refresh()` has run the cold-launch cache
    /// read. The read only fires when `sessions` is still empty (cold launch),
    /// so a warm in-memory list is never overwritten by a (possibly older) disk
    /// snapshot.
    /// The cache scope whose cold read has begun. This is deliberately a scope,
    /// not a process-wide Boolean: bootstrap can run before a gateway identity
    /// exists and profile switches must get their own local first paint.
    private var coldReadCacheScope: CacheScope?

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

    /// The active `(serverId, profileId)` cache partition, exposed so the
    /// composition root can hand ``ProjectsStore`` the SAME scope the session
    /// list uses (a profile/server switch then re-partitions both in lockstep).
    var projectsCacheScope: CacheScope? { currentCacheScope }

    func cacheIdentity(_ sessionId: String, profile: String? = nil) -> CacheIdentity? {
        guard let scope = currentCacheScope else { return nil }
        let actual = profile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileId = actual?.isEmpty == false ? actual! : (scope.profileId == CacheScope.allProfilesKey ? "default" : scope.profileId)
        return CacheIdentity(serverId: scope.serverId, profileId: profileId, sessionId: sessionId)
    }

    private static func normalizedProfileID(_ profile: String?) -> String {
        let value = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "default" : value
    }

    private func selectedProfileID(for summary: SessionSummary) -> String {
        let explicit = summary.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty { return explicit }
        let scope = activeProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scope.isEmpty, scope != CacheScope.allProfilesKey { return scope }
        return Self.defaultProfileName
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
    /// Signature: `(query, offset) async throws -> (results, rawPageFull)`.
    /// `rawPageFull` must reflect whether the raw (pre-collapse for plugin, direct
    /// for stock) server page was full — callers use it to determine whether more
    /// pages may exist via `searchHasMore`.
    var searchFetch: ((String, Int) async throws -> ([SessionSearchResult], Bool))?
    #endif

    /// In-flight transcript prefetch sweep (WhatsApp bar — coverage). Cancelled on
    /// disconnect/background so a paced background fetch never outlives the
    /// connection it was started under. At most one sweep runs at a time.
    private var prefetchTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        if let stored = defaults.array(forKey: DefaultsKeys.pinnedSessions) as? [String] {
            pinnedIds = Set(stored)
        }
        hideCron = (defaults.object(forKey: DefaultsKeys.hideCron) as? Bool) ?? true
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
        if let data = defaults.data(forKey: DefaultsKeys.sessionListDeltaCursors),
           let persisted = try? JSONDecoder().decode([PersistedSessionListCursor].self, from: data) {
            sessionListDeltaCursors = Dictionary(
                persisted.map { ($0.scope, $0.cursor) },
                uniquingKeysWith: { _, latest in latest }
            )
        }
        // STR-1022: profile-group collapse decisions are derived (see
        // ``isProfileGroupCollapsed(_:)``); these two sets hold only the user's
        // explicit overrides and are persisted so choices survive restarts.
        if let collapsed = defaults.array(forKey: DefaultsKeys.collapsedProfiles) as? [String] {
            collapsedProfiles = Set(collapsed)
        }
        if let expanded = defaults.array(forKey: DefaultsKeys.expandedProfiles) as? [String] {
            expandedProfiles = Set(expanded)
        }
    }

    /// Wire up the store graph. Called exactly once by `AppEnvironment`.
    func attach(connection: ConnectionStore, chat: ChatStore, attachments: AttachmentStore? = nil) {
        self.connection = connection
        self.chat = chat
        self.draftAttachments = attachments
        Task { [weak self] in
            guard let self else { return }
            guard self.workRepository == nil else { return }
            self.workRepository = try? await WorkRepository.openAppGroup(scope: self.durableWorkScope)
            self.restoreComposerDraft(for: self.activeComposerDraftKey)
        }
    }

    func attachWorkRepository(_ repository: WorkRepository) {
        workRepository = repository
        restoreComposerDraft(for: activeComposerDraftKey)
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
        resetSessionListDeltaState()
    }

    private var client: HermesGatewayClient? { connection?.client }

    /// A ``RestClient`` for the session-management endpoints (search / rename /
    /// archive / export — now ``RestClient`` extension members), resolved from the
    /// active connection's live token via ``ConnectionStore/rest``.
    ///
    /// ABH-194: this previously re-read ``KeychainService/loadToken(server:)``
    /// directly, creating a second token source that could diverge from
    /// ``ConnectionStore/currentToken`` (the authoritative in-memory token).
    /// Divergence scenarios: a re-pair that wrote `currentToken` before the
    /// Keychain item was updated, a device-token upgrade whose Keychain write
    /// failed (the `try?` path in ``ConnectionStore/configure(_:token:…)``), or
    /// a simulator reinstall that cleared UserDefaults but left a stale Keychain
    /// item. In all cases `SessionStore.restAPI` sent the stale/wrong token on
    /// REST calls and received HTTP 401, while everything routed through
    /// `connection.rest` / `currentToken` worked (including the WS auth and the
    /// transcript-fetch paths that correctly used `connection?.rest`).
    ///
    /// Fix: source the token from the single authoritative live path
    /// (`ConnectionStore.rest`) so there is only one token source. The
    /// HERMES_TOKEN dev-env override is already handled: `ConnectionStore.bootstrap`
    /// reads it and calls `configure()` with it, setting `currentToken` from the
    /// env value, so `connection?.rest` returns a client carrying the env token.
    /// Cold-launch safety is preserved: before `configure()` succeeds,
    /// `ConnectionStore.rest` returns `nil` exactly as the old Keychain read did
    /// (before any token existed), so callers' nil-guard / "Not connected." paths
    /// are unchanged.
    private var restAPI: RestClient? {
        connection?.rest
    }

    #if DEBUG
    /// DEBUG-only test accessor: the token string that ``restAPI`` would use for
    /// the next session-management REST call, or `nil` when there is no live
    /// connection. Exposed so regression tests can assert the single-source-of-truth
    /// invariant (ABH-194) without going through a real network call — the value
    /// equals ``ConnectionStore/rest``'s token, which is the authoritative
    /// in-memory ``ConnectionStore/currentToken``.
    var restAPITokenForTesting: String? { restAPI?.token }
    #endif

    // MARK: - Derived list slices

    /// Sessions after the human-Recents filter AND the multi-profile scope filter, sorted
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
    /// The source/count filter rejects cron, subagent, and true-empty rows. The
    /// source gate is duplicated server-side on fresh REST pages via
    /// ``recentsExcludeSources`` and `min_messages=1`, but remains client-side for
    /// old gateways, WS fallback rows, and stale cached rows. The profile filter is
    /// DORMANT unless multi-profile is available (no stale
    /// `activeProfile` can hide rows on a stock gateway). When available and a
    /// SPECIFIC profile scope is active, only rows whose `profile` matches survive;
    /// the aggregate ("all") scope keeps every row. The human-Recents filter still
    /// applies in every case.
    var visibleSessions: [SessionSummary] {
        var rows = sessions
        // Recents is human-chat-only BY CONSTRUCTION (drawer bifurcation):
        // automation runs (cron), agent-internal subagent/agent sessions,
        // generated loop/review/kanban machinery, and true-empty scaffolds never
        // become tappable chat history. Fresh REST pages also ask the server for
        // `exclude_sources=cron,subagent&min_messages=1`; this client-side gate
        // guarantees the stronger ABH-343 human-vs-machinery invariant for old
        // gateways, WS fallback, cli-source loop rows, and stale cache rows.
        rows = rows.filter(Self.isHumanRecentsSession)
        // ABH-373: this read-time filter is now BELT-AND-SUSPENDERS. The
        // invariant is established at ingress (mergeSessionPage +
        // paintFromCache), so machinery never enters `sessions`. This filter
        // remains as a defensive guarantee for any path that bypasses those
        // two gates (a future ingress point, or direct mutation during testing).
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

    /// Pure Recents eligibility gate (ABH-343). The drawer is a human-chat
    /// picker, not a channel picker: generated loop/kanban/review machinery may
    /// arrive as `source == "cli"`, so source-only filtering was insufficient.
    /// `messageCount == 0` is a known-empty scaffold and not pickable; `nil` is
    /// kept because older gateway/RPC payloads may omit the count even for real
    /// conversations.
    nonisolated static func isHumanRecentsSession(_ row: SessionSummary) -> Bool {
        isHumanRecentsSession(
            source: row.source,
            title: row.title,
            cwd: row.cwd,
            messageCount: row.messageCount
        )
    }

    /// Source/count overload for cache rows that have not decoded the full
    /// ``SessionSummary``. Kept beside the Recents predicate so Spotlight,
    /// transcript cache, and the drawer cannot drift on autonomous-source or
    /// empty-session eligibility.
    nonisolated static func isHumanRecentsSession(source: String?, messageCount: Int?) -> Bool {
        isHumanRecentsSession(source: source, title: nil, cwd: nil, messageCount: messageCount)
    }

    /// Full Recents predicate for REST/RPC rows with title + workspace metadata.
    /// The title/cwd checks are deliberately conservative and only catch
    /// unambiguous loop machinery; ordinary CLI conversations remain eligible.
    nonisolated static func isHumanRecentsSession(
        source: String?,
        title: String?,
        cwd: String?,
        messageCount: Int?
    ) -> Bool {
        if let count = messageCount, count == 0 { return false }
        let source = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if recentsMachinerySources.contains(source) { return false }

        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title.hasPrefix("loop plan") { return false }
        if recentsMachineryTitleFragments.contains(where: { title.contains($0) }) {
            return false
        }

        let cwd = (cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cwd.contains("/.worktrees/") || cwd.contains("/kanban/boards/") {
            return false
        }

        return true
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

    /// Offline rows are filtered by the selected profile even before the live
    /// capability probe settles. Duplicate stored ids are collapsed so the
    /// drawer never publishes two SwiftUI rows with the same identity.
    static func filterCachedSessions(
        _ rows: [SessionSummary],
        activeProfile: String,
        untaggedProfile: String? = nil
    ) -> [SessionSummary] {
        let requested = activeProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let allProfiles = requested.isEmpty || requested == CacheScope.allProfilesKey
        var seenScopedIDs: Set<String> = []
        return rows.filter { row in
            let explicit = row.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rowProfile = explicit.isEmpty
                ? (untaggedProfile ?? Self.defaultProfileName)
                : explicit
            guard allProfiles || rowProfile == requested else {
                return false
            }
            // Stored session ids are only unique inside a profile. Preserve
            // deliberate cross-profile collisions in the aggregate drawer.
            return seenScopedIDs.insert("\(rowProfile)\u{1F}\(row.id)").inserted
        }
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

    // MARK: - Drawer source grouping (ABH-345)

    /// Static source-section identities for the drawer. Matches the reachable
    /// desktop-parity source grouping order for the human chat feed: human chats,
    /// then messaging-platform chats. Automation runs are intentionally absent
    /// here because the session fetch path excludes cron/subagent rows; they live
    /// in the dedicated automation-runs surface instead.
    enum DrawerSourceKind: String, CaseIterable, Sendable {
        case chats
        case telegram

        var label: String {
            switch self {
            case .chats: return "Chats"
            case .telegram: return "Telegram"
            }
        }

        var systemImage: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right"
            case .telegram: return "paperplane"
            }
        }

        var emptyTitle: String {
            switch self {
            case .chats: return "No chats yet"
            case .telegram: return "No Telegram chats yet"
            }
        }
    }

    /// One source-grouped drawer section. `sessions` carries the full unpinned
    /// contents so the header count stays honest even when the group is empty.
    struct DrawerSourceGroup: Identifiable, Equatable, Sendable {
        let kind: DrawerSourceKind
        let sessions: [SessionSummary]

        var id: String { kind.rawValue }
        var count: Int { sessions.count }
        var label: String { kind.label }
        var systemImage: String { kind.systemImage }
        var emptyTitle: String { kind.emptyTitle }
    }

    /// Pinned drawer rows across all reachable drawer source groups. Pinning is a
    /// global affordance, so pinned Telegram rows float to the top instead of
    /// remaining inside the Telegram source section.
    var drawerPinnedSessions: [SessionSummary] {
        drawerSourceCandidateSessions.filter { pinnedIds.contains($0.id) }
    }

    /// Source-grouped unpinned sessions for the drawer. Groups are always returned
    /// in the static desktop order even when empty, giving the view a stable place
    /// to render designed per-group empty states.
    func drawerSourceGroups() -> [DrawerSourceGroup] {
        let unpinned = drawerSourceCandidateSessions.filter { !pinnedIds.contains($0.id) }
        return Self.drawerSourceGroups(from: unpinned)
    }

    nonisolated static func drawerSourceGroups(from rows: [SessionSummary]) -> [DrawerSourceGroup] {
        DrawerSourceKind.allCases.map { kind in
            DrawerSourceGroup(
                kind: kind,
                sessions: rows.filter { Self.drawerSourceKind(for: $0) == kind }
            )
        }
    }

    /// One owning-profile group for the All Profiles drawer. Rows remain full
    /// `SessionSummary` values so row actions keep threading `summary.profile`.
    struct DrawerProfileGroup: Identifiable, Equatable, Sendable {
        let profile: String
        let label: String
        let sessions: [SessionSummary]

        var id: String { profile }
        var count: Int { sessions.count }
        var sourceGroups: [DrawerSourceGroup] {
            SessionStore.drawerSourceGroups(from: sessions)
        }
    }

    /// All Profiles drawer groups: default profile first, then named profiles in
    /// localized alphabetical order. Pinned rows stay in the global Pinned section
    /// exactly as before; this groups the remaining drawer rows by their owner.
    func drawerProfileGroups() -> [DrawerProfileGroup] {
        guard isMultiProfileAvailable && isAllProfilesScope else { return [] }
        let unpinned = drawerSourceCandidateSessions.filter { !pinnedIds.contains($0.id) }
        return Self.drawerProfileGroups(rows: unpinned, profiles: profiles)
    }

    nonisolated static func drawerProfileGroups(
        rows: [SessionSummary],
        profiles: [ProfileSummary]
    ) -> [DrawerProfileGroup] {
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]

        for row in rows {
            let profile = normalizedDrawerProfile(row.profile)
            if buckets[profile] == nil {
                buckets[profile] = []
                order.append(profile)
            }
            buckets[profile]?.append(row)
        }

        let profileMap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
        let sorted = order.sorted { lhs, rhs in
            let lhsDefault = isDefaultDrawerProfile(lhs, profileMap: profileMap)
            let rhsDefault = isDefaultDrawerProfile(rhs, profileMap: profileMap)
            if lhsDefault != rhsDefault { return lhsDefault }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return sorted.compactMap { profile in
            guard let sessions = buckets[profile], !sessions.isEmpty else { return nil }
            return DrawerProfileGroup(
                profile: profile,
                label: labelForProfile(profile, profileMap: profileMap),
                sessions: sessions
            )
        }
    }

    private nonisolated static func normalizedDrawerProfile(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    private nonisolated static func isDefaultDrawerProfile(
        _ profile: String,
        profileMap: [String: ProfileSummary]
    ) -> Bool {
        profile == "default" || profileMap[profile]?.isDefault == true
    }

    private nonisolated static func labelForProfile(
        _ profile: String,
        profileMap: [String: ProfileSummary]
    ) -> String {
        guard let summary = profileMap[profile], summary.isDefault else {
            return profile
        }
        return "\(profile) (default)"
    }

    /// Rows eligible for the ABH-345 drawer source groups, after profile scope and
    /// newest-first ordering. This deliberately mirrors the live fetch path's
    /// human-facing session cache: cron/subagent automation rows are excluded by
    /// ``recentsExcludeSources`` before they ever populate `sessions`, so the
    /// drawer only advertises source groups it can actually fill.
    private var drawerSourceCandidateSessions: [SessionSummary] {
        let scoped = Self.filterByProfile(sessions, scope: activeProfile, multiAvailable: isMultiProfileAvailable)
            .filter { Self.drawerSourceKind(for: $0) != nil }
        return Self.sortedByActivity(scoped)
    }

    private nonisolated static func drawerSourceKind(for row: SessionSummary) -> DrawerSourceKind? {
        if isTelegramSource(row.source), isHumanRecentsSession(row) { return .telegram }
        if isHumanRecentsSession(row) { return .chats }
        return nil
    }

    private nonisolated static func isTelegramSource(_ source: String?) -> Bool {
        (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "telegram"
    }

    private nonisolated static func sortedByActivity(_ rows: [SessionSummary]) -> [SessionSummary] {
        var sorted = rows
        sorted.sort { lhs, rhs in
            let l = lhs.lastActive ?? lhs.startedAt ?? -.greatestFiniteMagnitude
            let r = rhs.lastActive ?? rhs.startedAt ?? -.greatestFiniteMagnitude
            return l > r
        }
        return sorted
    }

    // MARK: - Automation sessions slice (STR-351 / STR-542)

    /// Automation (cron + subagent run) sessions, fetched and cached
    /// independently of ``sessions``/``visibleSessions`` so the drawer
    /// Automation group preview and the Settings → Cron → Recent Runs deep
    /// surface (``AutomationRunsView``) share one live fetch contract instead
    /// of each running its own private REST call. Never populated from, and
    /// never merged into, ``sessions`` — Recents' cron/subagent exclusion is
    /// unaffected by this slice's existence.
    private(set) var automationSessions: [SessionSummary] = []

    /// Count of ``automationSessions`` as of the most recent successful
    /// fetch — i.e. the filtered row count, never the raw server-reported
    /// total. `nil` until the first successful fetch completes (mirrors
    /// ``totalSessions``). Deliberately NOT the server's `total` field: an
    /// older gateway that ignores `source=cron,subagent` can return a page
    /// containing human rows, which ``loadAutomationSessions()`` drops via
    /// ``isAutomationSource(_:)`` — preserving the untrusted server total
    /// here would let the slice's count silently disagree with its rows.
    private(set) var automationSessionsTotal: Int? = nil

    /// `true` while an automation-slice fetch is in flight. Distinct from
    /// ``isLoading``, which gates the Recents fetch.
    private(set) var isLoadingAutomationSessions: Bool = false

    /// Human-readable error from the most recent automation-slice fetch, or
    /// `nil` when it succeeded (or none has run yet).
    private(set) var automationSessionsError: String? = nil

    /// Monotonic token guarding ``loadAutomationSessions()`` the same way
    /// ``refreshToken`` guards ``refresh()``: a slow, superseded response can
    /// never overwrite a newer automation-slice result.
    private var automationRefreshToken: Int = 0

    /// Source values this slice both queries for and defends against at
    /// ingress — the single source of truth for the REST query value
    /// (`source=cron,subagent`) and the client-side filter, so the two can
    /// never drift apart.
    nonisolated static let automationSources = ["cron", "subagent"]

    #if DEBUG
    /// DEBUG-only seam: an explicit ``RestClient`` (typically
    /// URLProtocol-stubbed in tests) used instead of the live
    /// ``connection?.rest``. Lets tests prove ``loadAutomationSessions()``
    /// populates ``automationSessions`` by driving the real `RestClient`
    /// request path end-to-end, without hand-injecting the slice or standing
    /// up a live gateway connection.
    var automationRestClientForTesting: RestClient?
    #endif

    private var automationRest: RestClient? {
        #if DEBUG
        automationRestClientForTesting ?? connection?.rest
        #else
        connection?.rest
        #endif
    }

    /// Load (or refresh) the automation sessions slice. The single shared
    /// entry point for both the drawer Automation group preview and
    /// ``AutomationRunsView``'s deep Settings surface, so the two surfaces
    /// cannot drift onto two different fetch shapes (STR-351 reconciliation).
    ///
    /// Fetches cron + subagent rows with `include_children=true` (automation
    /// runs commonly nest subagent children the default parent-only listing
    /// hides), then re-applies ``isAutomationSource(_:)`` client-side as a
    /// defense-in-depth guarantee: an older gateway that ignores the
    /// `source`/`include_children` query params would otherwise hand back its
    /// entire unfiltered session list here.
    func loadAutomationSessions() async {
        guard let rest = automationRest else {
            automationSessionsError = "Not connected."
            isLoadingAutomationSessions = false
            return
        }
        isLoadingAutomationSessions = true
        automationRefreshToken &+= 1
        let myToken = automationRefreshToken
        do {
            let result = try await rest.sessionsWithTotal(
                source: Self.automationSources.joined(separator: ","),
                includeChildren: true
            )
            guard automationRefreshToken == myToken else { return }
            let filteredAutomationRows = result.sessions.filter { Self.isAutomationSource($0.source) }
            automationSessions = filteredAutomationRows
            automationSessionsTotal = filteredAutomationRows.count
            automationSessionsError = nil
            isLoadingAutomationSessions = false
        } catch {
            guard automationRefreshToken == myToken else { return }
            automationSessionsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoadingAutomationSessions = false
        }
    }

    /// Defense-in-depth predicate: is this row's source one of
    /// ``automationSources``? Applied at ingress in
    /// ``loadAutomationSessions()`` so an older gateway that ignores the
    /// `source`/`include_children` query params can never pollute the slice.
    nonisolated static func isAutomationSource(_ source: String?) -> Bool {
        automationSources.contains((source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    // MARK: - Workspace grouping (H2)

    /// One workspace section for the grouped Recents list: a stable group `id`
    /// (the trimmed `cwd`, or `"__no_workspace__"`), a display `label` (the
    /// basename, or "No workspace"), and the section's sessions.
    struct WorkspaceGroup: Identifiable, Equatable {
        let id: String
        let label: String
        let sessions: [SessionSummary]
    }

    /// Group ``unpinnedSessions`` by workspace, replicating the desktop sidebar's
    /// `workspaceGroupsFor` ordering for the legacy Recents grouped view.
    /// ``drawerWorkspaceGroups(for:)`` runs the same grouping algorithm over one
    /// source-group's rows so ABH-345 keeps workspaces scoped inside Chats.
    ///
    /// Ordering semantics:
    /// - **Pinned groups first.** Groups whose workspace key is in
    ///   ``pinnedWorkspaceKeys`` float to the top tier, preserving recency order
    ///   among themselves. Unpinned groups follow in the same recency order.
    /// - **Group order = recency.** Within each tier (pinned / unpinned), groups
    ///   appear in *first-seen* order of the recency-sorted input.
    /// - **Rows within a group = `startedAt` DESC, stably.** Newest-created on
    ///   top, but a stable sort means rows don't reshuffle when a message lands
    ///   (preserving muscle memory). A `nil` `startedAt` sorts to the bottom.
    ///
    /// Pinned sessions are intentionally absent: they live in the drawer's
    /// Pinned section regardless of grouping.
    /// Workspace groups for a single drawer source group. Used by the ABH-345
    /// source-grouped drawer so workspace folding stays inside Chats instead of
    /// mixing Telegram rows back into the human chat section.
    func drawerWorkspaceGroups(for group: DrawerSourceGroup) -> [WorkspaceGroup] {
        workspaceGroups(from: group.sessions)
    }

    func workspaceGroups() -> [WorkspaceGroup] {
        workspaceGroups(from: unpinnedSessions)
    }

    private func workspaceGroups(from rows: [SessionSummary]) -> [WorkspaceGroup] {
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]

        for session in rows {
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
    /// Idempotent and self-gating, preserving the scoped cold-read
    /// semantics the network merge relies on:
    ///   - fires at most once per cache scope — the scope-aware latch;
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
        // A pre-bootstrap call has no safe partition to latch. Wait until the
        // saved gateway has established a real cache identity instead.
        guard let scope = currentCacheScope else { return }
        // The scope latch normally collapses repeat calls to a single disk read.
        // EXCEPTION: if the in-memory list has since regressed to empty (a
        // cancelled/failed refresh cleared it, or a foreground recovery finds it
        // emptied), re-arm and re-paint from cache — otherwise the drawer stays
        // stuck empty until a network refresh lands. The read below re-checks
        // `sessions.isEmpty` after the await, so a concurrent populate is never
        // clobbered. (#208)
        guard coldReadCacheScope != scope || sessions.isEmpty else { return }
        guard sessions.isEmpty else {
            coldReadCacheScope = scope
            lastColdReadServerId = scope.serverId
            return
        }
        guard let cacheStore else { return }
        let paintStart = ContinuousClock.now
        var paintedRows = 0
        var paintFinished = false
        ReliabilityDiagnostics.shared.cachePaintStarted(identifier: nil)
        coldReadCacheScope = scope
        var cacheReadSucceeded = false
        defer {
            let duration = paintStart.duration(to: ContinuousClock.now)
            if paintFinished {
                ReliabilityDiagnostics.shared.cachePaintFinished(
                    rowCount: paintedRows, duration: duration
                )
            } else {
                ReliabilityDiagnostics.shared.cachePaintFailed(
                    rowCount: paintedRows, duration: duration
                )
            }
            // A transient GRDB/decode failure must not permanently suppress the
            // next foreground/bootstrap retry for this scope.
            if !cacheReadSucceeded, coldReadCacheScope == scope {
                coldReadCacheScope = nil
            }
        }
        do {
            lastColdReadServerId = scope.serverId
            if let manifest = try? await cacheStore.loadManifestProjection(scope: scope) {
                manifestFreshness = manifest.freshness
                manifestLastSyncedAt = manifest.lastSyncedAt
                manifestRevision = manifest.revision
            }
            var cached = Self.filterCachedSessions(
                try await cacheStore.loadSessionList(scope: scope),
                activeProfile: activeProfile,
                untaggedProfile: scope.profileId == CacheScope.allProfilesKey
                    ? nil
                    : scope.profileId
            )
            // A1(i)(iii): offline cold-open must NEVER blank the drawer just because
            // the persisted `activeProfile` (network-mutated by
            // `confirmActiveProfile`) partitions the concrete-profile read down to
            // zero rows, or because rows on this device were mis-stamped with the
            // literal "all" by an older build. When a concrete-profile scoped read
            // comes back empty, fall back to a serverId-only aggregate read painted
            // with aggregate semantics — the disk holds the user's chats and they
            // must appear. The next network refresh re-narrows to the confirmed
            // profile. The aggregate `loadSessionList` selects every non-legacy row
            // (including any mis-stamped "all"), so this covers both root causes.
            if cached.isEmpty, scope.profileId != CacheScope.allProfilesKey {
                let aggregate = try await cacheStore.loadSessionList(
                    scope: CacheScope(serverId: scope.serverId,
                                      profileId: CacheScope.allProfilesKey)
                )
                cached = Self.filterCachedSessions(
                    aggregate, activeProfile: CacheScope.allProfilesKey
                )
            }
            cacheReadSucceeded = true
            paintedRows = cached.count
            // Profile/server selection can change while the actor read is
            // suspended. Do not publish the old partition into the new shell.
            guard currentCacheScope == scope, coldReadCacheScope == scope else { return }
            if !cached.isEmpty {
                // Re-check emptiness after the await: a concurrent network
                // refresh may have populated the list while we were reading
                // disk — never overwrite fresher server data with the cache.
                if sessions.isEmpty {
                    // ABH-373: gate machinery at the cache-restore ingress too.
                    // A stale cache may contain rows that were eligible when
                    // cached but are now machinery (or were always machinery
                    // and slipped through an older build). The predicate is the
                    // single source of truth.
                    sessions = cached.filter(Self.isHumanRecentsSession)
                    // The cold cache paint is a real first page for the
                    // pagination cursors and the initial-fill fast-path.
                    // ABH-373: seed all-seen ids from the RAW cached page
                    // (before the machinery filter) so the cursor math on
                    // subsequent grow-limit appends is accurate.
                    seenServerSessionIds = Set(cached.map(sessionListIdentity))
                    loadedCount = cached.count
                    if let lastOpened = try? await cacheStore.loadLastOpenedSession(scope: scope),
                       currentCacheScope == scope,
                       coldReadCacheScope == scope,
                       let summary = sessions.first(where: {
                           $0.id == lastOpened.sessionId
                               && Self.normalizedProfileID($0.profile) == lastOpened.profileId
                       }) {
                        // Offline restoration changes only local selection and
                        // paints cached transcript. Runtime binding is deferred
                        // until the gateway is operationally ready.
                        open(summary, bindRuntime: false)
                    }
                    loadedOffset = cached.count
                }
            }
            paintFinished = true
        } catch {
            return
        }
    }

    // MARK: - Transcript prefetch (WhatsApp bar — coverage)

    /// How many most-recent human Recents sessions the post-hydration sweep warms.
    private static let prefetchSessionCount = 30
    /// Concurrency ceiling for the prefetch sweep — gentle pacing so it never
    /// contends with a live turn or the user's own open. 3 in flight at a time.
    private static let prefetchConcurrency = 3

    /// Background-prefetch transcripts for the top ~30 most-recent human Recents
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

        // Snapshot the prefetch targets on the main actor (newest-first human
        // Recents, excluding the open session). `visibleSessions` already applies
        // source/count filters and sorts by recency, so it is the right source. Map to a Sendable tuple so
        // the detached sweep captures plain values, not SessionSummary state.
        let openId = activeStoredId
        guard let cacheScope = currentCacheScope else { return }
        let targets: [(identity: CacheIdentity, lastActive: Double?)] = visibleSessions
            .filter { $0.id != openId }
            .prefix(Self.prefetchSessionCount)
            .map {
                let profile = $0.profile ?? (cacheScope.profileId == CacheScope.allProfilesKey ? "default" : cacheScope.profileId)
                return (CacheIdentity(serverId: cacheScope.serverId, profileId: profile, sessionId: $0.id), $0.lastActive)
            }
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
                        target.identity, lastActive: target.lastActive)) == true {
                        continue
                    }
                    if inFlight >= concurrency {
                        await group.next()
                        inFlight -= 1
                    }
                    let identity = target.identity
                    let sessionId = identity.sessionId
                    group.addTask(priority: .utility) {
                        if Task.isCancelled { return }
                        guard let stored = try? await fetch(identity) else { return }
                        if Task.isCancelled { return }
                        try? await cacheStore.saveTranscript(
                            identity: identity, messages: stored)
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

    /// Profile-aware variant of the prefetch seam. The legacy one-argument
    /// seam remains for existing tests, while production and new coverage carry
    /// the exact profile from the cached row all the way to the REST request.
    var prefetchFetchWithProfile: (@Sendable (String, String) async throws -> [StoredMessage])?

    /// Serializes persisted drawer selection. A newer selection waits for any
    /// already-started write, then re-checks its token before committing.
    private var lastOpenPersistenceTask: Task<Void, Never>?

    #if DEBUG
    /// DEBUG-only RestClient seam for exercising the live prefetch fetch resolver
    /// with a stubbed URLSession. The production path still resolves through the
    /// live ``ConnectionStore/rest`` client; tests use this only when they need to
    /// assert which REST endpoint the default prefetch sweep chose.
    var prefetchRestClientForTesting: RestClient?
    #endif

    /// The injected ``prefetchFetch``, or a `@Sendable` closure built from the live
    /// `RestClient` (a Sendable value struct — safe to capture across the task-group
    /// boundary). `nil` when unconfigured/offline, which makes the whole sweep a
    /// no-op (purely additive coverage, never a correctness dependency).
    private var resolvedPrefetchFetch: (@Sendable (CacheIdentity) async throws -> [StoredMessage])? {
        if let prefetchFetchWithProfile {
            return { identity in try await prefetchFetchWithProfile(identity.sessionId, identity.profileId) }
        }
        if let prefetchFetch {
            return { identity in try await prefetchFetch(identity.sessionId) }
        }
        #if DEBUG
        let resolvedRest = prefetchRestClientForTesting ?? connection?.rest
        #else
        let resolvedRest = connection?.rest
        #endif
        guard let rest = resolvedRest else { return nil }
        return { [cacheStore] identity in
            let sessionId = identity.sessionId
            // Cursor-bearing cached transcripts take the delta-aware path first so
            // an unchanged background sweep pays only the cheap cursor check. Rows
            // without a cursor keep the ABH-400 page-window prefetch behavior.
            if let cacheStore {
                do {
                    if let cursor = try await cacheStore.deltaCursor(for: identity),
                       cursor.afterId > 0 {
                        // Profile-scoped rows use the profile endpoint. Its
                        // current protocol lacks a delta equivalent, so prefer
                        // correctness over the aggregate-only delta shortcut.
                        if identity.profileId != "default" {
                            return try await rest.messages(sessionId: sessionId, profile: identity.profileId)
                        }
                        return try await fetchTranscriptDeltaAware(
                            rest: rest,
                            cacheStore: cacheStore,
                            sessionId: sessionId,
                            identity: identity
                        )
                    }
                } catch {
                    // Treat a cursor read failure like "no cursor"; the fetch path
                    // below preserves the previous best-effort prefetch semantics.
                }
            }
            if identity.profileId != "default" {
                return try await rest.messages(sessionId: sessionId, profile: identity.profileId)
            }
            if let page = await fetchTranscriptPage(
                rest: rest,
                sessionId: sessionId,
                limit: ChatStore.transcriptOpenWindowLimit
            ) {
                return page.messages
            }
            return try await fetchTranscriptDeltaAware(
                rest: rest,
                cacheStore: cacheStore,
                sessionId: sessionId,
                identity: identity
            )
        }
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
    /// Foreground refresh remains non-throwing and keeps its existing API.
    func refresh() async {
        _ = await refreshOutcome()
    }

    /// The same authoritative cache/REST/WS pipeline with a typed result for
    /// background policy. This must remain the sole refresh implementation.
    func refreshOutcome() async -> BackgroundRefreshOutcome {
        let myConnectionWorkGeneration = connectionWorkGeneration
        let myCacheScope = currentCacheScope
        var fallbackOutcome: BackgroundRefreshOutcome?
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
            guard connectionWorkGeneration == myConnectionWorkGeneration else { return .timeout }
            // A different server's list is showing — drop the stale in-memory rows
            // and re-arm the cold paint so the new server repaints from its own
            // (now sole) cached rows rather than leaving the prior server's list
            // on screen while the network refetches.
            sessions = []
            loadedCount = 0
            loadedOffset = 0
            seenServerSessionIds = []  // ABH-373
            resetSessionListDeltaState()
            coldReadCacheScope = nil
        }

        await paintFromCache()
        guard connectionWorkGeneration == myConnectionWorkGeneration,
              currentCacheScope == myCacheScope else { return .timeout }
        if let cacheStore, let scope = currentCacheScope {
            // Bounded, resumable batches. Yield between transactions so cache
            // paint and interaction are never held behind historical indexing.
            Task.detached(priority: .utility) {
                while (try? await cacheStore.backfillSearchIndex(scope: scope)) == false {
                    await Task.yield()
                }
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
                guard refreshToken == myToken,
                      currentCacheScope == myCacheScope else { return .timeout }
                mergeSessionPage(fetched, total: total)
                if let myCacheScope { persistSessionListToCache(scope: myCacheScope) }
                lastError = nil

                // Kick the decoupled initial-fill (idempotent; survives a sibling
                // refresh()'s token bump). It runs to the target / server-exhaust
                // on its OWN task, independent of `myToken`.
                ensureInitialFill()

                SpotlightIndexer.index(sessions: sessions)
            } catch {
                guard refreshToken == myToken,
                      currentCacheScope == myCacheScope else { return .timeout }
                return recordRefreshFailure(error)
            }
            return .success
        }

        // Multi-profile aggregate rail (F4b): only when the capability is
        // available AND the scope is not the default profile. The default scope
        // and every stock-gateway case skip this entirely → the existing fetch.
        if usesAggregateRail, let rest = connection?.rest {
            do {
                // fill30: the aggregate rail is just as autonomous-loop-dense as the single
                // rail, so it needs the SAME fill-to-target treatment. Floor the
                // first-page window at what the fill reached (so a post-fill
                // heartbeat / drawer-open can't collapse it back to 100) and kick
                // the decoupled `ensureInitialFill()` — which pages this rail via
                // `profileSessions` (routed inside `resolvedInitialFillFetch`).
                // Previously this branch fetched a HARDCODED limit=100 and `return`ed
                // BEFORE the fill, so on a multi-profile gateway the drawer was stuck
                // at ~6 human Recents regardless of the single-rail fix.
                let fetchLimit = max(100, loadedFloor, loadedCount)
                let result = try await rest.profileSessions(
                    profile: DefaultsKeys.allProfilesScope, limit: fetchLimit,
                    excludeSource: Self.recentsExcludeSources
                )
                guard refreshToken == myToken,
                      currentCacheScope == myCacheScope else { return .timeout }
                mergeSessionPage(result.sessions, total: result.total)
                if let myCacheScope { persistSessionListToCache(scope: myCacheScope) }
                lastError = nil
                ensureInitialFill()
                SpotlightIndexer.index(sessions: sessions)
                return .success
            } catch {
                guard refreshToken == myToken,
                      currentCacheScope == myCacheScope else { return .timeout }
                let outcome = Self.backgroundRefreshOutcome(for: error)
                if outcome == .authFailure { fallbackOutcome = outcome }
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
        let rest = connection?.rest
        if rest != nil || sessionListDeltaFetch != nil {
            let deltaScope = !usesAggregateRail
                && (sessionListDeltaFetch != nil || rest?.pathStyle == .plugin)
                ? sessionListDeltaScope(excludeSource: Self.recentsExcludeSources)
                : nil
            do {
                // Floor the first-page window at what the initial fill reached so a
                // post-fill heartbeat / gateway.ready replace can't collapse the
                // drawer back to ~100 rows (fill30): `max(100, loadedFloor, loadedCount)`.
                let fetchLimit = max(100, loadedFloor, loadedCount)
                // A2: the transport generation at the start of this refresh. If it
                // advanced since the delta rail last full-seeded, a reconnect /
                // foreground-recovery happened and the FIRST refresh on the new
                // transport must FULL-seed (bypass the persisted cursor) before
                // incremental deltas resume — see `lastReseededTransportGeneration`.
                let reseedGeneration = currentReconnectGeneration
                if let deltaScope {
                    var previousCursor = sessionListDeltaCursors[deltaScope]
                    if previousCursor != nil,
                       reseedGeneration != lastReseededTransportGeneration {
                        // Reconnected/recovered since the last seed: drop the cursor
                        // so this refresh takes the full first-page seed + fill-to-
                        // target path, then deltas resume from the new cursor.
                        previousCursor = nil
                        sessionListDeltaCursors[deltaScope] = nil
                    }
                    let delta: SessionListDeltaResult?
                    do {
                        delta = try await resolvedSessionListDeltaFetch(
                            rest: rest,
                            limit: fetchLimit,
                            updatedSince: previousCursor
                        )
                    } catch {
                        delta = nil
                    }
                    guard refreshToken == myToken,
                          currentCacheScope == myCacheScope,
                          sessionListDeltaScope(
                              excludeSource: Self.recentsExcludeSources
                          ) == deltaScope else { return .timeout }

                    if let delta {
                        sessionListDeltaCursors[deltaScope] = delta.cursor
                        // This refresh is now the seed for the current transport
                        // generation; subsequent same-generation refreshes resume
                        // incremental deltas (A2).
                        lastReseededTransportGeneration = reseedGeneration
                        let didChange: Bool
                        if previousCursor == nil {
                            mergeSessionPage(delta.sessions, total: delta.total)
                            reconcilePendingSessionListTombstones(
                                afterAuthoritativePage: delta.sessions,
                                scope: deltaScope
                            )
                            didChange = true
                        } else {
                            didChange = mergeSessionDelta(delta, scope: deltaScope)
                        }
                        if didChange {
                            if let myCacheScope { persistSessionListToCache(scope: myCacheScope) }
                            SpotlightIndexer.index(sessions: sessions)
                        }
                        lastError = nil
                        ensureInitialFill()
                        return .success
                    }

                    // A missing/old/malformed plugin endpoint must retry from a
                    // full seed later. Continue through the stock REST path now.
                    sessionListDeltaCursors[deltaScope] = nil
                }

                guard let rest else { return .retryableFailure }
                let result = try await rest.sessionsWithTotal(
                    limit: fetchLimit, minMessages: 1,
                    excludeSource: Self.recentsExcludeSources
                )
                guard refreshToken == myToken,
                      currentCacheScope == myCacheScope else { return .timeout }
                if let deltaScope {
                    guard sessionListDeltaScope(
                        excludeSource: Self.recentsExcludeSources
                    ) == deltaScope else { return .timeout }
                }
                mergeSessionPage(result.sessions, total: result.total)
                if let deltaScope {
                    reconcilePendingSessionListTombstones(
                        afterAuthoritativePage: result.sessions,
                        scope: deltaScope
                    )
                    // The stock REST path is itself a full first-page seed; mark the
                    // current transport generation as seeded so a delta cursor set
                    // later this generation is not force-bypassed again (A2).
                    lastReseededTransportGeneration = reseedGeneration
                }
                if let myCacheScope { persistSessionListToCache(scope: myCacheScope) }
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
                return .success
            } catch {
                guard refreshToken == myToken,
                      currentCacheScope == myCacheScope else { return .timeout }
                let outcome = Self.backgroundRefreshOutcome(for: error)
                if outcome == .authFailure { fallbackOutcome = outcome }
                if let deltaScope {
                    guard sessionListDeltaScope(
                        excludeSource: Self.recentsExcludeSources
                    ) == deltaScope else { return .timeout }
                }
                // Fall through to the WS RPC below.
            }
        }

        guard let client else { return fallbackOutcome ?? .retryableFailure }
        do {
            let raw = try await client.requestRaw(
                "session.list",
                params: .object(["limit": .number(100)])
            )
            guard refreshToken == myToken,
                  currentCacheScope == myCacheScope else { return .timeout }
            let fetched = Self.parseSessions(from: raw)
            // WS RPC shape has no total; preserve whatever was last known.
            mergeSessionPage(fetched, total: nil)
            if let myCacheScope { persistSessionListToCache(scope: myCacheScope) }
            lastError = nil
            // Republish the session list into Spotlight (fire-and-forget).
            SpotlightIndexer.index(sessions: sessions)
            return .success
        } catch {
            guard refreshToken == myToken,
                  currentCacheScope == myCacheScope else { return .timeout }
            return recordRefreshFailure(error, fallback: fallbackOutcome)
        }
    }

    /// Cancellation is control flow, never a user-facing failure: a reconnect,
    /// scope switch, or superseded task all cancel an in-flight refresh. Covers
    /// the three shapes it arrives in — a thrown `CancellationError`, cooperative
    /// `Task.isCancelled`, and a `URLError.cancelled` from a torn-down session. (#208)
    static func isRefreshCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func backgroundRefreshOutcome(for error: Error) -> BackgroundRefreshOutcome {
        if isRefreshCancellation(error) { return .timeout }
        if ConnectionStore.isAuthFailure(error) { return .authFailure }
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timeout }
        if case GatewayError.timeout = error { return .timeout }
        return .retryableFailure
    }

    /// Single write seam for a failed refresh/fill fetch. Classifies the error and
    /// writes ``lastError`` ONLY for a genuine failure — a cancellation never
    /// reaches it, so a cancelled refresh can never paint a false error row over
    /// retained cached rows. Returns the classified background-policy outcome
    /// (honouring an earlier `fallback`, e.g. a prior auth failure). (#208)
    @discardableResult
    private func recordRefreshFailure(
        _ error: Error,
        fallback: BackgroundRefreshOutcome? = nil
    ) -> BackgroundRefreshOutcome {
        if Self.isRefreshCancellation(error) { return fallback ?? .timeout }
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return fallback ?? Self.backgroundRefreshOutcome(for: error)
    }

    private func resolvedSessionListDeltaFetch(
        rest: RestClient?,
        limit: Int,
        updatedSince: String?
    ) async throws -> SessionListDeltaResult? {
        if let fetch = sessionListDeltaFetch {
            return try await fetch(updatedSince, limit)
        }
        guard let rest else { return nil }
        return await rest.sessionListDelta(
            limit: limit,
            minMessages: 1,
            excludeSource: Self.recentsExcludeSources,
            updatedSince: updatedSince
        )
    }

    /// Reconcile deferred tombstones after a full, authoritative page. Rows
    /// present in the page are live again; rows still present locally but absent
    /// from the page are working-set survivors and remain pending until a later
    /// refresh can remove them safely.
    private func reconcilePendingSessionListTombstones(
        afterAuthoritativePage page: [SessionSummary],
        scope: SessionListDeltaScope
    ) {
        let incomingIds = Set(page.filter(Self.isHumanRecentsSession).map(\.id))
        let currentIds = Set(sessions.map(\.id))
        var pending = pendingSessionListTombstones[scope] ?? []
        pending.subtract(incomingIds)
        pending.formUnion(currentIds.subtracting(incomingIds))
        pending.formIntersection(currentIds)
        if pending.isEmpty {
            pendingSessionListTombstones[scope] = nil
        } else {
            pendingSessionListTombstones[scope] = pending
        }
    }

    /// Merge changed rows and deferred removals without replacing the loaded
    /// grow-limit window. Returns whether the backing `sessions` rows changed so
    /// empty heartbeats can skip cache and Spotlight rewrites.
    /// Whether an optimistically-bumped local `lastActive` should be carried
    /// forward over a lagging server value for `identity` on a list merge (the
    /// anti-flicker keep-active-at-top invariant, ABH-86/178/157).
    ///
    /// A row is kept ahead of the server only while it is genuinely being driven.
    /// Two independent liveness signals qualify, OR'd so a gap in one never
    /// regresses the other:
    ///   - `turnsInProgress`: the EXPLICIT per-turn flag (ABH-178). Covers a long
    ///     turn whose silent inter-frame gap exceeds ``liveWindow`` — a time-proxy
    ///     alone would decay mid-turn and flicker the row down.
    ///   - `lastActivityAt` fresh within ``liveWindow``: a live-frame time signal.
    ///     Covers a turn STILL receiving frames after `turnsInProgress` was
    ///     force-cleared by a disconnect/reconnect (`clearAllTurnsInProgress`).
    ///     Without it, the reconnect's transport-epoch bump forces an A2 full
    ///     first-page reseed (`mergeSessionPage`) in which the active session —
    ///     present in the server page, so not a working-set survivor — decays to
    ///     the server's stale `lastActive` and sinks to "yesterday" until the next
    ///     live frame re-bumps it (LANE D transient mis-order).
    /// A SETTLED row (no in-flight turn AND no recent frame) qualifies for NEITHER,
    /// so a stale device-clock bump still decays to server authority (ABH-157).
    private func shouldCarryForwardLastActive(_ identity: String) -> Bool {
        if turnsInProgress.contains(identity) { return true }
        if let at = lastActivityAt[identity],
           Date().timeIntervalSince(at) < Self.liveWindow { return true }
        return false
    }

    private func mergeSessionDelta(
        _ delta: SessionListDeltaResult,
        scope: SessionListDeltaScope
    ) -> Bool {
        let previousTotal = totalSessions
        if let total = delta.total { totalSessions = total }

        let incoming = delta.sessions.filter(Self.isHumanRecentsSession)
        let incomingIds = Set(incoming.map(\.id))
        let filteredChangedIds = Set(delta.sessions.map(\.id)).subtracting(incomingIds)
        var departedIds = Set(delta.tombstones.map(\.id))
        departedIds.formUnion(filteredChangedIds)
        // A current human row wins if a defensive server response includes both
        // an upsert and a tombstone for the same id.
        departedIds.subtract(incomingIds)

        let totalChanged = delta.total != nil && previousTotal != delta.total
        if !incoming.isEmpty || !departedIds.isEmpty || totalChanged {
            sessionListUniverseRevision &+= 1
        }

        // Grow-limit pagination counts rows in the CURRENT server universe. A
        // tombstoned id that was previously consumed must stop advancing the
        // cursor, even when its rendered row remains temporarily protected as
        // active/pinned/live. Otherwise a reduced total can leave loadedOffset at
        // or past the end while current rows still exist beyond the loaded window.
        let departedSeenIds = departedIds.intersection(seenServerSessionIds)
        if !departedSeenIds.isEmpty {
            seenServerSessionIds.subtract(departedSeenIds)
            loadedCount = max(0, loadedCount - departedSeenIds.count)
            loadedOffset = loadedCount
        }

        var pending = pendingSessionListTombstones[scope] ?? []
        pending.formUnion(departedIds)
        // A current human row is authoritative evidence that a prior tombstone
        // was superseded (for example, a session re-entered the list universe).
        pending.subtract(incomingIds)

        let removableIds = pending.subtracting(workingSetSessionIds())
        let countBeforeRemoval = sessions.count
        if !removableIds.isEmpty {
            sessions.removeAll { removableIds.contains($0.id) }
            pending.subtract(removableIds)
            if let cacheStore, let cacheScope = currentCacheScope {
                for id in removableIds {
                    Task { try? await cacheStore.removeSession(scope: cacheScope, sessionId: id) }
                }
            }
        }
        let didRemove = sessions.count != countBeforeRemoval

        let priorLastActive: [String: Double] = sessions.reduce(into: [:]) { result, row in
            if let lastActive = row.lastActive { result[sessionListIdentity(row)] = lastActive }
        }
        let reconciled = incoming.map { row -> SessionSummary in
            let identity = sessionListIdentity(row)
            guard let prior = priorLastActive[identity],
                  shouldCarryForwardLastActive(identity),
                  prior > (row.lastActive ?? -.greatestFiniteMagnitude) else { return row }
            var bumped = row
            bumped.lastActive = prior
            return bumped
        }

        var didUpsert = false
        for row in reconciled {
            if let index = sessions.firstIndex(where: { $0.id == row.id }) {
                if sessions[index] != row {
                    sessions[index] = row
                    didUpsert = true
                }
            } else {
                sessions.append(row)
                didUpsert = true
            }
        }

        if didUpsert {
            // Match `visibleSessions`: descending activity with stable ordering
            // when timestamps tie. Do not add an id tie-breaker here.
            sessions.sort { lhs, rhs in
                let left = lhs.lastActive ?? lhs.startedAt ?? -.greatestFiniteMagnitude
                let right = rhs.lastActive ?? rhs.startedAt ?? -.greatestFiniteMagnitude
                return left > right
            }
        }

        if pending.isEmpty {
            pendingSessionListTombstones[scope] = nil
        } else {
            pendingSessionListTombstones[scope] = pending
        }
        return didRemove || didUpsert
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
    private func sessionListIdentity(_ row: SessionSummary) -> String {
        usesAggregateRail ? row.scopedIdentity : row.id
    }

    private func mergeSessionPage(_ page: [SessionSummary], total: Int?, isAppend: Bool = false) {
        // ABH-373: Gate machinery at INGRESS. Every path that writes into
        // `sessions` — fetch, WS-triggered refresh, background refresh, load-more
        // append, initial-fill append — funnels through this merge. Filtering
        // here means machinery (cron / subagent / agent / cli-loop) can NEVER
        // enter the drawer's backing array, so there is no flicker where a row
        // flashes in then disappears on the next `visibleSessions` read. The
        // predicate is the single source of truth (`isHumanRecentsSession`);
        // `visibleSessions` retains it as belt-and-suspenders, but the invariant
        // is established at write time, not read time.
        //
        // ABH-373 (two dedupe concerns — do NOT conflate them):
        //
        // 1. ROW-INCLUSION dedupe (which rows enter `sessions`): against the
        //    RENDERED set `sessions.map(\.id)`. This is the only set that
        //    contains working-set survivors (pinned/active/live rows carried
        //    forward from a prior first-page replace). Deduping row inclusion
        //    against any other set risks appending a survivor twice → a duplicate
        //    Identifiable id → SwiftUI ForEach undefined behavior.
        //
        // 2. CURSOR-ADVANCE dedupe (how far `loadedCount` has consumed the
        //    server list): against `seenServerSessionIds` (ALL server rows ever
        //    consumed, INCLUDING machinery filtered out at ingress). Grow-limit
        //    pagination re-fetches the full expanded window each iteration, so
        //    overlap rows reappear — they must NOT advance the cursor again.
        //    This set intentionally EXCLUDES working-set survivors (they are
        //    local-only, never delivered by the server), which is exactly why it
        //    must never be used for row inclusion.
        let rawCount = page.count
        let pageIds = page.map(sessionListIdentity)
        let incoming = page.filter(Self.isHumanRecentsSession)
        // Update the total count when the server provides it.
        if let total { totalSessions = total }

        if isAppend {
            // ABH-373 REWORK: row-inclusion dedupe MUST be against the actual
            // rendered set (`sessions`), NOT against `seenServerSessionIds`. The
            // all-seen-id set intentionally EXCLUDES working-set survivors
            // (pinned/active/live rows carried forward from a prior first-page
            // replace that were absent from that server page). A survivor that
            // reappears in a grown-limit append window would pass a
            // `seenServerSessionIds` filter and be appended a SECOND time → a
            // duplicate Identifiable id in `sessions` → SwiftUI ForEach undefined
            // behavior. Dedupe against the rendered set guarantees each id is
            // present exactly once.
            let existingIds = Set(sessions.map(sessionListIdentity))
            let newRows = incoming.filter { !existingIds.contains(sessionListIdentity($0)) }
            // ABH-373: the CURSOR advance dedupe stays against `seenServerSessionIds`
            // (all server rows ever consumed, including filtered machinery). A
            // grow-limit page returns the full expanded window, so rows from earlier
            // pages reappear — they are NOT new and must not advance `loadedCount`
            // again. This set is cursor-only; never use it for row inclusion.
            let newlySeenRawIds = pageIds.filter { !seenServerSessionIds.contains($0) }
            seenServerSessionIds.formUnion(pageIds)
            sessions.append(contentsOf: newRows)
            loadedCount += newlySeenRawIds.count
            return
        }

        // A full first-page response establishes a new authoritative universe.
        // Initial-fill requests that started before this replacement must re-page
        // even when the replacement happened to preserve `loadedCount`.
        sessionListUniverseRevision &+= 1

        // First-page (replace) path — original ABH-86 merge semantics.
        let incomingIds = Set(incoming.map(sessionListIdentity))

        // Working-set: active session + live/working + pinned. These survive
        // even if the server's current page window omits them.
        let workingIds = workingSetSessionIdentities()

        // Survivors: current rows absent from the incoming page but in the working set.
        let survivors = sessions.filter {
            !incomingIds.contains(sessionListIdentity($0))
                && workingIds.contains(sessionListIdentity($0))
        }

        // ABH-86: carry a HIGHER local `lastActive` forward over the incoming
        // server value. `noteActivity` optimistically bumps a session to NOW on a
        // live frame so it re-sorts to the top immediately; but the server only
        // advances `lastActive` on message.complete, so the debounced refresh that
        // fires ~400ms after message.start returns the OLD value and would knock
        // the row back down (visible flicker). Server `lastActive` is monotonic,
        // so `max(local, server)` keeps the optimistic position until the server
        // genuinely catches up, then converges to the authoritative value.
        let priorLastActive: [String: Double] = sessions.reduce(into: [:]) { acc, s in
            if let la = s.lastActive { acc[sessionListIdentity(s)] = la }
        }
        // ABH-178 / LANE D — gate the carry-forward on `shouldCarryForwardLastActive`:
        // the EXPLICIT per-turn flag (turnsInProgress) OR a live frame within the
        // ``liveWindow``. The explicit flag covers a long turn whose silent
        // inter-frame gap exceeds `liveWindow` (a time-proxy alone decayed mid-turn
        // and dropped the row to server authority). The live-window signal covers a
        // turn STILL streaming after `turnsInProgress` was force-cleared by a
        // disconnect/reconnect (`clearAllTurnsInProgress`): the reconnect's
        // transport-epoch bump forces an A2 full first-page reseed here, and without
        // the second signal the still-live active session would decay to the
        // server's stale `lastActive` and sink to "yesterday" (LANE D). The flag is
        // set on message.start and cleared on every turn-end path (complete, error,
        // cancel, disconnect/reconnect), so a mid-turn socket drop can never leave it
        // stuck; the live-window signal is self-expiring (pruned after `liveWindow`),
        // so a SETTLED bump still decays and neither signal revives the ABH-157
        // infinite-carry-forward bug.
        let reconciled = incoming.map { row -> SessionSummary in
            let identity = sessionListIdentity(row)
            guard let prior = priorLastActive[identity],
                  shouldCarryForwardLastActive(identity),
                  prior > (row.lastActive ?? -.greatestFiniteMagnitude) else { return row }
            var bumped = row
            bumped.lastActive = prior
            return bumped
        }

        // Merge: survivors first (they have the most up-to-date local state),
        // then the incoming page (server authority for everything else).
        // build125 smoothness (#208): a periodic first-page refresh (the 30s
        // heartbeat / drawer-open) very often returns byte-identical rows. Under
        // `@Observable`, reassigning `sessions` with an equal-but-new array still
        // fires the observation and relayouts the whole LazyVStack. Publish ONLY
        // when the merged result actually differs — an id-diff over the value-typed
        // array (`SessionSummary: Equatable`) — so an unchanged refresh causes zero
        // list churn. Ordering and contents are byte-identical to the prior
        // unconditional replace when it does differ.
        let merged = survivors + reconciled
        if merged != sessions {
            sessions = merged
        }

        // Reset pagination cursors on a first-page refresh.
        // ABH-373: a first-page replace is a fresh server window — rebuild the
        // all-seen-id set from the RAW page (before the machinery filter) so the
        // cursor math on subsequent grow-limit appends is accurate. Only the RAW
        // page ids count as "seen"; survivors (working-set rows absent from the
        // page) are local-only and must not be seeded (they may be machinery a
        // prior build failed to filter, and a future append should still skip them
        // honestly). `loadedCount` / `loadedOffset` track the RAW page position.
        seenServerSessionIds = Set(pageIds)
        loadedCount = rawCount
        loadedOffset = rawCount
    }

    private func workingSetSessionIds() -> Set<String> {
        var workingIds = pinnedIds
        if let active = activeStoredId { workingIds.insert(active) }
        // Any session that has had broadcast activity in the live window counts
        // as working. Keep this distinct from `turnsInProgress`, which gates only
        // optimistic timestamp carry-forward.
        let now = Date()
        for (id, at) in lastActivityAt {
            if now.timeIntervalSince(at) < Self.liveWindow { workingIds.insert(id) }
        }
        return workingIds
    }

    private func workingSetSessionIdentities() -> Set<String> {
        guard usesAggregateRail else { return workingSetSessionIds() }
        let now = Date()
        return Set(sessions.compactMap { row in
            let identity = sessionListIdentity(row)
            let isWorking = pinnedIds.contains(row.id)
                || isActive(row)
                || lastActivityAt[identity].map { now.timeIntervalSince($0) < Self.liveWindow } == true
            return isWorking ? identity : nil
        })
    }

    private func scopedSessionIdentity(
        forStoredID id: String,
        runtimeID: String? = nil
    ) -> String? {
        guard usesAggregateRail else { return id }
        let matches = sessions.filter { $0.id == id }
        if activeStoredId == id,
           runtimeID != nil,
           runtimeID == activeRuntimeId,
           let activeScopedIdentity {
            return activeScopedIdentity
        }
        guard matches.count == 1, let row = matches.first else { return nil }
        return sessionListIdentity(row)
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
              let identity = scopedSessionIdentity(forStoredID: id),
              let idx = sessions.firstIndex(where: { sessionListIdentity($0) == identity }) else { return }
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
        lastActivityAt[identity] = Date()
    }

    /// P3 write-through: persist the current `sessions` array into the local
    /// cache, fire-and-forget, OFF the UI path. Called after every successful
    /// `mergeSessionPage` so the cache tracks the freshest list. `saveSessionList`
    /// is an upsert (never deletes rows absent from the batch) and preserves
    /// `isPinned`/`lastAccessedAt`/transcript cursors on existing rows, so a
    /// partial-page refresh can never evict an unseen session or drop a cached
    /// transcript. No cache (tests/previews) ⇒ this is a no-op.
    private func persistSessionListToCache(scope: CacheScope) {
        guard let cacheStore, currentCacheScope == scope else { return }
        let snapshot = sessions
        Task { [weak self] in
            guard let self, self.currentCacheScope == scope else { return }
            try? await cacheStore.saveSessionList(snapshot, scope: scope)
        }
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
    /// - A patched gateway server-filters cron/subagent via `exclude_sources`
    ///   (plural — the real FastAPI param, see `RestClient.sessionsWithTotal`), so
    ///   the window is already automation-free and this loop converges fast. The
    ///   client-side Recents filter remains the hard invariant guarantee against a
    ///   STOCK/older gateway that ignores the param and returns a dense firehose window: `loadMore`
    ///   keeps fetching in a loop until `visibleSessions` grows OR there are no more
    ///   server rows — so the user is never stranded at a wall of hidden automation rows.
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
        // autonomous firehose window filters most of each fetched page out.
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
                recordRefreshFailure(error)
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
    /// filters (human-Recents / profile — `visibleSessions` already applies them) OR
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
    /// never retried it. Net: the drawer stuck at ~6 visible through dense automation rows.
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
    ///   (a gateway with < 30 human Recents rows never spins) and bounds itself with a
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
            // done so a <30-human-Recents gateway never spins on every refresh().
            // An UNKNOWN total is NOT exhaustion (release audit): a payload
            // that omits `total` must keep paging — the no-progress guard
            // below is the reliable exhaustion signal in that case.
            if let total = totalSessions, loadedCount >= total {
                initialFillDone = true
                return
            }

            let priorLoaded = loadedCount
            let priorUniverseRevision = sessionListUniverseRevision
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
                // If `loadedCount` OR the server-universe revision no longer
                // matches what we paged from, this page is for a stale window:
                // skip the append and re-loop to recompute a fresh `newLimit`.
                // The revision catches same-sized first-page replacements and
                // unseen tombstones that cursor math alone cannot observe.
                guard loadedCount == priorLoaded,
                      sessionListUniverseRevision == priorUniverseRevision else { continue }
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
                // Cancellation routes through the shared seam so a torn-down fill
                // never surfaces a false error row (#208).
                recordRefreshFailure(error)
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

    /// Test seam for priming pagination invariants around delta refreshes.
    #if DEBUG
    func setPaginationForTesting(loadedCount: Int, loadedOffset: Int, total: Int?) {
        self.loadedCount = loadedCount
        self.loadedOffset = loadedOffset
        self.totalSessions = total
    }

    /// Read-only accessor to the wired connection so tests can seed a ready
    /// transport (`ConnectionStore._seedConnectedForTesting`) without threading the
    /// store through their own graph builder.
    var connectionForTesting: ConnectionStore? { connection }

    /// Stamp the active runtime binding (id + the transport epoch it was minted
    /// under) exactly as a live resume would, so the `ensureActiveRuntime`
    /// fast-path — which now requires a transport-ready connection AND a matching
    /// epoch (#210) — is deterministically exercisable without a gateway.
    func _bindActiveRuntimeForTesting(id: String, epoch: UInt64) {
        activeRuntimeId = id
        activeRuntimeEpoch = epoch
    }
    #endif

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
        seenServerSessionIds = []  // ABH-373
        // A profile switch invalidates all in-flight selection work. The
        // durable selection remains available through cache restoration, but a
        // late old-profile resume/transcript must not publish here.
        openToken = UUID()
        clearActive()
        coldReadCacheScope = nil
        Task { [weak self] in await self?.refresh() }
    }

    // MARK: - Activation

    /// Open (resume) an existing session: `session.resume` then seed the
    /// transcript into `ChatStore` from the full REST history.
    /// Monotonic token for the most recent `open()`; background work from a
    /// superseded open (the user tapped another session) checks it and bails.
    private var openToken = UUID()
    /// The accepted transport generation that created `activeRuntimeId`.
    /// Runtime ids are ephemeral and cannot be reused after a reconnect.
    private var activeRuntimeEpoch: UInt64?
    /// The drawer's pending DISMISSAL INTENT (QA-1 B3). A drawer row tap hands
    /// its close here (`open(_:revealOnFirstPaint:)`); it fires on first paint
    /// or on the 300ms liveness deadline — whichever lands first — EXACTLY
    /// ONCE. Unlike the old `openRevealToken` gate, a SUPERSEDING open() that
    /// carries no reveal of its own (cold cache restore, cross-session review,
    /// land/recovery rotations) no longer clears it: the tap's intent to close
    /// the drawer survives any token rotation, so the drawer can never be
    /// stranded open by a reveal-less `open()` landing in the reveal window
    /// (the reported "sometimes leaves the drawer open" race). Only a NEWER
    /// drawer tap (a fresh reveal) replaces it; `firePendingDrawerReveal()`
    /// consumes it.
    private var pendingDrawerReveal: (@MainActor () -> Void)?
    private static let drawerRevealDeadline: Duration = .milliseconds(300)

    /// S9 (QA-3, 3rd recurrence): a monotonic epoch + wall-clock stamp of the
    /// most recent USER drawer gesture. Bumped by ``recordDrawerUserGesture``
    /// on every gesture that takes control of navigation (drawer row tap →
    /// `open(_:revealOnFirstPaint:)`, search-result tap, "New chat" →
    /// `startDraft`). The dismissal latch (`pendingDrawerReveal`) is a one-shot
    /// consumed at first-paint/300ms — but programmatic RE-OPEN edges
    /// (``PendingIntentRouter/drainDurable`` over a parked `.openSessions` App
    /// Intent, legacy `drain`, the notification route) are unserialized against
    /// it: a foreground transition that re-drains an older open-intent AFTER
    /// the tap-close fires re-opens the drawer over the in-flight load
    /// (last-writer-wins = the intent, not the user). The epoch lets those
    /// open-intents detect that the user has since taken control — they carry
    /// their queue `createdAt` and drop themselves when the user gestured at
    /// or after that instant. The user's in-app gesture always wins.
    private var drawerUserGestureEpoch: UInt64 = 0
    private var drawerUserGestureAt: Date = .distantPast

    /// Record a user-initiated drawer navigation gesture (row tap, search-result
    /// tap, "New chat" draft). The wall-clock stamp is compared against a
    /// programmatic open-intent's queue time so an intent queued BEFORE the
    /// gesture is dropped; the epoch lets an in-flight intent that captured the
    /// value before an await detect the bump after it. Test-injectable `now`
    /// keeps the regression deterministic.
    func recordDrawerUserGesture(now: Date = Date()) {
        drawerUserGestureEpoch &+= 1
        drawerUserGestureAt = now
    }

    /// Read the current gesture epoch. Programmatic open-intent paths capture
    /// this BEFORE their first await so a user gesture that lands during the
    /// await is detectable after it (`drawerUserGestureEpochAdvanced(since:)`).
    func currentDrawerUserGestureEpoch() -> UInt64 {
        drawerUserGestureEpoch
    }

    /// True iff a user drawer gesture landed strictly after `epoch` was
    /// captured. Used by open-intent paths that capture-then-await.
    func drawerUserGestureEpochAdvanced(since epoch: UInt64) -> Bool {
        drawerUserGestureEpoch > epoch
    }

    /// True iff a user drawer gesture landed at or after `queuedAt`. Used by
    /// ``PendingIntentRouter/drainDurable`` to drop a `.openSessions` App Intent
    /// whose queue time PREDATES the user's more recent in-app navigation —
    /// exactly the tap-during-in-flight-load race (S9).
    func drawerUserGestureHappenedSince(_ queuedAt: Date) -> Bool {
        drawerUserGestureAt >= queuedAt
    }

    /// Consume the pending drawer dismissal exactly once (QA-1 B3). Both fire
    /// edges — first paint (``seedTranscriptCacheFirst``) and the liveness
    /// deadline armed in ``open(_:)`` — funnel here, so whichever wins closes
    /// the drawer and the other is a no-op.
    private func firePendingDrawerReveal() {
        let reveal = pendingDrawerReveal
        pendingDrawerReveal = nil
        reveal?()
    }

    /// ABH-372 warm-switch cache: the already-normalized transcript snapshots
    /// from sessions opened in this app process. The disk cache avoids a network
    /// fetch, but a warm switch still paid SQLite decode + full `toChatMessages`
    /// normalization before the first frame. Keeping the normalized rows lets a
    /// re-open paint immediately, then reconcile with the authoritative delta/full
    /// fetch in the background. Bounded by recent session id to avoid unbounded
    /// transcript retention during long mobile sessions.
    private var warmOpenSnapshots: [String: [ChatMessage]] = [:]
    private var warmOpenSnapshotOrder: [String] = []
    private static let warmOpenSnapshotLimit = 6

    /// QA-3 S7/A3 — the stored session id whose transcript the chat view
    /// currently holds: stamped on every successful paint / reset this store
    /// drives. A re-open of the SAME session (a row re-tap, a notification
    /// deep-link onto the active chat) must NEVER re-run the first-frame cache
    /// paint over it — the cached copy is a known-partial tail window, and
    /// painting it `.replace` over the full in-memory transcript truncated the
    /// timeline to the window: the eager bottom-anchored VStack then rendered
    /// the surviving tail at the bottom with PURE VOID above on scroll-up
    /// (IMG_2589/2590). Provenance-keyed (not `activeStoredId`-keyed) so a
    /// superseded in-flight open can never masquerade as a same-session
    /// repaint. `nil` = the transcript holds no session (draft/reset/empty).
    private var transcriptPaintedStoredId: String?

    private func cachedWarmOpenSnapshot(for storedId: String) -> [ChatMessage]? {
        warmOpenSnapshots[storedId]
    }

    /// QA-3 S6/A2 — DURABLE OPTIMISTIC ECHOES: optimistic user echoes keyed by
    /// stored session id. `ChatStore.send` (relay branch) and `presentOutboxEcho`
    /// persist each echo here; the warm snapshot carries it so a session switch
    /// away and back (or any store rebuild that repaints from the warm/disk
    /// cache) re-renders the prompt BEFORE the relay's `userMessage` item
    /// re-lands — the S6 prompt-vanish (IMG_2585/2591: working rows with no
    /// prompt above them). ``markEchoReconciled(storedId:clientMessageID:text:)``
    /// purges an echo once the relay projection adopts it (or the user deletes
    /// a failed send), so a repaint never re-presents a second bubble beside
    /// the reconciled row.
    private var pendingDurableEchoes: [String: [ChatMessage]] = [:]

    /// Persist an optimistic echo into the session-keyed warm snapshot the
    /// switch-and-back paint reads. No-op without a stored session id (a
    /// draft send binds its echo once the relay-created session id lands —
    /// ChatStore re-calls this after `landRelayCreatedSession`).
    func persistDurableEcho(storedId: String?, echo: ChatMessage) {
        guard let storedId, !storedId.isEmpty else { return }
        var pending = pendingDurableEchoes[storedId] ?? []
        pending.removeAll {
            ($0.clientMessageID != nil && $0.clientMessageID == echo.clientMessageID)
                || $0.id == echo.id
        }
        pending.append(echo)
        pendingDurableEchoes[storedId] = pending
        // Fold the echo into the warm snapshot NOW when one exists (it leads
        // the repaint); otherwise the next `rememberWarmOpenSnapshot` for the
        // session folds every still-pending echo in (self-healing on the
        // session's next paint).
        if var snapshot = warmOpenSnapshots[storedId] {
            snapshot.removeAll {
                ($0.clientMessageID != nil && $0.clientMessageID == echo.clientMessageID)
                    || $0.id == echo.id
            }
            snapshot.append(echo)
            warmOpenSnapshots[storedId] = snapshot
        }
    }

    /// Drop a durable echo once it is reconciled — the relay `userMessage`
    /// adoption consumed its row (`adoptRelayEcho`), or the user deleted a
    /// failed send (`removeLocalEcho`). Idempotent; text-keyed only for
    /// cmid-less echoes (a distinct send of identical text carries its own
    /// cmid and must survive).
    func markEchoReconciled(storedId: String?, clientMessageID: String?, text: String) {
        guard let storedId, !storedId.isEmpty else { return }
        func isThisEcho(_ message: ChatMessage) -> Bool {
            if let clientMessageID { return message.clientMessageID == clientMessageID }
            return message.clientMessageID == nil && message.text == text
        }
        if var pending = pendingDurableEchoes[storedId] {
            pending.removeAll(where: isThisEcho)
            pendingDurableEchoes[storedId] = pending.isEmpty ? nil : pending
        }
        if var snapshot = warmOpenSnapshots[storedId] {
            snapshot.removeAll(where: isThisEcho)
            warmOpenSnapshots[storedId] = snapshot
        }
    }

    /// R1 write-through eviction (contract §1.2 / RR4): persist a SETTLED
    /// background entry's transcript before the coordinator drops it from the
    /// bounded LRU map — the next open paints from disk (I3: the cache is a
    /// seed) and the relay snapshot reconciles over it (I14). Text rows only
    /// (user + agent): the cache paints a seed the stream supersedes by
    /// item-id union, never a co-author. Fire-and-forget, off the UI path;
    /// `CacheStore` no-ops cron sessions (never transcript-cached).
    func persistRelayEntryWriteThrough(sessionID: String, items: [ChatItem]) {
        guard let cacheStore, let identity = cacheIdentity(sessionID) else { return }
        var wireId = 0
        let now = Date().timeIntervalSince1970
        let stored: [StoredMessage] = items.compactMap { item in
            let role: String
            switch item.type {
            case .userMessage:   role = "user"
            case .agentMessage:  role = "assistant"
            default: return nil
            }
            let text = item.textBody
            guard !text.isEmpty else { return nil }
            wireId += 1
            return StoredMessage(role: role, content: .string(text),
                                 timestamp: now, wireId: wireId)
        }
        guard !stored.isEmpty else { return }
        Task { try? await cacheStore.saveTranscript(identity: identity, messages: stored) }
    }

    private func rememberWarmOpenSnapshot(_ normalized: [ChatMessage], for storedId: String) {
        warmOpenSnapshots[storedId] = mergedWarmSnapshot(normalized, for: storedId)
        warmOpenSnapshotOrder.removeAll { $0 == storedId }
        warmOpenSnapshotOrder.append(storedId)
        if warmOpenSnapshotOrder.count > Self.warmOpenSnapshotLimit {
            let overflow = warmOpenSnapshotOrder.count - Self.warmOpenSnapshotLimit
            for evicted in warmOpenSnapshotOrder.prefix(overflow) {
                warmOpenSnapshots.removeValue(forKey: evicted)
            }
            warmOpenSnapshotOrder.removeFirst(overflow)
        }
    }

    /// QA-3 S7/A3 — warm snapshots are written from KNOWN-PARTIAL seeds (every
    /// seed source is a recent-tail window), so an OVERWRITE would degrade the
    /// warm copy to the window: a same-process re-open of a session the user
    /// had backward-paged would repaint only the tail (their loaded scrollback
    /// gone). Merge instead: `incoming` is the spine; unmatched EXISTING rows
    /// that precede the first matched row are the previously-loaded older
    /// history — PREPEND them (unmatched TRAILING rows are superseded content
    /// — an old streaming row, a since-deleted row — and drop). Then re-append
    /// any still-pending durable echo the incoming window does not cover
    /// (S6): a network seed that lands before the gateway persists the prompt
    /// must not lose it from the warm copy.
    private func mergedWarmSnapshot(
        _ incoming: [ChatMessage], for storedId: String
    ) -> [ChatMessage] {
        let existing = warmOpenSnapshots[storedId] ?? []
        var merged: [ChatMessage]
        if existing.isEmpty {
            merged = incoming
        } else {
            let incomingIDs = Set(incoming.map(\.id))
            if let firstMatch = existing.firstIndex(where: { incomingIDs.contains($0.id) }) {
                // Rows before the first match are previously-loaded older
                // history (backward paging) the window does not cover —
                // prepend them.
                merged = Array(existing.prefix(firstMatch)) + incoming
            } else {
                // No overlap (an empty reconcile, or a window that slid past
                // every loaded row): keep the existing spine and append the
                // genuinely-new incoming rows — NEVER drop loaded history
                // (R15 union contract: the merged view never shows less
                // settled history than the snapshot held before).
                let existingIDs = Set(existing.map(\.id))
                merged = existing + incoming.filter { !existingIDs.contains($0.id) }
            }
        }
        for echo in pendingDurableEchoes[storedId] ?? [] {
            let covered = merged.contains {
                ($0.clientMessageID != nil && $0.clientMessageID == echo.clientMessageID)
                    || $0.id == echo.id
                    || ($0.role == .user && $0.clientMessageID == nil && $0.text == echo.text)
            }
            if !covered { merged.append(echo) }
        }
        return merged
    }

    #if DEBUG
    /// DEBUG-only handle to the most recent open-seed Task. Stored so tests can
    /// `await` it without depending on wall-clock `settle()`. Set by `open()`
    /// before the seed Task is spawned; `nil` when no open is in flight.
    /// Never compiled into Release.
    private(set) var lastOpenSeedTask: Task<Void, Never>?

    /// DEBUG-only handle to the most recent open-resume Task. Stored so live
    /// re-entry tests can await the resume → status reconciliation path without a
    /// wall-clock settle.
    private(set) var lastOpenResumeTask: Task<Void, Never>?

    /// DEBUG-only hook for tests that need to hold the first-paint path while
    /// exercising the drawer reveal deadline.
    var beforeOpenSeedForTesting: (() async -> Void)?

    /// DEBUG-only: await the most recently spawned open-seed Task, then yield
    /// once so any main-actor mutations it enqueued have a chance to propagate.
    /// Call this in tests INSTEAD OF (or after) `settle()` to deterministically
    /// wait for the seed to land without a wall-clock timeout.
    func waitForPendingOpenForTesting() async {
        await lastOpenSeedTask?.value
        await lastOpenResumeTask?.value
        await lastOpenPersistenceTask?.value
        // One additional cooperative yield so `@Observable` write propagations
        // that happen synchronously inside the open Tasks' final awaits have
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
    ///   in the same window never fires a stale close. A selected-row re-tap fires
    ///   the reveal immediately because the content is already active, and a 300 ms
    ///   deadline races first paint so a missed paint signal cannot strand the
    ///   drawer. `nil` (the default, every non-drawer caller) preserves the exact
    ///   prior behavior.
    func open(
        _ summary: SessionSummary,
        revealOnFirstPaint: (@MainActor () -> Void)? = nil,
        bindRuntime: Bool = true
    ) {
        let wasAlreadyActive = isActive(summary)
        if let previous = activeSummary,
           previous.scopedIdentity != summary.scopedIdentity {
            ReliabilityDiagnostics.shared.sessionSuperseded(identifier: previous.scopedIdentity)
        }
        ReliabilityDiagnostics.shared.sessionSelected(identifier: summary.scopedIdentity)

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

        // S1 (Opus review): a SESSION SWITCH must not inherit a pending scroll
        // target left over from the PREVIOUS session. Clear when the incoming id
        // DIFFERS from the current `activeStoredId`. The deep-link path
        // (HermesURLRouter.openSession) sets `pendingMessageJump` for the target
        // id and then calls `open(summary)` — when that target is ALREADY the
        // active session (re-open, `activeStoredId == summary.id`) the just-set
        // jump is preserved; a deep-link to a different session re-arms via the
        // URL router's own `pendingMessageJump = messageId` assignment, which
        // runs on the SAME tap tick and is re-applied after this clear because
        // `openSession` is invoked synchronously after the assignment (the
        // router sets the jump, THEN calls open; this clear runs inside open, so
        // it would clear it — guarded by the id-equality check: when the
        // deep-link targets the already-active session the jump survives). The
        // `open(searchResult:)` path likewise targets the result's own session;
        // if it differs from active, the stale clear is correct and the result's
        // jump is re-set by `open(searchResult:)` AFTER clearSearch but BEFORE
        // open — re-ordered below to set after the switch clear.
        if !wasAlreadyActive {
            pendingMessageJump = nil
            pendingMessageJumpAttempts = 0
            pendingMessageJumpSnippet = nil
            pendingSearchScroll = nil
            pendingSearchScrollIsSnippet = false
            resetComposerHistoryBrowse()
        }

        // Activate instantly — the chat view can present right away with a loading
        // transcript instead of blocking navigation on the gateway. These pointers are
        // CHEAP and drive the drawer selection highlight + gate the composer + resolve
        // the seed's stored id, so they MUST land synchronously on the tap tick.
        let token = UUID()
        cancelRuntimeBinding()
        openToken = token
        // QA-1 B3: a drawer row tap hands its close here — record the intent.
        // A reveal-LESS open (cold cache restore, cross-session review, the
        // recovery path) leaves any pending intent ALIVE: the drawer is still
        // open and still wants to close, and killing the intent is exactly the
        // rotation that stranded it before.
        if let revealOnFirstPaint {
            pendingDrawerReveal = revealOnFirstPaint
            // S9 (QA-3): a drawer row tap is a USER gesture that takes control
            // of navigation — the drawer will close on first paint / 300ms
            // deadline. Stamp the epoch + wall-clock so a programmatic open
            // intent (drainDurable over a parked `.openSessions` App Intent,
            // re-drained on the foreground transition that accompanies the
            // tap-during-in-flight-load race) can detect that the user acted
            // AFTER it was queued and drop itself instead of re-opening the
            // drawer over the in-flight load.
            recordDrawerUserGesture()
        }
        let drawerIntentPending = pendingDrawerReveal != nil
        activeRuntimeId = nil          // gates the composer until resume lands
        activeRuntimeEpoch = nil
        activeStoredProfile = selectedProfileID(for: summary)
        activeStoredId = summary.id
        if let cacheStore, let scope = currentCacheScope,
           let identity = cacheIdentity(summary.id, profile: summary.profile) {
            let previousPersistence = lastOpenPersistenceTask
            let persistenceTask = Task { [weak self] in
                await previousPersistence?.value
                // A delayed A write may not overwrite a newer B selection. If A
                // was already inside SQLite, B commits strictly after it.
                guard let self, self.openToken == token else { return }
                try? await cacheStore.saveLastOpenedSession(identity, manifestScope: scope)
            }
            lastOpenPersistenceTask = persistenceTask
        }
        let networkProfile = profileParam(for: summary)
        // Cache identity comes from the row itself. It must not depend on the
        // live capability gate used for network profile parameters.
        let cacheProfile = selectedProfileID(for: summary)
        let transcriptWorkGeneration = connectionWorkGeneration
        let transcriptTransportEpoch = connection?.transportEpoch ?? 0
        // Fresh user intent to use this session: supersede any in-flight on-demand
        // re-resume (it was for the PREVIOUS session — its result must not bind
        // here) and reset the budget so a session that exhausted its retries
        // earlier can self-heal again.
        cancelEnsureRuntime()
        ensureRuntimeTargetId = summary.id
        ensureRuntimeAttempts = 0

        if wasAlreadyActive {
            if drawerIntentPending { firePendingDrawerReveal() }
        } else if drawerIntentPending {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.drawerRevealDeadline)
                // QA-1 B3: NO `openToken` gate here — the dismissal is
                // intent-based. Any pending drawer close fires on this deadline
                // regardless of the token rotations that used to kill it; first
                // paint consuming the intent earlier makes this a no-op. The
                // drawer can no longer be stranded open past the deadline.
                self?.firePendingDrawerReveal()
            }
        }

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
        // QA-1 B3: the seed's first-paint reveal — consume the pending drawer
        // dismissal intent when this open carries one. Computed OUTSIDE the
        // Task (explicit optional type) so the seed closure's inference stays
        // trivial for the type checker.
        let firstPaintReveal: (@MainActor () -> Void)?
        if wasAlreadyActive || !drawerIntentPending {
            firstPaintReveal = nil
        } else {
            firstPaintReveal = { [weak self] in
                guard let self else { return }
                firePendingDrawerReveal()
            }
        }
        let seedTask = Task { [weak self] in
            guard let self, self.openToken == token else { return }
            #if DEBUG
            await self.beforeOpenSeedForTesting?()
            guard self.openToken == token else { return }
            #endif
            await self.seedTranscriptCacheFirst(
                storedId: summary.id,
                networkProfile: networkProfile,
                cacheProfile: cacheProfile,
                token: token,
                workGeneration: transcriptWorkGeneration,
                transportEpoch: transcriptTransportEpoch,
                onFirstPaint: firstPaintReveal
            )
        }
        #if DEBUG
        lastOpenSeedTask = seedTask
        #endif

        // Cache restoration intentionally stops after local selection/paint.
        // Connection recovery invokes `resumeActiveAfterReconnect()` once the
        // ready handshake succeeds.
        guard bindRuntime else { return }

        // Wave-2 relay transport: when the relay is the active transport, the
        // gateway-direct `session.resume` RPC below cannot run — the gateway
        // socket is idle (only the relay client is connected), so it would throw
        // "Not connected to the Hermes gateway" and strand the deep-link
        // resume-to-send. Resume + own the session over the relay coordinator
        // instead, mirroring how the relay item projection already streams its
        // snapshot, so the composer unlocks and sends route through the relay.
        // The gateway-direct path (default OFF) is byte-identical below.
        if let connection, connection.transportPath == .relay {
            bindRelayRuntime(
                summary: summary,
                token: token,
                connectionWorkGeneration: connectionWorkGeneration
            )
            return
        }

        // Slow path: gateway resume — spins up the agent server-side; only
        // prompt submission depends on it.
        let resumeTask = Task { [weak self] in
            guard let self, self.client != nil || self.resumeRPC != nil else { return }
            let usingResumeTestSeam = self.resumeRPC != nil
            let connectionWorkGeneration = self.connectionWorkGeneration
            guard let bindingEpoch = await self.currentBindingEpoch(
                usingResumeTestSeam: usingResumeTestSeam
            ) else { return }
            do {
                // Thread the row's profile scope so an All-profiles tap resumes in
                // the row's owning profile home. Omitted for default/all/dormant
                // cases — byte-for-byte the shipped resume.
                var resumeParams: [String: JSONValue] = ["session_id": .string(summary.id)]
                if let networkProfile {
                    resumeParams["profile"] = .string(networkProfile)
                }
                let result = try await self.coalescedSessionResume(
                    storedId: summary.id,
                    profileId: cacheProfile,
                    params: resumeParams,
                    token: token,
                    transportEpoch: bindingEpoch
                )
                guard self.isCurrentRuntimeBinding(
                    token: token,
                    storedId: summary.id,
                    profileId: cacheProfile,
                    connectionWorkGeneration: connectionWorkGeneration,
                    transportEpoch: bindingEpoch,
                    usingResumeTestSeam: usingResumeTestSeam
                ) else {
                    if !usingResumeTestSeam,
                       self.connection?.transportEpoch != bindingEpoch {
                        ReliabilityDiagnostics.shared.epochRejected(
                            expected: bindingEpoch,
                            received: self.connection?.transportEpoch
                        )
                    }
                    if self.activeStoredId != summary.id || self.openToken != token {
                        ReliabilityDiagnostics.shared.sessionSuperseded(identifier: summary.id)
                    }
                    return
                }  // superseded or an older transport
                self.activeRuntimeId = result.sessionId
                self.activeRuntimeEpoch = bindingEpoch
                ReliabilityDiagnostics.shared.sessionBound(
                    identifier: summary.scopedIdentity, epoch: bindingEpoch
                )
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
                let boundStoredId = result.storedSessionId ?? summary.id
                if boundStoredId != summary.id {
                    // Re-stamp prompts queued under the parent id to the
                    // continuation BEFORE the swap, so drain's affinity guard
                    // doesn't skip them forever once activeStoredId moves.
                    self.onStoredIdMigrated?(summary.id, boundStoredId)
                    self.activeStoredId = boundStoredId
                    // Same token: the chain-tip seed's REST await is just as
                    // outrunnable by a newer open() as the fast path (R1 #43).
                    await self.seedTranscript(
                        storedId: boundStoredId,
                        networkProfile: networkProfile,
                        cacheProfile: cacheProfile,
                        token: token,
                        workGeneration: transcriptWorkGeneration,
                        transportEpoch: transcriptTransportEpoch
                    )
                    // Surface the chain-tip row in the drawer NOW rather than
                    // on the next 30s heartbeat (release audit P2).
                    Task { [weak self] in await self?.refresh() }
                }
                self.lastError = nil
                self.sessionActionError = nil
                // Runtime bound: clear the self-heal budget and flush anything the
                // composer queued during this resume window (an idle desktop-driven
                // session emits no turn-completion to trigger a drain otherwise).
                // The drain no-ops while a foreign turn streams and is re-entrancy
                self.ensureRuntimeAttempts = 0
                // ABH-371 live re-entry: the transcript seed is persisted history,
                // not proof the just-resumed runtime is idle. Wait for the open seed
                // so a stale REST/cache snapshot cannot erase the placeholder, then
                // reconcile against live `session.status`. If the runtime reports a
                // turn in flight, ChatStore restores the streaming placeholder + Stop
                // state immediately instead of showing a completed-turn action row.
                // Run this BEFORE the runtime-bound queue drain; otherwise an idle
                // queued prompt could slip into an already-running server turn during
                // the resume/status gap.
                await seedTask.value
                guard self.isCurrentRuntimeBinding(
                    token: token,
                    storedId: boundStoredId,
                    profileId: self.activeStoredProfile,
                    connectionWorkGeneration: connectionWorkGeneration,
                    transportEpoch: bindingEpoch,
                    usingResumeTestSeam: usingResumeTestSeam
                ), self.activeRuntimeId == result.sessionId else { return }
                await self.chat?.reconcileLiveTurnStatus(
                    runtimeId: result.sessionId,
                    snapshotRunning: result.snapshotRunning,
                    inflight: result.inflight
                )
                // Runtime bound: flush anything the composer queued during this
                // resume window. If live re-entry just restored a running turn, the
                // queue's busy guards now see that state and leave prompts queued.
                self.onActiveRuntimeBound?()
                // Seed the context-window meter from session.status so a resumed
                // session shows occupancy before its first new turn (H1). Runs
                // after the resume lands the runtime id; guarded against a newer
                // open inside ChatStore via the runtime-id check.
                await self.chat?.seedContextUsageFromStatus(runtimeId: result.sessionId)
            } catch {
                // A stale token/generation or a replaced epoch is a superseded
                // binding, not an actionable open failure.
                guard self.isCurrentRuntimeBinding(
                    token: token,
                    storedId: summary.id,
                    profileId: cacheProfile,
                    connectionWorkGeneration: connectionWorkGeneration,
                    transportEpoch: bindingEpoch,
                    usingResumeTestSeam: usingResumeTestSeam
                ) else { return }
                let message = self.errorMessage(from: error)
                self.lastError = message
                self.sessionActionError = SessionActionError(action: "Open Session", message: message)
            }
        }
        #if DEBUG
        lastOpenResumeTask = resumeTask
        #endif
    }

    /// Resume + own `summary` over the Wave-2 relay coordinator when the relay is
    /// the active transport (the gateway-direct `session.resume` in ``open`` is
    /// skipped — the gateway socket is idle in relay-only mode). Binds the runtime
    /// id so the composer unlocks and prompt submission routes through the relay,
    /// exactly as the gateway resume does on the direct path. The relay keys the
    /// runtime on the stored session id, so a successful resume binds `summary.id`.
    /// Supersession is guarded by `openToken` (a newer open()/draft cancels the
    /// stale bind) so a slow relay resume cannot bind into a session the user has
    /// since navigated away from.
    private func bindRelayRuntime(
        summary: SessionSummary,
        token: UUID,
        connectionWorkGeneration: UInt64
    ) {
        let resumeTask = Task { [weak self] in
            guard let self,
                  let coordinator = self.connection?.relayCoordinator else { return }
            do {
                // QA-1 B1: queue on the relay phase bridge instead of racing it.
                // A tap that lands while the socket is still coming up adopts the
                // session (the `.open` edge re-establishes it) and waits —
                // bounded — for readiness, instead of failing fast with
                // `notConnected` and surfacing an "Open Session Failed" alert
                // over a self-healing condition.
                if !coordinator.isOpen {
                    coordinator.adoptPendingSession(summary.id)
                    guard await coordinator.waitUntilOpen(timeout: .seconds(10)) else {
                        // Still down when the wait expires: the adopted session
                        // re-establishes on the next `.open` edge. Silent.
                        return
                    }
                }
                _ = try await coordinator.resume(summary.id)
                guard self.openToken == token,
                      self.connectionWorkGeneration == connectionWorkGeneration,
                      self.activeStoredId == summary.id else { return }
                // Relay runtime bound: the relay keys the live turn on the stored
                // session id. Unlock the composer and flush anything queued during
                // the resume window (mirrors the gateway `onActiveRuntimeBound`).
                self.activeRuntimeId = summary.id
                self.activeRuntimeEpoch = self.connection?.transportEpoch
                self.lastError = nil
                self.sessionActionError = nil
                self.ensureRuntimeAttempts = 0
                self.onActiveRuntimeBound?()
            } catch {
                // A superseded open (the user tapped another session) is not an
                // actionable failure — never surface it.
                guard self.openToken == token,
                      self.activeStoredId == summary.id else { return }
                let message = self.errorMessage(from: error)
                self.lastError = message
                // QA-1 B1 (north star): transport-readiness failures are
                // self-healing — adopt the session so the coordinator's `.open`
                // re-establishment re-opens it, and NEVER stamp a modal alert.
                // Only a genuine relay-side rejection (an RPC error answer) is
                // actionable enough to surface.
                if Self.isRetryableRelayBindingError(error) {
                    coordinator.adoptPendingSession(summary.id)
                    return
                }
                self.sessionActionError = SessionActionError(
                    action: "Open Session", message: message
                )
            }
        }
        #if DEBUG
        lastOpenResumeTask = resumeTask
        #endif
    }

    /// Transport-readiness failures of a relay session op (QA-1 B1). These are
    /// SELF-HEALING: the coordinator re-establishes the adopted session on its
    /// next crossing into `.open`, so they must drain silently once connected —
    /// never a modal alert (north-star rule). A relay RPC ERROR answer
    /// (`.rpc(code:message:)` — e.g. session-not-found) is the one actionable
    /// class and keeps the alert.
    private static func isRetryableRelayBindingError(_ error: Error) -> Bool {
        switch error {
        case RelayError.notConnected: return true
        case RelayError.timeout: return true
        case RelayError.transport: return true
        case RelayError.rpc: return false
        default:
            // The gateway client's not-connected / timeout / transport classes
            // can surface here when a relay-mode call still raced the direct
            // path; they are equally self-healing via the relay re-open.
            if error is CancellationError { return true }
            switch error {
            case GatewayError.notConnected, GatewayError.timeout, GatewayError.transport:
                return true
            default:
                return false
            }
        }
    }

    /// Enter a fresh **draft** chat: drop the active session pointers, mark the
    /// store as drafting, and reset the transcript to empty. No RPC — the real
    /// session is created lazily on the first prompt (see ``createDraftSession()``
    /// / `ChatStore.send`). This is what "New chat" and launch land on, so an
    /// abandoned draft never litters the session list with an empty session.
    func startDraft(cwd: String? = nil) {
        // Supersede any in-flight `open()` so its resume can't reactivate, and any
        // on-demand re-resume so its result can't bind into this fresh draft.
        openToken = UUID()
        // QA-1 B3: a fresh draft is a NEW navigation — drop any pending drawer
        // dismissal from a prior tap (the drawer row that starts a draft fires
        // `onNavigate` itself; a programmatic draft must not inherit a stale
        // close that could fire later against a re-opened drawer).
        pendingDrawerReveal = nil
        // S9 (QA-3): "New chat" is a USER drawer navigation gesture — the same
        // 3rd-recurrence race applies (drainDurable re-opening the drawer over
        // a fresh draft). Stamp the epoch so a stale `.openSessions` App Intent
        // drained on the foreground transition drops itself instead of
        // clobbering the draft surface.
        recordDrawerUserGesture()
        cancelEnsureRuntime()
        cancelRuntimeBinding()
        isDraft = true
        activeRuntimeId = nil
        activeRuntimeEpoch = nil
        activeStoredId = nil
        activeStoredProfile = nil
        resetComposerHistoryBrowse()
        chat?.reset()
        chat?.seed(from: [])  // empty IS the (draft) transcript
        transcriptPaintedStoredId = nil   // a draft holds no stored session
        // A draft has NO session: drop the previous session's hot-swap state
        // (else the pill shows the LAST chat's model) and any stale draft pick.
        connection?.clearSessionState()
        // R1 (contract I6): a draft is the ABSENCE of a session — the relay
        // write-gate moves OFF. No entry is active, so no frame from any
        // session can project onto the draft surface (structural: the S11
        // `projectionSuppressed` flag this replaces cannot exist to fail —
        // IMG_2594 is unreachable by construction). The previous session's
        // parked entry keeps folding its own frames for a fast re-open (I14);
        // the durable outbox re-routes the moment a real session binds.
        connection?.relayCoordinator?.enterDraft()
        // ABH-351: capture the cwd for the new-session-in-project flow. An
        // explicit non-empty path seeds the draft so the materializing
        // session.create carries it; nil/empty = the gateway default.
        let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        draftCwd = trimmed.isEmpty ? nil : trimmed
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
            // ABH-351: new-session-in-project — pass the captured draft cwd so
            // the session starts rooted at the project's repo (the gateway's
            // session.create honors an optional `cwd` that, when it resolves to
            // an existing directory, becomes the session's explicit workspace).
            // See startDraft(cwd:) and server.py:4987.
            if let cwd = draftCwd, !cwd.isEmpty {
                createParams["cwd"] = .string(cwd)
            }
            let result: SessionOpenResult = try await client.request(
                "session.create",
                params: .object(createParams),
                timeout: .seconds(120)
            )
            activeRuntimeId = result.sessionId
            activeRuntimeEpoch = connection?.transportEpoch
            activeStoredId = result.storedSessionId ?? result.sessionId
            let echoedProfile = result.info?.profileName
            activeStoredProfile = Self.normalizedProfileID(
                echoedProfile ?? (activeProfile == CacheScope.allProfilesKey
                    ? Self.defaultProfileName
                    : activeProfile)
            )
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

    /// Adopt a session the RELAY created on submit (QA-1 B13 — brand-new chat).
    ///
    /// The relay SUBMIT handler creates + owns the session when the phone sends
    /// with no session id (a draft) and returns its id in the RPC result. The
    /// gateway-direct `createDraftSession()` path cannot run in relay mode (the
    /// gateway client is idle), so this is the relay equivalent of its
    /// bookkeeping half: clear the draft, bind the stored + runtime ids (the
    /// relay keys its runtime on the STORED id), and refresh the drawer so the
    /// new row appears. Guarded to ONLY adopt when nothing is bound yet: a
    /// submit into an existing session echoes an id the pointers must NOT be
    /// overwritten with (the relay may echo a DISTINCT live id after a
    /// resume-remap — the stored id stays the phone's identity), and a deduped
    /// retry (`deduplicated: true`) must not churn the pointers.
    func landRelayCreatedSession(storedID: String) {
        guard isDraft || activeStoredId == nil else { return }
        isDraft = false
        activeStoredId = storedID
        activeRuntimeId = storedID
        activeRuntimeEpoch = connection?.transportEpoch
        ensureRuntimeAttempts = 0
        lastError = nil
        sessionActionError = nil
        // Surface the new row in the drawer; never block the turn on it
        // (mirrors `createDraftSession`'s background refresh).
        Task { [weak self] in await self?.refresh() }
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

    /// Materialize the destination for one durable new-session prompt. The
    /// processor persists `storedSessionID` immediately after this returns and
    /// therefore retries/resumes that destination instead of creating another.
    func createOutboxDestination() async throws -> OutboxDestination {
        if !isDraft { startDraft() }
        try await createDraftSession()
        guard let runtimeSessionID = activeRuntimeId,
              let storedSessionID = activeStoredId else {
            throw OutboxProcessorError.destinationUnavailable
        }
        return OutboxDestination(
            runtimeSessionID: runtimeSessionID,
            storedSessionID: storedSessionID
        )
    }

    /// Resolve only the active affinity. A background queue item for session A
    /// must never resume or submit into session B merely because B is visible.
    func runtimeForOutboxDestination(_ storedSessionID: String) async -> String? {
        guard activeStoredId == storedSessionID else { return nil }
        return await ensureActiveRuntime()
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
        let branchProfile = activeStoredProfile ?? Self.normalizedProfileID(activeProfile)
        isLoading = true
        defer { isLoading = false }
        var params: [String: JSONValue] = [
            "cols": .number(96),
            "messages": .array(seed),
        ]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        // Branch into the active profile scope (same conditional spot as `cwd`).
        applyProfileScope(to: &params, selectedProfile: activeStoredProfile)
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
            activeRuntimeEpoch = connection?.transportEpoch
            activeStoredId = storedId
            activeStoredProfile = branchProfile
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
            transcriptPaintedStoredId = storedId
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
            if let runtimeId, !runtimeId.isEmpty {
                activeRuntimeId = runtimeId
                activeRuntimeEpoch = connection?.transportEpoch
            }
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
        let profile = profileParam(for: summary)

        // (1) For the session this app holds open, interrupt the in-flight turn
        //     then evict it server-side so the delete doesn't trip the live
        //     guard. Best-effort: the server auto-evicts even if these are
        //     skipped, so neither blocks the delete attempt.
        let wasActive = isActive(summary) || summary.id == activeRuntimeId
        if wasActive {
            guard let send = resolvedRPCSend else { return }
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

        // (2) Delete keys on the STORED id. Non-default profile rows from the
        //     aggregate rail must use REST's profile-scoped delete path; default /
        //     dormant rows keep the shipped WS `session.delete` payload.
        do {
            if let profile {
                guard let delete = resolvedDeleteSessionRequest else {
                    throw RestError.network("Not connected.")
                }
                try await delete(summary.id, profile)
            } else {
                guard let send = resolvedRPCSend else { return }
                _ = try await send(
                    "session.delete",
                    .object(["session_id": .string(summary.id)])
                )
            }
            sessions.removeAll { $0.scopedIdentity == summary.scopedIdentity }
            if pinnedIds.remove(summary.id) != nil { persistPins() }
            // `clearActive()` already ran above for the active case; this covers
            // the rare drift where only the runtime id matched.
            if wasActive {
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
        let myConnectionWorkGeneration = connectionWorkGeneration
        let token = openToken
        guard let storedId = activeStoredId,
              client != nil || resumeRPC != nil || connection?.transportPath == .relay else { return nil }
        // QA-1 B1: on the relay transport the gateway `client` is deliberately
        // idle (never connected), so the gateway-direct `session.resume` below
        // can only ever throw "Not connected to the Hermes gateway" — which is
        // how every relay-mode cold open / reconnect landed a modal "Resume
        // Session Failed" alert over the painted transcript (a retryable
        // condition surfaced as an error; north-star violation). Resume over the
        // relay coordinator instead: it queues on transport readiness and never
        // alerts. The test seam keeps precedence so unit graphs are unchanged;
        // the gateway-direct path below stays byte-identical.
        if resumeRPC == nil, connection?.transportPath == .relay {
            return await resumeActiveOverRelay(
                storedId: storedId,
                token: token,
                connectionWorkGeneration: myConnectionWorkGeneration
            )
        }
        let bindingProfile = activeStoredProfile
        let usingResumeTestSeam = resumeRPC != nil
        guard let bindingEpoch = await currentBindingEpoch(
            usingResumeTestSeam: usingResumeTestSeam
        ) else { return nil }
        do {
            // Re-resume into the same profile scope so a reconnect keeps the
            // session in its per-profile home. Omitted for the default/all scope.
            var resumeParams: [String: JSONValue] = ["session_id": .string(storedId)]
            applyProfileScope(to: &resumeParams, selectedProfile: activeStoredProfile)
            let result = try await coalescedSessionResume(
                storedId: storedId,
                profileId: bindingProfile,
                params: resumeParams,
                token: token,
                transportEpoch: bindingEpoch
            )
            // SUPERSESSION GUARD: the active session may have changed across the
            // (up to 120 s) resume await — the user tapped another drawer row
            // (`open`), started a draft, or cleared the active session. Do NOT
            // clobber the now-active session's pointers with this stale resume's
            // result; otherwise a live send would misroute into the resumed
            // session (the R1 #17 class, on the un-affinity-guarded live path).
            // Mirrors open()'s `openToken` re-check after its own resume await.
            guard isCurrentRuntimeBinding(
                token: token,
                storedId: storedId,
                profileId: bindingProfile,
                connectionWorkGeneration: myConnectionWorkGeneration,
                transportEpoch: bindingEpoch,
                usingResumeTestSeam: usingResumeTestSeam
            ) else {
                if !usingResumeTestSeam,
                   connection?.transportEpoch != bindingEpoch {
                    ReliabilityDiagnostics.shared.epochRejected(
                        expected: bindingEpoch,
                        received: connection?.transportEpoch
                    )
                }
                if activeStoredId != storedId || openToken != token {
                    ReliabilityDiagnostics.shared.sessionSuperseded(identifier: storedId)
                }
                return nil
            }
            activeRuntimeId = result.sessionId
            activeRuntimeEpoch = bindingEpoch
            ReliabilityDiagnostics.shared.sessionBound(
                identifier: "\(activeStoredProfile ?? "default")\u{1F}\(storedId)",
                epoch: bindingEpoch
            )
            // A resume can follow a compression chain tip (parent → continuation);
            // re-stamp queued prompts so affinity-stamped ones aren't skipped forever.
            let newStored = result.storedSessionId ?? storedId
            if newStored != storedId { onStoredIdMigrated?(storedId, newStored) }
            activeStoredId = newStored
            if let echoedProfile = result.info?.profileName {
                activeStoredProfile = Self.normalizedProfileID(echoedProfile)
            }
            confirmActiveProfile(from: result.info)
            // Keep the composer pill session-true on this resume path too.
            if let info = result.info { connection?.applyRuntimeInfo(info) }
            // Reconnects can land in a quiet long-running tool call. Restore the
            // server's root-level snapshot before ConnectionStore backfills; the
            // backfill then correctly defers while this authoritative live turn
            // is active instead of erasing it as apparently idle.
            await chat?.reconcileLiveTurnStatus(
                runtimeId: result.sessionId,
                snapshotRunning: result.snapshotRunning,
                inflight: result.inflight
            )
            lastError = nil
            sessionActionError = nil
            return result.sessionId
        } catch {
            // The error belongs to an obsolete token/generation/epoch when the
            // transport changed while the RPC was suspended. Never surface it
            // into the current session's error channel.
            guard isCurrentRuntimeBinding(
                token: token,
                storedId: storedId,
                profileId: bindingProfile,
                connectionWorkGeneration: myConnectionWorkGeneration,
                transportEpoch: bindingEpoch,
                usingResumeTestSeam: usingResumeTestSeam
            ) else { return nil }
            let message = errorMessage(from: error)
            lastError = message
            sessionActionError = SessionActionError(action: "Resume Session", message: message)
            return nil
        }
    }

    /// Relay-transport resume (QA-1 B1): re-own `storedId` over the relay
    /// coordinator, QUEUING on transport readiness instead of racing the phase
    /// bridge. Never surfaces a modal alert — every failure mode here is
    /// self-healing: a socket still mid-connect opens moments later, and the
    /// coordinator's crossing INTO `.open` re-establishes the adopted session
    /// (its `applyState` re-open), so a retryable condition drains silently
    /// once connected (north-star rule). Mirrors ``bindRelayRuntime``'s binding
    /// so the composer unlocks and sends route over the relay.
    private func resumeActiveOverRelay(
        storedId: String,
        token: UUID,
        connectionWorkGeneration: UInt64
    ) async -> String? {
        guard let coordinator = connection?.relayCoordinator else { return nil }
        // Queue on the relay phase bridge: a cold-start resume that lands before
        // the socket is open adopts the session (the `.open` edge re-opens it)
        // and waits — bounded — for readiness, instead of throwing
        // `notConnected` into the alert channel.
        if !coordinator.isOpen {
            coordinator.adoptPendingSession(storedId)
            guard await coordinator.waitUntilOpen(timeout: .seconds(10)) else {
                // Still down: the adopted session re-establishes on the next
                // `.open` edge. Silent by design — never an alert.
                return nil
            }
        }
        do {
            _ = try await coordinator.resume(storedId)
            // SUPERSESSION GUARD: the active session may have changed across the
            // readiness wait / resume RPC — do not bind a stale resume over a
            // session the user has since navigated away from (mirrors the
            // gateway path's `isCurrentRuntimeBinding`).
            guard openToken == token,
                  activeStoredId == storedId,
                  self.connectionWorkGeneration == connectionWorkGeneration else { return nil }
            // The relay keys its runtime on the STORED session id, so a
            // successful resume binds `storedId` itself.
            activeRuntimeId = storedId
            activeRuntimeEpoch = connection?.transportEpoch
            ReliabilityDiagnostics.shared.sessionBound(
                identifier: "\(activeStoredProfile ?? "default")\u{1F}\(storedId)",
                epoch: activeRuntimeEpoch ?? 0
            )
            lastError = nil
            sessionActionError = nil
            ensureRuntimeAttempts = 0
            // Flush anything the composer queued while the runtime was nil
            // (mirrors the gateway path's `onActiveRuntimeBound`).
            onActiveRuntimeBound?()
            return storedId
        } catch {
            // Superseded: not an error, never surface.
            guard openToken == token, activeStoredId == storedId else { return nil }
            // Retryable transport failures self-heal on the next ready edge:
            // adopt so the `.open` re-establishment re-opens the session, record
            // for diagnostics, and NEVER stamp `sessionActionError` (no modal
            // alert for self-healing conditions — north-star rule).
            coordinator.adoptPendingSession(storedId)
            lastError = errorMessage(from: error)
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
        if let rid = activeRuntimeId,
           activeRuntimeEpoch == connection?.transportEpoch,
           connection?.isTransportReady == true {
            return rid
        }
        if activeRuntimeId != nil { transportDidBecomeUnavailable() }
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
        let canSearchRemote = apiOrNil != nil || searchFetch != nil
        #else
        let api = restAPI
        let canSearchRemote = api != nil
        #endif

        // Reset pagination state for the new query and bump the generation so
        // any stale load-more page from the prior query is discarded on arrival.
        searchOffset = 0
        searchHasMore = false
        searchGeneration &+= 1
        let generation = searchGeneration
        // Drop the PREVIOUS query's rows: the remote page below APPENDS (it
        // merges over the same-query local cache hits), so stale rows left in
        // place would survive into the new result set (pre-existing bug:
        // SearchPaginationTests.testNewQueryResetsState). The <2-char branch
        // above already clears immediately; a query change does too.
        searchResults = []
        searchIsPartial = false

        searchTask = Task { [weak self] in
            // Debounce.
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            guard let self else { return }
            self.isSearching = true
            defer { self.isSearching = false }
            do {
                // Local results publish first and remain visible while the
                // concurrent remote request is in flight (including offline).
                if let cache = self.cacheStore, let scope = self.currentCacheScope {
                    let page = try await cache.searchTranscript(
                        query: trimmed, scope: scope,
                        roles: Self.roles(for: self.searchScope), limit: Self.searchPageLimit
                    )
                    guard self.searchGeneration == generation else { return }
                    self.searchResults = page.hits.map {
                        SessionSearchResult(
                            id: $0.sessionId, snippet: $0.snippet, role: $0.role,
                            source: nil, model: nil, sessionStarted: nil, messageId: $0.wireId
                        )
                    }
                    self.searchIsPartial = page.partial
                }
                guard canSearchRemote else { return }
                #if DEBUG
                let (results, rawPageFull): ([SessionSearchResult], Bool)
                if let seam = self.searchFetch {
                    (results, rawPageFull) = try await seam(trimmed, 0)
                } else if let api = apiOrNil {
                    (results, rawPageFull) = try await self.fetchSearch(
                        query: trimmed, offset: 0, api: api
                    )
                } else {
                    return
                }
                #else
                guard let api else { return }
                let (results, rawPageFull) = try await self.fetchSearch(
                    query: trimmed, offset: 0, api: api
                )
                #endif
                if Task.isCancelled { return }
                // Guard against a stale response landing after the user typed on.
                guard self.searchGeneration == generation else { return }
                let existing = Set(self.searchResults.map {
                    "\($0.id)|\($0.messageId.map(String.init) ?? "")"
                })
                self.searchResults.append(contentsOf: results.filter {
                    !existing.contains("\($0.id)|\($0.messageId.map(String.init) ?? "")")
                })
                // Advance offset by the page limit (not collapsed count) so
                // the next load-more request starts at the correct message offset.
                self.searchOffset = Self.searchPageLimit
                // rawPageFull: true when the raw (pre-collapse for plugin, direct
                // for stock) server page was full — more messages may exist.
                self.searchHasMore = rawPageFull
                    && self.searchOffset < Self.searchOffsetCap
                self.lastError = nil
            } catch {
                if Task.isCancelled { return }
                // A remote failure must never flash already-published local hits.
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
                let (page, rawPageFull): ([SessionSearchResult], Bool)
                if let seam = self.searchFetch {
                    (page, rawPageFull) = try await seam(trimmed, offset)
                } else if let api = apiForMore {
                    (page, rawPageFull) = try await self.fetchSearch(
                        query: trimmed, offset: offset, api: api
                    )
                } else {
                    return
                }
                #else
                let (page, rawPageFull) = try await self.fetchSearch(
                    query: trimmed, offset: offset, api: api
                )
                #endif
                if Task.isCancelled { return }
                // Discard if the user changed the query while this was in flight.
                guard self.searchGeneration == generation else { return }
                // Append, deduplicating by session id — handles same session
                // appearing in two message-pages (plugin) or window shift (stock).
                let existingIds = Set(self.searchResults.map(\.id))
                let fresh = page.filter { !existingIds.contains($0.id) }
                self.searchResults.append(contentsOf: fresh)
                // Advance by the page limit (not collapsed count) so the next
                // load-more starts at the correct message-level offset.
                self.searchOffset = offset + Self.searchPageLimit
                // rawPageFull drives has-more: a full raw page means the server
                // may have more messages, even if collapse produced few sessions.
                self.searchHasMore = rawPageFull
                    && self.searchOffset < Self.searchOffsetCap
            } catch {
                if Task.isCancelled { return }
                // Leave existing results intact; a load-more failure is silent
                // (the user can scroll back up and the list is still readable).
            }
        }
    }

    /// Execute the search against the best available endpoint: plugin first (richer
    /// results + role-scoped + offset pagination), stock on 404 (older gateways).
    /// Only falls back on a true 404/not-found — real 500/transport errors are
    /// re-thrown so they surface as `lastError` and are not silently masked.
    ///
    /// `offset` is forwarded to both the plugin and stock endpoints.
    ///
    /// Returns `(results, rawPageFull)` where `rawPageFull` indicates whether the
    /// underlying server page was full at the message level (for plugin) or session
    /// level (for stock). Callers use `rawPageFull` to set `searchHasMore` — this
    /// correctly handles plugin pages that collapse to fewer sessions than the raw
    /// message limit but still have more messages to return.
    ///
    /// Extracted so tests can call it directly without spinning a Task.
    func fetchSearch(
        query: String, offset: Int = 0, api: RestClient
    ) async throws -> (results: [SessionSearchResult], rawPageFull: Bool) {
        let roles = Self.roles(for: searchScope)
        let sort = searchSort.rawValue
        do {
            // Plugin path: forward offset so load-more fetches subsequent
            // message pages. rawPageFull keys on the raw (pre-collapse) count.
            let (results, rawPageFull) = try await api.searchSessionsPlugin(
                query: query, limit: Self.searchPageLimit, offset: offset, sort: sort, roles: roles
            )
            return (results, rawPageFull)
        } catch RestError.badStatus(404, _) {
            // Plugin endpoint not available on this gateway — fall back to stock.
            let results = try await api.searchSessions(
                query: query, limit: Self.searchPageLimit, offset: offset,
                scope: searchScope.rawValue
            )
            // Stock path: rawPageFull = full session page (no pre-collapse step).
            return (results, results.count == Self.searchPageLimit)
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
    ///
    /// ABH-192: when the result carries a `messageId` (the per-message plugin
    /// endpoint and the artifacts gallery both thread one through), set
    /// ``pendingMessageJump`` so ChatView scrolls to that exact row once the
    /// transcript loads — instead of the query-text ``pendingSearchScroll``
    /// match. An exact-id jump is stricter and preferred when available.
    func open(searchResult result: SessionSearchResult, revealOnFirstPaint: (@MainActor () -> Void)? = nil) {
        let summary = sessions.first(where: { $0.id == result.id }) ?? result.asSessionSummary
        // Remember the query so ChatView scrolls to its first occurrence once
        // the transcript loads (jump-to-match). Captured BEFORE clearSearch()
        // wipes searchQuery.
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let jumpTarget = result.messageId
        // S2 (Opus review): on an exact-id MISS (coalesced assistant turn whose
        // matched row id isn't the turn's anchor, or a stock gateway with no
        // wireId), fall back to a query-text scroll using the search snippet so
        // the user lands inside the right turn instead of a silent no-op at the
        // bottom. `jumpToMessageIfNeeded` arms `pendingSearchScroll` from this
        // snippet when the id lookup misses; we ALSO seed it now for the no-id
        // path so a snippet-bearing result without a messageId still jumps.
        let snippetText = result.plainSnippet
        clearSearch()
        // S1 (Opus review): `open(summary)` clears any stale pending scroll on a
        // session SWITCH, so arm the new jump/search AFTER the open. The
        // cache→network seed is async (Task), so this synchronous assignment
        // still lands before the first `transcriptGeneration` bump.
        // R2 (drawer snap-back): hand the close in as `revealOnFirstPaint`
        // instead of firing it inline at the call site, so the drawer dismisses
        // FORWARD into the new session's first painted frame (parity with the
        // row-tap path). The old call site fired `onNavigate()` immediately,
        // animating the close onto the PREVIOUS session's card before the new
        // session painted — the "open-motion plays reversed" snap-back.
        open(summary, revealOnFirstPaint: revealOnFirstPaint)
        // An exact message-id jump (ABH-192) takes precedence over the
        // query-text match; only set pendingSearchScroll when there is no id.
        pendingMessageJump = jumpTarget
        pendingMessageJumpAttempts = 0
        // S2: carry the snippet so an exact-id MISS can fall back to a query-text
        // scroll inside the right turn.
        pendingMessageJumpSnippet = (jumpTarget != nil && !snippetText.isEmpty) ? snippetText : nil
        if jumpTarget == nil {
            if !q.isEmpty {
                // Literal user query — do NOT collapse whitespace on match.
                pendingSearchScroll = q
                pendingSearchScrollIsSnippet = false
            } else if !snippetText.isEmpty {
                // No user query, fall back to the server snippet — collapse OK.
                pendingSearchScroll = snippetText
                pendingSearchScrollIsSnippet = true
            } else {
                pendingSearchScroll = nil
                pendingSearchScrollIsSnippet = false
            }
        } else {
            pendingSearchScroll = nil
            pendingSearchScrollIsSnippet = false
        }
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
        searchIsPartial = false
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
            let stored = try await api.renameSession(
                id: summary.id,
                title: trimmed,
                profile: profileParam(for: summary)
            )
            guard let index = sessions.firstIndex(where: {
                $0.scopedIdentity == summary.scopedIdentity
            }) else { return }
            let current = sessions[index]
            // Carry `current.profile` through the rebuild (F4b polish) so a
            // rename doesn't drop the row's profile tag in the aggregate view
            // before the next rail re-fetch re-tags it.
            sessions[index] = SessionSummary(
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
            try await api.setSessionArchived(
                id: summary.id,
                archived: true,
                profile: profileParam(for: summary)
            )
            sessions.removeAll { $0.scopedIdentity == summary.scopedIdentity }
            if pinnedIds.remove(summary.id) != nil { persistPins() }
            if isActive(summary) || summary.id == activeRuntimeId {
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
            try await api.setSessionArchived(
                id: summary.id,
                archived: false,
                profile: profileParam(for: summary)
            )
            archivedSessions.removeAll { $0.scopedIdentity == summary.scopedIdentity }
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

    /// Fetch the full `/api/sessions/{id}/messages` transcript and render it to a
    /// Markdown export. Returns `nil` and surfaces a session-action alert on
    /// failure/empty transcript so the caller never presents an empty share sheet.
    func exportMarkdown(_ summary: SessionSummary) async -> String? {
        guard let api = restAPI else {
            lastError = "Not connected."
            sessionActionError = SessionActionError(action: "Export", message: "Not connected.")
            return nil
        }
        do {
            let markdown = try await api.exportSessionMarkdown(summary: summary)
            lastError = nil
            sessionActionError = nil
            return markdown
        } catch {
            let message = errorMessage(from: error)
            lastError = message
            sessionActionError = SessionActionError(action: "Export", message: message)
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
        guard let id = storedSessionId, !id.isEmpty,
              let identity = scopedSessionIdentity(forStoredID: id) else { return }
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
        if let last = lastActivityStampAt[identity],
           now.timeIntervalSince(last) < Self.liveStampCoalesce {
            return
        }
        lastActivityStampAt[identity] = now
        lastActivityAt[identity] = now
        startLiveCleanupIfNeeded()
    }

    /// Whether `summary`'s row should pulse: its conversation saw broadcast
    /// activity within the last ``liveWindow`` seconds.
    func isLive(_ summary: SessionSummary) -> Bool {
        guard let at = lastActivityAt[sessionListIdentity(summary)] else { return false }
        return Date().timeIntervalSince(at) < Self.liveWindow
    }

    /// Whether a stored session id is currently within the live window.
    func isLive(storedSessionId id: String) -> Bool {
        guard let identity = scopedSessionIdentity(forStoredID: id),
              let at = lastActivityAt[identity] else { return false }
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
    private func applyProfileScope(
        to params: inout [String: JSONValue],
        selectedProfile: String? = nil
    ) {
        if let name = Self.profileParam(
            scope: selectedProfile ?? activeProfile,
            multiAvailable: isMultiProfileAvailable
        ) {
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

    /// Profile param for an action on a concrete session row. A row tag from the
    /// aggregate rail is authoritative: non-default rows thread that profile;
    /// explicit default rows stay profile-less and must never be retargeted to the
    /// active switcher scope. Rows without a tag fall back to the active specific
    /// scope, preserving the existing named-profile path.
    static func profileParam(
        for summary: SessionSummary,
        activeScope: String,
        multiAvailable: Bool
    ) -> String? {
        guard multiAvailable else { return nil }
        if let rowProfile = summary.profile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rowProfile.isEmpty {
            return rowProfile == defaultProfileName ? nil : rowProfile
        }
        return profileParam(scope: activeScope, multiAvailable: multiAvailable)
    }

    private func profileParam(for summary: SessionSummary) -> String? {
        Self.profileParam(
            for: summary,
            activeScope: activeProfile,
            multiAvailable: profileThreadingAvailable
        )
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
        cancelRuntimeBinding()
        isDraft = false
        activeRuntimeId = nil
        activeRuntimeEpoch = nil
        activeStoredId = nil
        activeStoredProfile = nil
        chat?.reset()
        transcriptPaintedStoredId = nil
    }

    /// Injectable seam for the session-list fetch. `nil` resolves the live
    /// `connection?.rest` path (same as the existing `refresh()` body); tests
    /// inject a closure that answers with a preset list (or throws) without a
    /// live gateway. The closure returns a tuple of `(sessions, total?)` so
    /// tests can also verify that `totalSessions` is decoded and exposed.
    var sessionsFetch: (() async throws -> (sessions: [SessionSummary], total: Int?))?

    /// Injectable seam for the plugin session-list delta endpoint. The first
    /// parameter is the previously stored cursor, if any; the second is the
    /// grow-limit window size requested for this refresh.
    var sessionListDeltaFetch: ((String?, Int) async throws -> SessionListDeltaResult?)?

    /// Injectable seam for the initial-fill grow-limit loop (Bug B). Each call
    /// pops the next page from the array, letting tests stage multiple pages
    /// without a live REST client. `nil` = live REST path. The closure receives
    /// the requested `limit` so tests can assert on grow-limit semantics.
    var initialFillFetch: ((Int) async throws -> (sessions: [SessionSummary], total: Int?))?

    /// REST fetch backing ``seedTranscript(storedId:profile:token:)``, injected for
    /// tests (mirrors `ChatStore.backfillFetch`). In the app it resolves the
    /// live `connection?.rest` lazily on each call. The legacy one-argument seam
    /// is kept so existing tests/default-scope callers remain byte-for-byte.
    var transcriptFetch: ((String) async throws -> [StoredMessage])?

    /// Profile-aware transcript seam for ABH-408: All-profiles row opens must
    /// invoke the stored-transcript fetch with the row's owning profile.
    var transcriptFetchWithProfile: ((String, String?) async throws -> [StoredMessage])?

    /// Shape-aware transcript seam (WS-5.1 skeleton cold-open). The third argument
    /// is the requested payload tier (`"skeleton"` for the fast cold-open paint,
    /// `"full"` for the background hydrate). Preferred over the legacy seams when
    /// present so a test can assert BOTH the skeleton request and the full hydrate.
    var transcriptFetchShaped: ((String, String?, String) async throws -> [StoredMessage])?

    /// Test override for ``skeletonColdOpenEligible`` — forces the cold-open seed
    /// to request the skeleton tier (and hydrate) regardless of the live gateway
    /// path style, so the two-phase behavior is deterministically exercisable.
    var skeletonColdOpenForced: Bool?

    /// Profile-aware delete seam for ABH-408. The live path resolves to
    /// `RestClient.deleteSession(id:profile:)`; tests inject this to assert that
    /// All-profiles row deletes target the row's owning profile store.
    var deleteSessionRequest: ((String, String?) async throws -> Void)?

    private func isCurrentTranscriptSelection(
        token: UUID,
        workGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled
            && openToken == token
            && connectionWorkGeneration == workGeneration
    }

    /// Validity of the LOCAL (memory/disk) cache paint — phase 1 of a cold-open
    /// seed. Deliberately transport-generation-INDEPENDENT: a cache paint reads
    /// disk for the captured scoped identity, so it is correct regardless of the
    /// `connectionWorkGeneration` (which fences prior-GATEWAY NETWORK data — the
    /// concern of phase 2's ``isCurrentTranscriptNetworkWork``, not a disk read).
    ///
    /// This is the cold-launch-resume fix (#208 follow-up): `open(bindRuntime:false)`
    /// scheduled from `paintFromCache()` at frame 0 captures the pre-bootstrap
    /// generation, then `ConnectionStore.bootstrap()` runs `advanceConnectionGeneration()`
    /// (which bumps `connectionWorkGeneration`) BEFORE this seed's Task drains. The
    /// old `isCurrentTranscriptSelection` phase-1 guard then treated the cache paint
    /// as stale and skipped BOTH the paint AND the miss-path `reset()`, stranding
    /// the transcript on its launch skeleton (isLoading:false, no error). The
    /// manual drawer re-tap never hit this because it captures a settled generation.
    /// `openToken` alone is the correct supersession key here — a newer open or a
    /// gateway scope switch (``invalidateGatewayScopeWork``) rotates it, which
    /// still cancels a superseded/foreign cache paint.
    private func isCurrentTranscriptOpen(token: UUID) -> Bool {
        !Task.isCancelled && openToken == token
    }

    private func isCurrentTranscriptNetworkWork(
        token: UUID,
        workGeneration: UInt64,
        transportEpoch: UInt64
    ) -> Bool {
        isCurrentTranscriptSelection(token: token, workGeneration: workGeneration)
            && (connection?.transportEpoch ?? 0) == transportEpoch
    }

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
        storedId: String,
        networkProfile: String?,
        cacheProfile: String,
        token: UUID,
        workGeneration: UInt64,
        transportEpoch: UInt64,
        onFirstPaint: (@MainActor () -> Void)? = nil
    ) async {
        let paintStart = ContinuousClock.now
        var paintedRows = 0
        var paintFinished = false
        ReliabilityDiagnostics.shared.cachePaintStarted(identifier: storedId)
        defer {
            let duration = paintStart.duration(to: ContinuousClock.now)
            if paintFinished {
                ReliabilityDiagnostics.shared.cachePaintFinished(
                    rowCount: paintedRows, duration: duration
                )
            } else {
                ReliabilityDiagnostics.shared.cachePaintFailed(
                    rowCount: paintedRows, duration: duration
                )
            }
        }
        // R40 reveal-on-paint: fire the caller's reveal (drawer close) exactly
        // once, after phase 1 lands the first frame — even on the early-out paths
        // below, so a missing `chat` can never strand the drawer open.
        var firstPaintSignalled = false
        func signalFirstPaint() {
            guard !firstPaintSignalled else { return }
            firstPaintSignalled = true
            // The reveal fires once phase 1 lands a first frame; it is gated only by
            // the open identity (a generation bump between open() and this seed —
            // e.g. bootstrap's advanceConnectionGeneration — must not strand the
            // drawer open on a cold-launch resume).
            if isCurrentTranscriptOpen(token: token) { onFirstPaint?() }
        }
        guard let chat else {
            paintFinished = true
            signalFirstPaint()
            return
        }
        // Capture the scoped identity before any await. A server/profile change
        // rotates `openToken`; this captured key ensures an old task cannot
        // persist its response into whichever scope happens to be current later.
        let capturedIdentity = cacheIdentity(storedId, profile: cacheProfile)

        #if DEBUG
        // OPEN→PAINTED LATENCY instrumentation (WhatsApp bar): measure where the
        // open cost goes — disk read vs REST round-trip vs paint — so the 2.5–4s
        // white void is quantified, not guessed. DEBUG-only; absent in Release.
        let openClock = ContinuousClock.now
        #endif

        // Phase 1 — warm memory paint, then disk cache paint (or reset on miss).
        // ABH-372: if this process already opened the session, the normalized
        // rows are the cheapest safe first frame. This bypasses both REST and
        // the SQLite decode/normalize path; the authoritative fetch below still
        // reconciles any tail/delta afterward.
        var paintedFromCache = false
        var paintedFromDisk = false
        // QA-3 S7/A3 — VOID SCROLLBACK IMPOSSIBLE: when the transcript ALREADY
        // holds THIS session (a row re-tap, a notification deep-link onto the
        // active chat, a re-open of the same session), its in-memory rows ARE
        // the truth — backward-paged history, a live turn, an optimistic echo
        // included. Re-running the first-frame cache paint over it painted the
        // KNOWN-PARTIAL cached tail window `.replace` (warm snapshot 5504 /
        // disk `cached.suffix(windowLimit)` 5540), truncating the full
        // transcript to the window — the eager bottom-anchored VStack then
        // rendered the surviving tail at the bottom with PURE VOID above on
        // scroll-up (IMG_2589/2590). Skip phase 1 entirely: the phase-2
        // network seed (below) reconciles server-side deltas in place with a
        // `.union` policy, so nothing newer is lost and nothing older is
        // evicted. Provenance-keyed off `transcriptPaintedStoredId` (stamped
        // on every paint/reset this store drives) — NEVER off `activeStoredId`,
        // which open() re-points synchronously on the tap tick before this
        // task runs.
        let sameSessionRepaint = (transcriptPaintedStoredId == storedId)
        if sameSessionRepaint {
            paintedFromCache = true        // content already painted — phase 2
            paintedRows = chat.messages.count   // still reconciles deltas
            #if DEBUG
            Self.logOpenLatency(
                phase: "same-session(skip-paint)", storedId: storedId, since: openClock)
            #endif
        } else if isCurrentTranscriptOpen(token: token),
           let cached = cachedWarmOpenSnapshot(for: storedId) {
            chat.seed(normalized: Array(cached.suffix(ChatStore.transcriptOpenWindowLimit)))
            transcriptPaintedStoredId = storedId
            paintedRows = cached.count
            paintedFromCache = true
            #if DEBUG
            Self.logOpenLatency(
                phase: "memory-paint(HIT)", storedId: storedId, since: openClock)
            #endif
        }
        // The cron-only sessions are never transcript-cached (CacheStore guards
        // the write), so this misses for them and the network fetch is the sole
        // seed. No cache (tests/previews) ⇒ treated as a miss (reset),
        // network-only path preserved.
        if !paintedFromCache, let cacheStore {
            // `touchSession` bumps `lastAccessedAt` so an actively-opened session
            // never ages out of the eviction horizon.
            guard let identity = capturedIdentity else {
                // QA-1 B3: an identity-less early-out cannot paint, but it must
                // still signal — the old silent return left the drawer reveal to
                // the deadline alone (and when that was token-gated, a rotation
                // stranded the drawer open).
                paintFinished = true
                signalFirstPaint()
                return
            }
            try? await cacheStore.touchSession(identity)
            if isCurrentTranscriptOpen(token: token),
               (try? await cacheStore.hasTranscript(identity)) == true,
               isCurrentTranscriptOpen(token: token),
               let cached = try? await cacheStore.loadTranscript(identity),
               isCurrentTranscriptOpen(token: token) {
                // ARCH37 STEP 2 — normalize the cached rows OFF main, hop to main
                // only for the in-place reconcile (the FIRST painted frame).
                let cachedWindow = Array(cached.suffix(ChatStore.transcriptOpenWindowLimit))
                let normalized = await Self.normalizeOffMain(cachedWindow)
                guard isCurrentTranscriptOpen(token: token) else { return }
                rememberWarmOpenSnapshot(normalized, for: storedId)
                chat.seed(normalized: normalized)  // in-place reconcile — FIRST frame
                transcriptPaintedStoredId = storedId
                paintedRows = cachedWindow.count
                chat.noteTranscriptSeedWindow(cachedWindow)
                paintedFromCache = true
                paintedFromDisk = true
            }
        }
        if !paintedFromCache, isCurrentTranscriptOpen(token: token) {
            // Cache miss (or no cache): empty the transcript so ChatView shows the
            // skeleton, not a stale prior session's rows, while the network loads.
            chat.reset()
            // QA-3 S7: the honest empty state belongs to THIS session (the
            // skeleton, not a stale provenance) — a re-tap of it must not
            // re-run the miss-reset over whatever phase 2 paints next.
            transcriptPaintedStoredId = storedId
        }
        paintFinished = true
        #if DEBUG
        Self.logOpenLatency(
            phase: paintedFromCache ? "cache-paint(HIT)" : "cache-miss(reset)",
            storedId: storedId, since: openClock)
        // QA-1 A7 signpost: the session-switch cache paint must be INSTANT and
        // can never be blocked by the network refresh below (it runs AFTER this
        // point). Instrument/console-capturable proof of the cache-first chain.
        let paintMs = Self.openLatencyMilliseconds(since: openClock)
        let paintSource = paintedFromCache ? (paintedFromDisk ? "disk" : "memory") : "miss"
        os_signpost(
            .event, log: sessionSignposts, name: "transcript-cache-paint",
            "session=%{public}@ source=%{public}@ ms=%.1f",
            storedId, paintSource, paintMs)
        #endif

        // Phase 1 done — the new session's first frame is on screen. Reveal it:
        // the drawer (if it handed us its close) slides away NOW, uncovering
        // settled content rather than reconciling mid-slide (R40).
        signalFirstPaint()

        // Phase 2 — authoritative network seed, reconciled in place.
        // WS-5.1: on plugin gateways, seed with the SKELETON tier (conversational
        // text only; heavy reasoning_content + tool_calls nulled server-side) so
        // the network seed paints instantly and never blocks behind a full fetch;
        // a background task then hydrates the heavy fields to full and reconciles
        // in place. Stock gateways ignore `shape` and keep the single full fetch.
        let seedShape: String? = skeletonColdOpenEligible ? "skeleton" : nil
        let seedWasSkeleton = seedShape != nil
        guard let fetch = resolvedTranscriptFetch(shape: seedShape) else { return }
        do {
            // ARCH37 STEP 3 — skip the redundant network seed only when the SAME
            // DISK copy we just painted is FRESH. A memory snapshot is an instant
            // first frame only; disk can advance independently via backfill/prefetch,
            // so memory paints must still run the authoritative fetch and reconcile.
            // Staleness is proven against the session's `lastActive`; a nil
            // `lastActive` is treated as STALE (Step 3 / CacheStore change), so
            // "fresh" is never over-broad.
            if paintedFromDisk, let cacheStore,
               let lastActive = sessions.first(where: { $0.id == storedId })?.lastActive,
               let identity = capturedIdentity,
               (try? await cacheStore.transcriptIsFresh(identity, lastActive: lastActive)) == true {
                guard isCurrentTranscriptSelection(
                    token: token,
                    workGeneration: workGeneration
                ) else { return }
                #if DEBUG
                Self.logOpenLatency(
                    phase: "network-seed-skipped(fresh)", storedId: storedId, since: openClock)
                #endif
                return
            }
            let stored = try await fetch(storedId, networkProfile)
            guard isCurrentTranscriptNetworkWork(
                token: token,
                workGeneration: workGeneration,
                transportEpoch: transportEpoch
            ) else { return }
            // ARCH37 STEP 2 — normalize OFF the main actor (the pure `toChatMessages`
            // transform), hop to main only for the in-place reconcile assignment with
            // a fresh openToken re-check (a superseded open's normalize is dropped).
            let normalized = await Self.normalizeOffMain(stored)
            guard isCurrentTranscriptNetworkWork(
                token: token,
                workGeneration: workGeneration,
                transportEpoch: transportEpoch
            ) else { return }
            rememberWarmOpenSnapshot(normalized, for: storedId)
            // QA-2 R15: the network reseed is the SAME session (supersession
            // guards above) and a KNOWN-PARTIAL snapshot — relay history honors
            // `limit` with `messages[-limit:]` (downstream.py), plugin REST
            // serves the 50-row tail. Union it so settled history the window
            // does not cover survives (the stuck-episode segment drop).
            chat.seed(normalized: normalized, policy: .union)
            chat.noteTranscriptSeedWindow(stored)
            #if DEBUG
            Self.logOpenLatency(
                phase: seedWasSkeleton ? "network-painted(skeleton)" : "network-painted",
                storedId: storedId, since: openClock)
            // QA-1 B2 signpost: which transport the authoritative network seed
            // used — on relay it must be the relay `history` RPC (the gateway
            // REST path is the 15s-timeout skeleton-forever hole).
            let networkMs = Self.openLatencyMilliseconds(since: openClock)
            let seedTransport = connection?.transportPath == .relay ? "relay" : "rest"
            os_signpost(
                .event, log: sessionSignposts, name: "transcript-network-seed",
                "session=%{public}@ transport=%{public}@ ms=%.1f",
                storedId, seedTransport, networkMs)
            #endif
            // P3 write-through: persist the freshly-fetched transcript so the
            // next open paints it from disk. Fire-and-forget, OFF the UI path.
            // The skeleton tier writes ALL rows (heavy fields nulled, row count
            // unchanged) so it is a valid intermediate; the hydrate below
            // overwrites it with the full payload if it lands.
            if let cacheStore, let identity = capturedIdentity {
                Task { [weak self] in
                    guard let self,
                          self.isCurrentTranscriptNetworkWork(
                              token: token,
                              workGeneration: workGeneration,
                              transportEpoch: transportEpoch
                          ) else { return }
                    try? await cacheStore.saveTranscript(identity: identity, messages: stored)
                }
            }
            // WS-5.1: background-hydrate the heavy fields the skeleton tier nulled.
            // The skeleton is a fully-usable read (conversational text intact), so
            // hydration is best-effort and never blocks the UI. It reconciles in
            // place by deterministic wire id — rows do not remount, only their
            // reasoning/tool-call content enriches (no re-layout jump). This is the
            // fix for reopened chats losing reasoning/tool-call content (#208).
            if seedWasSkeleton {
                Task(priority: .utility) { [weak self] in
                    await self?.hydrateTranscriptToFull(
                        storedId: storedId,
                        networkProfile: networkProfile,
                        cacheProfile: cacheProfile,
                        token: token,
                        workGeneration: workGeneration,
                        transportEpoch: transportEpoch
                    )
                }
            }
        } catch {
            guard isCurrentTranscriptNetworkWork(
                token: token,
                workGeneration: workGeneration,
                transportEpoch: transportEpoch
            ) else { return }
            // History fetch failed. If the cache already painted, KEEP it (offline-
            // with-cache is a fully usable read) and stay silent. Only an EMPTY
            // transcript needs the recoverable error state — never an infinite
            // "Loading…" spinner (R1 #79).
            if !paintedFromCache {
                chat.reset()
                transcriptPaintedStoredId = storedId
                let description = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                chat.noteTranscriptLoadFailure(description)
            }
        }
    }

    /// WS-5.1 — background hydration of the skeleton cold-open seed. Fetches the
    /// FULL transcript (heavy `reasoning_content` + `tool_calls` restored) and
    /// reconciles it in place over the skeleton-painted rows, then overwrites the
    /// intermediate skeleton cache with the full payload so the next open paints
    /// the complete transcript from disk. Best-effort: the skeleton is a
    /// fully-usable read, so any failure is swallowed (a later open re-attempts).
    ///
    /// Runs at `.utility` priority so it never contends with the open path or a
    /// live turn; the network `await` and ``normalizeOffMain`` suspend off the
    /// main actor. The in-place `chat.seed` reconcile is identity-preserving (by
    /// deterministic wire id), so enriched rows don't remount — no visible jump.
    /// The same supersession guards as the seed (`token` / `workGeneration` /
    /// `transportEpoch`) abort a hydration a newer open/reconnect superseded.
    private func hydrateTranscriptToFull(
        storedId: String,
        networkProfile: String?,
        cacheProfile: String,
        token: UUID,
        workGeneration: UInt64,
        transportEpoch: UInt64
    ) async {
        guard isCurrentTranscriptNetworkWork(
            token: token, workGeneration: workGeneration, transportEpoch: transportEpoch
        ), let chat else { return }
        guard let fetch = resolvedTranscriptFetch(shape: nil) else { return }
        do {
            let full = try await fetch(storedId, networkProfile)
            guard isCurrentTranscriptNetworkWork(
                token: token, workGeneration: workGeneration, transportEpoch: transportEpoch
            ) else { return }
            let normalized = await Self.normalizeOffMain(full)
            guard isCurrentTranscriptNetworkWork(
                token: token, workGeneration: workGeneration, transportEpoch: transportEpoch
            ) else { return }
            rememberWarmOpenSnapshot(normalized, for: storedId)
            // QA-2 R15: hydration reconciles the SAME session's full rows over
            // the skeleton paint — union so any settled row painted since (or a
            // live relay turn's untagged history) survives the enrichment.
            chat.seed(normalized: normalized, policy: .union)
            chat.noteTranscriptSeedWindow(full)
            // Overwrite the intermediate skeleton cache with the full payload.
            if let cacheStore, let identity = cacheIdentity(storedId, profile: cacheProfile) {
                try? await cacheStore.saveTranscript(identity: identity, messages: full)
            }
            #if DEBUG
            Self.logOpenLatency(
                phase: "network-hydrated(full)", storedId: storedId,
                since: ContinuousClock.now)
            #endif
        } catch {
            // Best-effort: skeleton remains the usable read. A later open or
            // backfill will retry. Surface nothing to the UI.
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
    private func seedTranscript(
        storedId: String?,
        networkProfile: String?,
        cacheProfile: String,
        token: UUID,
        workGeneration: UInt64,
        transportEpoch: UInt64
    ) async {
        guard let chat else { return }
        guard let storedId, let fetch = resolvedTranscriptFetch() else {
            chat.reset()
            transcriptPaintedStoredId = nil
            return
        }
        let capturedIdentity = cacheIdentity(storedId, profile: cacheProfile)

        // Cache read-through first (identical to the cold-open phase 1, minus the
        // reset-on-miss: a chain-tip seed reconciles over already-painted content,
        // so a miss simply leaves it for the network fetch below).
        var paintedFromCache = false
        if let cacheStore {
            guard let identity = capturedIdentity else { return }
            try? await cacheStore.touchSession(identity)
            if isCurrentTranscriptSelection(token: token, workGeneration: workGeneration),
               (try? await cacheStore.hasTranscript(identity)) == true,
               isCurrentTranscriptSelection(token: token, workGeneration: workGeneration),
               let cached = try? await cacheStore.loadTranscript(identity),
               isCurrentTranscriptSelection(token: token, workGeneration: workGeneration) {
                let cachedWindow = Array(cached.suffix(ChatStore.transcriptOpenWindowLimit))
                let normalized = await Self.normalizeOffMain(cachedWindow)
                guard isCurrentTranscriptSelection(
                    token: token,
                    workGeneration: workGeneration
                ) else { return }
                rememberWarmOpenSnapshot(normalized, for: storedId)
                // QA-2 R15: the chain-tip seed reconciles over already-painted
                // content of the SAME session (no reset here by design) — union
                // so rows the cached window does not cover are retained.
                chat.seed(normalized: normalized, policy: .union)
                chat.noteTranscriptSeedWindow(cachedWindow)
                transcriptPaintedStoredId = storedId
                paintedFromCache = true
            }
        }

        do {
            let stored = try await fetch(storedId, networkProfile)
            guard isCurrentTranscriptNetworkWork(
                token: token,
                workGeneration: workGeneration,
                transportEpoch: transportEpoch
            ) else { return }
            let normalized = await Self.normalizeOffMain(stored)
            guard isCurrentTranscriptNetworkWork(
                token: token,
                workGeneration: workGeneration,
                transportEpoch: transportEpoch
            ) else { return }
            rememberWarmOpenSnapshot(normalized, for: storedId)
            // QA-2 R15: same-session network reconcile — union (the snapshot is
            // a known-partial tail window; never evict settled history it does
            // not cover).
            chat.seed(normalized: normalized, policy: .union)
            chat.noteTranscriptSeedWindow(stored)
            transcriptPaintedStoredId = storedId
            if let cacheStore, let identity = capturedIdentity {
                Task { [weak self] in
                    guard let self,
                          self.isCurrentTranscriptNetworkWork(
                              token: token,
                              workGeneration: workGeneration,
                              transportEpoch: transportEpoch
                          ) else { return }
                    try? await cacheStore.saveTranscript(identity: identity, messages: stored)
                }
            }
        } catch {
            guard isCurrentTranscriptNetworkWork(
                token: token,
                workGeneration: workGeneration,
                transportEpoch: transportEpoch
            ) else { return }
            // A valid cache paint remains readable when reconciliation fails.
            // Only an empty miss needs the recoverable error presentation.
            if !paintedFromCache {
                chat.reset()
                transcriptPaintedStoredId = storedId
            }
            let description = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            if !paintedFromCache { chat.noteTranscriptLoadFailure(description) }
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

    /// Milliseconds since `start` for the open-latency signposts (QA-1 A7/B2).
    private static func openLatencyMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let d = ContinuousClock.now - start
        let comps = d.components
        return Double(comps.seconds) * 1000
            + Double(comps.attoseconds) / 1_000_000_000_000_000
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

    /// Decode a relay `history`/`open` RPC result into the stored rows the
    /// cache/REST seed path consumes (QA-1 B2). The relay answers
    /// `{"session_id", "messages": […]}` where `messages` is the gateway's
    /// `GET /api/sessions/{id}/messages` row set PROXIED VERBATIM
    /// (`relay/hermes_relay/downstream.py` → `rest_history`), so the row shape
    /// is exactly what `StoredMessage(json:)` / `toChatMessages` already parse
    /// off gateway REST — one data source, two transports.
    nonisolated static func relayHistoryMessages(from result: JSONValue) -> [StoredMessage] {
        guard let rows = result["messages"]?.arrayValue else { return [] }
        return rows.compactMap(StoredMessage.init(json:))
    }

    /// The injected transcript seams, or the default that resolves the live
    /// REST client (mirrors `ChatStore.resolvedBackfillFetch`).
    ///
    /// `shape` (WS-5.1): tiers the requested payload — `"skeleton"` nulls the heavy
    /// `reasoning_content` + `tool_calls` fields server-side for a faster cold-open
    /// paint; `nil` (the default) is the shipped FULL fetch. Only the plugin mount
    /// honors `shape`; a stock gateway ignores the unknown query param and returns
    /// full, so this stays backward-safe. The shape-aware test seam
    /// (``transcriptFetchShaped``) is preferred when present; otherwise the legacy
    /// shape-ignorant seams are used as-is for the default (`nil`) shape only.
    private func resolvedTranscriptFetch(
        shape: String? = nil
    ) -> ((String, String?) async throws -> [StoredMessage])? {
        if let transcriptFetchShaped {
            let seam = transcriptFetchShaped
            return { sessionId, profile in
                try await seam(sessionId, profile, shape ?? "full")
            }
        }
        // Default (no shape requested): keep the legacy shape-ignorant seams
        // byte-for-byte so existing tests/default-scope callers are unchanged.
        if shape == nil {
            if let transcriptFetchWithProfile { return transcriptFetchWithProfile }
            if let transcriptFetch { return { sessionId, _ in try await transcriptFetch(sessionId) } }
        }
        // QA-1 B2: on the relay transport the gateway REST URL may be
        // unreachable from the phone (relay-only reach — off-LAN tailnet relay),
        // so a cache-miss switch that seeds over `connection.rest` hangs to the
        // 15s RestClient timeout — skeleton rows "forever". The relay `history`
        // RPC returns the SAME gateway store rows over the transport that IS up
        // (relay/hermes_relay/downstream.py: OPEN/HISTORY → rest_history →
        // `GET /api/sessions/{id}/messages` verbatim). Seed over the relay
        // instead: the switch paints the moment the relay answers, independent
        // of gateway-REST reachability. The relay path carries no `shape` tier
        // (the relay proxies full rows), which only forgoes the skeleton
        // optimization — never correctness. Test seams above keep precedence.
        if connection?.transportPath == .relay,
           let coordinator = connection?.relayCoordinator {
            let relayRest = connection?.rest
            return { sessionId, profile in
                if let profile, !profile.isEmpty {
                    // The relay history route has no profile-scoped variant yet;
                    // non-default profile rows keep today's gateway-REST read.
                    guard let relayRest else { throw RelayError.notConnected }
                    return try await relayRest.messages(
                        sessionId: sessionId, profile: profile, shape: shape
                    )
                }
                // Queue on the relay phase bridge (bounded) instead of failing a
                // cold cache-miss open the instant the socket is mid-connect.
                guard await coordinator.waitUntilOpen(timeout: .seconds(10)) else {
                    throw RelayError.notConnected
                }
                let result = try await coordinator.history(
                    sessionID: sessionId,
                    limit: ChatStore.transcriptOpenWindowLimit
                )
                return Self.relayHistoryMessages(from: result)
            }
        }
        guard let rest = connection?.rest else { return nil }
        // ABH-408: a non-default row opened from the All-profiles rail must use
        // RestClient+Profiles.messages(sessionId:profile:) so the backend reads
        // that profile's store. The plugin transcript-page route currently has no
        // profile-scoped/latest-descendant equivalent, so scoped opens deliberately
        // bypass the ABH-400 page/delta fast path until plugins/hermes-mobile adds
        // a profile-aware latest-descendant/messages route.
        return { [cacheStore] sessionId, profile in
            if let profile, !profile.isEmpty {
                return try await rest.messages(sessionId: sessionId, profile: profile, shape: shape)
            }
            // ABH-400: plugin gateways fetch only the recent tail window on open;
            // legacy/older plugin builds keep the existing delta-aware full fallback.
            if let page = await fetchTranscriptPage(
                rest: rest,
                sessionId: sessionId,
                limit: ChatStore.transcriptOpenWindowLimit,
                shape: shape
            ) {
                return page.messages
            }
            return try await fetchTranscriptDeltaAware(
                rest: rest, cacheStore: cacheStore, sessionId: sessionId,
                identity: self.cacheIdentity(sessionId), shape: shape)
        }
    }

    /// Whether the cold-open network seed should request the `skeleton` tier and
    /// then hydrate to full in the background (WS-5.1). True only on the plugin
    /// mount — the sole route that honors `shape` (the stock endpoint ignores the
    /// unknown query param and returns full, so a skeleton-then-hydrate there would
    /// be a redundant double full fetch). Overridable by tests via
    /// ``skeletonColdOpenForced``.
    private var skeletonColdOpenEligible: Bool {
        if let forced = skeletonColdOpenForced { return forced }
        return connection?.rest?.pathStyle == .plugin
    }

    /// The injected ``rpcSend``, or the default that forwards to the live gateway
    /// client (mirrors ``resolvedTranscriptFetch``). `nil` when there is no
    /// client at all (unconfigured) — the caller no-ops, as before.
    private var resolvedRPCSend: ((String, JSONValue) async throws -> JSONValue)? {
        if let rpcSend { return rpcSend }
        guard let client else { return nil }
        return { method, params in try await client.requestRaw(method, params: params) }
    }

    /// The injected profile-aware delete seam, or the live REST profile-scoped
    /// delete. Used only for non-default profile rows; default/dormant deletes
    /// keep using the existing WS `session.delete` path.
    private var resolvedDeleteSessionRequest: ((String, String?) async throws -> Void)? {
        if let deleteSessionRequest { return deleteSessionRequest }
        guard let api = restAPI else { return nil }
        return { sessionId, profile in
            try await api.deleteSession(id: sessionId, profile: profile)
        }
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

/// A surfaced failure from a session action (open/resume/delete/archive/rename).
///
/// Owned by ``SessionStore`` and published via ``SessionStore/sessionActionError``
/// for the drawer to present as a system alert (ABH-73 — failures used to be
/// swallowed into the unobserved `lastError`). `Identifiable` so the view can
/// bind a value-presenting `.alert`; `Equatable` for `@Observable` change
/// tracking and tests.
struct SessionActionError: Identifiable, Equatable {
    let id = UUID()
    /// The verb shown in the alert title ("Open Session", "Delete", "Archive").
    let action: String
    /// Human-readable detail — the gateway error message where available.
    let message: String
}

// MARK: - Projects overview (ABH-351 SLICE 2)

/// ABH-351 (SLICE 2) — read-only Projects browsing for the drawer's Projects tab.
///
/// Fetches the projects overview from the slice-1 REST route
/// (`GET /api/plugins/hermes-mobile/projects`) — the merged user-created +
/// auto-discovered git-repo-roots + session-cwds list, junk-filtered, reshaped
/// to `{id, label, root, session_count}`. The store exposes the fetched list
/// plus designed loading / empty / error states, and derives per-project
/// sessions from ``SessionStore`` (a project's sessions are the ones whose
/// `cwd` matches the project's `root`).
///
/// This slice is READ-ONLY browsing + session-start ONLY. Create-project /
/// attach-folders / set-idea is a FAST-FOLLOW and lives outside this store.
///
/// The store is `@Observable` + `@MainActor`, mirroring the app's other store
/// shape (``SessionStore``, ``ConnectionStore``). It owns NO back-references at
/// construction time — ``attach(connection:)`` is called by ``AppEnvironment``
/// after the store graph is built, exactly as the other stores are wired.
@MainActor
@Observable
final class ProjectsStore {

    // MARK: - Published state

    /// The fetched projects overview (slice-1 route payload), or `nil` before
    /// the first successful load completes. An empty array IS a valid loaded
    /// state (no projects discovered) and renders a designed empty state, NOT
    /// this `nil` placeholder.
    private(set) var projects: [Project]?

    /// `true` while a fetch is in flight. Drives the loading state.
    private(set) var isLoading = false

    /// A human-readable error message from the last failed fetch, or `nil`.
    /// Renders a designed error state (never fakes 'ok'). Cleared on the next
    /// successful fetch.
    private(set) var loadError: String?

    // MARK: - Per-project sessions (ABH-407)

    /// Server-scoped session lists for Project detail, keyed by ``Project/id``.
    /// Populated by ``refreshSessions(for:)`` via `GET /api/sessions?cwd_prefix=…`
    /// — independent of ``SessionStore/sessions`` (the global drawer Recents list)
    /// so a project fetch can never corrupt Recents or the active session state.
    private(set) var projectSessionsById: [String: [SessionSummary]] = [:]

    /// Project ids with a fetch currently in flight (drives the detail loading state).
    private(set) var projectSessionsLoadingIds: Set<String> = []

    /// A human-readable error per project id from its last failed fetch, or absent.
    /// Cleared on the next successful fetch for that project.
    private(set) var projectSessionsErrorById: [String: String] = [:]

    /// Testing seam: when set, ``refreshSessions(for:)`` calls this instead of
    /// hitting the network via `connection?.rest` — mirrors
    /// ``SessionStore/sessionsFetch``. Lets tests prove the store renders
    /// exactly the (stubbed) server-scoped response without a live gateway.
    var sessionsFetch: ((Project) async throws -> (sessions: [SessionSummary], total: Int?))?

    // MARK: - Back-reference (injected by AppEnvironment)

    /// The connection store, for REST access. `nil` until
    /// ``attach(connection:)`` is called by the composition root.
    private var connection: ConnectionStore?

    // MARK: - Offline cache (cache-first projects)

    /// The shared cache actor, injected by ``attachCache(_:scope:)``. `nil` until
    /// wired (or when the cache failed to open) — every cache path then no-ops
    /// and the store runs network-only, byte-identical to before.
    private var cacheStore: CacheStore?

    /// Supplies the ACTIVE `(serverId, profileId)` cache partition. Sourced from
    /// ``SessionStore`` so Projects share the same scope as the session list
    /// (a profile/server switch re-partitions both). `nil` before there is a
    /// connection.
    private var cacheScopeProvider: (() -> CacheScope?)?

    init() {}

    /// Inject the connection store (REST access). Called once by
    /// ``AppEnvironment`` after the store graph is built — mirrors the
    /// attach-pattern the other stores use (``SessionStore/attach`` etc.).
    func attach(connection: ConnectionStore) {
        self.connection = connection
    }

    /// Inject the offline cache + its scope provider, and immediately seed the
    /// in-memory list from disk so a cold/offline launch paints projects instead
    /// of a blank "Not connected" wall (the network refresh write-through then
    /// repaints). Mirrors the session-list cache-first pattern.
    func attachCache(_ cache: CacheStore, scope: @escaping () -> CacheScope?) {
        self.cacheStore = cache
        self.cacheScopeProvider = scope
        Task { await seedFromCache() }
    }

    /// Paint ``projects`` from the on-disk snapshot when nothing is loaded yet.
    /// No-op once a (possibly empty) network result has landed — the cache never
    /// clobbers fresher server data.
    func seedFromCache() async {
        guard projects == nil,
              let cache = cacheStore,
              let scope = cacheScopeProvider?() else { return }
        if let cached = try? await cache.loadProjects(scope: scope),
           !cached.isEmpty,
           projects == nil {
            projects = cached
        }
    }

    // MARK: - Fetch

    /// Fetch the projects overview from the slice-1 REST route and update
    /// ``projects`` / ``isLoading`` / ``loadError``.
    ///
    /// Safe to call repeatedly (drawer-open refresh, pull-to-refresh). A fetch
    /// supersedes the prior error state. Never throws — failures land in
    /// ``loadError`` and leave the last successful ``projects`` intact so the
    /// UI doesn't flicker on a transient network blip.
    func refresh() async {
        guard let rest = connection?.rest else {
            // Offline: paint from disk so cold launch shows the last-known
            // projects instead of a blank "Not connected" list.
            await seedFromCache()
            if projects == nil { loadError = "Not connected" }
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await rest.get(
                path: "\(rest.mobileAPIPrefix)/projects"
            )
            // The route returns a bare JSON array (see test_projects_route.py);
            // decode with default keys (no snake_case conversion needed — the
            // keys are already lowercase with underscores).
            let decoded = try JSONDecoder().decode(
                [Project].self, from: data
            )
            projects = decoded
            loadError = nil
            // Write-through: persist the fresh list so the next cold/offline
            // launch paints instantly.
            writeThroughProjects(decoded)
        } catch {
            // Preserve the last successful list so the UI doesn't blank out
            // on a transient failure — only surface the error when there is no
            // cached data to show. Seed from disk first so a transient network
            // failure at cold launch still paints the last-known list.
            if projects == nil { await seedFromCache() }
            if projects == nil {
                loadError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// Persist the freshly-fetched projects overview to the on-disk snapshot.
    private func writeThroughProjects(_ projects: [Project]) {
        guard let cache = cacheStore, let scope = cacheScopeProvider?() else { return }
        Task { try? await cache.saveProjects(projects, scope: scope) }
    }

    // MARK: - Create (cache-first project creation)

    /// The outcome of a create-project attempt: the created ``Project`` on
    /// success (so the caller can open it), or a human-readable error message.
    enum CreateResult: Sendable, Equatable {
        case created(Project)
        case failure(String)
    }

    /// Create a project via the plugin `POST /projects` route, then refresh the
    /// overview so the new project appears in the list. Never throws — failures
    /// come back as ``CreateResult/failure`` for the sheet to surface.
    func createProject(name: String, root: String) async -> CreateResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure("Project name is required.") }
        guard !trimmedRoot.isEmpty else { return .failure("Root folder path is required.") }
        guard let rest = connection?.rest else { return .failure("Not connected") }
        do {
            let project = try await rest.createProject(name: trimmedName, root: trimmedRoot)
            await refresh()
            return .created(project)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return .failure(message)
        }
    }

    /// Testing seam: overrides the retry backoff in ``refreshSessions(for:)``
    /// so unit tests don't burn wall-clock time on the real delay. `nil` (the
    /// production default) uses ``projectSessionsRetryDelayNanoseconds``.
    var projectSessionsRetryDelayOverrideNanoseconds: UInt64?

    /// Delay before the single automatic retry in ``refreshSessions(for:)``.
    /// Short and fixed (not exponential) — this covers a sub-second gateway
    /// respawn window (PROJECTS-401), not a sustained outage; the manual
    /// "Retry" affordance in the detail view's error row handles anything
    /// longer.
    private static let projectSessionsRetryDelayNanoseconds: UInt64 = 600_000_000

    /// `true` for a failure the gateway can recover from within the same
    /// respawn window: a 401/403 (device-token auth racing plugin-route
    /// registration during a crash-respawn — PROJECTS-401), any 5xx, or a
    /// transport-level failure (timeout / dropped connection). Treated
    /// exactly like the legacy "gateway too old" 404 — fall back to the
    /// `cwd_prefix` path, and retry the whole two-tier fetch once.
    ///
    /// NOT transient: 4xx other than 401/403/404 (a genuinely malformed
    /// request) and decode failures (a real contract mismatch) — those
    /// propagate immediately so the designed error state stays honest.
    static func isTransientProjectSessionsFailure(_ error: Error) -> Bool {
        switch error {
        case RestError.badStatus(let status, _):
            return status == 401 || status == 403 || status == 404 || (500...599).contains(status)
        case RestError.network:
            return true
        default:
            return false
        }
    }

    /// The detail view's error row copy for `error`. Transient failures (see
    /// ``isTransientProjectSessionsFailure(_:)``) get directional copy — the
    /// user should just retry, a raw "HTTP 401" is not actionable — everything
    /// else keeps its specific message.
    static func projectSessionsErrorMessage(for error: Error) -> String {
        guard isTransientProjectSessionsFailure(error) else {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return "Reconnecting to gateway — retry"
    }

    /// Fetch a project's sessions from the server with `cwd_prefix=project.root`
    /// (ABH-407) and update ``projectSessionsById`` / ``projectSessionsLoadingIds``
    /// / ``projectSessionsErrorById`` for that project's id. This is the primary
    /// Project detail data source — it does NOT touch ``SessionStore/sessions``
    /// (the global drawer Recents list) or the active session state.
    ///
    /// Safe to call repeatedly (detail-view appear, pull-to-refresh). Never
    /// throws — failures land in ``projectSessionsErrorById`` and leave the last
    /// successful list for this project intact so the UI doesn't flicker on a
    /// transient network blip.
    func refreshSessions(for project: Project) async {
        let fetch: () async throws -> (sessions: [SessionSummary], total: Int?)
        if let sessionsFetch {
            fetch = { try await sessionsFetch(project) }
        } else {
            guard let rest = connection?.rest else {
                // Offline: paint from the per-project cache snapshot if we have
                // one, so cold-launch detail isn't a blank "Not connected" wall.
                await seedProjectSessionsFromCache(for: project)
                if projectSessionsById[project.id] == nil {
                    projectSessionsErrorById[project.id] = "Not connected"
                }
                return
            }
            // Primary: the plugin's folded project-sessions route (matches the
            // count). Fall back to the legacy cwd_prefix path on a 404 (gateway
            // too old to serve the plugin route) OR a transient failure — a
            // 401/403/5xx/timeout observed during a gateway crash-respawn
            // window (PROJECTS-401: device-token auth can race plugin-route
            // registration on a fresh process). A non-transient failure
            // propagates so the designed error state is honest.
            fetch = {
                do {
                    return try await rest.projectSessions(projectId: project.id)
                } catch let error where Self.isTransientProjectSessionsFailure(error) {
                    return try await rest.sessionsWithTotal(cwdPrefix: project.root)
                }
            }
        }
        // Seed instantly from the per-project cache snapshot so the detail view
        // paints before the network returns (write-through repaints on success).
        await seedProjectSessionsFromCache(for: project)
        projectSessionsLoadingIds.insert(project.id)
        defer { projectSessionsLoadingIds.remove(project.id) }
        do {
            let result = try await fetchProjectSessionsWithRetry(fetch)
            // S10 (QA-3): never accept a fallback `[]` as authoritative when
            // the project overview's `sessionCount > 0`. The overview count
            // comes from the same `_build_project_tree` machinery that folds
            // worktrees, so a non-zero count is authoritative — a `[]` here
            // means the detail query's cwd_prefix path missed worktree cwds
            // (the server fix in `_cwd_prefix_clause` closes this; this is the
            // iOS-side defensive backstop while the relay/plugin propagates).
            // Treat an empty-list-when-count>0 as a transient failure so the
            // detail surfaces a "Reconnecting to gateway — retry" state rather
            // than a lying "No sessions yet" (IMG_2593). Preserve any prior
            // non-empty list so the UI doesn't flicker to empty on a blip.
            if result.sessions.isEmpty && project.sessionCount > 0 {
                if projectSessionsById[project.id] == nil {
                    projectSessionsErrorById[project.id] = Self.projectSessionsEmptyButCountedMessage
                }
                return
            }
            projectSessionsById[project.id] = result.sessions
            projectSessionsErrorById[project.id] = nil
            writeThroughProjectSessions(result.sessions, for: project)
        } catch {
            if projectSessionsById[project.id] == nil {
                projectSessionsErrorById[project.id] = Self.projectSessionsErrorMessage(for: error)
            }
        }
    }

    /// S10: surfaced copy when the detail fetch returned `[]` but the project
    /// overview's `sessionCount > 0`. Same directional copy as a transient
    /// failure — the user should retry; a lying "No sessions yet" is not
    /// actionable. Distinct constant so a test can pin the contract.
    static let projectSessionsEmptyButCountedMessage = "Reconnecting to gateway — retry"

    /// Runs `fetch` (which already carries the 404/transient → `cwd_prefix`
    /// fallback above); on a transient failure from THAT combined attempt,
    /// waits one short fixed backoff and retries the whole thing exactly
    /// once before giving up. Covers the case where a gateway respawn window
    /// outlasts both the primary and fallback request in the same call.
    private func fetchProjectSessionsWithRetry(
        _ fetch: () async throws -> (sessions: [SessionSummary], total: Int?)
    ) async throws -> (sessions: [SessionSummary], total: Int?) {
        do {
            return try await fetch()
        } catch {
            guard Self.isTransientProjectSessionsFailure(error) else { throw error }
            let delay = projectSessionsRetryDelayOverrideNanoseconds ?? Self.projectSessionsRetryDelayNanoseconds
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            return try await fetch()
        }
    }

    /// Paint `project`'s detail list from the on-disk snapshot when nothing is in
    /// memory yet. No-op when a cache/scope isn't wired, the snapshot is missing,
    /// or an in-memory list already exists (never clobber fresher data).
    private func seedProjectSessionsFromCache(for project: Project) async {
        guard projectSessionsById[project.id] == nil,
              let cache = cacheStore,
              let scope = cacheScopeProvider?() else { return }
        if let cached = try? await cache.loadProjectSessions(scope: scope, projectId: project.id),
           !cached.isEmpty,
           projectSessionsById[project.id] == nil {
            projectSessionsById[project.id] = cached
        }
    }

    /// Persist `project`'s freshly-fetched sessions to the on-disk snapshot.
    private func writeThroughProjectSessions(_ sessions: [SessionSummary], for project: Project) {
        guard let cache = cacheStore, let scope = cacheScopeProvider?() else { return }
        let projectId = project.id
        Task { try? await cache.saveProjectSessions(sessions, scope: scope, projectId: projectId) }
    }

    /// The server-scoped session list for `project`, or `[]` if it hasn't
    /// loaded yet (a designed loading/empty state in the detail view, not a
    /// silent zero). Populated by ``refreshSessions(for:)``.
    func sessions(for project: Project) -> [SessionSummary] {
        projectSessionsById[project.id] ?? []
    }

    /// `true` while a ``refreshSessions(for:)`` fetch is in flight for `project`.
    func isLoadingSessions(for project: Project) -> Bool {
        projectSessionsLoadingIds.contains(project.id)
    }

    /// The last fetch error for `project`, or `nil`. Cleared on the next
    /// successful ``refreshSessions(for:)`` call.
    func sessionsError(for project: Project) -> String? {
        projectSessionsErrorById[project.id]
    }

    // MARK: - Derived queries

    /// Client-side fallback/test utility: the sessions belonging to a project
    /// filtered from an already-loaded ``SessionStore`` by matching `cwd` to the
    /// project's `root` (exact match on the trimmed path, case-insensitive,
    /// trailing-slash-insensitive). ABH-407 moved Project detail's primary data
    /// source to the server-side ``sessions(for:)`` / ``refreshSessions(for:)``
    /// pair above (`cwd_prefix` query) — this method is kept for tests and as a
    /// fallback utility, not as the detail view's data source.
    ///
    /// Returns `[]` when the session list hasn't loaded yet (a designed
    /// loading/empty state in the detail view, not a silent zero).
    func sessions(for project: Project, in sessionStore: SessionStore) -> [SessionSummary] {
        let root = Self.normalizedPath(project.root)
        guard !root.isEmpty else { return [] }
        return sessionStore.sessions.filter {
            Self.normalizedPath($0.cwd ?? "") == root
        }
    }

    /// Normalize a filesystem path for cwd matching: trimmed, trailing slashes
    /// stripped, case-folded. Empty / whitespace-only → "" (never matches).
    static func normalizedPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }
}

/// One entry in the projects overview (the slice-1 route's `{id, label, root,
/// session_count}` contract).
///
/// `id` and `root` are both the repo root path (stable identity, matching how
/// the desktop keys project entries). `session_count` is the number of sessions
/// whose cwd resolved to that repo root (server-side count; the iOS client
/// re-derives the live list from ``SessionStore`` for the detail view).
struct Project: Decodable, Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let label: String
    let root: String
    let sessionCount: Int

    enum CodingKeys: String, CodingKey {
        case id, label, root
        case sessionCount = "session_count"
    }

    init(id: String, label: String, root: String, sessionCount: Int) {
        self.id = id
        self.label = label
        self.root = root
        self.sessionCount = sessionCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.root = try c.decode(String.self, forKey: .root)
        self.sessionCount = try c.decode(Int.self, forKey: .sessionCount)
    }
}
