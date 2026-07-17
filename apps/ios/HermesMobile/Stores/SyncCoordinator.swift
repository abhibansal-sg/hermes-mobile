import Foundation

@MainActor
@Observable
final class SyncCoordinator {
    enum Trigger: Sendable { case launch, foreground, reconnect, pullToRefresh, backgroundPush, backgroundRefresh }

    private(set) var projection: ManifestProjection = .empty
    private let cache: CacheStore
    private let scope: CacheScope
    private let manifestScope: String
    private let client: RestClient
    private let legacyFallback: @Sendable () async -> Void
    private let transcriptDelta: @Sendable (String) async -> Void
    private let registerPush: @Sendable () async -> Void
    private var inFlight: Task<Void, Never>?
    private var pendingRevision: Int64?

    init(cache: CacheStore, scope: CacheScope, manifestScope: String, client: RestClient,
         legacyFallback: @escaping @Sendable () async -> Void = {},
         transcriptDelta: @escaping @Sendable (String) async -> Void = { _ in },
         registerPush: @escaping @Sendable () async -> Void = {}) {
        self.cache = cache; self.scope = scope; self.manifestScope = manifestScope; self.client = client
        self.legacyFallback = legacyFallback; self.transcriptDelta = transcriptDelta; self.registerPush = registerPush
    }

    /// Synchronous-with-respect-to-network first paint: disk is awaited before
    /// the detached recovery request is launched.
    func start() async {
        if let cached = try? await cache.loadManifestProjection(scope: scope) { projection = cached }
        trigger(.launch)
    }

    func trigger(_ trigger: Trigger, invalidationRevision: Int64? = nil) {
        if inFlight != nil {
            if let invalidationRevision, invalidationRevision > (pendingRevision ?? projection.revision) { pendingRevision = invalidationRevision }
            return
        }
        inFlight = Task { [weak self] in
            await self?.recover()
            guard let self else { return }
            self.inFlight = nil
            if let pending = self.pendingRevision, pending > self.projection.revision {
                self.pendingRevision = nil
                self.trigger(.reconnect, invalidationRevision: pending)
            }
        }
    }

    private func recover() async {
        do {
            var pages: [SyncManifestPage] = []
            var continuationCursor: String?
            var resumeCursor = projection.cursor
            var seenCursors: Set<String> = []
            var encodedBytes = 0
            var entityCount = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            repeat {
                try Task.checkCancellation()
                guard pages.count < 100,
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
                let page = response.page
                pages.append(page)
                encodedBytes += response.encodedByteCount
                entityCount += page.sessions.upserts.count + page.sessions.tombstones.count
                guard encodedBytes <= 16 * 1024 * 1024, entityCount <= 50_000 else {
                    throw ManifestFetchLimitError.limitExceeded
                }
                if page.complete { break }
                guard let next = page.continuationCursor,
                      seenCursors.insert(next).inserted else {
                    throw ManifestFetchLimitError.cursorCycle
                }
                continuationCursor = next
                resumeCursor = nil
            } while true
            let chain = try ManifestChain(validating: pages)
            let committed = try await cache.applyManifest(chain, scope: scope)
            guard committed.revision >= projection.revision else { return }
            let priorHeads = projection.transcriptHeads
            projection = committed // exactly one observable assignment
            for (id, head) in committed.transcriptHeads where priorHeads[id] != head {
                Task { await transcriptDelta(id) }
            }
            if chain.deviceRegistered == false { await registerPush() }
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
        } catch {
            // Atomic cache and the last published projection remain untouched.
        }
    }
}

private enum ManifestFetchLimitError: Error {
    case limitExceeded
    case cursorCycle
}
