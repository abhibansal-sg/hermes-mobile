import Foundation
import GRDB

enum ManifestCacheError: Error, Equatable {
    case authorityTransitionRequiresMigration
}

enum CompactTurnCacheError: Error, Equatable {
    case incompatiblePage
    case stalePage
}

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

    struct CompactTurnCommitIdentity: Sendable, Equatable {
        let clientMessageID: String
        let turnID: String
    }

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

    struct ManifestCommitPayload: Codable {
        let gatewayID: String?
        let journalEpoch: String?
        let profileAuthorities: [ManifestProfileAuthority]?
        let revision: Int64
        let cursor: String
        let sessions: [SessionSummary]
        let attention: [ManifestAttentionItem]
        let activeTurns: [ManifestActiveTurn]
        let transcriptHeads: [String: Int]
        let capabilities: Set<String>
        let serverTime: Double?
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

    /// Reads the last indivisible manifest snapshot. Session rows and metadata
    /// are read in the same SQLite snapshot, so no consumer can observe mixed
    /// revisions after relaunch.
    func loadManifestProjection(scope: CacheScope) throws -> ManifestProjection {
        try db.read { db in
            let locator = (try? GatewayLocatorBindingV1.normalize(locator: scope.serverId))
                ?? scope.serverId
            if let binding = try Self.locatorBinding(locator, db: db),
               let requestedScope = Self.manifestScope(
                   for: scope.profileId,
                   authorities: binding.profileAuthorities
               ) {
                // Production synchronizes the complete authority map through
                // `scope=all`. A named-profile cold launch may therefore read
                // that same indivisible snapshot and let SessionStore apply its
                // UI filter. A profile-specific snapshot, when present, wins.
                let candidates = requestedScope == "all"
                    ? ["all"]
                    : [requestedScope, "all"]
                for manifestScope in candidates {
                    if let projection = try Self.manifestProjection(
                        gatewayID: binding.gatewayID,
                        manifestScope: manifestScope,
                        db: db
                    ) {
                        return projection
                    }
                }
            }
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
            return ManifestProjection(
                gatewayID: payload.gatewayID,
                journalEpoch: payload.journalEpoch,
                profileAuthorities: payload.profileAuthorities ?? [],
                revision: payload.revision,
                cursor: payload.cursor,
                sessions: payload.sessions,
                attention: payload.attention,
                activeTurns: payload.activeTurns,
                transcriptHeads: payload.transcriptHeads,
                capabilities: payload.capabilities,
                freshness: .cached,
                lastSyncedAt: payload.serverTime.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func loadManifestProjection(
        locator: String,
        manifestScope: String
    ) throws -> ManifestProjection {
        let normalized = try GatewayLocatorBindingV1.normalize(locator: locator)
        return try db.read { db in
            guard let binding = try Self.locatorBinding(normalized, db: db),
                  let projection = try Self.manifestProjection(
                      gatewayID: binding.gatewayID,
                      manifestScope: manifestScope,
                      db: db
                  ) else {
                return .empty
            }
            return projection
        }
    }

    func loadLocatorBinding(locator: String) throws -> GatewayLocatorBindingV1? {
        let normalized = try GatewayLocatorBindingV1.normalize(locator: locator)
        return try db.read { db in try Self.locatorBinding(normalized, db: db) }
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

    /// Compatibility entry point for existing tests/callers. Production uses
    /// staged pages below, but both paths end in the same authority-keyed final
    /// transaction. The legacy CacheScope is treated only as a locator here.
    func applyManifest(_ chain: ManifestChain, scope: CacheScope) throws -> ManifestProjection {
        let locator = (try? GatewayLocatorBindingV1.normalize(locator: scope.serverId))
            ?? scope.serverId
        return try db.write { db in
            try Self.applyManifest(chain, normalizedLocator: locator, db: db).projection
        }
    }

    /// Persist one validated wire page into non-observable staging storage.
    /// Staging never changes the locator binding or current projection.
    func stageManifestPage(
        _ response: SyncManifestHTTPPage,
        locator: String,
        pageIndex: Int
    ) throws {
        let normalized = try GatewayLocatorBindingV1.normalize(locator: locator)
        guard (0..<100).contains(pageIndex), response.encodedByteCount == response.encodedData.count,
              response.encodedByteCount <= 16 * 1024 * 1024 else {
            throw ManifestBindingError.invalidStage
        }
        let page = response.page
        try db.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: "DELETE FROM manifest_page_stage_v2 WHERE createdAt < ?",
                arguments: [now - 10 * 60]
            )
            let existing = try Row.fetchAll(
                db,
                sql: """
                    SELECT pageIndex,normalizedLocator,gatewayId,journalEpoch,revision,
                           manifestScope,pageSize,pageJSON
                    FROM manifest_page_stage_v2
                    WHERE snapshotId=? ORDER BY pageIndex
                    """,
                arguments: [page.snapshotID]
            )
            if let first = existing.first {
                let stagedLocator: String = first["normalizedLocator"]
                let stagedGateway: String = first["gatewayId"]
                let stagedJournal: String = first["journalEpoch"]
                let stagedRevision: Int64 = first["revision"]
                let stagedScope: String = first["manifestScope"]
                let stagedPageSize: Int = first["pageSize"]
                guard stagedLocator == normalized,
                      stagedGateway == page.gatewayID,
                      stagedJournal == page.journalEpoch,
                      stagedRevision == page.revision,
                      stagedScope == page.scope,
                      stagedPageSize == page.pageSize else {
                    throw ManifestBindingError.invalidStage
                }
                if pageIndex < existing.count {
                    let prior: Data = existing[pageIndex]["pageJSON"]
                    guard prior == response.encodedData else {
                        throw ManifestBindingError.invalidStage
                    }
                    return
                }
                guard pageIndex == existing.count else {
                    throw ManifestBindingError.invalidStage
                }
            } else if pageIndex != 0 {
                throw ManifestBindingError.invalidStage
            }
            let totals = try Row.fetchOne(
                db,
                sql: "SELECT count(*) AS n,coalesce(sum(encodedBytes),0) AS bytes FROM manifest_page_stage_v2 WHERE snapshotId=?",
                arguments: [page.snapshotID]
            )
            let count: Int = totals?["n"] ?? 0
            let bytes: Int = totals?["bytes"] ?? 0
            guard count < 100, bytes + response.encodedByteCount <= 16 * 1024 * 1024 else {
                throw ManifestBindingError.invalidStage
            }
            try db.execute(
                sql: """
                    INSERT INTO manifest_page_stage_v2
                    (snapshotId,pageIndex,normalizedLocator,gatewayId,journalEpoch,
                     revision,manifestScope,pageSize,pageJSON,encodedBytes,createdAt)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    page.snapshotID, pageIndex, normalized, page.gatewayID,
                    page.journalEpoch, page.revision, page.scope, page.pageSize,
                    response.encodedData, response.encodedByteCount, now,
                ]
            )
        }
    }

    /// Validate and publish the staged chain in one final GRDB transaction.
    /// The resume cursor and every projection row become visible together.
    func commitStagedManifest(
        snapshotID: String,
        locator: String,
        expectedPageCount: Int
    ) throws -> ManifestCommitResult {
        let normalized = try GatewayLocatorBindingV1.normalize(locator: locator)
        guard snapshotID.hasPrefix("ms_"), (1...100).contains(expectedPageCount) else {
            throw ManifestBindingError.invalidStage
        }
        return try db.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT pageIndex,normalizedLocator,pageJSON
                    FROM manifest_page_stage_v2
                    WHERE snapshotId=? ORDER BY pageIndex
                    """,
                arguments: [snapshotID]
            )
            guard rows.count == expectedPageCount,
                  rows.enumerated().allSatisfy({ index, row in
                      let stagedIndex: Int = row["pageIndex"]
                      let stagedLocator: String = row["normalizedLocator"]
                      return stagedIndex == index && stagedLocator == normalized
                  }) else {
                throw ManifestBindingError.invalidStage
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let pages = try rows.map { row -> SyncManifestPage in
                let data: Data = row["pageJSON"]
                return try decoder.decode(SyncManifestPage.self, from: data)
            }
            let chain = try ManifestChain(validating: pages)
            guard chain.snapshotID == snapshotID else {
                throw ManifestBindingError.invalidStage
            }
            let result = try Self.applyManifest(
                chain,
                normalizedLocator: normalized,
                db: db
            )
            try db.execute(
                sql: "DELETE FROM manifest_page_stage_v2 WHERE snapshotId=?",
                arguments: [snapshotID]
            )
            return result
        }
    }

    func discardStagedManifest(snapshotID: String) throws {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM manifest_page_stage_v2 WHERE snapshotId=?",
                arguments: [snapshotID]
            )
        }
    }

    private static func applyManifest(
        _ chain: ManifestChain,
        normalizedLocator: String,
        db: Database
    ) throws -> ManifestCommitResult {
        let now = Date().timeIntervalSince1970
        let oldBinding = try locatorBinding(normalizedLocator, db: db)
        var replacedGatewayID: String?
        var replacedProfiles: Set<ManifestAuthorityReplacement> = []

        if let oldBinding, oldBinding.gatewayID != chain.gatewayID {
            replacedGatewayID = oldBinding.gatewayID
            replacedProfiles.formUnion(oldBinding.profileAuthorities.map {
                ManifestAuthorityReplacement(
                    gatewayID: oldBinding.gatewayID,
                    profileID: $0.profileID,
                    authorityEpoch: $0.authorityEpoch
                )
            })
            try db.execute(
                sql: "UPDATE authority_partition_v1 SET state='recovered',updatedAt=? WHERE gatewayId=? AND state='current'",
                arguments: [now, oldBinding.gatewayID]
            )
        } else if let oldBinding {
            let incomingByID = Dictionary(
                uniqueKeysWithValues: chain.profileAuthorities.map { ($0.profileID, $0) }
            )
            let incomingByName = Dictionary(
                uniqueKeysWithValues: chain.profileAuthorities.map { ($0.profileName, $0) }
            )
            for old in oldBinding.profileAuthorities {
                let sameID = incomingByID[old.profileID]
                let sameName = incomingByName[old.profileName]
                if sameID?.authorityEpoch != old.authorityEpoch
                    || (sameID == nil && sameName?.profileID != old.profileID) {
                    replacedProfiles.insert(
                        ManifestAuthorityReplacement(
                            gatewayID: oldBinding.gatewayID,
                            profileID: old.profileID,
                            authorityEpoch: old.authorityEpoch
                        )
                    )
                    try db.execute(
                        sql: """
                            UPDATE authority_partition_v1
                            SET state='recovered',updatedAt=?
                            WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                            """,
                        arguments: [
                            now, oldBinding.gatewayID, old.profileID, old.authorityEpoch,
                        ]
                    )
                }
            }
        }

        for authority in chain.profileAuthorities {
            try db.execute(
                sql: """
                    INSERT INTO authority_partition_v1
                    (gatewayId,profileId,authorityEpoch,profileName,state,updatedAt)
                    VALUES (?,?,?,?, 'current', ?)
                    ON CONFLICT(gatewayId,profileId,authorityEpoch) DO UPDATE SET
                      profileName=excluded.profileName,state='current',updatedAt=excluded.updatedAt
                    """,
                arguments: [
                    chain.gatewayID, authority.profileID, authority.authorityEpoch,
                    authority.profileName, now,
                ]
            )
        }

        let authorityData = try JSONEncoder().encode(chain.profileAuthorities)
        try db.execute(
            sql: """
                INSERT INTO gateway_locator_binding_v1
                (normalizedLocator,gatewayId,profileAuthoritiesJSON,verifiedAt)
                VALUES (?,?,?,?)
                ON CONFLICT(normalizedLocator) DO UPDATE SET
                  gatewayId=excluded.gatewayId,
                  profileAuthoritiesJSON=excluded.profileAuthoritiesJSON,
                  verifiedAt=excluded.verifiedAt
                """,
            arguments: [normalizedLocator, chain.gatewayID, authorityData, now]
        )

        if let existing = try manifestProjection(
            gatewayID: chain.gatewayID,
            manifestScope: chain.scope,
            db: db
        ), existing.journalEpoch == chain.journalEpoch,
           existing.profileAuthorities == chain.profileAuthorities,
           chain.revision <= existing.revision {
            let binding = GatewayLocatorBindingV1(
                normalizedLocator: normalizedLocator,
                gatewayID: chain.gatewayID,
                profileAuthorities: chain.profileAuthorities,
                verifiedAt: Date(timeIntervalSince1970: now)
            )
            return ManifestCommitResult(
                projection: ManifestProjection(
                    gatewayID: existing.gatewayID,
                    journalEpoch: existing.journalEpoch,
                    profileAuthorities: existing.profileAuthorities,
                    revision: existing.revision,
                    cursor: existing.cursor,
                    sessions: existing.sessions,
                    attention: existing.attention,
                    activeTurns: existing.activeTurns,
                    transcriptHeads: existing.transcriptHeads,
                    capabilities: existing.capabilities,
                    freshness: .fresh,
                    lastSyncedAt: existing.lastSyncedAt
                ),
                binding: binding,
                transition: ManifestAuthorityTransition(
                    replacedGatewayID: replacedGatewayID,
                    replacedProfiles: replacedProfiles
                )
            )
        }

        if let state = try Row.fetchOne(
            db,
            sql: "SELECT journalEpoch FROM manifest_projection_state_v2 WHERE gatewayId=? AND manifestScope=?",
            arguments: [chain.gatewayID, chain.scope]
        ) {
            let oldJournal: String = state["journalEpoch"]
            guard oldJournal == chain.journalEpoch
                    || (chain.reset && chain.resetReason == "journal_rebuilt") else {
                throw ManifestCacheError.authorityTransitionRequiresMigration
            }
        }

        if chain.reset {
            for authority in chain.profileAuthorities {
                try db.execute(
                    sql: """
                        DELETE FROM manifest_session_projection_v2
                        WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                        """,
                    arguments: [
                        chain.gatewayID, authority.profileID, authority.authorityEpoch,
                    ]
                )
            }
        }

        for tombstone in chain.tombstoneRecords {
            try db.execute(
                sql: """
                    INSERT INTO projection_tombstone_v1
                    (gatewayId,profileId,authorityEpoch,entityKind,entityId,serverRevision,deletedAt)
                    VALUES (?,?,?,'session',?,?,?)
                    ON CONFLICT(gatewayId,profileId,authorityEpoch,entityKind,entityId)
                    DO UPDATE SET serverRevision=excluded.serverRevision,deletedAt=excluded.deletedAt
                    WHERE excluded.serverRevision >= projection_tombstone_v1.serverRevision
                    """,
                arguments: [
                    chain.gatewayID, tombstone.profileID, tombstone.authorityEpoch,
                    tombstone.sessionID, tombstone.entityRevision, tombstone.deletedAt,
                ]
            )
            try db.execute(
                sql: """
                    DELETE FROM manifest_session_projection_v2
                    WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                      AND sessionId=? AND entityRevision<=?
                    """,
                arguments: [
                    chain.gatewayID, tombstone.profileID, tombstone.authorityEpoch,
                    tombstone.sessionID, tombstone.entityRevision,
                ]
            )
        }

        let encoder = JSONEncoder()
        for upsert in chain.sessionUpserts {
            let tombstoneRevision = try Int64.fetchOne(
                db,
                sql: """
                    SELECT serverRevision FROM projection_tombstone_v1
                    WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                      AND entityKind='session' AND entityId=?
                    """,
                arguments: [
                    chain.gatewayID, upsert.profileID, upsert.authorityEpoch,
                    upsert.summary.id,
                ]
            )
            guard (tombstoneRevision ?? -1) < upsert.entityRevision else { continue }
            let summaryData = try encoder.encode(upsert.summary)
            try db.execute(
                sql: """
                    INSERT INTO manifest_session_projection_v2
                    (gatewayId,profileId,authorityEpoch,sessionId,summaryJSON,entityRevision,lastActive)
                    VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(gatewayId,profileId,authorityEpoch,sessionId) DO UPDATE SET
                      summaryJSON=excluded.summaryJSON,
                      entityRevision=excluded.entityRevision,
                      lastActive=excluded.lastActive
                    WHERE excluded.entityRevision >= manifest_session_projection_v2.entityRevision
                    """,
                arguments: [
                    chain.gatewayID, upsert.profileID, upsert.authorityEpoch,
                    upsert.summary.id, summaryData, upsert.entityRevision,
                    upsert.summary.lastActive,
                ]
            )
        }

        var projectedSessions: [SessionSummary] = []
        for authority in chain.profileAuthorities {
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT summaryJSON FROM manifest_session_projection_v2
                    WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                    ORDER BY lastActive DESC
                    """,
                arguments: [
                    chain.gatewayID, authority.profileID, authority.authorityEpoch,
                ]
            )
            projectedSessions.append(contentsOf: try rows.map { row in
                let data: Data = row["summaryJSON"]
                return try JSONDecoder().decode(SessionSummary.self, from: data)
            })
        }
        projectedSessions.sort { ($0.lastActive ?? 0) > ($1.lastActive ?? 0) }

        let payload = ManifestCommitPayload(
            gatewayID: chain.gatewayID,
            journalEpoch: chain.journalEpoch,
            profileAuthorities: chain.profileAuthorities,
            revision: chain.revision,
            cursor: chain.cursor,
            sessions: projectedSessions,
            attention: chain.attention,
            activeTurns: chain.activeTurns,
            transcriptHeads: chain.transcriptHeads,
            capabilities: chain.capabilities,
            serverTime: chain.serverTime
        )
        let payloadData = try encoder.encode(payload)
        try db.execute(
            sql: """
                INSERT INTO manifest_projection_state_v2
                (gatewayId,manifestScope,journalEpoch,revision,resumeCursor,payloadJSON,updatedAt)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(gatewayId,manifestScope) DO UPDATE SET
                  journalEpoch=excluded.journalEpoch,
                  revision=excluded.revision,
                  resumeCursor=excluded.resumeCursor,
                  payloadJSON=excluded.payloadJSON,
                  updatedAt=excluded.updatedAt
                """,
            arguments: [
                chain.gatewayID, chain.scope, chain.journalEpoch, chain.revision,
                chain.cursor, payloadData, now,
            ]
        )
        let binding = GatewayLocatorBindingV1(
            normalizedLocator: normalizedLocator,
            gatewayID: chain.gatewayID,
            profileAuthorities: chain.profileAuthorities,
            verifiedAt: Date(timeIntervalSince1970: now)
        )
        let projection = ManifestProjection(
            gatewayID: chain.gatewayID,
            journalEpoch: chain.journalEpoch,
            profileAuthorities: chain.profileAuthorities,
            revision: chain.revision,
            cursor: chain.cursor,
            sessions: projectedSessions,
            attention: chain.attention,
            activeTurns: chain.activeTurns,
            transcriptHeads: chain.transcriptHeads,
            capabilities: chain.capabilities,
            freshness: .fresh,
            lastSyncedAt: chain.serverTime.map(Date.init(timeIntervalSince1970:))
        )
        return ManifestCommitResult(
            projection: projection,
            binding: binding,
            transition: ManifestAuthorityTransition(
                replacedGatewayID: replacedGatewayID,
                replacedProfiles: replacedProfiles
            )
        )
    }

    private static func locatorBinding(
        _ normalizedLocator: String,
        db: Database
    ) throws -> GatewayLocatorBindingV1? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT gatewayId,profileAuthoritiesJSON,verifiedAt
                FROM gateway_locator_binding_v1 WHERE normalizedLocator=?
                """,
            arguments: [normalizedLocator]
        ) else { return nil }
        let data: Data = row["profileAuthoritiesJSON"]
        let authorities = try JSONDecoder().decode(
            [ManifestProfileAuthority].self,
            from: data
        )
        return GatewayLocatorBindingV1(
            normalizedLocator: normalizedLocator,
            gatewayID: row["gatewayId"],
            profileAuthorities: authorities,
            verifiedAt: Date(timeIntervalSince1970: row["verifiedAt"])
        )
    }

    private static func manifestScope(
        for profileSelector: String,
        authorities: [ManifestProfileAuthority]
    ) -> String? {
        if profileSelector == CacheScope.allProfilesKey { return "all" }
        if profileSelector.hasPrefix("pf_") { return "profile:\(profileSelector)" }
        guard let authority = authorities.first(where: {
            $0.profileName == profileSelector
        }) else { return nil }
        return "profile:\(authority.profileID)"
    }

    private static func manifestProjection(
        gatewayID: String,
        manifestScope: String,
        db: Database
    ) throws -> ManifestProjection? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT payloadJSON FROM manifest_projection_state_v2
                WHERE gatewayId=? AND manifestScope=?
                """,
            arguments: [gatewayID, manifestScope]
        ) else { return nil }
        let data: Data = row["payloadJSON"]
        let payload = try JSONDecoder().decode(ManifestCommitPayload.self, from: data)
        return ManifestProjection(
            gatewayID: payload.gatewayID,
            journalEpoch: payload.journalEpoch,
            profileAuthorities: payload.profileAuthorities ?? [],
            revision: payload.revision,
            cursor: payload.cursor,
            sessions: payload.sessions,
            attention: payload.attention,
            activeTurns: payload.activeTurns,
            transcriptHeads: payload.transcriptHeads,
            capabilities: payload.capabilities,
            freshness: .cached,
            lastSyncedAt: payload.serverTime.map(Date.init(timeIntervalSince1970:))
        )
    }

    /// Apply one bounded turn page atomically. WorkRepository completion is a
    /// deliberately separate, idempotent step performed by the coordinator
    /// after this transaction returns.
    func applyCompactTurnPage(
        _ page: CompactTurnPageV1,
        authority: AuthorityScopeV1,
        now: Date = Date()
    ) throws -> [CompactTurnCommitIdentity] {
        guard page.schemaVersion == 1,
              page.projectionVersion == 1,
              !page.storedSessionID.isEmpty else {
            throw CompactTurnCacheError.incompatiblePage
        }
        return try db.write { db in
            let existingHead = try Int64.fetchOne(
                db,
                sql: """
                    SELECT sourceHeadId FROM turn_projection_state_v1
                    WHERE gatewayId=? AND profileId=? AND authorityEpoch=? AND sessionId=?
                    """,
                arguments: [
                    authority.gatewayID, authority.profileID, authority.authorityEpoch,
                    page.storedSessionID,
                ]
            )
            if let existingHead, existingHead > page.sourceHeadID {
                throw CompactTurnCacheError.stalePage
            }
            let scopeArguments: [DatabaseValueConvertible] = [
                authority.gatewayID,
                authority.profileID,
                authority.authorityEpoch,
                page.storedSessionID,
            ]
            if page.reset {
                try db.execute(
                    sql: """
                        DELETE FROM turn_projection_v1
                        WHERE gatewayId=? AND profileId=? AND authorityEpoch=? AND sessionId=?
                        """,
                    arguments: StatementArguments(scopeArguments)
                )
            }

            for tombstone in page.tombstones {
                let entityID = "\(page.storedSessionID):\(tombstone.turnID)"
                try db.execute(
                    sql: """
                        INSERT INTO projection_tombstone_v1
                        (gatewayId,profileId,authorityEpoch,entityKind,entityId,serverRevision,deletedAt)
                        VALUES (?,?,?,?,?,?,?)
                        ON CONFLICT(gatewayId,profileId,authorityEpoch,entityKind,entityId)
                        DO UPDATE SET serverRevision=excluded.serverRevision,
                                      deletedAt=excluded.deletedAt
                        WHERE excluded.serverRevision >= projection_tombstone_v1.serverRevision
                        """,
                    arguments: [
                        authority.gatewayID, authority.profileID, authority.authorityEpoch,
                        "turn", entityID, tombstone.serverRevision, tombstone.deletedAt,
                    ]
                )
                try db.execute(
                    sql: """
                        DELETE FROM turn_projection_v1
                        WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                          AND sessionId=? AND turnId=? AND serverRevision<=?
                        """,
                    arguments: [
                        authority.gatewayID, authority.profileID, authority.authorityEpoch,
                        page.storedSessionID, tombstone.turnID, tombstone.serverRevision,
                    ]
                )
            }

            let encoder = JSONEncoder()
            var committed: [CompactTurnCommitIdentity] = []
            for turn in page.turns {
                let entityID = "\(page.storedSessionID):\(turn.turnID)"
                let tombstoneRevision = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT serverRevision FROM projection_tombstone_v1
                        WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                          AND entityKind='turn' AND entityId=?
                        """,
                    arguments: [
                        authority.gatewayID, authority.profileID,
                        authority.authorityEpoch, entityID,
                    ]
                )
                guard (tombstoneRevision ?? -1) < turn.serverRevision else { continue }
                let finalJSON = try turn.final.map(encoder.encode)
                try db.execute(
                    sql: """
                        INSERT INTO turn_projection_v1
                        (gatewayId,profileId,authorityEpoch,sessionId,turnId,clientMessageId,
                         state,acceptedAt,startedAt,completedAt,elapsedMs,timingQuality,
                         authorityState,finalJSON,sourceHeadId,projectionVersion,
                         serverRevision,updatedAt)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(gatewayId,profileId,authorityEpoch,sessionId,turnId)
                        DO UPDATE SET clientMessageId=excluded.clientMessageId,
                          state=excluded.state,acceptedAt=excluded.acceptedAt,
                          startedAt=excluded.startedAt,completedAt=excluded.completedAt,
                          elapsedMs=excluded.elapsedMs,timingQuality=excluded.timingQuality,
                          authorityState=excluded.authorityState,finalJSON=excluded.finalJSON,
                          sourceHeadId=excluded.sourceHeadId,
                          projectionVersion=excluded.projectionVersion,
                          serverRevision=excluded.serverRevision,updatedAt=excluded.updatedAt
                        WHERE excluded.serverRevision >= turn_projection_v1.serverRevision
                        """,
                    arguments: [
                        authority.gatewayID, authority.profileID, authority.authorityEpoch,
                        page.storedSessionID, turn.turnID, turn.clientMessageID,
                        turn.state, turn.acceptedAt, turn.startedAt, turn.completedAt,
                        turn.elapsedMs, turn.timingQuality, turn.authorityState,
                        finalJSON, page.sourceHeadID, page.projectionVersion,
                        turn.serverRevision, now.timeIntervalSince1970,
                    ]
                )
                try db.execute(
                    sql: """
                        DELETE FROM turn_input_v1
                        WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                          AND sessionId=? AND turnId=?
                        """,
                    arguments: StatementArguments(scopeArguments + [turn.turnID])
                )
                for input in turn.inputs {
                    try db.execute(
                        sql: """
                            INSERT INTO turn_input_v1
                            (gatewayId,profileId,authorityEpoch,sessionId,turnId,inputId,
                             clientMessageId,ordinal,inputKind,contentJSON,createdAt)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?)
                            """,
                        arguments: StatementArguments(scopeArguments + [
                            turn.turnID, input.inputID, input.clientMessageID,
                            input.ordinal, input.inputKind,
                            try encoder.encode(input.content), input.createdAt,
                        ])
                    )
                }
                try db.execute(
                    sql: """
                        DELETE FROM turn_activity_group_v1
                        WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                          AND sessionId=? AND turnId=?
                        """,
                    arguments: StatementArguments(scopeArguments + [turn.turnID])
                )
                for group in turn.activityGroups {
                    try db.execute(
                        sql: """
                            INSERT INTO turn_activity_group_v1
                            (gatewayId,profileId,authorityEpoch,sessionId,turnId,groupId,
                             ordinal,category,displayLabel,operationCount,state,startedAt,
                             completedAt,detailAvailable,serverRevision)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                            """,
                        arguments: StatementArguments(scopeArguments + [
                            turn.turnID, group.groupID, group.ordinal, group.category,
                            group.displayLabel, group.operationCount, group.state,
                            group.startedAt, group.completedAt, group.detailAvailable,
                            turn.serverRevision,
                        ])
                    )
                }
                if let clientMessageID = turn.clientMessageID {
                    committed.append(CompactTurnCommitIdentity(
                        clientMessageID: clientMessageID,
                        turnID: turn.turnID
                    ))
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO turn_projection_state_v1
                    (gatewayId,profileId,authorityEpoch,sessionId,sourceHeadId,
                     previousCursor,hasOlder,coverageComplete,updatedAt)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(gatewayId,profileId,authorityEpoch,sessionId)
                    DO UPDATE SET sourceHeadId=excluded.sourceHeadId,
                      previousCursor=excluded.previousCursor,hasOlder=excluded.hasOlder,
                      coverageComplete=excluded.coverageComplete,updatedAt=excluded.updatedAt
                    WHERE excluded.sourceHeadId >= turn_projection_state_v1.sourceHeadId
                    """,
                arguments: StatementArguments(scopeArguments + [
                    page.sourceHeadID, page.previousCursor, page.hasOlder,
                    page.coverageComplete, now.timeIntervalSince1970,
                ])
            )
            return committed
        }
    }

    /// Read only the newest requested compact turns. This is the normal
    /// local-first session-open path and never decodes legacy raw rows.
    func loadCompactTurns(
        authority: AuthorityScopeV1,
        storedSessionID: String,
        limit: Int = 30
    ) throws -> [CompactTurnV1] {
        let safeLimit = max(1, min(limit, 100))
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM (
                      SELECT * FROM turn_projection_v1
                      WHERE gatewayId=? AND profileId=? AND authorityEpoch=? AND sessionId=?
                      ORDER BY acceptedAt DESC, turnId DESC LIMIT ?
                    ) ORDER BY acceptedAt ASC, turnId ASC
                    """,
                arguments: [
                    authority.gatewayID, authority.profileID, authority.authorityEpoch,
                    storedSessionID, safeLimit,
                ]
            )
            let decoder = JSONDecoder()
            return try rows.map { row in
                let turnID: String = row["turnId"]
                let inputRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM turn_input_v1
                        WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                          AND sessionId=? AND turnId=? ORDER BY ordinal
                        """,
                    arguments: [
                        authority.gatewayID, authority.profileID, authority.authorityEpoch,
                        storedSessionID, turnID,
                    ]
                )
                let inputs = try inputRows.map { input -> CompactTurnInputV1 in
                    let contentData: Data = input["contentJSON"]
                    return CompactTurnInputV1(
                        inputID: input["inputId"],
                        clientMessageID: input["clientMessageId"],
                        ordinal: input["ordinal"],
                        inputKind: input["inputKind"],
                        content: try decoder.decode(JSONValue.self, from: contentData),
                        createdAt: input["createdAt"]
                    )
                }
                let groupRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM turn_activity_group_v1
                        WHERE gatewayId=? AND profileId=? AND authorityEpoch=?
                          AND sessionId=? AND turnId=? ORDER BY ordinal
                        """,
                    arguments: [
                        authority.gatewayID, authority.profileID, authority.authorityEpoch,
                        storedSessionID, turnID,
                    ]
                )
                let groups = groupRows.map { group in
                    CompactTurnActivityGroupV1(
                        groupID: group["groupId"],
                        ordinal: group["ordinal"],
                        category: group["category"],
                        displayLabel: group["displayLabel"],
                        operationCount: group["operationCount"],
                        state: group["state"],
                        startedAt: group["startedAt"],
                        completedAt: group["completedAt"],
                        detailAvailable: group["detailAvailable"]
                    )
                }
                let finalData: Data? = row["finalJSON"]
                return CompactTurnV1(
                    turnID: turnID,
                    clientMessageID: row["clientMessageId"],
                    inputs: inputs,
                    state: row["state"],
                    acceptedAt: row["acceptedAt"],
                    startedAt: row["startedAt"],
                    completedAt: row["completedAt"],
                    elapsedMs: row["elapsedMs"],
                    timingQuality: row["timingQuality"],
                    authorityState: row["authorityState"],
                    serverRevision: row["serverRevision"],
                    final: try finalData.map {
                        try decoder.decode(CompactTurnFinalV1.self, from: $0)
                    },
                    activityGroups: groups
                )
            }
        }
    }

    func compactTurnProjectionState(
        authority: AuthorityScopeV1,
        storedSessionID: String
    ) throws -> CompactTurnProjectionStateV1? {
        try db.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT sourceHeadId,previousCursor,hasOlder,coverageComplete
                    FROM turn_projection_state_v1
                    WHERE gatewayId=? AND profileId=? AND authorityEpoch=? AND sessionId=?
                    """,
                arguments: [
                    authority.gatewayID, authority.profileID, authority.authorityEpoch,
                    storedSessionID,
                ]
            ) else { return nil }
            return CompactTurnProjectionStateV1(
                sourceHeadID: row["sourceHeadId"],
                previousCursor: row["previousCursor"],
                hasOlder: row["hasOlder"],
                coverageComplete: row["coverageComplete"]
            )
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
