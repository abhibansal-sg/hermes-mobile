import Foundation

struct SyncManifestHTTPPage: Sendable, Equatable {
    let page: SyncManifestPage
    let encodedByteCount: Int
}

/// Exact schema-v2 hermes-mobile manifest envelope.
struct SyncManifestPage: Decodable, Sendable, Equatable {
    let schemaVersion: Int
    let gatewayID: String
    let profileAuthorities: [ManifestProfileAuthority]
    let journalEpoch: String
    let complete: Bool
    let revision: Int64
    let snapshotID: String
    let pageSize: Int
    let scope: String
    let continuationCursor: String?
    let resumeCursor: String?
    let reset: Bool
    let resetReason: String?
    let serverTime: Double
    let sessions: ManifestSessionDelta
    let pendingAttention: [ManifestAttentionItem]?
    let runtimeSnapshot: ManifestRuntimeSnapshot?
    let transcriptHeads: [ManifestTranscriptHead]?
    let widgetSummary: ManifestWidgetSummary?
    let pushRegistry: ManifestPushRegistry?
}

struct ManifestProfileAuthority: Codable, Sendable, Equatable, Hashable {
    let profileID: String
    let profileName: String
    let authorityEpoch: String
}

struct ManifestSessionDelta: Decodable, Sendable, Equatable {
    let upserts: [ManifestSessionUpsert]
    let tombstones: [ManifestSessionTombstone]
}

struct ManifestSessionUpsert: Decodable, Sendable, Equatable {
    let summary: SessionSummary
    let profileID: String
    let authorityEpoch: String
    let entityRevision: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(String.self, forKey: .profileID)
        authorityEpoch = try container.decode(String.self, forKey: .authorityEpoch)
        entityRevision = try container.decode(Int64.self, forKey: .entityRevision)
        summary = try SessionSummary(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case profileID
        case authorityEpoch
        case entityRevision
    }
}

struct ManifestSessionTombstone: Decodable, Sendable, Equatable, Hashable {
    let sessionID: String
    let profileID: String
    let authorityEpoch: String
    let entityRevision: Int64
    let deletedAt: Double
    let reason: String
}

struct ManifestAttentionItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let sessionID: String
    let storedSessionID: String?
    let profileID: String
    let authorityEpoch: String
    let kind: String
    let safeTitle: String?
    let status: String?
    let entityRevision: Int64

    var sessionId: String { storedSessionID ?? sessionID }
    var title: String? { safeTitle }
}

struct ManifestActiveTurn: Codable, Sendable, Equatable, Identifiable {
    let sessionID: String
    let storedSessionID: String?
    let profileID: String
    let authorityEpoch: String
    let state: String?
    let startedAt: Double?

    var id: String { storedSessionID ?? sessionID }
    var sessionId: String { storedSessionID ?? sessionID }
}

struct ManifestRuntimeSnapshot: Codable, Sendable, Equatable {
    let runtimeInstanceID: String
    let sequence: Int64
    let capturedAt: Double
    let activeTurns: [ManifestActiveTurn]
}

struct ManifestTranscriptHead: Codable, Sendable, Equatable {
    let sessionID: String
    let profileID: String
    let authorityEpoch: String
    let maxMessageID: Int?
    let messageCount: Int
    let lastMessageAt: Double?
    let entityRevision: Int64
}

struct ManifestWidgetSummary: Codable, Sendable, Equatable {
    let openSessionCount: Int
    let activeTurnCount: Int
    let pendingAttentionCount: Int
    let tokensToday: Int?
    let estimatedCostToday: Double?
}

struct ManifestPushRegistry: Codable, Sendable, Equatable {
    let deviceRegistered: Bool
}

struct ManifestChain: Sendable, Equatable {
    let gatewayID: String
    let journalEpoch: String
    let profileAuthorities: [ManifestProfileAuthority]
    let revision: Int64
    let snapshotID: String
    let scope: String
    let cursor: String
    let reset: Bool
    let resetReason: String?
    let sessionUpserts: [ManifestSessionUpsert]
    let tombstoneRecords: [ManifestSessionTombstone]
    let sessions: [SessionSummary]
    let tombstones: Set<String>
    let attention: [ManifestAttentionItem]
    let activeTurns: [ManifestActiveTurn]
    let transcriptHeads: [String: Int]
    let runtimeSnapshot: ManifestRuntimeSnapshot
    let deviceRegistered: Bool?
    let capabilities: Set<String>
    let serverTime: Double?

