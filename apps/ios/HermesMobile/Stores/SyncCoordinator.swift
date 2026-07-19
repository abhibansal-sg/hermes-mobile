import Foundation

@MainActor
@Observable
final class SyncCoordinator {
    enum Trigger: Sendable { case launch, foreground, reconnect, pullToRefresh, backgroundPush, backgroundRefresh }

    private(set) var projection: ManifestProjection = .empty
    private let cache: CacheStore
    private let scope: CacheScope
    private let client: RestClient
    private let legacyFallback: @Sendable () async -> Void
    private let transcriptDelta: @Sendable (String) async -> Void
    private let registerPush: @Sendable () async -> Void
    private var inFlight: Task<Void, Never>?
    private var pendingRevision: Int64?

    init(cache: CacheStore, scope: CacheScope, client: RestClient,
         legacyFallback: @escaping @Sendable () async -> Void = {},
         transcriptDelta: @escaping @Sendable (String) async -> Void = { _ in },
         registerPush: @escaping @Sendable () async -> Void = {}) {
        self.cache = cache; self.scope = scope; self.client = client
        self.legacyFallback = legacyFallback; self.transcriptDelta = transcriptDelta; self.registerPush = registerPush
    }

    /// Synchronous-with-respect-to-network first paint: disk is awaited before
    /// the detached recovery request is launched.
    func start() async {
        if let cached = try? await cache.loadManifestProjection(scope: scope) { projection = cached }
        trigger(.launch)
    }

    /// Await one atomic manifest recovery (used by silent/background triggers).
    func synchronize() async -> ManifestProjection? {
        if let cached = try? await cache.loadManifestProjection(scope: scope) {
            projection = cached
        }
        return await recover() ? projection : nil
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

    private func recover() async -> Bool {
        do {
            var pages: [SyncManifestPage] = []
            var cursor = projection.cursor
            repeat {
                let page = try await client.syncManifest(scope: scope, cursor: cursor)
                pages.append(page)
                cursor = page.nextCursor
            } while pages.last?.hasMore == true
            let chain = try ManifestChain(validating: pages)
            let committed = try await cache.applyManifest(chain, scope: scope)
            guard committed.revision >= projection.revision else { return false }
            let priorHeads = projection.transcriptHeads
            projection = committed // exactly one observable assignment
            for (id, head) in committed.transcriptHeads where priorHeads[id] != head {
                Task { await transcriptDelta(id) }
            }
            if chain.deviceRegistered == false { await registerPush() }
            return true
        } catch RestError.badStatus(let code, _) where code == 404 || code == 405 {
            await legacyFallback()
            projection = ManifestProjection(revision: projection.revision, cursor: projection.cursor, sessions: projection.sessions, attention: projection.attention, activeTurns: projection.activeTurns, transcriptHeads: projection.transcriptHeads, capabilities: projection.capabilities, freshness: .partial)
            return false
        } catch {
            // Atomic cache and the last published projection remain untouched.
            return false
        }
    }
}
