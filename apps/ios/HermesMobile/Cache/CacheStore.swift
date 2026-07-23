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

    struct OfflineSearchHit: Sendable, Equatable {
        let scope: CacheScope
        let sessionId: String
        let wireId: Int?
        let ordinal: Int
        let role: String
        let snippet: String
    }

    struct OfflineSearchPage: Sendable, Equatable {
        let hits: [OfflineSearchHit]
        let partial: Bool
    }

    struct LastOpenedSession: Sendable, Equatable {
        let profileId: String
        let sessionId: String
    }

    // MARK: - Internal state (actor-isolated)

    private let db: DatabaseQueue

    // MARK: - Init / open

    /// Open (or create) the cache database at the canonical App Support location.
    /// Applies WAL pragma, enables foreign keys, runs migrations.
    /// Throws if the database cannot be opened or migrated.
    init() throws {
        let dbURL = try Self.dbURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        // Resilient, NON-erasing migration: on failure it attempts one bounded,
        // data-preserving repair and retries rather than wiping the owner's real
        // chats. If migration is truly impossible it rethrows; AppEnvironment then
        // leaves the cache nil and the app runs network-only (the cache is a pure
        // accelerator), but the on-disk database is preserved for a later build.
        try CacheSchema.migrateResiliently(queue)
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
            var request = SessionCacheRecord
                .filter(Column("serverId") == scope.serverId)
            if scope.profileId == CacheScope.allProfilesKey {
                // `all` is a query selector over concrete profile rows, never a
                // stored row profile (CONTRACT-OFFLINE-CACHE identity invariant).
                request = request.filter(Column("profileId") != CacheScope.legacy.profileId)
            } else {
                request = request.filter(Column("profileId") == scope.profileId)
            }
            let records = try request.order(Column("lastActive").desc).fetchAll(db)
            return try records.map { try $0.decodeSummary() }
        }
    }

    // MARK: - Pending attention

    /// Load the Inbox and its cursor from one SQLite read snapshot. Callers use
    /// this before networking on launch, so a killed app paints the exact last
    /// committed pending count and rows.
    func loadAttentionSnapshot(scope: CacheScope) throws -> AttentionSnapshot {
        try db.read { db in try Self.attentionSnapshot(scope: scope, db: db) }
    }

    /// Persist a provisional WebSocket prompt. A server-revisioned, responding,
    /// failed, or terminal row always wins over an unrevisioned replay.
    func upsertLiveAttention(_ item: PersistedAttentionItem, scope: CacheScope) throws -> AttentionSnapshot {
        try db.write { db in
            let existing = try Self.attentionItem(id: item.id, scope: scope, db: db)
            if existing == nil || (existing?.revision == 0 && existing?.state == .pending) {
                try Self.saveAttentionItem(item, scope: scope, db: db)
            }
            return try Self.attentionSnapshot(scope: scope, db: db)
        }
    }

    /// Commit a local response overlay before/after the RPC. The row stays in
    /// the database until a later tombstone or reset snapshot confirms server
    /// resolution.
    func markAttentionState(id: String, state: AttentionLifecycle, scope: CacheScope) throws -> AttentionSnapshot {
        try db.write { db in
            if var item = try Self.attentionItem(id: id, scope: scope, db: db),
               !item.state.isTerminal {
                item.state = state
                item.updatedAt = Date().timeIntervalSince1970
                try Self.saveAttentionItem(item, scope: scope, db: db)
            }
            return try Self.attentionSnapshot(scope: scope, db: db)
        }
    }

    /// `message.complete` is authoritative live server truth that the prompt
    /// window closed. Expire every still-visible item for that runtime in the
    /// same transaction as the count change.
    func expireAttention(sessionId: String, scope: CacheScope) throws -> AttentionSnapshot {
        try db.write { db in
            let items = try Self.attentionItems(scope: scope, db: db)
            for var item in items where item.sessionId == sessionId && item.state.contributesToPendingCount {
                item.state = .expired
                item.updatedAt = Date().timeIntervalSince1970
                try Self.saveAttentionItem(item, scope: scope, db: db)
            }
            return try Self.attentionSnapshot(scope: scope, db: db)
        }
    }

    /// Apply one server snapshot/delta and its opaque cursor indivisibly.
    /// Repeated/older revisions are idempotent; equal-revision server upserts do
    /// not overwrite a responding/failed overlay.
    func applyPendingAttention(_ envelope: PendingAttentionEnvelope, scope: CacheScope) throws -> AttentionSnapshot {
        try db.write { db in
            let priorMeta = try Self.attentionMetadata(scope: scope, db: db)
            let protected: [String: PersistedAttentionItem] = (envelope.reset
                && (priorMeta == nil || priorMeta?.serverInstanceId == envelope.serverInstanceId))
                ? Dictionary(uniqueKeysWithValues: try Self.attentionItems(scope: scope, db: db)
                    .filter { $0.state == .responding || $0.state == .failedRetryable || $0.state.isTerminal }
                    .map { ($0.id, $0) })
                : [:]
            if envelope.reset || priorMeta?.serverInstanceId != envelope.serverInstanceId {
                try db.execute(
                    sql: "DELETE FROM pending_attention_cache WHERE serverId=? AND profileId=?",
                    arguments: [scope.serverId, scope.profileId]
                )
            }

            var highWater = (priorMeta?.serverInstanceId == envelope.serverInstanceId)
                ? (priorMeta?.revision ?? 0) : 0
            for record in envelope.upserts {
                highWater = max(highWater, record.revision)
                if let local = protected[record.id], local.revision == 0 || local.revision >= record.revision {
                    try Self.saveAttentionItem(local, scope: scope, db: db)
                    continue
                }
                let incoming = PersistedAttentionItem(server: record)
                if let existing = try Self.attentionItem(id: record.id, scope: scope, db: db) {
                    guard record.revision >= existing.revision else { continue }
                    if record.revision == existing.revision,
                       existing.state == .responding || existing.state == .failedRetryable || existing.state.isTerminal {
                        continue
                    }
                }
                try Self.saveAttentionItem(incoming, scope: scope, db: db)
            }

            for tombstone in envelope.tombstones {
                highWater = max(highWater, tombstone.revision)
                guard var existing = try Self.attentionItem(id: tombstone.id, scope: scope, db: db),
                      tombstone.revision >= existing.revision else { continue }
                existing.revision = tombstone.revision
                existing.state = tombstone.status == "expired" ? .expired : .resolvedElsewhere
                existing.updatedAt = tombstone.deletedAt
                try Self.saveAttentionItem(existing, scope: scope, db: db)
            }

            try db.execute(
                sql: """
                    INSERT INTO attention_reconciliation_meta
                    (serverId,profileId,serverInstanceId,cursor,revision,updatedAt)
                    VALUES (?,?,?,?,?,?)
                    ON CONFLICT(serverId,profileId) DO UPDATE SET
                      serverInstanceId=excluded.serverInstanceId,
                      cursor=excluded.cursor,
                      revision=excluded.revision,
                      updatedAt=excluded.updatedAt
                    """,
                arguments: [scope.serverId, scope.profileId, envelope.serverInstanceId,
                            envelope.cursor, highWater, Date().timeIntervalSince1970]
            )
            return try Self.attentionSnapshot(scope: scope, db: db)
        }
    }

    func removeTerminalAttention(scope: CacheScope, id: String? = nil) throws -> AttentionSnapshot {
        try db.write { db in
            var sql = "DELETE FROM pending_attention_cache WHERE serverId=? AND profileId=? AND state IN (?,?)"
            var arguments: StatementArguments = [scope.serverId, scope.profileId,
                                                   AttentionLifecycle.resolvedElsewhere.rawValue,
                                                   AttentionLifecycle.expired.rawValue]
            if let id {
                sql += " AND id=?"
                arguments += [id]
            }
            try db.execute(sql: sql, arguments: arguments)
            return try Self.attentionSnapshot(scope: scope, db: db)
        }
    }

    func removeAttention(scope: CacheScope, id: String) throws -> AttentionSnapshot {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM pending_attention_cache WHERE serverId=? AND profileId=? AND id=?",
                arguments: [scope.serverId, scope.profileId, id]
            )
            return try Self.attentionSnapshot(scope: scope, db: db)
        }
    }

    /// Optional privacy cleanup on a verified gateway switch. Scope-filtered
    /// reads already prevent bleed; this also removes abandoned partitions.
    func clearAttentionForOtherGateways(keepingServerId: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM pending_attention_cache WHERE serverId != ?", arguments: [keepingServerId])
            try db.execute(sql: "DELETE FROM attention_reconciliation_meta WHERE serverId != ?", arguments: [keepingServerId])
        }
    }

    private static func attentionItems(scope: CacheScope, db: Database) throws -> [PersistedAttentionItem] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT payloadJSON FROM pending_attention_cache WHERE serverId=? AND profileId=? ORDER BY createdAt DESC, id ASC",
            arguments: [scope.serverId, scope.profileId]
        )
        return try rows.map { row in
            let data: Data = row["payloadJSON"]
            return try JSONDecoder().decode(PersistedAttentionItem.self, from: data)
        }
    }

    private static func attentionItem(id: String, scope: CacheScope, db: Database) throws -> PersistedAttentionItem? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT payloadJSON FROM pending_attention_cache WHERE serverId=? AND profileId=? AND id=?",
            arguments: [scope.serverId, scope.profileId, id]
        ) else { return nil }
        let data: Data = row["payloadJSON"]
        return try JSONDecoder().decode(PersistedAttentionItem.self, from: data)
    }

    private static func saveAttentionItem(_ item: PersistedAttentionItem, scope: CacheScope, db: Database) throws {
        let payload = try JSONEncoder().encode(item)
        try db.execute(
            sql: """
                INSERT INTO pending_attention_cache
                (serverId,profileId,id,requestId,sessionId,storedSessionId,kind,payloadJSON,createdAt,expiresAt,state,revision,updatedAt)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(serverId,profileId,id) DO UPDATE SET
                  requestId=excluded.requestId, sessionId=excluded.sessionId,
                  storedSessionId=excluded.storedSessionId, kind=excluded.kind,
                  payloadJSON=excluded.payloadJSON, createdAt=excluded.createdAt,
                  expiresAt=excluded.expiresAt, state=excluded.state,
                  revision=excluded.revision, updatedAt=excluded.updatedAt
                """,
            arguments: [scope.serverId, scope.profileId, item.id, item.requestId,
                        item.sessionId, item.storedSessionId, item.kind, payload,
                        item.createdAt, item.expiresAt, item.state.rawValue,
                        item.revision, item.updatedAt]
        )
    }

    private static func attentionMetadata(scope: CacheScope, db: Database) throws -> AttentionReconciliationMetadata? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT serverInstanceId,cursor,revision,updatedAt FROM attention_reconciliation_meta WHERE serverId=? AND profileId=?",
            arguments: [scope.serverId, scope.profileId]
        ) else { return nil }
        return AttentionReconciliationMetadata(
            serverInstanceId: row["serverInstanceId"], cursor: row["cursor"],
            revision: row["revision"], updatedAt: row["updatedAt"]
        )
    }

    private static func attentionSnapshot(scope: CacheScope, db: Database) throws -> AttentionSnapshot {
        AttentionSnapshot(
            items: try attentionItems(scope: scope, db: db),
            metadata: try attentionMetadata(scope: scope, db: db)
        )
    }

    func saveLastOpenedSession(_ identity: CacheIdentity, manifestScope: CacheScope) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO last_opened_session (serverId, manifestScope, profileId, sessionId) VALUES (?, ?, ?, ?)",
                arguments: [manifestScope.serverId, manifestScope.profileId, identity.profileId, identity.sessionId]
            )
        }
    }

    func loadLastOpenedSession(scope: CacheScope) throws -> LastOpenedSession? {
        try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT profileId, sessionId FROM last_opened_session WHERE serverId = ? AND manifestScope = ?",
                arguments: [scope.serverId, scope.profileId]
            ) else { return nil }
            return LastOpenedSession(profileId: row["profileId"], sessionId: row["sessionId"])
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
                let actualProfile = Self.storedProfileId(for: summary, scope: scope)
                let identity = CacheIdentity(serverId: scope.serverId, profileId: actualProfile, sessionId: summary.id)
                let existing = try Self.session(identity, in: db)
                let record = try SessionCacheRecord.make(
                    from: summary,
                    scope: CacheScope(serverId: identity.serverId, profileId: identity.profileId),
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
    func hasTranscript(_ identity: CacheIdentity) throws -> Bool {
        try db.read { db in
            guard let record = try Self.session(identity, in: db) else {
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
    func transcriptIsFresh(_ identity: CacheIdentity, lastActive: Double?) throws -> Bool {
        try db.read { db in
            guard let record = try Self.session(identity, in: db),
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
    func loadTranscript(_ identity: CacheIdentity) throws -> [StoredMessage]? {
        try db.read { db in
            let rows = try MessageRowRecord
                .filter(Column("serverId") == identity.serverId)
                .filter(Column("profileId") == identity.profileId)
                .filter(Column("sessionId") == identity.sessionId)
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
    /// session row. No-ops for sessions that are not human-Recents-eligible.
    func saveTranscript(
        identity: CacheIdentity,
        messages: [StoredMessage],
        wireIds: [Int?]? = nil,
        scope explicitScope: CacheScope? = nil
    ) throws {
        try db.write { db in
            // Guard: sessions excluded from human Recents are never transcript-cached.
            guard let sessionRecord = try Self.session(identity, in: db) else {
                return
            }
            guard SessionStore.isHumanRecentsSession(
                source: sessionRecord.source,
                messageCount: sessionRecord.messageCount
            ) else { return }
            let scope = explicitScope ?? CacheScope(
                serverId: sessionRecord.serverId, profileId: sessionRecord.profileId
            )

            // The scoped mirror and its FTS rows are replaced atomically with the
            // canonical transcript write. Virtual tables have no FK cascade.
            try db.execute(
                sql: "DELETE FROM transcript_fts WHERE serverId = ? AND profileId = ? AND sessionId = ?",
                arguments: [scope.serverId, scope.profileId, identity.sessionId]
            )
            try db.execute(
                sql: "DELETE FROM offline_message_cache WHERE serverId = ? AND profileId = ? AND sessionId = ?",
                arguments: [scope.serverId, scope.profileId, identity.sessionId]
            )

            // Delete existing rows for this session
            try MessageRowRecord
                .filter(Column("serverId") == identity.serverId)
                .filter(Column("profileId") == identity.profileId)
                .filter(Column("sessionId") == identity.sessionId)
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
                    identity: identity,
                    ordinal: ordinal,
                    wireId: wireId,
                    message: message
                )
                try row.insert(db)
                try db.execute(
                    sql: """
                        INSERT INTO offline_message_cache
                        (serverId, profileId, sessionId, ordinal, wireId, role, timestamp, rowJSON)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [scope.serverId, scope.profileId, identity.sessionId, ordinal,
                                wireId, row.role, row.timestamp, row.rowJSON]
                )
                if let text = Self.searchableText(message), !text.isEmpty {
                    try db.execute(
                        sql: """
                            INSERT INTO transcript_fts
                            (serverId, profileId, sessionId, messageKey, wireId, ordinal, role, content)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [scope.serverId, scope.profileId, identity.sessionId,
                                    wireId.map(String.init) ?? "o:\(ordinal)", wireId,
                                    ordinal, message.role, text]
                    )
                }
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

    /// Compatibility entry point for scoped offline-search callers. The
    /// canonical write remains identity-qualified.
    func saveTranscript(
        sessionId: String, messages: [StoredMessage], scope: CacheScope
    ) throws {
        let identity = CacheIdentity(
            serverId: scope.serverId,
            profileId: scope.profileId,
            sessionId: sessionId
        )
        try saveTranscript(identity: identity, messages: messages, scope: scope)
    }

    /// Append rows while preserving their scoped ordinal identity. The read and
    /// replacement execute as one actor operation; `saveTranscript` performs the
    /// actual cache + FTS replacement atomically in its database transaction.
    func appendTranscript(
        sessionId: String, messages: [StoredMessage], scope: CacheScope
    ) throws {
        let existing = try loadTranscript(scope: scope, sessionId: sessionId) ?? []
        try saveTranscript(sessionId: sessionId, messages: existing + messages, scope: scope)
    }

    /// Scope-safe local search. FTS syntax is never accepted from callers: the
    /// quoted phrase treats punctuation as text and prevents malformed MATCH.
    func searchTranscript(
        query: String, scope: CacheScope, roles: [String] = [], limit: Int = 50
    ) throws -> OfflineSearchPage {
        try db.read { db in
            let terms = query.split(whereSeparator: { $0.isWhitespace })
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
            guard !terms.isEmpty else { return OfflineSearchPage(hits: [], partial: false) }
            var sql = """
                SELECT serverId, profileId, sessionId, wireId, ordinal, role,
                       snippet(transcript_fts, 7, '<b>', '</b>', '…', 18) AS snippet
                FROM transcript_fts
                WHERE transcript_fts MATCH ? AND serverId = ? AND profileId = ?
                """
            var arguments: StatementArguments = [terms, scope.serverId, scope.profileId]
            if !roles.isEmpty {
                sql += " AND role IN (\(Array(repeating: "?", count: roles.count).joined(separator: ",")))"
                arguments += StatementArguments(roles)
            }
            sql += " ORDER BY rowid LIMIT ?"
            arguments += [limit]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            let hits = rows.map { row in
                OfflineSearchHit(
                    scope: scope, sessionId: row["sessionId"], wireId: row["wireId"],
                    ordinal: row["ordinal"], role: row["role"], snippet: row["snippet"]
                )
            }
            let progress = try Row.fetchOne(
                db,
                sql: "SELECT complete FROM offline_search_backfill WHERE serverId = ? AND profileId = ?",
                arguments: [scope.serverId, scope.profileId]
            )
            return OfflineSearchPage(hits: hits, partial: (progress?["complete"] as Bool?) != true)
        }
    }

    /// Index at most `batchSize` legacy cached rows for one scope. Callers run
    /// this from an unstructured startup task, so opening the database and first
    /// paint never wait for a full historical scan. Progress commits with each
    /// batch and therefore resumes after termination.
    @discardableResult
    func backfillSearchIndex(scope: CacheScope, batchSize: Int = 100) throws -> Bool {
        try db.write { db in
            let progress = try Row.fetchOne(
                db, sql: "SELECT lastRowId, complete FROM offline_search_backfill WHERE serverId=? AND profileId=?",
                arguments: [scope.serverId, scope.profileId]
            )
            if (progress?["complete"] as Bool?) == true { return true }
            let lastRowId: Int64 = progress?["lastRowId"] ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.rowid AS sourceRowId, m.sessionId, m.ordinal, m.wireId, m.role,
                       m.timestamp, m.rowJSON
                FROM message_row_cache m JOIN session_cache s ON s.id=m.sessionId
                WHERE s.serverId=? AND s.profileId=? AND m.rowid>? ORDER BY m.rowid LIMIT ?
                """, arguments: [scope.serverId, scope.profileId, lastRowId, batchSize])
            var highWater = lastRowId
            for row in rows {
                let sourceRowId: Int64 = row["sourceRowId"]
                highWater = max(highWater, sourceRowId)
                let data: Data = row["rowJSON"]
                let message = try JSONDecoder().decode(StoredMessageMirror.self, from: data).toStoredMessage()
                let sessionId: String = row["sessionId"]
                let ordinal: Int = row["ordinal"]
                let wireId: Int? = row["wireId"]
                try db.execute(sql: """
                    INSERT OR REPLACE INTO offline_message_cache
                    (serverId,profileId,sessionId,ordinal,wireId,role,timestamp,rowJSON)
                    VALUES (?,?,?,?,?,?,?,?)
                    """, arguments: [scope.serverId, scope.profileId, sessionId, ordinal,
                                      wireId, message.role, message.timestamp, data])
                if let text = Self.searchableText(message), !text.isEmpty {
                    // Skip rows the write-through path already indexed
                    // (saveTranscript inserts the FTS row as it caches the
                    // message): re-inserting would double every hit for a
                    // backfilled session. messageKey is the stable per-message
                    // identity both writers share (wireId, or "o:\<ordinal\>").
                    let messageKey = wireId.map(String.init) ?? "o:\(ordinal)"
                    try db.execute(sql: """
                        INSERT INTO transcript_fts
                        (serverId,profileId,sessionId,messageKey,wireId,ordinal,role,content)
                        SELECT ?,?,?,?,?,?,?,?
                        WHERE NOT EXISTS (
                            SELECT 1 FROM transcript_fts
                            WHERE serverId=? AND profileId=? AND sessionId=? AND messageKey=?
                        )
                        """, arguments: [scope.serverId, scope.profileId, sessionId,
                                          messageKey, wireId,
                                          ordinal, message.role, text,
                                          scope.serverId, scope.profileId, sessionId, messageKey])
                }
            }
            let complete = rows.count < batchSize
            try db.execute(sql: """
                INSERT INTO offline_search_backfill(serverId,profileId,lastRowId,complete)
                VALUES (?,?,?,?) ON CONFLICT(serverId,profileId) DO UPDATE SET
                lastRowId=excluded.lastRowId, complete=excluded.complete
                """, arguments: [scope.serverId, scope.profileId, highWater, complete])
            return complete
        }
    }

    /// Loads the exact scoped cached row selected by an offline hit.
    func loadTranscript(scope: CacheScope, sessionId: String) throws -> [StoredMessage]? {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT rowJSON FROM offline_message_cache
                    WHERE serverId = ? AND profileId = ? AND sessionId = ? ORDER BY ordinal
                    """,
                arguments: [scope.serverId, scope.profileId, sessionId]
            )
            guard !rows.isEmpty else { return nil }
            return try rows.map { row in
                let data: Data = row["rowJSON"]
                return try JSONDecoder().decode(StoredMessageMirror.self, from: data).toStoredMessage()
            }
        }
    }

    /// Explicit tombstone cleanup; FTS5 cannot participate in FK cascades.
    func removeSession(scope: CacheScope, sessionId: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM transcript_fts WHERE serverId=? AND profileId=? AND sessionId=?",
                           arguments: [scope.serverId, scope.profileId, sessionId])
            try db.execute(sql: "DELETE FROM offline_message_cache WHERE serverId=? AND profileId=? AND sessionId=?",
                           arguments: [scope.serverId, scope.profileId, sessionId])
            // Delete the scoped parent last. The canonical transcript rows use
            // its composite identity as a foreign key, so this removes legacy
            // message_row_cache rows through SQLite's cascade as well.
            try db.execute(sql: "DELETE FROM session_cache WHERE serverId=? AND profileId=? AND id=?",
                           arguments: [scope.serverId, scope.profileId, sessionId])
        }
    }

    /// Destructive primitive reserved for the future Forget Gateway flow.
    @discardableResult
    func purgeGateway(serverId: String) throws -> Int {
        try db.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_fts WHERE serverId=?", arguments: [serverId]) ?? 0
            try db.execute(sql: "DELETE FROM transcript_fts WHERE serverId=?", arguments: [serverId])
            for table in ["offline_message_cache", "offline_search_backfill", "session_cache"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE serverId=?", arguments: [serverId])
            }
            try db.execute(sql: "DELETE FROM last_opened_session WHERE serverId=?", arguments: [serverId])
            // Optional foundation tables are purged when present; this keeps the
            // primitive forward-compatible without creating speculative schema.
            for table in ["pending_attention_cache", "attention_reconciliation_meta", "attention_cache", "turn_cache", "head_cache", "cursor_cache", "last_opened_cache", "widget_source_state"] {
                if try db.tableExists(table) {
                    try db.execute(sql: "DELETE FROM \(table) WHERE serverId=?", arguments: [serverId])
                }
            }
            return count
        }
    }

    private static func searchableText(_ message: StoredMessage) -> String? {
        guard ["user", "assistant", "tool"].contains(message.role) else { return nil }
        func flatten(_ value: JSONValue) -> [String] {
            switch value {
            case .string(let value): return [value]
            case .array(let values): return values.flatMap(flatten)
            case .object(let value):
                // Only textual leaves are indexed; image/data URL payloads and
                // opaque binary fields are intentionally excluded.
                return value.filter { !["data", "image", "image_url", "audio"].contains($0.key.lowercased()) }
                    .flatMap { flatten($0.value) }
            default: return []
            }
        }
        return flatten(message.content).filter { !$0.hasPrefix("data:") }.joined(separator: "\n")
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
            let profile = Self.storedProfileId(for: summary, scope: scope)
            let identity = CacheIdentity(serverId: scope.serverId, profileId: profile, sessionId: summary.id)
            let existing = try Self.session(identity, in: db)
            let record = try SessionCacheRecord.make(
                from: summary,
                scope: CacheScope(serverId: identity.serverId, profileId: identity.profileId),
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
    func touchSession(_ identity: CacheIdentity) throws {
        try db.write { db in
            guard var record = try Self.session(identity, in: db) else {
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
    func markTranscriptDirty(_ identity: CacheIdentity) throws {
        try db.write { db in
            guard var record = try Self.session(identity, in: db) else {
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

            // Clear transcript cursor fields on evicted sessions
            for var record in stale {
                try MessageRowRecord
                    .filter(Column("serverId") == record.serverId)
                    .filter(Column("profileId") == record.profileId)
                    .filter(Column("sessionId") == record.id)
                    .deleteAll(db)
                record.transcriptCachedAt = nil
                record.maxMessageId = nil
                try record.save(db)
            }

            return stale.count
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
    func maxMessageId(for identity: CacheIdentity) throws -> Int? {
        try db.read { db in
            try Self.session(identity, in: db)?.maxMessageId
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
    func deltaCursor(for identity: CacheIdentity) throws -> (afterId: Int, prefixCount: Int)? {
        try db.read { db in
            guard let record = try Self.session(identity, in: db),
                  let afterId = record.maxMessageId else { return nil }
            let prefixCount = try MessageRowRecord
                .filter(Column("serverId") == identity.serverId)
                .filter(Column("profileId") == identity.profileId)
                .filter(Column("sessionId") == identity.sessionId)
                .filter(Column("wireId") != nil)
                .fetchCount(db)
            return (afterId, prefixCount)
        }
    }

    #if DEBUG
    /// TEST-ONLY: persist a session row stamped with an EXACT `profileId`,
    /// bypassing the `storedProfileId` normalization, so the read-side tolerance
    /// for legacy rows mis-stamped with the literal "all" (A1(iii)) can be
    /// exercised deterministically. Never used outside tests.
    func _writeRawSessionRowForTesting(
        _ summary: SessionSummary, serverId: String, profileId: String
    ) throws {
        try db.write { db in
            let record = try SessionCacheRecord.make(
                from: summary,
                scope: CacheScope(serverId: serverId, profileId: profileId)
            )
            try record.save(db)
        }
    }
    #endif

    /// The concrete profile a row must be STORED under, given a summary and the
    /// active write scope. `all` is only ever a query selector, never a stored
    /// value (CONTRACT-OFFLINE-CACHE identity invariant): a blank/absent summary
    /// profile collapses to the scope's own profile, or `default` when the scope
    /// itself is the aggregate key. Shared by every session-list write path so
    /// the stored profileId can never drift between them.
    static func storedProfileId(for summary: SessionSummary, scope: CacheScope) -> String {
        let profile = summary.profile?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A real session profile is never the aggregate sentinel — reject a
        // literal "all" here too so no write path can stamp the selector onto a row.
        if let profile, !profile.isEmpty, profile != CacheScope.allProfilesKey { return profile }
        return scope.profileId == CacheScope.allProfilesKey ? "default" : scope.profileId
    }

    private static func session(_ identity: CacheIdentity, in db: Database) throws -> SessionCacheRecord? {
        try SessionCacheRecord
            .filter(Column("serverId") == identity.serverId)
            .filter(Column("profileId") == identity.profileId)
            .filter(Column("id") == identity.sessionId)
            .fetchOne(db)
    }

    // MARK: - Projects (cache-first Projects tab, CacheSchema v6)

    /// Load the cached projects overview for `scope`, in the server's list order
    /// (`orderIndex`). Empty when nothing has been persisted for this partition.
    func loadProjects(scope: CacheScope) throws -> [Project] {
        try db.read { db in
            let records = try ProjectCacheRecord
                .filter(Column("serverId") == scope.serverId)
                .filter(Column("profileId") == scope.profileId)
                .order(Column("orderIndex"))
                .fetchAll(db)
            return records.map {
                Project(id: $0.id, label: $0.label, root: $0.root, sessionCount: $0.sessionCount)
            }
        }
    }

    /// Replace the persisted projects overview for `scope` with `projects`
    /// (full-list write-through). The delete-then-insert runs in one transaction
    /// so a reader never observes a partial list, and stale projects (deleted
    /// server-side) never linger.
    func saveProjects(_ projects: [Project], scope: CacheScope) throws {
        let now = Date().timeIntervalSince1970
        try db.write { db in
            try ProjectCacheRecord
                .filter(Column("serverId") == scope.serverId)
                .filter(Column("profileId") == scope.profileId)
                .deleteAll(db)
            for (index, project) in projects.enumerated() {
                try ProjectCacheRecord(
                    serverId: scope.serverId,
                    profileId: scope.profileId,
                    id: project.id,
                    label: project.label,
                    root: project.root,
                    sessionCount: project.sessionCount,
                    orderIndex: index,
                    updatedAt: now
                ).insert(db)
            }
        }
    }

    /// Load the cached detail session snapshot for one project, or `nil` when no
    /// snapshot has been persisted for this (scope, projectId).
    func loadProjectSessions(scope: CacheScope, projectId: String) throws -> [SessionSummary]? {
        try db.read { db in
            guard let record = try ProjectSessionCacheRecord
                .filter(Column("serverId") == scope.serverId)
                .filter(Column("profileId") == scope.profileId)
                .filter(Column("projectId") == projectId)
                .fetchOne(db)
            else { return nil }
            return try? JSONDecoder().decode([SessionSummary].self, from: record.sessionsJSON)
        }
    }

    /// Persist (upsert) a project's detail session snapshot for (scope, projectId).
    func saveProjectSessions(
        _ sessions: [SessionSummary], scope: CacheScope, projectId: String
    ) throws {
        let data = try JSONEncoder().encode(sessions)
        try db.write { db in
            try ProjectSessionCacheRecord(
                serverId: scope.serverId,
                profileId: scope.profileId,
                projectId: projectId,
                sessionsJSON: data,
                updatedAt: Date().timeIntervalSince1970
            ).save(db)
        }
    }
}