    init(validating pages: [SyncManifestPage]) throws {
        guard let first = pages.first else { throw ManifestValidationError.emptyChain }
        guard first.schemaVersion == 2 else { throw ManifestValidationError.unsupportedSchema }
        guard first.gatewayID.hasPrefix("gw_"), first.journalEpoch.hasPrefix("je_"),
              first.snapshotID.hasPrefix("ms_"), first.pageSize > 0 else {
            throw ManifestValidationError.invalidIdentity
        }
        let authorities = first.profileAuthorities
        guard !authorities.isEmpty,
              authorities == authorities.sorted(by: { $0.profileID < $1.profileID }),
              Set(authorities.map(\.profileID)).count == authorities.count,
              authorities.allSatisfy({
                  $0.profileID.hasPrefix("pf_") && $0.authorityEpoch.hasPrefix("ae_")
              }) else {
            throw ManifestValidationError.invalidAuthorityMap
        }
        let authorityMap = Dictionary(
            uniqueKeysWithValues: authorities.map { ($0.profileID, $0.authorityEpoch) }
        )

        for (index, page) in pages.enumerated() {
            guard page.schemaVersion == first.schemaVersion else {
                throw ManifestValidationError.unsupportedSchema
            }
            guard page.gatewayID == first.gatewayID,
                  page.journalEpoch == first.journalEpoch,
                  page.profileAuthorities == authorities else {
                throw ManifestValidationError.authorityChanged
            }
            guard page.revision == first.revision else {
                throw ManifestValidationError.revisionChanged
            }
            guard page.snapshotID == first.snapshotID,
                  page.pageSize == first.pageSize,
                  page.scope == first.scope,
                  page.reset == first.reset,
                  page.resetReason == first.resetReason else {
                throw ManifestValidationError.pageContractChanged
            }
            let isLast = index == pages.count - 1
            if page.complete {
                guard isLast, page.continuationCursor == nil,
                      page.resumeCursor?.isEmpty == false,
                      page.pendingAttention != nil,
                      page.runtimeSnapshot != nil,
                      page.transcriptHeads != nil,
                      page.widgetSummary != nil,
                      page.pushRegistry != nil else {
                    throw ManifestValidationError.invalidPagination
                }
            } else {
                guard !isLast, page.continuationCursor?.isEmpty == false,
                      page.resumeCursor == nil,
                      page.pendingAttention == nil,
                      page.runtimeSnapshot == nil,
                      page.transcriptHeads == nil,
                      page.widgetSummary == nil,
                      page.pushRegistry == nil else {
                    throw ManifestValidationError.invalidPagination
                }
            }
            guard page.sessions.upserts.count + page.sessions.tombstones.count <= page.pageSize else {
                throw ManifestValidationError.pageLimitExceeded
            }
            for item in page.sessions.upserts {
                guard authorityMap[item.profileID] == item.authorityEpoch else {
                    throw ManifestValidationError.entityAuthorityMismatch
                }
            }
            for item in page.sessions.tombstones {
                guard authorityMap[item.profileID] == item.authorityEpoch else {
                    throw ManifestValidationError.entityAuthorityMismatch
                }
            }
        }
        guard pages.last?.complete == true else { throw ManifestValidationError.incompleteChain }
        guard first.reset == (first.resetReason != nil) else {
            throw ManifestValidationError.invalidReset
        }

        let final = pages[pages.count - 1]
        let attention = final.pendingAttention ?? []
        let runtime = final.runtimeSnapshot!
        let heads = final.transcriptHeads ?? []
        guard attention.allSatisfy({ authorityMap[$0.profileID] == $0.authorityEpoch }),
              runtime.activeTurns.allSatisfy({ authorityMap[$0.profileID] == $0.authorityEpoch }),
              heads.allSatisfy({ authorityMap[$0.profileID] == $0.authorityEpoch }) else {
            throw ManifestValidationError.entityAuthorityMismatch
        }

        let upserts = pages.flatMap(\.sessions.upserts)
        let deleted = pages.flatMap(\.sessions.tombstones)
        gatewayID = first.gatewayID
        journalEpoch = first.journalEpoch
        profileAuthorities = authorities
        revision = first.revision
        snapshotID = first.snapshotID
        scope = first.scope
        cursor = final.resumeCursor!
        reset = first.reset
        resetReason = first.resetReason
        sessionUpserts = upserts
        tombstoneRecords = deleted
        sessions = upserts.map(\.summary)
        tombstones = Set(deleted.map(\.sessionID))
        self.attention = attention
        activeTurns = runtime.activeTurns
        transcriptHeads = Dictionary(
            heads.compactMap { head in
                head.maxMessageID.map { (head.sessionID, $0) }
            },
            uniquingKeysWith: { _, new in new }
        )
        runtimeSnapshot = runtime
        deviceRegistered = final.pushRegistry?.deviceRegistered
        capabilities = ["sync_manifest_v2"]
        serverTime = final.serverTime
    }
}

enum ManifestValidationError: Error, Equatable {
    case emptyChain
    case unsupportedSchema
    case invalidIdentity
    case invalidAuthorityMap
    case revisionChanged
    case authorityChanged
    case pageContractChanged
    case invalidPagination
    case incompleteChain
    case pageLimitExceeded
    case entityAuthorityMismatch
    case invalidReset
}

enum ManifestFreshness: Sendable, Equatable { case cached, fresh, partial }

struct ManifestProjection: Sendable, Equatable {
    let gatewayID: String?
    let journalEpoch: String?
    let profileAuthorities: [ManifestProfileAuthority]
    let revision: Int64
    let cursor: String?
    let sessions: [SessionSummary]
    let attention: [ManifestAttentionItem]
    let activeTurns: [ManifestActiveTurn]
    let transcriptHeads: [String: Int]
    let capabilities: Set<String>
    let freshness: ManifestFreshness
    let lastSyncedAt: Date?

    init(
        gatewayID: String? = nil,
        journalEpoch: String? = nil,
        profileAuthorities: [ManifestProfileAuthority] = [],
        revision: Int64,
        cursor: String?,
        sessions: [SessionSummary],
        attention: [ManifestAttentionItem],
        activeTurns: [ManifestActiveTurn],
        transcriptHeads: [String: Int],
        capabilities: Set<String>,
        freshness: ManifestFreshness,
        lastSyncedAt: Date? = nil
    ) {
        self.gatewayID = gatewayID
        self.journalEpoch = journalEpoch
        self.profileAuthorities = profileAuthorities
        self.revision = revision
        self.cursor = cursor
        self.sessions = sessions
        self.attention = attention
        self.activeTurns = activeTurns
        self.transcriptHeads = transcriptHeads
        self.capabilities = capabilities
        self.freshness = freshness
        self.lastSyncedAt = lastSyncedAt
    }

    static let empty = ManifestProjection(
        revision: 0,
        cursor: nil,
        sessions: [],
        attention: [],
        activeTurns: [],
        transcriptHeads: [:],
        capabilities: [],
        freshness: .cached
    )
}
