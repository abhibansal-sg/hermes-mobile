import XCTest
import GRDB
@testable import HermesMobile

// MARK: - CacheMigrationV3RepairTests
//
// Regression coverage for the dead-offline-cache defect (WhatsApp recovery,
// wave1). The v3 shadow-table migration in CacheSchema copied session_cache /
// message_row_cache into `_v3` shadows, dropped the originals, and renamed the
// shadows back. On SQLite builds that do NOT rewrite a child table's foreign-key
// reference when its parent is renamed — Apple's system SQLite, which GRDB links
// on device and in the simulator — the transcript FK stayed pointed at the now
// removed `session_cache_v3`. `PRAGMA foreign_key_check` then flagged every
// transcript row, so v3 threw and rolled back on EVERY launch of any POPULATED
// database. The chain never reached the v5-cache-seams repair (v3 aborts the
// whole `migrate()` first), AppEnvironment's `try? CacheStore()` returned nil,
// and the offline drawer went empty ("Couldn't load conversation").
//
// These tests reproduce the stuck shape (migrations applied THROUGH
// v3-offline-search, with real rows in the pre-v3 table shapes) and assert the
// full chain now advances past v3 with every row preserved and a clean
// foreign_key_check — i.e. the owner's 1610 sessions survive the upgrade.

final class CacheMigrationV3RepairTests: XCTestCase {

    /// A build-116 phone did not start from an empty database: it reopened a
    /// populated, fully-migrated cache. Recreate that on-disk shape, close the
    /// queue (process boundary), open it as build 119, and prove a draft-born
    /// durable-id row can still be written and read alongside the old rows.
    func testBuild116PopulatedDeviceDBReopensAndAcceptsDraftBornWrite() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abh519-build116-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let scope = CacheScope(serverId: "https://device.example", profileId: "default")
        func identity(_ sessionID: String) -> CacheIdentity {
            CacheIdentity(
                serverId: scope.serverId, profileId: scope.profileId, sessionId: sessionID)
        }
        let oldID = "20260721_120000_build116"

        do {
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            try CacheSchema.makeMigrator().migrate(queue)
            let cache = try CacheStore(testDB: queue)
            let old = SessionSummary(
                id: oldID, title: "Existing device chat", preview: "before upgrade",
                startedAt: 1, messageCount: 1, source: nil, lastActive: 1, cwd: nil
            )
            try await cache.upsertSession(old, scope: scope)
            try await cache.saveTranscript(
                identity: identity(oldID),
                messages: [StoredMessage(role: "user", content: .string("before upgrade"))]
            )
        }

        let queue119 = try DatabaseQueue(path: url.path, configuration: config)
        try CacheSchema.migrateResiliently(queue119)
        let cache119 = try CacheStore(testDB: queue119)
        let newID = "20260722_140236_f61148"
        let draftBorn = SessionSummary(
            id: newID, title: "New device chat", preview: "after upgrade",
            startedAt: 2, messageCount: 1, source: nil, lastActive: 2, cwd: nil
        )
        try await cache119.upsertSession(draftBorn, scope: scope)
        try await cache119.saveTranscript(
            identity: identity(newID),
            messages: [StoredMessage(
                role: "user", content: .string("after upgrade"),
                clientMessageID: "cmid-device"
            )]
        )

