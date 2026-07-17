import Foundation

enum CompactTurnSyncResult: Sendable, Equatable {
    case unsupported
    case available([CompactTurnV1], projectionPending: Bool)
}

/// Capability-gated convergence for the reconstructible compact transcript.
///
/// WorkRepository and the projection cache are separate databases. The server
/// receipt remains `accepted` until `applyCompactTurnPage` commits, then this
/// coordinator completes the matching overlay idempotently.
actor CompactTurnCoordinator {
    private let cache: CacheStore
    private let workRepository: WorkRepository
    private var supportByGateway: [String: Bool] = [:]

    init(cache: CacheStore, workRepository: WorkRepository) {
        self.cache = cache
        self.workRepository = workRepository
    }

    func cachedTurns(
        binding: GatewayLocatorBindingV1,
        profileName: String,
        storedSessionID: String,
        limit: Int = 30
    ) async -> [CompactTurnV1]? {
        guard let authority = Self.authority(binding: binding, profileName: profileName) else {
            return nil
        }
        return try? await cache.loadCompactTurns(
            authority: authority,
            storedSessionID: storedSessionID,
            limit: limit
        )
    }

    func synchronize(
        client: RestClient,
        binding: GatewayLocatorBindingV1,
        profileName: String,
        storedSessionID: String,
        limit: Int = 30
    ) async throws -> CompactTurnSyncResult {
        let supported: Bool
        if let cached = supportByGateway[binding.gatewayID] {
            supported = cached
        } else {
            let capabilities = try await client.mobilePluginCapabilities()
            supported = capabilities.supportsCompactTurns
            supportByGateway[binding.gatewayID] = supported
        }
        guard supported,
              let authority = Self.authority(binding: binding, profileName: profileName) else {
            return .unsupported
        }

        let state = try await cache.compactTurnProjectionState(
            authority: authority,
            storedSessionID: storedSessionID
        )
        let page = try await client.compactTurns(
            storedSessionID: storedSessionID,
            profile: profileName,
            afterRevision: state?.sourceHeadID ?? 0,
            limit: limit
        )
        let committed = try await cache.applyCompactTurnPage(page, authority: authority)
        let workScope = try WorkScope(serverID: binding.normalizedLocator, authority: authority)
        for identity in committed {
            _ = try await workRepository.completeAcceptedProjection(
                scope: workScope,
                clientMessageID: identity.clientMessageID,
                authoritativeTurnID: identity.turnID
            )
        }
        let turns = try await cache.loadCompactTurns(
            authority: authority,
            storedSessionID: storedSessionID,
            limit: limit
        )
        return .available(turns, projectionPending: page.projectionPending)
    }

    func invalidateCapabilities(gatewayID: String? = nil) {
        if let gatewayID {
            supportByGateway[gatewayID] = nil
        } else {
            supportByGateway.removeAll()
        }
    }

    private static func authority(
        binding: GatewayLocatorBindingV1,
        profileName: String
    ) -> AuthorityScopeV1? {
        let normalized = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profile = binding.profileAuthorities.first(where: {
            $0.profileName == normalized || $0.profileID == normalized
        }) else { return nil }
        return try? AuthorityScopeV1(
            gatewayID: binding.gatewayID,
            profileID: profile.profileID,
            authorityEpoch: profile.authorityEpoch
        )
    }
}
