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

    struct ManifestCommitPayload: Codable {
        let revision: Int64
        let cursor: String
        let sessions: [SessionSummary]
        let attention: [ManifestAttentionItem]
        let activeTurns: [ManifestActiveTurn]
        let transcriptHeads: [String: Int]
        let capabilities: Set<String>
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
            var request = SessionCacheRecord
                .filter(Column("serverId") == scope.serverId)
            if scope.profileId == CacheScope.allProfilesKey {
                request = request.filter(Column("profileId") != CacheScope.legacy.profileId)
            } else {
                request = request.filter(Column("profileId") == scope.profileId)
            }
            let records = try request.order(Column("lastActive").desc).fetchAll(db)
            return try records.map { try $0.decodeSummary() }
        }
    }

    /// Reads the last indivisible manifest snapshot. Session rows and metadata
    /// are read in the same SQLite snapshot, so no consumer can observe mixed
    /// revisions after relaunch.
    func loadManifestProjection(scope: CacheScope) throws -> ManifestProjection {
        try db.read { db in
            let rows = try SessionCacheRecord
                .filter(Column("serverId") == scope.serverId)
                .filter(Column("profileId") == scope.profileId)
                .order(Column("lastActive").desc)
                .fetchAll(db)
            let legacySessions = try rows.map { try $0.decodeSummary() }
            guard let raw = try SyncMetaRecord.fetchOne(db, key: SyncMetaRecord.Key.manifest(scope))?.value,
                  let data = raw.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ManifestCommitPayload.self, from: data) else {
                return ManifestProjection(revision: 0, cursor: nil, sessions: legacySessions, attention: [], activeTurns: [], transcriptHeads: [:], capabilities: [], freshness: .cached)
            }
            return ManifestProjection(revision: payload.revision, cursor: payload.cursor, sessions: payload.sessions, attention: payload.attention, activeTurns: payload.activeTurns, transcriptHeads: payload.transcriptHeads, capabilities: payload.capabilities, freshness: .cached)
        }
    }

    /// Applies the fully validated chain in one GRDB transaction. Tombstones
    /// are unconditional on disk; survivor policy belongs to the in-memory
    /// working-set overlay and can never repersist a removed row.
    func applyManifest(_ chain: ManifestChain, scope: CacheScope) throws -> ManifestProjection {
        try db.write { db in
            if let oldRaw = try SyncMetaRecord.fetchOne(db, key: SyncMetaRecord.Key.manifest(scope))?.value,
               let data = oldRaw.data(using: .utf8),
               let old = try? JSONDecoder().decode(ManifestCommitPayload.self, from: data),
               chain.revision <= old.revision {
                let rows = try SessionCacheRecord.filter(Column("serverId") == scope.serverId).filter(Column("profileId") == scope.profileId).order(Column("lastActive").desc).fetchAll(db)
                return ManifestProjection(revision: old.revision, cursor: old.cursor, sessions: old.sessions, attention: old.attention, activeTurns: old.activeTurns, transcriptHeads: old.transcriptHeads, capabilities: old.capabilities, freshness: .fresh)
            }

            for id in chain.tombstones {
                try SessionCacheRecord
                    .filter(Column("id") == id)
                    .filter(Column("serverId") == scope.serverId)
                    .filter(Column("profileId") == scope.profileId)
                    .deleteAll(db)
            }
            for summary in chain.sessions where !chain.tombstones.contains(summary.id) {
                let existing = try SessionCacheRecord.fetchOne(db, key: summary.id)
                // The legacy cache table's id-only PK predates scoped manifests.
                // Keep another profile's same-id row untouched; the authoritative
                // scoped session array is persisted in the manifest payload below.
                if let existing, (existing.serverId != scope.serverId || existing.profileId != scope.profileId) { continue }
                let record = try SessionCacheRecord.make(from: summary, scope: scope, isPinned: existing?.isPinned ?? false, lastAccessedAt: existing?.lastAccessedAt ?? 0, transcriptCachedAt: existing?.transcriptCachedAt, maxMessageId: existing?.maxMessageId)
                try record.save(db)
            }
            let previous: [SessionSummary]
            if chain.reset { previous = [] }
            else if let raw = try SyncMetaRecord.fetchOne(db, key: SyncMetaRecord.Key.manifest(scope))?.value,
                    let data = raw.data(using: .utf8), let old = try? JSONDecoder().decode(ManifestCommitPayload.self, from: data) { previous = old.sessions }
            else { previous = (try? SessionCacheRecord.filter(Column("serverId") == scope.serverId).filter(Column("profileId") == scope.profileId).fetchAll(db).map { try $0.decodeSummary() }) ?? [] }
            var byID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            for id in chain.tombstones { byID.removeValue(forKey: id) }
            for session in chain.sessions where !chain.tombstones.contains(session.id) { byID[session.id] = session }
            let projectedSessions = byID.values.sorted { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }
            let payload = ManifestCommitPayload(revision: chain.revision, cursor: chain.cursor, sessions: projectedSessions, attention: chain.attention, activeTurns: chain.activeTurns, transcriptHeads: chain.transcriptHeads, capabilities: chain.capabilities)
            let encoded = try JSONEncoder().encode(payload)
            try SyncMetaRecord(key: SyncMetaRecord.Key.manifest(scope), value: String(decoding: encoded, as: UTF8.self)).save(db)
            let rows = try SessionCacheRecord.filter(Column("serverId") == scope.serverId).filter(Column("profileId") == scope.profileId).order(Column("lastActive").desc).fetchAll(db)
            return ManifestProjection(revision: chain.revision, cursor: chain.cursor, sessions: projectedSessions, attention: chain.attention, activeTurns: chain.activeTurns, transcriptHeads: chain.transcriptHeads, capabilities: chain.capabilities, freshness: .fresh)
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
                let profile = summary.profile?.trimmingCharacters(in: .whitespacesAndNewlines)
                let actualProfile = (profile?.isEmpty == false) ? profile! : (scope.profileId == CacheScope.allProfilesKey ? "default" : scope.profileId)
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
                arguments: [scope.serverId, scope.profileId, sessionId]
            )
            try db.execute(
                sql: "DELETE FROM offline_message_cache WHERE serverId = ? AND profileId = ? AND sessionId = ?",
                arguments: [scope.serverId, scope.profileId, sessionId]
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
                    arguments: [scope.serverId, scope.profileId, sessionId, ordinal,
                                wireId, row.role, row.timestamp, row.rowJSON]
                )
                if let text = Self.searchableText(message), !text.isEmpty {
                    try db.execute(
                        sql: """
                            INSERT INTO transcript_fts
                            (serverId, profileId, sessionId, messageKey, wireId, ordinal, role, content)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [scope.serverId, scope.profileId, sessionId,
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
                    try db.execute(sql: """
                        INSERT INTO transcript_fts
                        (serverId,profileId,sessionId,messageKey,wireId,ordinal,role,content)
                        VALUES (?,?,?,?,?,?,?,?)
                        """, arguments: [scope.serverId, scope.profileId, sessionId,
                                          wireId.map(String.init) ?? "o:\(ordinal)", wireId,
                                          ordinal, message.role, text])
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
            // Optional foundation tables are purged when present; this keeps the
            // primitive forward-compatible without creating speculative schema.
            for table in ["attention_cache", "turn_cache", "head_cache", "cursor_cache", "last_opened_cache", "widget_source_state"] {
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
            let profile = summary.profile ?? (scope.profileId == CacheScope.allProfilesKey ? "default" : scope.profileId)
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

    private static func session(_ identity: CacheIdentity, in db: Database) throws -> SessionCacheRecord? {
        try SessionCacheRecord
            .filter(Column("serverId") == identity.serverId)
            .filter(Column("profileId") == identity.profileId)
            .filter(Column("id") == identity.sessionId)
            .fetchOne(db)
    }
}
