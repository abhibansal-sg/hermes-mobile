import Foundation

// MARK: - SyncEngine
//
// Pure-logic sync engine over CacheStore. Injectable fetch + store seams make
// it unit-testable without a live gateway. NOT wired into the live stores yet
// (that is P3). See CONTRACT-OFFLINE-CACHE.md §3.
//
// Concurrency: actor-isolated. All public methods are async and safe to call
// from any actor. The CacheStore seam is the sole database access path.

// MARK: - Seam protocols

/// Fetch seam: provides the live gateway data. Injectable for tests (mock with
/// recorded fixtures).
protocol SessionListFetcher: Sendable {
    /// Fetch a page of sessions. Mirrors the SessionStore's existing REST call shape.
    func fetchSessionList() async throws -> [SessionSummary]
}

/// Transcript fetch seam: fetches [StoredMessage] for a session.
protocol TranscriptFetcher: Sendable {
    func fetchTranscript(sessionId: String) async throws -> [StoredMessage]
}

// MARK: - List diff result

/// The classified outcome of comparing a fresh session list page against the cache.
struct SessionListDiff: Sendable {
    /// Sessions present in the live page but absent from the cache (new arrivals)
    let added: [SessionSummary]
    /// Sessions whose (lastActive, messageCount) pair or title/archived changed
    let dirty: [SessionSummary]
    /// Sessions that were removed from the live page (only meaningful on a full enumeration)
    let removed: [String]
    /// Sessions that are unchanged
    let unchanged: [SessionSummary]
}

// MARK: - SyncEngine actor

