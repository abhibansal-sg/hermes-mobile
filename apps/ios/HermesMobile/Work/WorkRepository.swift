import CryptoKit
import Foundation
import GRDB

enum WorkRepositoryError: Error, LocalizedError, Equatable {
    case appGroupUnavailable
    case protectedDataUnavailable
    case invalidScope
    case invalidRelativePath
    case jobNotFound
    case draftNotFound
    case assetNotFound
    case invalidTransition(from: WorkJobState, to: WorkJobState)
    case leaseLost
    case shareQueueFull(limit: Int)
    case shareStorageFull(limitBytes: Int)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "Couldn’t reach Hermes’ shared storage. Check the app is installed."
        case .protectedDataUnavailable:
            "Hermes’ protected storage is locked. Unlock the device and try again."
        case .invalidScope:
            "The work item has an invalid gateway scope."
        case .invalidRelativePath:
            "The work item contains an invalid asset path."
        case .jobNotFound:
            "The queued work item no longer exists."
        case .draftNotFound:
            "The draft no longer exists."
        case .assetNotFound:
            "The work asset no longer exists."
        case .invalidTransition(let from, let to):
            "Invalid work transition from \(from.rawValue) to \(to.rawValue)."
        case .leaseLost:
            "Another worker owns this work item."
        case .shareQueueFull(let limit):
            "Hermes can hold up to \(limit) pending shares. Retry or delete one first."
        case .shareStorageFull(let limitBytes):
            "Pending shares have reached the \(limitBytes / 1_048_576) MiB local limit."
        }
    }
}

struct WorkRepositoryConfiguration: Sendable {
    static let databaseName = "hermes_work.sqlite"
    static let assetsDirectoryName = "WorkAssets"

    let databaseURL: URL
    let assetsDirectoryURL: URL
    let protectedDataAvailable: @Sendable () -> Bool

    init(
        containerURL: URL,
        protectedDataAvailable: @escaping @Sendable () -> Bool = { true }
    ) {
        self.databaseURL = containerURL.appendingPathComponent(Self.databaseName)
        self.assetsDirectoryURL = containerURL.appendingPathComponent(
            Self.assetsDirectoryName,
            isDirectory: true
        )
        self.protectedDataAvailable = protectedDataAvailable
    }

    static func appGroup(
        protectedDataAvailable: @escaping @Sendable () -> Bool = { true }
    ) throws -> WorkRepositoryConfiguration {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) else {
            throw WorkRepositoryError.appGroupUnavailable
        }
        return WorkRepositoryConfiguration(
            containerURL: containerURL,
            protectedDataAvailable: protectedDataAvailable
        )
    }
}

