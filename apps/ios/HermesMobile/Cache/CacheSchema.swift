import Foundation
import GRDB

// MARK: - CacheSchema
//
// DatabaseMigrator with numbered, append-only migrations applied idempotently at
// open. Each migration is safe to re-run (GRDB tracks applied migrations in the
// `grdb_migrations` system table). See CONTRACT-OFFLINE-CACHE.md §2.4.
//
// Migration policy:
//   - v1: create all three tables + four indexes (first ship)
//   - Recognized versions migrate transactionally; v3 uses verified shadow tables.
//   - v4 concretizes the reserved pending-attention table + scoped cursor metadata.

enum CacheSchema {

    // MARK: - Fingerprint

    /// Increment this when a migration that doesn't fit the additive pattern would
    /// normally be needed — instead the schema is nuked and rebuilt from v1.
    ///
    /// "v2": adds the composite (serverId, profileId) scope columns + index to
    /// `session_cache` (P4 per-(server, profile) scoping). The v2 ALTER is the
    /// normal GRDB path on a live DB; the fingerprint bump means any DB so old
    /// it cannot ALTER cleanly takes the nuke-and-rebuild escape hatch instead —
    /// always safe (the cache is 100% reconstructible from the gateway).
    static let currentFingerprint = "v5"

    // MARK: - Migrator

    /// The full migrator (v1 + v2 + future). Renamed from `makeV1Migrator` now
    /// that it carries more than one migration; the old name is kept as a thin
    /// alias so frozen call sites compile.
    static func makeV1Migrator() -> DatabaseMigrator { makeMigrator() }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // In tests / CI we allow erasing the DB so migration failures don't
        // block the test suite. Production builds keep it false (the default).
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif

