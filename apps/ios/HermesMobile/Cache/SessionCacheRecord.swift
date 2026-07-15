import Foundation
import GRDB

// MARK: - CacheScope
//
// The composite (serverId, profileId) partition key for the session-list +
// transcript cache (P4, decided design 2026-06-08). All scoped cache reads and
// writes are filtered to the ACTIVE scope.
//
//   - serverId  = the trimmed `ConnectionStore.serverURLString` (the saved
//                 gateway base URL — the SAME identity already used for the
//                 Keychain token and `DefaultsKeys.deviceIdsByServer`).
//   - profileId = the NORMALIZED `SessionStore.activeProfile`: blank → "all"
//                 (the canonical aggregate key); "default" and named profiles
//                 keep their literal value.
//
// PROFILE switch (same server) = swap the profileId filter — both profiles
// coexist, isolated, instant-paint preserved. SERVER switch = clear other
// servers' rows + repopulate. serverId is ALWAYS part of the key so dropping
// the server-clear policy later is a one-line change with NO further migration.
struct CacheScope: Sendable, Equatable {
    let serverId: String
    let profileId: String

    /// The canonical aggregate ("all profiles") profile key. Matches
    /// `DefaultsKeys.allProfilesScope`; duplicated here so the cache layer has no
    /// dependency on the store layer's constant.
    static let allProfilesKey = "all"

    /// Build a scope from a raw server URL string and a raw `activeProfile`
    /// value, applying the normalization rules above. A blank/whitespace
    /// `profile` (or the "all" sentinel) collapses to the single canonical
    /// aggregate key so the aggregate scope has exactly one partition.
    init(serverId rawServer: String, profileId rawProfile: String) {
        self.serverId = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProfile = rawProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profileId = trimmedProfile.isEmpty ? Self.allProfilesKey : trimmedProfile
    }

    /// The sentinel scope stamped on legacy rows backfilled by the v2 migration
    /// (which predate scope columns and so cannot be attributed to a real
    /// server/profile). A row with this scope matches no live scope, so it is
    /// inert until overwritten by the next scoped write — the network path
    /// repopulates it. Kept distinct so a legacy row can never masquerade as a
    /// real one.
    static let legacy = CacheScope(serverId: "__legacy__", profileId: "__legacy__")
}

// MARK: - SessionCacheRecord
//
// One row per session (raw, includes cron). The full SessionSummary is stored
// as a JSON blob in `summaryJSON`; only the four SQL-useful fields are promoted
// to real columns for indexed WHERE/ORDER BY. See CONTRACT-OFFLINE-CACHE.md §2.2.

struct SessionCacheRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// SessionSummary.id (stored_session_id; stable across compression chains)
    var id: String
    /// Composite scope key — the server this row belongs to (the trimmed
    /// `ConnectionStore.serverURLString`, the SAME identity already used for the
    /// Keychain token + `deviceIdsByServer` maps). ALWAYS part of the key
    /// (architected so dropping the server-clear policy later is a one-line
    /// change with NO further migration). Nullable in SQL so the v2 ALTER can
    /// backfill legacy rows to a sentinel; non-optional here because every WRITE
    /// after v2 stamps it. See CacheScope + CONTRACT §scope (P4).
    var serverId: String
    /// Composite scope key — the active profile (the normalized
    /// `SessionStore.activeProfile`: blank → "all", else the literal value).
    /// Both profiles on the same server coexist (isolated by this column); a
    /// profile switch is a WHERE-filter swap, not a cache clear.
    var profileId: String
    /// The full SessionSummary, JSON-encoded (round-trips every field incl. profile/source/cwd)
    var summaryJSON: Data
    /// SessionSummary.lastActive — EVICTION + DIRTY key (indexed)
    var lastActive: Double?
    /// SessionSummary.messageCount — DIRTY key
    var messageCount: Int?
    /// "cron" vs human — read-time filter, NOT a cache filter
    var source: String?
    /// Mirror of the row's archived state
    var archived: Bool
    /// Additive; pinned => never evicted (set at P4 wiring)
    var isPinned: Bool
    /// When the user last OPENED this session (touch on open)
    var lastAccessedAt: Double
    /// nil => transcript not yet cached (lazy); set on first save
    var transcriptCachedAt: Double?
    /// Local cursor: max wire `id` persisted for this session (see §3.4)
    var maxMessageId: Int?

    static let databaseTableName = "session_cache"
}

// MARK: - SessionSummary Encodable extension (cache-layer only)
//
// The contract adds Encodable to SessionSummary so the full row round-trips
// inside summaryJSON. SessionSummary is Decodable + Identifiable + Sendable +
// Equatable in ProtocolTypes.swift; we add Encodable here, confined to the
// cache layer. The synthesized Encodable is safe because all stored properties
// are Encodable (String?, Double?, Int?, Bool — all plain Foundation types).

extension SessionSummary: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(messageCount, forKey: .messageCount)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(lastActive, forKey: .lastActive)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(profile, forKey: .profile)
    }

    /// CodingKeys that match the wire's snake_case -> camelCase decode
    /// (JSONDecoder .convertFromSnakeCase maps `last_active` -> `lastActive`, etc.)
    /// We encode with the SAME camelCase keys so the same JSONDecoder round-trips
    /// back on read (no snake_case conversion needed for read since we encode camelCase).
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case preview
        case startedAt
        case messageCount
        case source
        case lastActive
        case cwd
        case profile
    }
}

// MARK: - SessionCacheRecord factory

extension SessionCacheRecord {
    /// Build a new cache record from a live SessionSummary.
    /// `lastAccessedAt` defaults to 0 (the session has never been opened);
    /// callers should pass the current timestamp when the user opens it.
    static func make(
        from summary: SessionSummary,
        scope: CacheScope,
        isPinned: Bool = false,
        lastAccessedAt: Double = 0,
        transcriptCachedAt: Double? = nil,
        maxMessageId: Int? = nil
    ) throws -> SessionCacheRecord {
        let encoder = JSONEncoder()
        // Store with camelCase keys matching the Encodable extension above.
        let data = try encoder.encode(summary)
        return SessionCacheRecord(
            id: summary.id,
            serverId: scope.serverId,
            profileId: scope.profileId,
            summaryJSON: data,
            lastActive: summary.lastActive,
            messageCount: summary.messageCount,
            source: summary.source,
            archived: false,
            isPinned: isPinned,
            lastAccessedAt: lastAccessedAt,
            transcriptCachedAt: transcriptCachedAt,
            maxMessageId: maxMessageId
        )
    }

    /// Decode the embedded SessionSummary back out of summaryJSON.
    func decodeSummary() throws -> SessionSummary {
        let decoder = JSONDecoder()
        return try decoder.decode(SessionSummary.self, from: summaryJSON)
    }
}
