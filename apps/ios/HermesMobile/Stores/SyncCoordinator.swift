import Foundation

enum SyncRecoveryOutcome: Sendable, Equatable {
    case applied
    case noChange
    case unsupported
    case failed
}

@MainActor
@Observable
final class SyncCoordinator {
    enum Trigger: Sendable { case launch, foreground, reconnect, pullToRefresh, backgroundPush, backgroundRefresh }
    enum CancellationCheckpoint: Hashable, Sendable {
        case afterPageFetch
        case beforeStage
        case beforeCommit
    }

    private(set) var projection: ManifestProjection = .empty
    private let cache: CacheStore
    private let scope: CacheScope
    private let manifestScope: String
    private let client: RestClient
    private let legacyFallback: @Sendable () async -> Void
    private let transcriptDelta: @Sendable (String) async -> Void
    private let registerPush: @Sendable () async -> Void
    private let authorityTransition: @Sendable (GatewayLocatorBindingV1, ManifestAuthorityTransition) async -> Void
    private let cancellationCheckpoint: (@Sendable (CancellationCheckpoint) async -> Void)?
    private var inFlight: Task<Void, Never>?
    private var pendingRevision: Int64?

    init(cache: CacheStore, scope: CacheScope, manifestScope: String, client: RestClient,
         legacyFallback: @escaping @Sendable () async -> Void = {},
         transcriptDelta: @escaping @Sendable (String) async -> Void = { _ in },
         registerPush: @escaping @Sendable () async -> Void = {},
         authorityTransition: @escaping @Sendable (
             GatewayLocatorBindingV1,
             ManifestAuthorityTransition
         ) async -> Void = { _, _ in },
         cancellationCheckpoint: (@Sendable (CancellationCheckpoint) async -> Void)? = nil) {
        self.cache = cache; self.scope = scope; self.manifestScope = manifestScope; self.client = client
        self.legacyFallback = legacyFallback; self.transcriptDelta = transcriptDelta; self.registerPush = registerPush
        self.authorityTransition = authorityTransition; self.cancellationCheckpoint = cancellationCheckpoint
    }

    /// Synchronous-with-respect-to-network first paint: disk is awaited before
    /// the detached recovery request is launched.
    func start() async {
        if let cached = try? await cache.loadManifestProjection(
            locator: scope.serverId,
            manifestScope: manifestScope
        ) {
            projection = cached
        }
        trigger(.launch)
    }

    /// Awaitable entry point used by foreground, silent-push, and BG refresh
    /// orchestration. A fresh coordinator may be created from the current
    /// authenticated REST client; durable resume state still comes from GRDB.
    @discardableResult
    func synchronizeNow() async -> SyncRecoveryOutcome {
        if let cached = try? await cache.loadManifestProjection(
            locator: scope.serverId,
            manifestScope: manifestScope
        ) {
            projection = cached
        }
        return await recover()
    }

    func trigger(_ trigger: Trigger, invalidationRevision: Int64? = nil) {
        if inFlight != nil {
            if let invalidationRevision, invalidationRevision > (pendingRevision ?? projection.revision) { pendingRevision = invalidationRevision }
            return
        }
        inFlight = Task { [weak self] in
            _ = await self?.recover()
            guard let self else { return }
            self.inFlight = nil
            if let pending = self.pendingRevision, pending > self.projection.revision {
                self.pendingRevision = nil
                self.trigger(.reconnect, invalidationRevision: pending)
            }
        }
    }

