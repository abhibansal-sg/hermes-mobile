import Foundation
import GRDB

// MARK: - CacheStore
//
// The single actor that owns the SQLite DatabaseQueue. ALL database access is
// serialised through this actor — there is no concurrent reader pool. The actor
// boundary IS the full isolation boundary: no SessionSummary, StoredMessage,
// ChatMessage, or ChatMessagePart value is ever held as actor state; they are
// Sendable parameters and return values only.
//
// DB location: Application Support / hermes_cache.sqlite
// WAL mode + foreign_keys=ON applied at open.
// Excluded from iCloud backup (it is a reconstructible cache).
//
// See CONTRACT-OFFLINE-CACHE.md §1, §2, §3.

actor CacheStore {

    // MARK: - Internal state (actor-isolated)

    private let db: DatabaseQueue

    // MARK: - Init / open

    /// Open (or create) the cache database at the canonical App Support location.
    /// Applies WAL pragma, enables foreign keys, runs migrations.
    /// Throws if the database cannot be opened or migrated.
    init() throws {
        let dbURL = try Self.dbURL()
        // Drop-and-rebuild escape hatch: nuke on fingerprint mismatch
        CacheSchema.nukeIfSchemaMismatch(at: dbURL)

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try CacheSchema.makeMigrator().migrate(queue)
        self.db = queue
    }

    /// Designated init for tests: accepts an in-memory DatabaseQueue so unit
    /// tests never touch the filesystem.
    init(testDB: DatabaseQueue) throws {
        self.db = testDB
        try CacheSchema.makeMigrator().migrate(testDB)
    }

    // MARK: - DB URL

    static func dbURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("HermesMobile", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hermes_cache.sqlite")
        // Exclude from iCloud backup — the cache is 100% reconstructible.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        return url
    }

    // MARK: - Session list read

    /// Load the cached session list for the given `scope` (server + profile),
    /// sorted by lastActive descending. Returns SessionSummary values decoded
    /// from the summaryJSON blobs. Used by P3 cold-launch read in
    /// SessionStore.refresh(). A scope filter means a PROFILE switch (same
    /// server) re-paints from the other profile's rows instantly, and a server's
    /// rows never bleed into another server's list.
    func loadSessionList(scope: CacheScope) throws -> [SessionSummary] {
        try db.read { db in
            let records = try SessionCacheRecord
                .filter(Column("serverId") == scope.serverId)
                .filter(Column("profileId") == scope.profileId)
                .order(Column("lastActive").desc)
                .fetchAll(db)
            return try records.map { try $0.decodeSummary() }
        }
    }

    /// Save (upsert) a batch of SessionSummary values into session_cache under
    /// `scope`. Existing rows are updated; new rows are inserted. Does NOT delete
    /// rows absent from the batch — partial pages must never evict unseen
    /// sessions. `isPinned`/`lastAccessedAt`/transcript cursors are preserved for
    /// existing rows; the row's scope is always re-stamped to the active scope so
    /// every persisted row carries a valid (serverId, profileId).
    func saveSessionList(_ summaries: [SessionSummary], scope: CacheScope) throws {
        try db.write { db in
            for summary in summaries {
                let existing = try SessionCacheRecord.fetchOne(db, key: summary.id)
                let record = try SessionCacheRecord.make(
                    from: summary,
                    scope: scope,
                    isPinned: existing?.isPinned ?? false,
                    lastAccessedAt: existing?.lastAccessedAt ?? 0,
                    transcriptCachedAt: existing?.transcriptCachedAt,
                    maxMessageId: existing?.maxMessageId
                )
                try record.save(db)
            }
        }
    }

    // MARK: - Server-switch policy (P4)

    /// Clear every session row (and, via FK cascade, every transcript row) whose
    /// `serverId` is NOT `keepingServerId`. This is the SERVER-switch policy: on
    /// connecting to a different gateway we drop the other servers' cached rows
    /// and repopulate the active one from the network.
    ///
    /// Architected as the SOLE place the server-clear lives: dropping this to a
    /// full coexist-all-servers model (option 1) is a one-line change — stop
    /// calling this method. The serverId column stays part of the key regardless,
    /// so NO further migration is ever needed. Returns the number of session rows
    /// deleted.
    @discardableResult
    func clearSessionsForOtherServers(keepingServerId: String) throws -> Int {
        let keep = keepingServerId.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.write { db in
            // FK is ON DELETE CASCADE, so deleting session rows drops their
            // transcript rows in the same statement.
            try SessionCacheRecord
                .filter(Column("serverId") != keep)
                .deleteAll(db)
        }
    }

    // MARK: - Transcript read

    /// Returns true if the session has cached transcript rows.
    func hasTranscript(_ sessionId: String) throws -> Bool {
        try db.read { db in
            guard let record = try SessionCacheRecord.fetchOne(db, key: sessionId) else {
                return false
            }
            return record.transcriptCachedAt != nil
        }
    }

    /// Whether the cached transcript for `sessionId` is FRESH relative to the
    /// session's `lastActive` — i.e. a transcript exists AND it was cached at or
    /// after the session's most recent activity. Used by the WhatsApp-bar
    /// prefetch to SKIP sessions whose disk copy is already current (so a warm
    /// cache costs zero network), while still re-fetching a session whose
    /// `lastActive` advanced since it was cached (a new turn landed elsewhere) —
    /// and (ARCH37 Step 3) to gate the open-time NETWORK-SEED SKIP: a fresh cache
    /// copy is the only seed on open, so freshness here MUST be conservative.
    ///
    /// ARCH37 STEP 3 — `lastActive == nil` now means STALE (was: fresh-on-any-rows).
    /// The old false-fresh shortcut silently served a STALE disk copy whenever the
    /// session summary lacked `lastActive`, and starved prefetch of exactly the
    /// sessions most likely to have drifted — feeding the positional-id remount on
    /// the network reconcile. Treating unknown freshness as STALE costs a little
    /// extra network but collapses the freshness contract to ONE rule (cachedAt >=
    /// lastActive) and never skips a reconcile on an unprovable copy. The caller's
    /// fast-path gate also requires a non-nil `lastActive` before consulting this,
    /// so a nil here both fails the skip AND keeps the session in the prefetch set.
    func transcriptIsFresh(_ sessionId: String, lastActive: Double?) throws -> Bool {
        try db.read { db in
            guard let record = try SessionCacheRecord.fetchOne(db, key: sessionId),
                  let cachedAt = record.transcriptCachedAt else {
                return false
            }
            // Unknown freshness ⇒ STALE (cannot prove the disk copy is current).
            guard let lastActive else { return false }
            return cachedAt >= lastActive
        }
    }

    /// Load the cached transcript for `sessionId` as an ordered array of
    /// StoredMessage values (sorted by ordinal ASC). Returns nil if no rows
    /// exist. The caller reconstructs [ChatMessage] via toChatMessages.
    func loadTranscript(_ sessionId: String) throws -> [StoredMessage]? {
        try db.read { db in
            let rows = try MessageRowRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("ordinal").asc)
                .fetchAll(db)
            guard !rows.isEmpty else { return nil }
            return try rows.map { try $0.decodeStoredMessage() }
        }
    }

    // MARK: - Transcript write

    /// Persist a full transcript page for a session, replacing any existing rows.
    /// Extracts wireId from the optional `wireIds` parallel array (same count and
    /// order as `messages`). Sets transcriptCachedAt and maxMessageId on the
    /// session row. No-ops for sessions whose source is "cron".
    func saveTranscript(
        sessionId: String,
        messages: [StoredMessage],
        wireIds: [Int?]? = nil
    ) throws {
        try db.write { db in
            // Guard: cron sessions are never transcript-cached
            guard let sessionRecord = try SessionCacheRecord.fetchOne(db, key: sessionId) else {
                return
            }
            guard sessionRecord.source != "cron" else { return }

            // Delete existing rows for this session
            try MessageRowRecord
                .filter(Column("sessionId") == sessionId)
                .deleteAll(db)

            // Insert fresh rows
            var maxWireId: Int? = nil
            for (ordinal, message) in messages.enumerated() {
                // ARCH37 STEP 4 — the wire id now travels ON the StoredMessage, so an
                // explicit parallel `wireIds` array is optional: fall back to the
                // message's own `wireId` (the gateway-emitted stable ordinal) so the
                // cursor column + the persisted-row identity stay in sync.
                let wireId = wireIds?[ordinal] ?? message.wireId
                let row = try MessageRowRecord.make(
                    sessionId: sessionId,
                    ordinal: ordinal,
                    wireId: wireId,
                    message: message
                )
                try row.insert(db)
                if let wid = wireId {
                    maxWireId = max(maxWireId ?? Int.min, wid)
                }
            }

            // Update cursor and cached timestamp on the session row
            var updated = sessionRecord
            updated.transcriptCachedAt = Date().timeIntervalSince1970
            updated.maxMessageId = maxWireId ?? sessionRecord.maxMessageId
            try updated.save(db)
        }
    }

    // MARK: - Upsert page (individual session update)

    /// Upsert a single SessionSummary under `scope` (e.g. from a session.info
    /// broadcast frame or a list-diff dirty/added row). Preserves isPinned,
    /// lastAccessedAt, transcriptCachedAt, maxMessageId; re-stamps the scope so
    /// the row always carries a valid (serverId, profileId). If the row already
    /// exists under a DIFFERENT scope, its scope is updated to the active one
    /// (the active scope is authoritative for where the row currently lives).
    func upsertSession(_ summary: SessionSummary, scope: CacheScope) throws {
        try db.write { db in
            let existing = try SessionCacheRecord.fetchOne(db, key: summary.id)
            let record = try SessionCacheRecord.make(
                from: summary,
                scope: scope,
                isPinned: existing?.isPinned ?? false,
                lastAccessedAt: existing?.lastAccessedAt ?? 0,
                transcriptCachedAt: existing?.transcriptCachedAt,
                maxMessageId: existing?.maxMessageId
            )
            try record.save(db)
        }
    }

    // MARK: - Touch session

    /// Bump `lastAccessedAt` to now for `sessionId`. Called on every session open
    /// to prevent eviction of actively-used sessions.
    func touchSession(_ sessionId: String) throws {
        try db.write { db in
            guard var record = try SessionCacheRecord.fetchOne(db, key: sessionId) else {
                return
            }
            record.lastAccessedAt = Date().timeIntervalSince1970
            try record.save(db)
        }
    }

    // MARK: - Mark session dirty

    /// Clear `transcriptCachedAt` and `maxMessageId` for `sessionId`, forcing a
    /// re-fetch on next open. Used when a `message.complete` or list-diff marks a
    /// session as dirty.
    func markTranscriptDirty(_ sessionId: String) throws {
        try db.write { db in
            guard var record = try SessionCacheRecord.fetchOne(db, key: sessionId) else {
                return
            }
            record.transcriptCachedAt = nil
            record.maxMessageId = nil
            try record.save(db)
        }
    }

    // MARK: - Eviction

    /// Evict transcript rows for human sessions not opened/active in ~1 year and
    /// not pinned. The session-list ROW is kept (the drawer still lists it); only
    /// the transcript body is evicted. Updates transcriptCachedAt and maxMessageId
    /// to nil on evicted sessions.
    ///
    /// Horizon: 365 days. Pinned sessions are always exempt.
    /// Returns the count of sessions whose transcripts were evicted.
    @discardableResult
    func evictStaleTranscripts(horizonDays: Int = 365) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - Double(horizonDays) * 86400

        return try db.write { db in
            // Find sessions eligible for eviction
            let stale = try SessionCacheRecord
                .filter(Column("isPinned") == false)
                .filter(
                    sql: "COALESCE(lastActive, lastAccessedAt) < ?",
                    arguments: [cutoff]
                )
                .fetchAll(db)

            guard !stale.isEmpty else { return 0 }

            let staleIds = stale.map(\.id)
            // Delete transcript rows (CASCADE also fires but we do it explicitly)
            try MessageRowRecord
                .filter(staleIds.contains(Column("sessionId")))
                .deleteAll(db)

            // Clear transcript cursor fields on evicted sessions
            for var record in stale {
                record.transcriptCachedAt = nil
                record.maxMessageId = nil
                try record.save(db)
            }

            return staleIds.count
        }
    }

    /// Run the eviction sweep if it hasn't run in the last 24 hours (WhatsApp bar
    /// hygiene). Safe to call on every connect; internally throttled via the
    /// `eviction.lastRunAt` sync_meta key. Returns the count of sessions whose
    /// transcripts were evicted (0 when throttled or nothing was stale).
    ///
    /// This inlines the throttle that previously lived only in the never-wired
    /// `SyncEngine.runEvictionIfNeeded`, so eviction now actually runs — no dead
    /// code, no extra fetcher dependencies.
    @discardableResult
    func evictStaleTranscriptsIfNeeded(horizonDays: Int = 365) throws -> Int {
        let oneDayAgo = Date().timeIntervalSince1970 - 86400
        if let raw = try readMeta(SyncMetaRecord.Key.evictionLastRunAt),
           let lastRun = Double(raw),
           lastRun > oneDayAgo {
            return 0  // Ran recently; skip.
        }
        let evicted = try evictStaleTranscripts(horizonDays: horizonDays)
        let now = String(Date().timeIntervalSince1970)
        try writeMeta(SyncMetaRecord.Key.evictionLastRunAt, value: now)
        return evicted
    }

    // MARK: - Sync meta

    /// Read a sync_meta value by key. Returns nil if the key doesn't exist.
    func readMeta(_ key: String) throws -> String? {
        try db.read { db in
            try SyncMetaRecord.fetchOne(db, key: key)?.value
        }
    }

    /// Write (upsert) a sync_meta value.
    func writeMeta(_ key: String, value: String) throws {
        try db.write { db in
            let record = SyncMetaRecord(key: key, value: value)
            try record.save(db)
        }
    }

    // MARK: - maxMessageId query

    /// Return the max wireId persisted for a session (the per-session cursor).
    func maxMessageId(for sessionId: String) throws -> Int? {
        try db.read { db in
            try SessionCacheRecord.fetchOne(db, key: sessionId)?.maxMessageId
        }
    }

    /// The delta-sync cursor for `sessionId` (Phase 3): `afterId` = the max cached
    /// wireId (the durable gateway DB id, via the stock REST path), `prefixCount` =
    /// the number of cached rows that carry a wireId. The plugin delta route
    /// validates `prefixCount` against its own `count(active id <= afterId)`; for a
    /// clean mirror they are equal, so any server-side prefix reshape (retry /
    /// rewind / compaction) is detected and forces a full re-sync. Returns nil when
    /// there is no cached transcript or no wire-backed rows — the caller then does a
    /// full fetch (no cursor to send).
    func deltaCursor(for sessionId: String) throws -> (afterId: Int, prefixCount: Int)? {
        try db.read { db in
            guard let record = try SessionCacheRecord.fetchOne(db, key: sessionId),
                  let afterId = record.maxMessageId else { return nil }
            let prefixCount = try MessageRowRecord
                .filter(Column("sessionId") == sessionId)
                .filter(Column("wireId") != nil)
                .fetchCount(db)
            return (afterId, prefixCount)
        }
    }
}
