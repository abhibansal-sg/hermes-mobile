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
//   - Future migrations are ADDITIVE (ALTER TABLE ADD COLUMN, new indexes, FTS5)
//   - Drop-and-rebuild escape hatch: if `schemaVersion` in sync_meta no longer
//     matches the expected fingerprint, wipe and re-open. The cache is 100%
//     reconstructible from the gateway so this is always safe.

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
    static let currentFingerprint = "v2"

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

        return migrator
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
