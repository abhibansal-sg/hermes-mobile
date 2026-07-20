import Foundation
import GRDB

// MARK: - ProjectCacheRecord
//
// One row per project in the overview list (the `{id, label, root,
// session_count}` contract), scope-partitioned by (serverId, profileId) exactly
// like `SessionCacheRecord`. `orderIndex` preserves the server's list order so a
// cache-seeded paint matches the network order. See CacheSchema v6.

struct ProjectCacheRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "project_cache"

    var serverId: String
    var profileId: String
    var id: String
    var label: String
    var root: String
    var sessionCount: Int
    var orderIndex: Int
    var updatedAt: Double
}

// MARK: - ProjectSessionCacheRecord
//
// One JSON snapshot of a project's detail session list, keyed by (serverId,
// profileId, projectId). The list is stored whole (a `[SessionSummary]` blob)
// rather than joined out of `session_cache`, because a project's detail rows are
// the SERVER's folded/worktree-hydrated view (`/project-sessions`), which is not
// the same set as the flat Recents cache and must not be recomputed on-device.

struct ProjectSessionCacheRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "project_session_cache"

    var serverId: String
    var profileId: String
    var projectId: String
    var sessionsJSON: Data
    var updatedAt: Double
}
