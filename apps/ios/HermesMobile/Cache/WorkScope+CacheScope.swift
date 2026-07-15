import Foundation

extension WorkScope {
    /// The only app-side bridge into durable work identity. `CacheScope` owns
    /// Phase-1 normalization; `WorkScope` merely persists its canonical values.
    init(cacheScope: CacheScope) throws {
        try self.init(serverID: cacheScope.serverId, profileID: cacheScope.profileId)
    }
}