actor SyncEngine {

    // MARK: - Dependencies (injectable seams)

    private let cache: CacheStore
    private let listFetcher: any SessionListFetcher
    private let transcriptFetcher: any TranscriptFetcher

    /// The (server, profile) scope this engine reads/writes the session-list
    /// cache under (P4). All `loadSessionList`/`saveSessionList`/`upsertSession`
    /// calls are partitioned by it. Transcript methods key by globally-unique
    /// sessionId and need no scope.
    private let scope: CacheScope

    // MARK: - In-memory dirty set
    // Sessions known to need a transcript re-fetch. Populated by broadcast frames
    // and list diffs; cleared on successful re-fetch.

    private var dirtySessionIds: Set<String> = []

    // MARK: - Init

    init(
        cache: CacheStore,
        listFetcher: some SessionListFetcher,
        transcriptFetcher: some TranscriptFetcher,
        scope: CacheScope
    ) {
        self.cache = cache
        self.listFetcher = listFetcher
        self.transcriptFetcher = transcriptFetcher
        self.scope = scope
    }

    // MARK: - P2.1: Session list sync

    /// Full-fetch + client-side diff (v1 protocol). Fetches the session list,
    /// diffs against the cache, upserts changed rows, stamps lastFullFetchAt.
    /// Returns the diff result so the caller can react (e.g. schedule dirty
    /// transcript re-fetches).
    @discardableResult
    func syncSessionList() async throws -> SessionListDiff {
        let live = try await listFetcher.fetchSessionList()
        let diff = try await diffSessionList(live)

        // Upsert all changed and new sessions under the active scope
        for summary in diff.added + diff.dirty {
            try await cache.upsertSession(summary, scope: scope)
        }

        // Mark dirty sessions' transcripts stale so they re-fetch on open
        for summary in diff.dirty {
            dirtySessionIds.insert(summary.id)
            try await cache.markTranscriptDirty(summary.id)
        }

        // Stamp the full-fetch timestamp
        let now = String(Date().timeIntervalSince1970)
        try await cache.writeMeta(SyncMetaRecord.Key.sessionListLastFullFetchAt, value: now)

        return diff
    }

    // MARK: - P2.2: List diff

    /// Compare a live page against the cache using (lastActive, messageCount) as
    /// the dirty key, plus title/archived changes. Returns a classified diff.
    /// Does NOT delete sessions absent from a partial page — only a full
    /// enumeration (page covers total) can determine removals.
    func diffSessionList(_ live: [SessionSummary]) async throws -> SessionListDiff {
        var added: [SessionSummary] = []
        var dirty: [SessionSummary] = []
        var unchanged: [SessionSummary] = []

        let cached = try await cache.loadSessionList(scope: scope)
        let cachedById = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
        let liveIds = Set(live.map(\.id))

        for summary in live {
            guard let existing = cachedById[summary.id] else {
                added.append(summary)
                continue
            }
            // Dirty check: (lastActive, messageCount) pair detects new messages;
            // preview/title detects renames; archived detects archive changes.
            let lastActiveChanged = summary.lastActive != existing.lastActive
            let messageCountChanged = summary.messageCount != existing.messageCount
            let previewChanged = summary.preview != existing.preview
            let titleChanged = summary.title != existing.title
            if lastActiveChanged || messageCountChanged || previewChanged || titleChanged {
                dirty.append(summary)
            } else {
                unchanged.append(summary)
            }
        }

        // Removals: sessions in cache but not in this live page.
        // Only meaningful when the page covers the full dataset; callers decide
        // whether to act on removals based on their total-count knowledge.
        let removed = cached.map(\.id).filter { !liveIds.contains($0) }

        return SessionListDiff(added: added, dirty: dirty, removed: removed, unchanged: unchanged)
    }

    // MARK: - P2.3: Lazy transcript cache

    /// Ensure the transcript for `sessionId` is cached. If already cached and
    /// not dirty, returns immediately (fast path). Otherwise fetches from the
    /// gateway and persists. Returns the cached [StoredMessage] after ensuring.
    func ensureTranscript(sessionId: String) async throws -> [StoredMessage] {
        // Fast path: already cached and not dirty
        if !dirtySessionIds.contains(sessionId),
           let cached = try await cache.loadTranscript(sessionId) {
            return cached
        }

        // Fetch from gateway
        let messages = try await transcriptFetcher.fetchTranscript(sessionId: sessionId)
        try await cache.saveTranscript(sessionId: sessionId, messages: messages)
        dirtySessionIds.remove(sessionId)
        return messages
    }

    // MARK: - P2.4: Broadcast frame apply

    /// React to a settled broadcast frame from the gateway's JSON-RPC channel.
    /// Only settled frames are acted on (message.delta is ignored).
    /// See CONTRACT-OFFLINE-CACHE.md §3.5 table.
    func applyBroadcastFrame(_ event: BroadcastCacheEvent) async {
        switch event {
        case .messageComplete(let sessionId):
            // Mark dirty; background re-fetch will run on next open or explicit sync
            dirtySessionIds.insert(sessionId)
            try? await cache.markTranscriptDirty(sessionId)

        case .messageStart(let sessionId):
            // Metadata-only: mark as live/active (no transcript mutation needed)
            // The transcript is marked dirty so it re-fetches at next opportunity.
            dirtySessionIds.insert(sessionId)

        case .messageDelta:
            // Ignored — buffered live in ChatStore, persisted only at message.complete
            break

        case .sessionInfo(let summary):
            // Merge changed metadata fields into the cached summary blob
            try? await cache.upsertSession(summary, scope: scope)

        case .gatewayReady:
            // Trigger a full session list sync
            try? await syncSessionList()
        }
    }

    // MARK: - P2.5: Per-session cursor

    /// Return the maxMessageId cursor for `sessionId`. Used by v2 delta path
    /// (ServerCapabilities.deltaSync) to request only rows after this id.
    /// In v1 (full-fetch-diff), this classifies a re-fetch as append-only vs rewind.
    func maxMessageId(for sessionId: String) async throws -> Int? {
        try await cache.maxMessageId(for: sessionId)
    }

    // MARK: - P2.6: Dirty session management

    /// Mark a session dirty (transcript needs re-fetch). Called externally e.g.
    /// when the list diff finds a changed (lastActive, messageCount).
    func markDirty(_ sessionId: String) {
        dirtySessionIds.insert(sessionId)
    }

    /// Returns true if the session is in the dirty set.
    func isDirty(_ sessionId: String) -> Bool {
        dirtySessionIds.contains(sessionId)
    }

    /// Snapshot of the full dirty set (for testing/diagnostics).
    func dirtySnapshot() -> Set<String> {
        dirtySessionIds
    }

    // MARK: - P2.7: Eviction (throttled, ~once/day)

    /// Run the eviction sweep if it hasn't run in the last 24 hours.
    /// Safe to call on every app launch; internally throttled via sync_meta.
    func runEvictionIfNeeded(horizonDays: Int = 365) async throws {
        let oneDayAgo = Date().timeIntervalSince1970 - 86400
        if let raw = try await cache.readMeta(SyncMetaRecord.Key.evictionLastRunAt),
           let lastRun = Double(raw),
           lastRun > oneDayAgo {
            return // Ran recently; skip
        }

        try await cache.evictStaleTranscripts(horizonDays: horizonDays)
        let now = String(Date().timeIntervalSince1970)
        try await cache.writeMeta(SyncMetaRecord.Key.evictionLastRunAt, value: now)
    }
}

// MARK: - BroadcastCacheEvent

/// Typed representation of gateway broadcast frames that the SyncEngine reacts to.
/// This is a pure-logic enum: the caller (P3 ConnectionStore routing) maps
/// raw GatewayEvent frames to these cases.
enum BroadcastCacheEvent: Sendable {
    case messageComplete(sessionId: String)
    case messageStart(sessionId: String)
    case messageDelta
    case sessionInfo(SessionSummary)
    case gatewayReady
}
