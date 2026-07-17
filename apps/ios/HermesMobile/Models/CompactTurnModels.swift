import Foundation

struct MobilePluginCapabilitiesV1: Decodable, Sendable, Equatable {
    let schemaVersion: Int
    let syncManifest: Int
    let turnProjection: Int
    let turnDetail: Int
    let stableAssets: Int
    let conditionalMutations: Int

    var supportsCompactTurns: Bool {
        schemaVersion == 1 && turnProjection >= 1
    }
}

struct CompactTurnPageV1: Decodable, Sendable, Equatable {
    let schemaVersion: Int
    let projectionVersion: Int
    let storedSessionID: String
    let sourceHeadID: Int64
    let coverageComplete: Bool
    let projectionPending: Bool
    let reset: Bool
    let turns: [CompactTurnV1]
    let tombstones: [CompactTurnTombstoneV1]
    let previousCursor: String?
    let hasOlder: Bool
}

struct CompactTurnV1: Decodable, Sendable, Equatable, Identifiable {
    let turnID: String
    let clientMessageID: String?
    let inputs: [CompactTurnInputV1]
    let state: String
    let acceptedAt: Double
    let startedAt: Double?
    let completedAt: Double?
    let elapsedMs: Int64?
    let timingQuality: String
    let authorityState: String
    let serverRevision: Int64
    let final: CompactTurnFinalV1?
    let activityGroups: [CompactTurnActivityGroupV1]

    var id: String { turnID }
}

struct CompactTurnInputV1: Codable, Sendable, Equatable, Identifiable {
    let inputID: String
    let clientMessageID: String?
    let ordinal: Int
    let inputKind: String
    let content: JSONValue
    let createdAt: Double

    var id: String { inputID }
}

struct CompactTurnFinalV1: Codable, Sendable, Equatable {
    let messageID: String
    let content: JSONValue
    let createdAt: Double
}

struct CompactTurnActivityGroupV1: Codable, Sendable, Equatable, Identifiable {
    let groupID: String
    let ordinal: Int
    let category: String
    let displayLabel: String
    let operationCount: Int
    let state: String
    let startedAt: Double?
    let completedAt: Double?
    let detailAvailable: Bool

    var id: String { groupID }
}

struct CompactTurnTombstoneV1: Decodable, Sendable, Equatable {
    let turnID: String
    let state: String
    let serverRevision: Int64
    let deletedAt: Double
}

struct CompactTurnProjectionStateV1: Sendable, Equatable {
    let sourceHeadID: Int64
    let previousCursor: String?
    let hasOlder: Bool
    let coverageComplete: Bool
}