/// Shared, protected source of truth for drafts and queued user work.
///
/// Each process creates its own actor and `DatabasePool`. WAL and SQL leases
/// coordinate those connections; no process-local singleton is used for
/// correctness. The actor serializes its own callers, while GRDB performs all
/// SQLite work away from `MainActor`.
actor WorkRepository {
    private static let protection: FileProtectionType = .completeUntilFirstUserAuthentication
    static let shareJobLimit = 20
    static let shareByteLimit = 100 * 1_048_576
    static let shareLifetime: TimeInterval = 14 * 24 * 60 * 60
    static let orphanAssetGrace: TimeInterval = 5 * 60

    let database: DatabasePool
    private let configuration: WorkRepositoryConfiguration
    private let observation: WorkRepositoryObservation?

    init(
        configuration: WorkRepositoryConfiguration,
        observation: WorkRepositoryObservation? = nil
    ) throws {
        guard configuration.protectedDataAvailable() else {
            throw WorkRepositoryError.protectedDataUnavailable
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: configuration.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.protection]
        )
        try fileManager.createDirectory(
            at: configuration.assetsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.protection]
        )

        var databaseConfiguration = Configuration()
        databaseConfiguration.busyMode = .timeout(5)
        databaseConfiguration.prepareDatabase { db in
            // DatabasePool otherwise gives read-only connections GRDB's
            // 10-second default; the cross-process contract requires 5 seconds
            // for every connection in both processes.
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        let pool = try DatabasePool(
            path: configuration.databaseURL.path,
            configuration: databaseConfiguration
        )
        try WorkSchema.makeMigrator().migrate(pool)

        self.database = pool
        self.configuration = configuration
        self.observation = observation

        try Self.protectAndExcludeFromBackup(configuration.databaseURL)
        try Self.protectAndExcludeFromBackup(configuration.assetsDirectoryURL)
        Self.protectSQLiteCompanions(for: configuration.databaseURL)
    }

    static func openAppGroup(
        scope: WorkScope?,
        observation: WorkRepositoryObservation? = nil
    ) async throws -> WorkRepository {
        let repository = try WorkRepository(configuration: .appGroup(), observation: observation)
        try await repository.importLegacyWork(from: LegacyWorkImportSource(scope: scope))
        try await repository.refreshObservation()
        return repository
    }

    // MARK: - Job CRUD

    @discardableResult
    func enqueue(_ input: WorkJobInput, assets: [WorkAssetInput] = []) async throws -> WorkJob {
        try ensureProtectedDataAvailable()
        let preparedAssets = try prepareAssets(assets)
        let now = input.createdAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let job = Self.makeJob(input, preparedAssets: preparedAssets, now: now)

        do {
            try await database.write { db in
                try job.insert(db)
                for (ordinal, prepared) in preparedAssets.enumerated() {
                    try prepared.record.insert(db)
                    try WorkJobAsset(
                        jobID: job.jobID,
                        assetID: prepared.record.assetID,
                        ordinal: ordinal,
                        transferID: nil,
                        remotePath: nil,
                        state: "local"
                    ).insert(db)
                }
            }
        } catch {
            removePreparedFiles(preparedAssets)
            throw error
        }

        await publishObservation()
        return job
    }

    /// Atomically accepts one share after enforcing count, byte, and age policy.
    @discardableResult
    func enqueueShare(
        _ source: WorkJobInput,
        assets: [WorkAssetInput] = [],
        now: Date = Date()
    ) async throws -> WorkJob {
        guard source.kind == .share else { throw WorkRepositoryError.jobNotFound }
        let incomingBytes = assets.reduce(0) { $0 + $1.data.count }
        guard incomingBytes <= Self.shareByteLimit else {
            throw WorkRepositoryError.shareStorageFull(limitBytes: Self.shareByteLimit)
        }
        try ensureProtectedDataAvailable()
        let preparedAssets = try prepareAssets(assets)
        var input = source
        input.expiresAt = now.addingTimeInterval(Self.shareLifetime)
        input.createdAt = input.createdAt ?? now
        let job = Self.makeJob(
            input,
            preparedAssets: preparedAssets,
            now: input.createdAt!.timeIntervalSince1970
        )
        let timestamp = now.timeIntervalSince1970

        do {
            let expiredPaths = try await database.write { db -> [String] in
                let paths = try Self.deleteExpiredShareRows(db, now: timestamp)
                let activeCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM work_jobs
                        WHERE kind = 'share'
                          AND state NOT IN ('completed', 'cancelled', 'expired')
                          AND (expires_at IS NULL OR expires_at > ?)
                        """,
                    arguments: [timestamp]
                ) ?? 0
                guard activeCount < Self.shareJobLimit else {
                    throw WorkRepositoryError.shareQueueFull(limit: Self.shareJobLimit)
                }
                let activeBytes = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COALESCE(SUM(byte_count), 0)
                        FROM work_assets
                        WHERE asset_id IN (
                            SELECT DISTINCT job_assets.asset_id
                            FROM job_assets
                            JOIN work_jobs USING (job_id)
                            WHERE work_jobs.kind = 'share'
                              AND (work_jobs.expires_at IS NULL OR work_jobs.expires_at > ?)
                        )
                        """,
                    arguments: [timestamp]
                ) ?? 0
                guard activeBytes + incomingBytes <= Self.shareByteLimit else {
                    throw WorkRepositoryError.shareStorageFull(limitBytes: Self.shareByteLimit)
                }
                try job.insert(db)
                for (ordinal, prepared) in preparedAssets.enumerated() {
                    try prepared.record.insert(db)
                    try WorkJobAsset(
                        jobID: job.jobID,
                        assetID: prepared.record.assetID,
                        ordinal: ordinal,
                        transferID: nil,
                        remotePath: nil,
                        state: "local"
                    ).insert(db)
                }
                return paths
            }
            removeAssetFiles(expiredPaths)
        } catch {
            removePreparedFiles(preparedAssets)
            throw error
        }
        await publishObservation()
        return job
    }

    /// Binds every unpaired share exactly once after setup establishes identity.
    func bindPendingShares(to scope: WorkScope, now: Date = Date()) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE work_jobs
                    SET server_id = ?, profile_id = ?, state = 'queued', updated_at = ?
                    WHERE kind = 'share' AND state = 'waiting_for_scope'
                      AND server_id IS NULL AND profile_id IS NULL
                    """,
                arguments: [scope.serverID, scope.profileID, now.timeIntervalSince1970]
            )
        }
        await publishObservation()
    }

    /// Expires stale shares and removes database/file orphans without touching live references.
    @discardableResult
    func cleanupShareWork(now: Date = Date()) async throws -> Int {
        try ensureProtectedDataAvailable()
        let timestamp = now.timeIntervalSince1970
        let result = try await database.write { db -> (Int, [String]) in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM work_jobs WHERE kind = 'share'") ?? 0
            var paths = try Self.deleteExpiredShareRows(db, now: timestamp)
            paths.append(contentsOf: try Self.deleteUnreferencedAssetRows(db))
            let after = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM work_jobs WHERE kind = 'share'") ?? 0
            return (before - after, Array(Set(paths)))
        }
        removeAssetFiles(result.1)
        try removeOrphanAssetFiles(now: now)
        await publishObservation()
        return result.0
    }

    func job(id: String) throws -> WorkJob? {
        try database.read { db in
            try WorkJob.fetchOne(db, key: id)
        }
    }

    func jobs(scope: WorkScope? = nil) throws -> [WorkJob] {
        try database.read { db in
            var request = WorkJob.order(Column("created_at"), Column("job_id"))
            if let scope {
                request = request
                    .filter(Column("server_id") == scope.serverID)
                    .filter(Column("profile_id") == scope.profileID)
            }
            return try request.fetchAll(db)
        }
    }

    func databasePragmas() throws -> WorkDatabasePragmas {
        try database.read { db in
            WorkDatabasePragmas(
                journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                foreignKeysEnabled: (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) == 1,
                busyTimeoutMilliseconds: try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
            )
        }
    }

    /// Atomically claims the oldest eligible job. Ordering by `job_id` breaks
    /// timestamp ties so two processes always choose the same candidate.
    func claimNextJob(
        scope: WorkScope? = nil,
        activeStoredSessionID: String? = nil,
        enforceSessionAffinity: Bool = false,
        owner: String,
        now: Date,
        leaseDuration: TimeInterval
    ) throws -> WorkJob? {
        guard !owner.isEmpty, leaseDuration > 0 else { throw WorkRepositoryError.leaseLost }
        let timestamp = now.timeIntervalSince1970
        let leaseExpiry = timestamp + leaseDuration
        var scopeSQL = ""
        var arguments: StatementArguments = [
            owner, leaseExpiry, timestamp, timestamp, timestamp, timestamp,
        ]
        if let scope {
            scopeSQL = " AND server_id = ? AND profile_id = ?"
            arguments += [scope.serverID, scope.profileID]
        }
        var affinitySQL = ""
        if enforceSessionAffinity {
            if let activeStoredSessionID {
                affinitySQL = """
                     AND (
                        kind != 'prompt' OR intent_kind = 'new_session'
                        OR COALESCE(destination_session_id, stored_session_id) IS NULL
                        OR COALESCE(destination_session_id, stored_session_id) = ?
                     )
                    """
                arguments += [activeStoredSessionID]
            } else {
                affinitySQL = """
                     AND (
                        kind != 'prompt' OR intent_kind = 'new_session'
                        OR COALESCE(destination_session_id, stored_session_id) IS NULL
                     )
                    """
            }
        }

        return try database.write { db in
            try WorkJob.fetchOne(
                db,
                sql: """
                    UPDATE work_jobs
                    SET lease_owner = ?, lease_expires_at = ?, updated_at = ?,
                        attempt_count = attempt_count + 1
                    WHERE job_id = (
                        SELECT job_id
                        FROM work_jobs
                        WHERE state IN (
                            'queued', 'creating_destination', 'uploading', 'submitting',
                            'accepted', 'retry_wait'
                        )
                          AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                          AND (lease_owner IS NULL OR lease_expires_at IS NULL OR lease_expires_at <= ?)
                          AND (expires_at IS NULL OR expires_at > ?)
                          \(scopeSQL)
                          \(affinitySQL)
                        ORDER BY created_at ASC, job_id ASC
                        LIMIT 1
                    )
                    RETURNING *
                    """,
                arguments: arguments
            )
        }
    }

    @discardableResult
    func transitionJob(
        id: String,
        from expectedState: WorkJobState,
        to newState: WorkJobState,
        owner: String? = nil,
        now: Date = Date(),
        destinationSessionID: String? = nil,
        nextAttemptAt: Date? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) async throws -> WorkJob {
        guard Self.allowedTransitions[expectedState, default: []].contains(newState) else {
            throw WorkRepositoryError.invalidTransition(from: expectedState, to: newState)
        }

        let timestamp = now.timeIntervalSince1970
        let existing = try await database.write { db -> WorkJob in
            guard var job = try WorkJob.fetchOne(db, key: id) else {
                throw WorkRepositoryError.jobNotFound
            }
            guard job.state == expectedState else {
                throw WorkRepositoryError.invalidTransition(from: job.state, to: newState)
            }
            if let owner, job.leaseOwner != owner {
                throw WorkRepositoryError.leaseLost
            }

            job.state = newState
            job.updatedAt = timestamp
            if let destinationSessionID {
                if let current = job.destinationSessionID, current != destinationSessionID {
                    throw WorkRepositoryError.invalidTransition(from: expectedState, to: newState)
                }
                job.destinationSessionID = destinationSessionID
            }
            job.nextAttemptAt = nextAttemptAt?.timeIntervalSince1970
            job.lastErrorCode = errorCode
            job.lastErrorMessage = errorMessage
            if newState == .accepted { job.acceptedAt = timestamp }
            if newState == .completed { job.completedAt = timestamp }
            try job.update(db)
            return job
        }
        await publishObservation()
        return existing
    }

    func releaseLease(id: String, owner: String, now: Date = Date()) async throws {
        let changed = try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE work_jobs
                    SET lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
                    WHERE job_id = ? AND lease_owner = ?
                    """,
                arguments: [now.timeIntervalSince1970, id, owner]
            )
            return db.changesCount
        }
        guard changed == 1 else { throw WorkRepositoryError.leaseLost }
        await publishObservation()
    }

    func bindScope(jobID: String, scope: WorkScope, now: Date = Date()) async throws -> WorkJob {
        let result = try await database.write { db -> WorkJob in
            guard var job = try WorkJob.fetchOne(db, key: jobID) else {
                throw WorkRepositoryError.jobNotFound
            }
            guard job.state == .waitingForScope, job.scope == nil else {
                throw WorkRepositoryError.invalidTransition(from: job.state, to: .queued)
            }
            job.serverID = scope.serverID
            job.profileID = scope.profileID
            job.state = .queued
            job.updatedAt = now.timeIntervalSince1970
            try job.update(db)
            return job
        }
        await publishObservation()
        return result
    }

    func deleteJob(id: String) async throws {
        let paths = try await database.write { db -> [String] in
            guard try WorkJob.deleteOne(db, key: id) else { return [] }
            return try Self.deleteUnreferencedAssetRows(db)
        }
        removeAssetFiles(paths)
        await publishObservation()
    }

    /// Editing and reordering are intentionally restricted to work that no
    /// processor has claimed. Once a lease exists, immutable payload semantics
    /// (and the server receipt fingerprint) must win over queue UI affordances.
    @discardableResult
    func updateQueuedPrompt(id: String, text: String, now: Date = Date()) async throws -> WorkJob {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkRepositoryError.jobNotFound }
        let result = try await database.write { db -> WorkJob in
            guard var job = try WorkJob.fetchOne(db, key: id) else {
                throw WorkRepositoryError.jobNotFound
            }
            guard job.kind == .prompt, job.state == .queued, job.leaseOwner == nil else {
                throw WorkRepositoryError.invalidTransition(from: job.state, to: job.state)
            }
            job.text = trimmed
            job.payloadHash = Self.payloadHash(
                kind: job.kind,
                intentKind: job.intentKind,
                text: trimmed,
                sourceURL: job.sourceURL,
                comment: job.comment,
                storedSessionID: job.storedSessionID,
                assetHashes: try Self.assetHashes(db, jobID: job.jobID)
            )
            job.updatedAt = now.timeIntervalSince1970
            try job.update(db)
            return job
        }
        await publishObservation()
        return result
    }

    func reorderQueuedPrompts(ids: [String], now: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        try await database.write { db in
            let jobs = try WorkJob.filter(ids.contains(Column("job_id"))).fetchAll(db)
            guard jobs.count == ids.count,
                  jobs.allSatisfy({ $0.kind == .prompt && $0.state == .queued && $0.leaseOwner == nil }) else {
                throw WorkRepositoryError.leaseLost
            }
            let floor = jobs.map(\.createdAt).min() ?? now.timeIntervalSince1970
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE work_jobs SET created_at = ?, updated_at = ? WHERE job_id = ?",
                    arguments: [floor + Double(index) * 0.000_001, now.timeIntervalSince1970, id]
                )
            }
        }
        await publishObservation()
    }

    func restampQueuedPrompts(from oldID: String, to newID: String, now: Date = Date()) async throws {
        guard oldID != newID else { return }
        try await database.write { db in
            let jobs = try WorkJob.fetchAll(
                db,
                sql: """
                SELECT * FROM work_jobs
                WHERE kind = ? AND state = ? AND lease_owner IS NULL AND stored_session_id = ?
                """,
                arguments: [WorkJobKind.prompt.rawValue, WorkJobState.queued.rawValue, oldID]
            )
            for var job in jobs {
                job.storedSessionID = newID
                job.payloadHash = Self.payloadHash(
                    kind: job.kind,
                    intentKind: job.intentKind,
                    text: job.text,
                    sourceURL: job.sourceURL,
                    comment: job.comment,
                    storedSessionID: newID,
                    assetHashes: try Self.assetHashes(db, jobID: job.jobID)
                )
                job.updatedAt = now.timeIntervalSince1970
                try job.update(db)
            }
        }
        await publishObservation()
    }

    @discardableResult
    func retryFailedJob(id: String, now: Date = Date()) async throws -> WorkJob {
        let result = try await database.write { db -> WorkJob in
            guard var job = try WorkJob.fetchOne(db, key: id) else {
                throw WorkRepositoryError.jobNotFound
            }
            guard job.state == .failed else {
                throw WorkRepositoryError.invalidTransition(from: job.state, to: .queued)
            }
            job.state = .queued
            job.nextAttemptAt = nil
            job.lastErrorCode = nil
            job.lastErrorMessage = nil
            job.leaseOwner = nil
            job.leaseExpiresAt = nil
            job.updatedAt = now.timeIntervalSince1970
            try job.update(db)
            return job
        }
        await publishObservation()
        return result
    }

    func cancelJob(id: String, now: Date = Date()) async throws {
        try await database.write { db in
            guard var job = try WorkJob.fetchOne(db, key: id) else { return }
            guard !job.state.isTerminal else { return }
            job.state = .cancelled
            job.leaseOwner = nil
            job.leaseExpiresAt = nil
            job.updatedAt = now.timeIntervalSince1970
            try job.update(db)
        }
        await publishObservation()
    }

    func jobAssets(jobID: String) throws -> [WorkJobAssetSnapshot] {
        try database.read { db in
            let links = try WorkJobAsset
                .filter(Column("job_id") == jobID)
                .order(Column("ordinal"))
                .fetchAll(db)
            return try links.map { link in
                guard let asset = try WorkAsset.fetchOne(db, key: link.assetID) else {
                    throw WorkRepositoryError.assetNotFound
                }
                return WorkJobAssetSnapshot(link: link, asset: asset)
            }
        }
    }

    func updateJobAsset(
        jobID: String,
        ordinal: Int,
        owner: String,
        state: String,
        transferID: String? = nil,
        remotePath: String? = nil
    ) async throws {
        guard ["local", "transferring", "uploaded", "failed"].contains(state) else {
            throw WorkRepositoryError.assetNotFound
        }
        try await database.write { db in
            guard let job = try WorkJob.fetchOne(db, key: jobID), job.leaseOwner == owner else {
                throw WorkRepositoryError.leaseLost
            }
            guard var link = try WorkJobAsset
                .filter(Column("job_id") == jobID)
                .filter(Column("ordinal") == ordinal)
                .fetchOne(db) else { throw WorkRepositoryError.assetNotFound }
            link.state = state
            if let transferID { link.transferID = transferID }
            if let remotePath { link.remotePath = remotePath }
            try link.update(db)
        }
        await publishObservation()
    }

    /// Records a non-accepted server disposition/transport outcome without
    /// deleting the job. Releasing the lease makes a later explicit wake safe;
    /// the stable client id remains untouched.
    func retainPendingJob(
        id: String,
        owner: String,
        status: String,
        message: String? = nil,
        nextAttemptAt: Date? = nil,
        now: Date = Date()
    ) async throws {
        let changed = try await database.write { db -> Int in
            try db.execute(
                sql: """
                    UPDATE work_jobs
                    SET last_error_code = ?, last_error_message = ?, next_attempt_at = ?,
                        lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
                    WHERE job_id = ? AND lease_owner = ?
                    """,
                arguments: [status, message, nextAttemptAt?.timeIntervalSince1970,
                            now.timeIntervalSince1970, id, owner]
            )
            return db.changesCount
        }
        guard changed == 1 else { throw WorkRepositoryError.leaseLost }
        await publishObservation()
    }

    // MARK: - Draft CRUD

    @discardableResult
    func upsertDraft(
        scope: WorkScope,
        contextKey: String,
        storedSessionID: String? = nil,
        text: String,
        cwd: String? = nil,
        modelSelectionJSON: String? = nil,
        now: Date = Date()
    ) async throws -> WorkDraft {
        guard !contextKey.isEmpty else { throw WorkRepositoryError.invalidScope }
        let timestamp = now.timeIntervalSince1970
        let draft = try await database.write { db -> WorkDraft in
            if var existing = try WorkDraft
                .filter(Column("server_id") == scope.serverID)
                .filter(Column("profile_id") == scope.profileID)
                .filter(Column("context_key") == contextKey)
                .fetchOne(db) {
                existing.storedSessionID = storedSessionID
                existing.text = text
                existing.cwd = cwd
                existing.modelSelectionJSON = modelSelectionJSON
                existing.revision += 1
                existing.updatedAt = timestamp
                try existing.update(db)
                return existing
            }
            let created = WorkDraft(
                draftID: UUID().uuidString.lowercased(),
                serverID: scope.serverID,
                profileID: scope.profileID,
                contextKey: contextKey,
                storedSessionID: storedSessionID,
                text: text,
                cwd: cwd,
                modelSelectionJSON: modelSelectionJSON,
                revision: 1,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try created.insert(db)
            return created
        }
        await publishObservation()
        return draft
    }

    func drafts(scope: WorkScope) throws -> [WorkDraft] {
        try database.read { db in
            try WorkDraft
                .filter(Column("server_id") == scope.serverID)
                .filter(Column("profile_id") == scope.profileID)
                .order(Column("updated_at").desc, Column("draft_id"))
                .fetchAll(db)
        }
    }

    func draft(scope: WorkScope, contextKey: String) throws -> WorkDraftSnapshot? {
        try database.read { db in
            guard let draft = try WorkDraft
                .filter(Column("server_id") == scope.serverID)
                .filter(Column("profile_id") == scope.profileID)
                .filter(Column("context_key") == contextKey)
                .fetchOne(db) else { return nil }
            let assets = try WorkAsset.fetchAll(db, sql: """
                SELECT work_assets.* FROM work_assets
                JOIN draft_assets USING (asset_id)
                WHERE draft_assets.draft_id = ? ORDER BY draft_assets.ordinal
                """, arguments: [draft.draftID])
            return WorkDraftSnapshot(draft: draft, assets: assets)
        }
    }

    /// Saves the complete composer state in one transaction. Asset bytes are
    /// copied into protected WorkAssets before their rows become visible.
    @discardableResult
    func saveDraft(
        scope: WorkScope,
        contextKey: String,
        storedSessionID: String?,
        text: String,
        cwd: String?,
        modelSelectionJSON: String?,
        assets: [WorkAssetInput],
        now: Date = Date()
    ) async throws -> WorkDraft? {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && assets.isEmpty
        if isEmpty {
            if let existing = try draft(scope: scope, contextKey: contextKey) {
                try await deleteDraft(id: existing.draft.draftID)
            }
            return nil
        }
        let prepared = try prepareAssets(assets)
        let timestamp = now.timeIntervalSince1970
        do {
            let result = try await database.write { db -> (WorkDraft, [String]) in
                var draft: WorkDraft
                if var existing = try WorkDraft
                    .filter(Column("server_id") == scope.serverID)
                    .filter(Column("profile_id") == scope.profileID)
                    .filter(Column("context_key") == contextKey).fetchOne(db) {
                    existing.storedSessionID = storedSessionID
                    existing.text = text
                    existing.cwd = cwd
                    existing.modelSelectionJSON = modelSelectionJSON
                    existing.revision += 1
                    existing.updatedAt = timestamp
                    try existing.update(db)
                    draft = existing
                } else {
                    draft = WorkDraft(draftID: UUID().uuidString.lowercased(), serverID: scope.serverID,
                        profileID: scope.profileID, contextKey: contextKey, storedSessionID: storedSessionID,
                        text: text, cwd: cwd, modelSelectionJSON: modelSelectionJSON, revision: 1,
                        createdAt: timestamp, updatedAt: timestamp)
                    try draft.insert(db)
                }
                try WorkDraftAsset.filter(Column("draft_id") == draft.draftID).deleteAll(db)
                for (ordinal, item) in prepared.enumerated() {
                    try item.record.insert(db)
                    try WorkDraftAsset(draftID: draft.draftID, assetID: item.record.assetID, ordinal: ordinal).insert(db)
                }
                return (draft, try Self.deleteUnreferencedAssetRows(db))
            }
            removeAssetFiles(result.1)
            await publishObservation()
            return result.0
        } catch {
            removePreparedFiles(prepared)
            throw error
        }
    }

    func assetData(_ asset: WorkAsset) throws -> Data {
        try Data(contentsOf: assetURL(relativePath: asset.relativePath))
    }

    /// Creates the prompt job and acknowledges exactly the revision submitted.
    /// A newer edit remains as a draft; an unchanged revision is cleared.
    func convertDraftToJob(
        draftID: String,
        acknowledgedRevision: Int,
        jobID: UUID = UUID(),
        now: Date = Date()
    ) async throws -> WorkJob {
        let timestamp = now.timeIntervalSince1970
        let result = try await database.write { db -> (WorkJob, [String]) in
            guard let draft = try WorkDraft.fetchOne(db, key: draftID) else { throw WorkRepositoryError.draftNotFound }
            guard draft.revision == acknowledgedRevision else { throw WorkRepositoryError.draftNotFound }
            let links = try WorkDraftAsset.filter(Column("draft_id") == draftID).order(Column("ordinal")).fetchAll(db)
            let input = WorkJobInput(jobID: jobID, kind: .prompt, scope: try WorkScope(serverID: draft.serverID, profileID: draft.profileID), state: .queued, text: draft.text, storedSessionID: draft.storedSessionID, createdAt: now)
            let job = Self.makeJob(input, preparedAssets: [], now: timestamp)
            try job.insert(db)
            for link in links {
                try WorkJobAsset(jobID: job.jobID, assetID: link.assetID, ordinal: link.ordinal, transferID: nil, remotePath: nil, state: "local").insert(db)
            }
            try WorkDraft.deleteOne(db, key: draftID)
            return (job, try Self.deleteUnreferencedAssetRows(db))
        }
        removeAssetFiles(result.1)
        await publishObservation()
        return result.0
    }

    func attachAsset(_ assetID: String, toDraft draftID: String, ordinal: Int) async throws {
        try await database.write { db in
            guard try WorkDraft.fetchOne(db, key: draftID) != nil else {
                throw WorkRepositoryError.draftNotFound
            }
            guard try WorkAsset.fetchOne(db, key: assetID) != nil else {
                throw WorkRepositoryError.assetNotFound
            }
            try WorkDraftAsset(draftID: draftID, assetID: assetID, ordinal: ordinal).insert(db)
        }
        await publishObservation()
    }

    func deleteDraft(id: String) async throws {
        let paths = try await database.write { db -> [String] in
            guard try WorkDraft.deleteOne(db, key: id) else { return [] }
            return try Self.deleteUnreferencedAssetRows(db)
        }
        removeAssetFiles(paths)
        await publishObservation()
    }

    // MARK: - Assets and observations

    func assets(jobID: String) throws -> [WorkAsset] {
        try database.read { db in
            try WorkAsset.fetchAll(
                db,
                sql: """
                    SELECT work_assets.*
                    FROM work_assets
                    JOIN job_assets USING (asset_id)
                    WHERE job_assets.job_id = ?
                    ORDER BY job_assets.ordinal
                    """,
                arguments: [jobID]
            )
        }
    }

    func assetFileExists(relativePath: String) throws -> Bool {
        let url = try assetURL(relativePath: relativePath)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func refreshObservation() async throws {
        await publishObservation()
    }

    // MARK: - Internals

    private struct PreparedAsset: Sendable {
        let record: WorkAsset
        let url: URL
    }

    private static let allowedTransitions: [WorkJobState: Set<WorkJobState>] = [
        .waitingForScope: [.queued, .cancelled, .expired],
        .queued: [.creatingDestination, .uploading, .submitting, .retryWait, .failed, .cancelled, .expired],
        .creatingDestination: [.uploading, .submitting, .retryWait, .failed, .cancelled, .expired],
        .uploading: [.submitting, .retryWait, .failed, .cancelled, .expired],
        .submitting: [.accepted, .retryWait, .failed, .cancelled, .expired],
        .accepted: [.completed],
        .retryWait: [.queued, .creatingDestination, .uploading, .submitting, .failed, .cancelled, .expired],
        .failed: [.queued, .cancelled, .expired],
        .completed: [],
        .cancelled: [],
        .expired: [],
    ]

    private static func makeJob(
        _ input: WorkJobInput,
        preparedAssets: [PreparedAsset],
        now: Double
    ) -> WorkJob {
        let jobID = input.jobID.uuidString.lowercased()
        let assetHashes = preparedAssets.map(\.record.sha256)

        return WorkJob(
            jobID: jobID,
            kind: input.kind,
            clientMessageID: jobID,
            serverID: input.scope?.serverID,
            profileID: input.scope?.profileID,
            state: input.state,
            intentKind: input.intentKind,
            text: input.text,
            sourceURL: input.sourceURL,
            comment: input.comment,
            storedSessionID: input.storedSessionID,
            destinationSessionID: nil,
            payloadHash: Self.payloadHash(
                kind: input.kind,
                intentKind: input.intentKind,
                text: input.text,
                sourceURL: input.sourceURL,
                comment: input.comment,
                storedSessionID: input.storedSessionID,
                assetHashes: assetHashes
            ),
            attemptCount: 0,
            nextAttemptAt: nil,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            leaseOwner: nil,
            leaseExpiresAt: nil,
            expiresAt: input.expiresAt?.timeIntervalSince1970,
            legacyImportKey: input.legacyImportKey,
            createdAt: now,
            updatedAt: now,
            acceptedAt: nil,
            completedAt: nil
        )
    }

    private func prepareAssets(_ inputs: [WorkAssetInput]) throws -> [PreparedAsset] {
        var prepared: [PreparedAsset] = []
        do {
            for input in inputs {
                let ext = input.fileExtension.lowercased()
                guard !ext.isEmpty,
                      ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                    throw WorkRepositoryError.invalidRelativePath
                }
                let assetID = UUID().uuidString.lowercased()
                let relativePath = "\(assetID).\(ext)"
                let url = try assetURL(relativePath: relativePath)
                try input.data.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.protectionKey: Self.protection],
                    ofItemAtPath: url.path
                )
                try Self.protectAndExcludeFromBackup(url)
                let now = Date().timeIntervalSince1970
                prepared.append(PreparedAsset(
                    record: WorkAsset(
                        assetID: assetID,
                        relativePath: relativePath,
                        mimeType: input.mimeType,
                        byteCount: input.data.count,
                        sha256: Self.sha256(input.data),
                        createdAt: now,
                        lastAccessedAt: now
                    ),
                    url: url
                ))
            }
            return prepared
        } catch {
            removePreparedFiles(prepared)
            throw error
        }
    }

    private func assetURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains(".."),
              !relativePath.contains("\\"),
              (relativePath as NSString).pathComponents.count == 1 else {
            throw WorkRepositoryError.invalidRelativePath
        }
        return configuration.assetsDirectoryURL.appendingPathComponent(relativePath)
    }

    private func removePreparedFiles(_ assets: [PreparedAsset]) {
        for asset in assets {
            try? FileManager.default.removeItem(at: asset.url)
        }
    }

    private func removeAssetFiles(_ relativePaths: [String]) {
        for path in relativePaths {
            guard let url = try? assetURL(relativePath: path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeOrphanAssetFiles(now: Date) throws {
        let referenced = try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT relative_path FROM work_assets"))
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: configuration.assetsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt <= now.addingTimeInterval(-Self.orphanAssetGrace),
                  !referenced.contains(url.lastPathComponent) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func deleteExpiredShareRows(_ db: Database, now: Double) throws -> [String] {
        try db.execute(
            sql: """
                DELETE FROM work_jobs
                WHERE kind = 'share' AND expires_at IS NOT NULL AND expires_at <= ?
                  AND (lease_owner IS NULL OR lease_expires_at IS NULL OR lease_expires_at <= ?)
                """,
            arguments: [now, now]
        )
        return try deleteUnreferencedAssetRows(db)
    }

    private static func deleteUnreferencedAssetRows(_ db: Database) throws -> [String] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT relative_path
                FROM work_assets AS asset
                WHERE NOT EXISTS (SELECT 1 FROM job_assets WHERE asset_id = asset.asset_id)
                  AND NOT EXISTS (SELECT 1 FROM draft_assets WHERE asset_id = asset.asset_id)
                """
        )
        let paths = rows.map { $0["relative_path"] as String }
        if !paths.isEmpty {
            try db.execute(
                sql: """
                    DELETE FROM work_assets
                    WHERE NOT EXISTS (SELECT 1 FROM job_assets WHERE asset_id = work_assets.asset_id)
                      AND NOT EXISTS (SELECT 1 FROM draft_assets WHERE asset_id = work_assets.asset_id)
                    """
            )
        }
        return paths
    }

    private func publishObservation() async {
        guard let observation else { return }
        guard let snapshot = try? await database.read({ db in
            WorkRepositorySnapshot(
                jobs: try WorkJob.order(Column("created_at"), Column("job_id")).fetchAll(db),
                drafts: try WorkDraft.order(Column("updated_at").desc).fetchAll(db)
            )
        }) else { return }
        await observation.publish(snapshot)
    }

    private func ensureProtectedDataAvailable() throws {
        guard configuration.protectedDataAvailable() else {
            throw WorkRepositoryError.protectedDataUnavailable
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func payloadHash(
        kind: WorkJobKind,
        intentKind: WorkIntentKind?,
        text: String?,
        sourceURL: String?,
        comment: String?,
        storedSessionID: String?,
        assetHashes: [String]
    ) -> String {
        let payload = [kind.rawValue, intentKind?.rawValue ?? "", text ?? "",
                       sourceURL ?? "", comment ?? "", storedSessionID ?? "",
                       assetHashes.joined(separator: ",")]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return sha256(Data(payload.utf8))
    }

    private static func assetHashes(_ db: Database, jobID: String) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT work_assets.sha256 FROM work_assets
            JOIN job_assets USING (asset_id)
            WHERE job_assets.job_id = ? ORDER BY job_assets.ordinal
            """, arguments: [jobID])
    }

    private static func protectAndExcludeFromBackup(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes(
                [.protectionKey: protection],
                ofItemAtPath: url.path
            )
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func protectSQLiteCompanions(for databaseURL: URL) {
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: databaseURL.path + suffix)
            try? protectAndExcludeFromBackup(companion)
        }
    }
}
