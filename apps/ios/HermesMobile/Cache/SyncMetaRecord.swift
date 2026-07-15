import Foundation
import GRDB

// MARK: - SyncMetaRecord
//
// Singleton-ish KV for sync bookkeeping. Known keys:
//   "sessionList.lastFullFetchAt"  — Unix timestamp of the last full list fetch
//   "eviction.lastRunAt"           — Unix timestamp of the last eviction sweep
//   "schemaVersion"                — fingerprint for the drop-and-rebuild escape hatch
//
// See CONTRACT-OFFLINE-CACHE.md §2.2 and §3.

struct SyncMetaRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// e.g. "sessionList.lastFullFetchAt", "serverCaps.deltaSessions"
    var key: String
    /// Small JSON/string blob
    var value: String

    static let databaseTableName = "sync_meta"
}

// MARK: - Well-known keys

extension SyncMetaRecord {
    enum Key {
        static let sessionListLastFullFetchAt = "sessionList.lastFullFetchAt"
        static let evictionLastRunAt = "eviction.lastRunAt"
        static let schemaVersion = "schemaVersion"
    }
}