    private func recover() async -> SyncRecoveryOutcome {
        do {
            var continuationCursor: String?
            var resumeCursor = projection.cursor
            var seenCursors: Set<String> = []
            var encodedBytes = 0
            var entityCount = 0
            var pageIndex = 0
            var stagedSnapshotID: String?
            var finalDeviceRegistered: Bool?
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            do {
                repeat {
                    try Task.checkCancellation()
                    guard pageIndex < 100,
                          encodedBytes <= 16 * 1024 * 1024,
                          entityCount <= 50_000,
                          ContinuousClock.now < deadline else {
                        throw ManifestFetchLimitError.limitExceeded
                    }
                    let response = try await client.syncManifest(
                        scope: manifestScope,
                        resumeCursor: continuationCursor == nil ? resumeCursor : nil,
                        continuationCursor: continuationCursor,
                        limit: 500
                    )
                    try Task.checkCancellation()
                    if let cancellationCheckpoint {
                        await cancellationCheckpoint(.afterPageFetch)
                    }
                    try Task.checkCancellation()
                    let page = response.page
                    if let stagedSnapshotID {
                        guard stagedSnapshotID == page.snapshotID else {
                            throw ManifestFetchLimitError.snapshotChanged
                        }
                    } else {
                        stagedSnapshotID = page.snapshotID
                    }
                    try Task.checkCancellation()
                    if let cancellationCheckpoint {
                        await cancellationCheckpoint(.beforeStage)
                    }
                    try Task.checkCancellation()
                    try await cache.stageManifestPage(
                        response,
                        locator: scope.serverId,
                        pageIndex: pageIndex
                    )
                    pageIndex += 1
                    encodedBytes += response.encodedByteCount
                    entityCount += page.sessions.upserts.count + page.sessions.tombstones.count
                    guard encodedBytes <= 16 * 1024 * 1024, entityCount <= 50_000 else {
                        throw ManifestFetchLimitError.limitExceeded
                    }
                    if page.complete {
                        finalDeviceRegistered = page.pushRegistry?.deviceRegistered
                        break
                    }
                    guard let next = page.continuationCursor,
                          seenCursors.insert(next).inserted else {
                        throw ManifestFetchLimitError.cursorCycle
                    }
                    continuationCursor = next
                    resumeCursor = nil
                } while true
            } catch {
                if let stagedSnapshotID {
                    try? await cache.discardStagedManifest(snapshotID: stagedSnapshotID)
                }
                throw error
            }
            guard let stagedSnapshotID else { throw ManifestBindingError.invalidStage }
            try Task.checkCancellation()
            if let cancellationCheckpoint {
                await cancellationCheckpoint(.beforeCommit)
            }
            try Task.checkCancellation()
            let result: ManifestCommitResult
            do {
                result = try await cache.commitStagedManifest(
                    snapshotID: stagedSnapshotID,
                    locator: scope.serverId,
                    expectedPageCount: pageIndex
                )
            } catch {
                try? await cache.discardStagedManifest(snapshotID: stagedSnapshotID)
                throw error
            }
            let committed = result.projection
            if committed.gatewayID == projection.gatewayID,
               committed.journalEpoch == projection.journalEpoch,
               committed.revision < projection.revision {
                return .noChange
            }
            let priorProjection = projection
            let priorHeads = priorProjection.transcriptHeads
            projection = committed // exactly one observable assignment
            await authorityTransition(result.binding, result.transition)
            for (id, head) in committed.transcriptHeads where priorHeads[id] != head {
                Task { await transcriptDelta(id) }
            }
            if finalDeviceRegistered == false { await registerPush() }
            return committed != priorProjection ? .applied : .noChange
        } catch RestError.badStatus(let code, _) where code == 404 || code == 405 {
            await legacyFallback()
            projection = ManifestProjection(
                gatewayID: projection.gatewayID,
                journalEpoch: projection.journalEpoch,
                profileAuthorities: projection.profileAuthorities,
                revision: projection.revision,
                cursor: projection.cursor,
                sessions: projection.sessions,
                attention: projection.attention,
                activeTurns: projection.activeTurns,
                transcriptHeads: projection.transcriptHeads,
                capabilities: projection.capabilities,
                freshness: .partial,
                lastSyncedAt: projection.lastSyncedAt
            )
            return .unsupported
        } catch {
            // Atomic cache and the last published projection remain untouched.
            return .failed
        }
    }
}

private enum ManifestFetchLimitError: Error {
    case limitExceeded
    case cursorCycle
    case snapshotChanged
}