        migrator.registerMigration("v1") { db in
            // session_cache: one row per session (raw, cron included)
            try db.create(table: SessionCacheRecord.databaseTableName, ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("summaryJSON", .blob).notNull()
                t.column("lastActive", .double)
                t.column("messageCount", .integer)
                t.column("source", .text)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("lastAccessedAt", .double).notNull().defaults(to: 0)
                t.column("transcriptCachedAt", .double)
                t.column("maxMessageId", .integer)
            }

            // message_row_cache: one row per StoredMessage (human sessions only)
            try db.create(table: MessageRowRecord.databaseTableName, ifNotExists: true) { t in
                t.column("sessionId", .text).notNull()
                    .references(SessionCacheRecord.databaseTableName,
                                onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("wireId", .integer)
                t.column("role", .text).notNull()
                t.column("timestamp", .double)
                t.column("rowJSON", .blob).notNull()
                t.primaryKey(["sessionId", "ordinal"])
            }

            // sync_meta: singleton-ish KV for bookkeeping
            try db.create(table: SyncMetaRecord.databaseTableName, ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            // Indexes per §2.3
            // session_cache(lastActive) — recency sort + eviction range scan
            try db.create(
                index: "session_cache_lastActive",
                on: SessionCacheRecord.databaseTableName,
                columns: ["lastActive"],
                ifNotExists: true
            )
            // session_cache(isPinned) — pinned exemption in eviction
            try db.create(
                index: "session_cache_isPinned",
                on: SessionCacheRecord.databaseTableName,
                columns: ["isPinned"],
                ifNotExists: true
            )
            // message_row_cache(sessionId, ordinal) — transcript load (hot read)
            try db.create(
                index: "message_row_cache_sessionId_ordinal",
                on: MessageRowRecord.databaseTableName,
                columns: ["sessionId", "ordinal"],
                ifNotExists: true
            )
            // message_row_cache(sessionId, wireId) — cursor / append-merge
            try db.create(
                index: "message_row_cache_sessionId_wireId",
                on: MessageRowRecord.databaseTableName,
                columns: ["sessionId", "wireId"],
                ifNotExists: true
            )

            // Stamp the schema fingerprint (v1; the v2 migration restamps it).
            let meta = SyncMetaRecord(key: SyncMetaRecord.Key.schemaVersion,
                                      value: "v1")
            try meta.save(db)
        }

        // v2 — composite (serverId, profileId) scope on session_cache (P4).
        // Append-only + idempotent (GRDB tracks applied migrations in
        // grdb_migrations). message_row_cache is UNCHANGED: a message row's scope
        // is inherited via its FK (sessionId → session_cache.id), and message
        // rows are reachable ONLY through a scoped session row, so they need no
        // own scope columns. Existing v1 rows are backfilled to the legacy
        // sentinel scope (they predate scope and can't be attributed to a real
        // server/profile) — a sentinel-scoped row matches no live scope, so it is
        // inert until the next scoped write overwrites it from the network.
        migrator.registerMigration("v2") { db in
            let legacy = CacheScope.legacy
            try db.alter(table: SessionCacheRecord.databaseTableName) { t in
                // NOT NULL with a default so the ALTER backfills every existing
                // v1 row in one statement (SQLite cannot add a bare NOT NULL
                // column without a default).
                t.add(column: "serverId", .text).notNull().defaults(to: legacy.serverId)
                t.add(column: "profileId", .text).notNull().defaults(to: legacy.profileId)
            }

            // Composite index for the scoped recency read/sort:
            // WHERE serverId = ? AND profileId = ? ORDER BY lastActive DESC.
            try db.create(
                index: "session_cache_scope_lastActive",
                on: SessionCacheRecord.databaseTableName,
                columns: ["serverId", "profileId", "lastActive"],
                ifNotExists: true
            )

            // Re-stamp the fingerprint to v2.
            let meta = SyncMetaRecord(key: SyncMetaRecord.Key.schemaVersion,
                                      value: CacheSchema.currentFingerprint)
            try meta.save(db)
        }

        // ABH-460 — scope-safe transcript mirror + FTS5.  The mirror deliberately
        // owns its complete identity instead of inheriting the legacy global
        // session id, so equal session ids in two profiles remain distinct.
        migrator.registerMigration("v3-offline-search") { db in
            try db.create(table: "offline_message_cache", ifNotExists: true) { t in
                t.column("serverId", .text).notNull()
                t.column("profileId", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("ordinal", .integer).notNull()
                t.column("wireId", .integer)
                t.column("role", .text).notNull()
                t.column("timestamp", .double)
                t.column("rowJSON", .blob).notNull()
                t.primaryKey(["serverId", "profileId", "sessionId", "ordinal"])
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
                    serverId UNINDEXED, profileId UNINDEXED, sessionId UNINDEXED,
                    messageKey UNINDEXED, wireId UNINDEXED, ordinal UNINDEXED,
                    role UNINDEXED, content, tokenize='unicode61 remove_diacritics 2'
                )
                """)
            try db.create(table: "offline_search_backfill", ifNotExists: true) { t in
                t.column("serverId", .text).notNull()
                t.column("profileId", .text).notNull()
                t.column("lastRowId", .integer).notNull().defaults(to: 0)
                t.column("complete", .boolean).notNull().defaults(to: false)
                t.primaryKey(["serverId", "profileId"])
            }
        }

        // v3 makes scope part of identity. Shadow tables keep recognized v2
        // databases paintable throughout the transaction and permit complete
        // count/FK validation before the atomic rename.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try db.create(table: "session_cache_v3") { t in
                t.column("serverId", .text).notNull(); t.column("profileId", .text).notNull()
                t.column("id", .text).notNull(); t.column("summaryJSON", .blob).notNull()
                t.column("lastActive", .double); t.column("messageCount", .integer); t.column("source", .text)
                t.column("archived", .boolean).notNull().defaults(to: false); t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("lastAccessedAt", .double).notNull().defaults(to: 0); t.column("transcriptCachedAt", .double); t.column("maxMessageId", .integer)
                t.primaryKey(["serverId", "profileId", "id"])
            }
            try db.create(table: "message_row_cache_v3") { t in
                t.column("serverId", .text).notNull(); t.column("profileId", .text).notNull(); t.column("sessionId", .text).notNull(); t.column("ordinal", .integer).notNull()
                t.column("wireId", .integer); t.column("role", .text).notNull(); t.column("timestamp", .double); t.column("rowJSON", .blob).notNull()
                t.primaryKey(["serverId", "profileId", "sessionId", "ordinal"])
                t.foreignKey(["serverId", "profileId", "sessionId"], references: "session_cache_v3", columns: ["serverId", "profileId", "id"], onDelete: .cascade)
            }
            try db.execute(sql: "INSERT INTO session_cache_v3 SELECT serverId,profileId,id,summaryJSON,lastActive,messageCount,source,archived,isPinned,lastAccessedAt,transcriptCachedAt,maxMessageId FROM session_cache")
            try db.execute(sql: "INSERT INTO message_row_cache_v3 SELECT s.serverId,s.profileId,m.sessionId,m.ordinal,m.wireId,m.role,m.timestamp,m.rowJSON FROM message_row_cache m JOIN session_cache s ON s.id=m.sessionId")
            let oldSessions = try Int.fetchOne(db, sql: "SELECT count(*) FROM session_cache") ?? 0
            let newSessions = try Int.fetchOne(db, sql: "SELECT count(*) FROM session_cache_v3") ?? 0
            let oldMessages = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_row_cache") ?? 0
            let newMessages = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_row_cache_v3") ?? 0
            guard oldSessions == newSessions, oldMessages == newMessages else { throw DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "v3 shadow-copy count mismatch") }
            try db.drop(table: "message_row_cache"); try db.drop(table: "session_cache")
            try db.rename(table: "session_cache_v3", to: "session_cache"); try db.rename(table: "message_row_cache_v3", to: "message_row_cache")
            try db.create(index: "session_cache_scope_lastActive", on: "session_cache", columns: ["serverId", "profileId", "lastActive"])
            try db.create(index: "message_row_cache_identity_wireId", on: "message_row_cache", columns: ["serverId", "profileId", "sessionId", "wireId"])
            try db.create(table: "manifest_scope_state") { t in
                t.column("serverId", .text).notNull(); t.column("manifestScope", .text).notNull(); t.column("revision", .text); t.column("finalCursor", .text); t.column("capabilitiesVersion", .text); t.column("serverTime", .double); t.column("localFetchedTime", .double); t.column("widgetJSON", .blob); t.column("deviceRegistrationState", .blob); t.primaryKey(["serverId", "manifestScope"])
            }
            for (name, tail) in [("pending_attention_cache", "id TEXT NOT NULL, PRIMARY KEY(serverId,profileId,id)"), ("active_turn_cache", "sessionId TEXT NOT NULL, PRIMARY KEY(serverId,profileId,sessionId)"), ("transcript_head_cache", "sessionId TEXT NOT NULL, PRIMARY KEY(serverId,profileId,sessionId)")] {
                try db.execute(sql: "CREATE TABLE \(name) (serverId TEXT NOT NULL, profileId TEXT NOT NULL, \(tail))")
            }
            try db.execute(sql: "CREATE TABLE last_opened_session (serverId TEXT NOT NULL, manifestScope TEXT NOT NULL, profileId TEXT NOT NULL, sessionId TEXT NOT NULL, PRIMARY KEY(serverId,manifestScope))")
            // Some SQLite builds (notably Apple's system SQLite, which GRDB links
            // on-device) do NOT rewrite a child table's foreign-key reference when
            // its parent is renamed. After the `session_cache_v3 -> session_cache`
            // rename above, the transcript FK can therefore still point at the
            // now-removed `session_cache_v3`, and `foreign_key_check` reports every
            // transcript row as a violation — so a POPULATED database (real chats)
            // throws here and this migration rolls back on every launch, stranding
            // the DB one step short and leaving `CacheStore()` unbuildable. Fold the
            // FK repair in BEFORE verifying so the chain advances past v3 without
            // data loss. This is a no-op on builds that did rewrite the reference
            // (and on the empty-table fresh-install path, where the FK never binds).
            try repairTranscriptForeignKeyIfNeeded(db)
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            guard violations.isEmpty else { throw DatabaseError(resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY, message: "v3 foreign-key verification failed") }
            try SyncMetaRecord(key: SyncMetaRecord.Key.schemaVersion, value: currentFingerprint).save(db)
        }

        // v4 — make the Phase-1 reserved attention identity table concrete for
        // the Phase-0 killed-app Inbox. The row contains display-safe JSON only;
        // cursor/instance metadata is scope-qualified and commits in the same
        // transaction as every delta.
        migrator.registerMigration("v4-pending-attention") { db in
            try db.alter(table: "pending_attention_cache") { t in
                t.add(column: "requestId", .text).notNull().defaults(to: "")
                t.add(column: "sessionId", .text).notNull().defaults(to: "")
                t.add(column: "storedSessionId", .text)
                t.add(column: "kind", .text).notNull().defaults(to: "approval")
                t.add(column: "payloadJSON", .blob).notNull().defaults(to: Data("{}".utf8))
                t.add(column: "createdAt", .double).notNull().defaults(to: 0)
                t.add(column: "expiresAt", .double)
                t.add(column: "state", .text).notNull().defaults(to: AttentionLifecycle.pending.rawValue)
                t.add(column: "revision", .integer).notNull().defaults(to: 0)
                t.add(column: "updatedAt", .double).notNull().defaults(to: 0)
            }
            try db.create(
                index: "pending_attention_scope_state",
                on: "pending_attention_cache",
                columns: ["serverId", "profileId", "state"],
                ifNotExists: true
            )
            try db.create(table: "attention_reconciliation_meta", ifNotExists: true) { t in
                t.column("serverId", .text).notNull()
                t.column("profileId", .text).notNull()
                t.column("serverInstanceId", .text).notNull()
                t.column("cursor", .text).notNull()
                t.column("revision", .integer).notNull()
                t.column("updatedAt", .double).notNull()
                t.primaryKey(["serverId", "profileId"])
            }
            try SyncMetaRecord(key: SyncMetaRecord.Key.schemaVersion, value: currentFingerprint).save(db)
        }

        // v5 — repair the transcript FK after the v3 shadow-table rename. Some
        // SQLite builds preserve the temporary parent name in the child schema,
        // leaving deletes pointed at the removed `session_cache_v3` table.
        migrator.registerMigration("v5-cache-seams") { db in
            // Repairs devices that recorded v3 with a still-dangling transcript FK
            // (the empty-table fresh-install path: v3's `foreign_key_check` found no
            // rows to flag, so v3 committed even though the reference points at the
            // removed `session_cache_v3`). Those devices never re-run v3, so the
            // repair must live in this later migration too. Shares the exact repair
            // used inside v3 so the two paths can never diverge.
            try repairTranscriptForeignKeyIfNeeded(db)
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            guard violations.isEmpty else {
                throw DatabaseError(
                    resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY,
                    message: "v5 foreign-key verification failed"
                )
            }
            try SyncMetaRecord(
                key: SyncMetaRecord.Key.schemaVersion,
                value: currentFingerprint
            ).save(db)
        }

        return migrator
    }

    // MARK: - Transcript foreign-key repair (shared by v3 + v5)

    /// Rebuild `message_row_cache` with a correct composite foreign key to
    /// `session_cache` IF its stored schema still references the transient
    /// `session_cache_v3` parent produced during the v3 shadow-table swap.
    ///
    /// Root cause: SQLite builds that do not rewrite child foreign-key references
    /// on `ALTER TABLE ... RENAME` (Apple's system SQLite among them) leave the
    /// transcript FK pointing at the dropped `session_cache_v3`. `foreign_key_check`
    /// then flags every transcript row, so v3 threw and rolled back forever on any
    /// populated database.
    ///
    /// The repair is data-preserving: it copies every row into a fresh table that
    /// carries the correct FK, asserts the row count is identical, then atomically
    /// swaps it in. Renaming the CHILD table never disturbs its own FK's parent
    /// reference (`session_cache`, which exists), so the swap cannot re-introduce a
    /// dangling reference. It is a no-op — and cheap — when the FK is already
    /// correct (the common healthy path). Returns true iff a rebuild was performed.
    @discardableResult
    static func repairTranscriptForeignKeyIfNeeded(_ db: Database) throws -> Bool {
        // No transcript table yet (should not happen post-v3) ⇒ nothing to repair.
        guard try db.tableExists(MessageRowRecord.databaseTableName) else { return false }
        let parents = try String.fetchAll(
            db,
            sql: "SELECT \"table\" FROM pragma_foreign_key_list('message_row_cache')"
        )
        // Already references the real parent (and only it) ⇒ healthy, no rebuild.
        guard Set(parents) != [SessionCacheRecord.databaseTableName] else { return false }

        try db.create(table: "message_row_cache_fkfix") { t in
            t.column("serverId", .text).notNull()
            t.column("profileId", .text).notNull()
            t.column("sessionId", .text).notNull()
            t.column("ordinal", .integer).notNull()
            t.column("wireId", .integer)
            t.column("role", .text).notNull()
            t.column("timestamp", .double)
            t.column("rowJSON", .blob).notNull()
            t.primaryKey(["serverId", "profileId", "sessionId", "ordinal"])
            t.foreignKey(
                ["serverId", "profileId", "sessionId"],
                references: SessionCacheRecord.databaseTableName,
                columns: ["serverId", "profileId", "id"],
                onDelete: .cascade
            )
        }
        try db.execute(sql: """
            INSERT INTO message_row_cache_fkfix
            SELECT serverId,profileId,sessionId,ordinal,wireId,role,timestamp,rowJSON
            FROM message_row_cache
            """)
        let before = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_row_cache") ?? 0
        let after = try Int.fetchOne(db, sql: "SELECT count(*) FROM message_row_cache_fkfix") ?? 0
        guard before == after else {
            throw DatabaseError(
                resultCode: .SQLITE_CONSTRAINT,
                message: "transcript FK repair count mismatch (\(before) != \(after))"
            )
        }
        try db.drop(table: "message_row_cache")
        try db.rename(table: "message_row_cache_fkfix", to: "message_row_cache")
        // The transcript-cursor index rides on the table it indexes, so the drop
        // above removed it; recreate it on the rebuilt table.
        try db.create(
            index: "message_row_cache_identity_wireId",
            on: "message_row_cache",
            columns: ["serverId", "profileId", "sessionId", "wireId"],
            ifNotExists: true
        )
        return true
    }

    // MARK: - Resilient migrate (defense in depth)

    /// Run the full migration chain, NEVER erasing the database on failure. The
    /// offline cache holds the owner's real chats and is only reconstructible from
    /// a live gateway they may not currently be able to reach, so wiping is not an
    /// acceptable recovery — `eraseDatabaseOnSchemaChange` stays false everywhere.
    ///
    /// If the chain throws, attempt the one known in-place, data-preserving repair
    /// (the dangling transcript FK left by the v3 shadow rename) and retry the
    /// chain EXACTLY once. If it still fails, the error is rethrown so the caller
    /// can surface a diagnostic — the database is left intact, untouched, and
    /// fully recoverable by a future build rather than silently destroyed.
    static func migrateResiliently(_ writer: some DatabaseWriter) throws {
        let migrator = makeMigrator()
        do {
            try migrator.migrate(writer)
            return
        } catch let firstError {
            // Bounded recovery: repair the transcript FK in place, then retry.
            do {
                try writer.write { db in
                    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                    try repairTranscriptForeignKeyIfNeeded(db)
                }
            } catch {
                // The repair itself failed — surface the ORIGINAL migration cause,
                // never wipe. A nil cache degrades to the network-only path.
                throw firstError
            }
            try migrator.migrate(writer)
        }
    }

    // MARK: - Drop-and-rebuild escape hatch

    /// Check the persisted schema fingerprint against the current one. If they
    /// don't match, delete the database file so it is recreated fresh on the
    /// next open. Returns true if a rebuild was triggered.
    @discardableResult
    static func nukeIfSchemaMismatch(at url: URL) -> Bool {
        // Try to open read-only to check the fingerprint
        guard let db = try? DatabaseQueue(path: url.path) else { return false }
        let persisted = try? db.read { db in
            try SyncMetaRecord.fetchOne(db, key: SyncMetaRecord.Key.schemaVersion)?.value
        }
        guard persisted == currentFingerprint else {
            // Fingerprint mismatch: delete all GRDB files so the next open rebuilds
            let fm = FileManager.default
            let paths = [url.path, url.path + "-shm", url.path + "-wal"]
            for path in paths { try? fm.removeItem(atPath: path) }
            return true
        }
        return false
    }
}