        let oldRows = try await cache119.loadTranscript(identity(oldID))
        let newRows = try await cache119.loadTranscript(identity(newID))
        XCTAssertEqual(oldRows?.first?.text, "before upgrade")
        XCTAssertEqual(newRows?.first?.text, "after upgrade")
        XCTAssertEqual(newRows?.first?.clientMessageID, "cmid-device")
    }

    /// Build an in-memory database in the exact "stuck" shape: the migrator run
    /// only up to `v3-offline-search` (so v1 + v2 + the mirror migration are
    /// recorded but `v3` is not), then seeded with `sessions` session rows and
    /// `messagesPerSession` transcript rows each in the v1/v2 table shapes.
    private func makeStuckV3DB(
        sessions: Int, messagesPerSession: Int
    ) throws -> (queue: DatabaseQueue, sessionCount: Int, messageCount: Int) {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config) // in-memory
        // Advance ONLY through the transcript-mirror migration, stopping before v3.
        try CacheSchema.makeMigrator().migrate(queue, upTo: "v3-offline-search")

        let blob = Data("{}".utf8)
        try queue.write { db in
            for s in 0..<sessions {
                let sid = "session-\(s)"
                try db.execute(
                    sql: """
                        INSERT INTO session_cache
                        (id, summaryJSON, lastActive, messageCount, source,
                         archived, isPinned, lastAccessedAt, serverId, profileId)
                        VALUES (?, ?, ?, ?, ?, 0, 0, 0, ?, ?)
                        """,
                    arguments: [sid, blob, Double(1000 + s), messagesPerSession,
                                "human", "https://gw.example", "default"]
                )
                for o in 0..<messagesPerSession {
                    try db.execute(
                        sql: """
                            INSERT INTO message_row_cache
                            (sessionId, ordinal, wireId, role, timestamp, rowJSON)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [sid, o, o, (o % 2 == 0) ? "user" : "assistant",
                                    Double(o), blob]
                    )
                }
            }
        }
        return (queue, sessions, sessions * messagesPerSession)
    }

    /// The core regression: a populated v3-offline-search DB must migrate all the
    /// way through v5-cache-seams without throwing and without losing a single row.
    func testChainAdvancesPastV3OnPopulatedDBWithoutDataLoss() throws {
        let (queue, expectedSessions, expectedMessages) =
            try makeStuckV3DB(sessions: 7, messagesPerSession: 11)

        // On the buggy build this threw at v3's foreign_key_check. It must now run
        // the full chain (v3 -> v4-pending-attention -> v5-cache-seams) to the end.
        XCTAssertNoThrow(try CacheSchema.makeMigrator().migrate(queue))

        try queue.read { db in
            // Every migration recorded, including the latest.
            let applied = try Set(String.fetchAll(
                db, sql: "SELECT identifier FROM grdb_migrations"))
            XCTAssertTrue(applied.isSuperset(of: [
                "v1", "v2", "v3-offline-search", "v3",
                "v4-pending-attention", "v5-cache-seams",
            ]), "missing migrations, applied = \(applied.sorted())")

            // Row counts fully preserved through both shadow copies + the repair.
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM session_cache"),
                expectedSessions)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message_row_cache"),
                expectedMessages)

            // The transcript FK points at the REAL parent, not the transient shadow.
            let parents = try Set(String.fetchAll(
                db,
                sql: "SELECT \"table\" FROM pragma_foreign_key_list('message_row_cache')"))
            XCTAssertEqual(parents, ["session_cache"])

            // And the whole database is foreign-key clean.
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            XCTAssertTrue(violations.isEmpty,
                          "unexpected FK violations: \(violations)")

            // Fingerprint stamped current so the nuke-and-rebuild hatch stays shut.
            let fingerprint = try SyncMetaRecord.fetchOne(
                db, key: SyncMetaRecord.Key.schemaVersion)?.value
            XCTAssertEqual(fingerprint, CacheSchema.currentFingerprint)
        }
    }

    /// The resilient (non-erasing) entry point used by the production CacheStore
    /// init reaches the same green end state and never wipes the seeded rows.
    func testResilientMigratePreservesRowsOnStuckShape() throws {
        let (queue, expectedSessions, expectedMessages) =
            try makeStuckV3DB(sessions: 4, messagesPerSession: 5)

        XCTAssertNoThrow(try CacheSchema.migrateResiliently(queue))

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM session_cache"),
                expectedSessions)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message_row_cache"),
                expectedMessages)
            XCTAssertTrue(
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    /// Re-running the full migrator on an already-migrated DB is a clean no-op:
    /// GRDB skips migrations whose identifier is already recorded, so the edited
    /// v3 body never re-runs on devices where v3 committed cleanly, and no row is
    /// touched.
    func testSecondMigrateIsIdempotentNoOp() throws {
        let (queue, expectedSessions, expectedMessages) =
            try makeStuckV3DB(sessions: 3, messagesPerSession: 4)
        try CacheSchema.makeMigrator().migrate(queue)

        XCTAssertNoThrow(try CacheSchema.makeMigrator().migrate(queue))

        try queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM session_cache"),
                expectedSessions)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message_row_cache"),
                expectedMessages)
            XCTAssertTrue(
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    /// Proves the repair is LOAD-BEARING (not a lucky no-op) by constructing the
    /// exact stuck on-disk shape the owner's device is in: `message_row_cache`
    /// carries a composite FK to the removed `session_cache_v3`, with a real
    /// transcript row present. `foreign_key_check` flags that row (this is the
    /// violation that made v3 throw on every launch); `repairTranscriptForeignKeyIfNeeded`
    /// must clear it, re-point the FK at `session_cache`, and preserve the row.
    ///
    /// The dangling FK is built directly (rather than via `ALTER TABLE RENAME`)
    /// because the modern SQLite that ships with the current simulator runtime
    /// rewrites child FK references on rename — the legacy build the owner is on
    /// does not, which is precisely why the on-device DB is stuck. Building the
    /// shape directly makes the repair proof deterministic on any host.
    func testRepairIsLoadBearing_danglingFKIsRepaired() throws {
        // foreign_keys OFF for this queue so the dangling child row can be seeded
        // (an INSERT against a FK whose parent table is missing would otherwise be
        // rejected). GRDB enables foreign keys by default, so disable them here.
        // foreign_key_check is an explicit pragma and reports violations regardless
        // of the enforcement flag.
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE session_cache(
                    serverId TEXT NOT NULL, profileId TEXT NOT NULL, id TEXT NOT NULL,
                    summaryJSON BLOB NOT NULL, PRIMARY KEY(serverId,profileId,id))
                """)
            // Child FK points at the transient `session_cache_v3` that the v3 swap
            // dropped — the dangling reference this whole fix exists to repair.
            try db.execute(sql: """
                CREATE TABLE message_row_cache(
                    serverId TEXT NOT NULL, profileId TEXT NOT NULL, sessionId TEXT NOT NULL,
                    ordinal INTEGER NOT NULL, wireId INTEGER, role TEXT NOT NULL,
                    timestamp DOUBLE, rowJSON BLOB NOT NULL,
                    PRIMARY KEY(serverId,profileId,sessionId,ordinal),
                    FOREIGN KEY(serverId,profileId,sessionId)
                        REFERENCES session_cache_v3(serverId,profileId,id) ON DELETE CASCADE)
                """)
            let blob = Data("{}".utf8)
            try db.execute(sql: "INSERT INTO session_cache VALUES(?,?,?,?)",
                           arguments: ["s", "p", "sess", blob])
            try db.execute(sql: "INSERT INTO message_row_cache VALUES(?,?,?,?,?,?,?,?)",
                           arguments: ["s", "p", "sess", 0, 0, "user", 0.0, blob])

            // The dangling reference + a populated row = the v3 failure condition.
            let parentsBefore = try Set(String.fetchAll(
                db, sql: "SELECT \"table\" FROM pragma_foreign_key_list('message_row_cache')"))
            XCTAssertEqual(parentsBefore, ["session_cache_v3"])
            XCTAssertFalse(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
                           "expected a FK violation from the dangling reference")

            // The repair clears it, re-points the FK, and keeps the row.
            XCTAssertTrue(try CacheSchema.repairTranscriptForeignKeyIfNeeded(db))
            let parentsAfter = try Set(String.fetchAll(
                db, sql: "SELECT \"table\" FROM pragma_foreign_key_list('message_row_cache')"))
            XCTAssertEqual(parentsAfter, ["session_cache"])
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_row_cache"), 1)

            // Idempotent: a second call is a clean no-op (FK already correct).
            XCTAssertFalse(try CacheSchema.repairTranscriptForeignKeyIfNeeded(db))
        }
    }

    /// A fresh (empty) database still migrates cleanly end-to-end — the repair is
    /// a no-op when there are no transcript rows for the dangling FK to bind.
    func testFreshEmptyDatabaseMigratesClean() throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)

        XCTAssertNoThrow(try CacheSchema.makeMigrator().migrate(queue))

        try queue.read { db in
            let parents = try Set(String.fetchAll(
                db,
                sql: "SELECT \"table\" FROM pragma_foreign_key_list('message_row_cache')"))
            XCTAssertEqual(parents, ["session_cache"])
            XCTAssertTrue(
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}
