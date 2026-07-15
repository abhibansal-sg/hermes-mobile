import Foundation

/// Frozen hermes-mobile sync-manifest wire envelope. Pages are accumulated and
/// validated in memory before they are handed to the cache transaction.
struct SyncManifestPage: Decodable, Sendable, Equatable {
    let revision: Int64
    let cursor: String
    let nextCursor: String?
    let hasMore: Bool
    let reset: Bool
    let sessions: [SessionSummary]
    let tombstones: [String]
    let attention: [ManifestAttentionItem]
    let activeTurns: [ManifestActiveTurn]
    let transcriptHeads: [String: Int]
    let deviceRegistered: Bool?
    let capabilities: [String]
    let serverTime: Double?

    enum CodingKeys: String, CodingKey {
        case revision, cursor, nextCursor, hasMore, reset, sessions, tombstones
        case attention, activeTurns, transcriptHeads, deviceRegistered, capabilities
        case serverTime = "server_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int64.self, forKey: .revision)
        cursor = try c.decode(String.self, forKey: .cursor)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? nextCursor != nil
        reset = try c.decodeIfPresent(Bool.self, forKey: .reset) ?? false
        sessions = try c.decodeIfPresent([SessionSummary].self, forKey: .sessions) ?? []
        attention = try c.decodeIfPresent([ManifestAttentionItem].self, forKey: .attention) ?? []
        activeTurns = try c.decodeIfPresent([ManifestActiveTurn].self, forKey: .activeTurns) ?? []
        transcriptHeads = try c.decodeIfPresent([String: Int].self, forKey: .transcriptHeads) ?? [:]
        deviceRegistered = try c.decodeIfPresent(Bool.self, forKey: .deviceRegistered)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        serverTime = try c.decodeIfPresent(Double.self, forKey: .serverTime)
        let raw = try c.decodeIfPresent([ManifestTombstone].self, forKey: .tombstones) ?? []
        tombstones = raw.map(\.id)
    }
}

private struct ManifestTombstone: Decodable {
    let id: String
    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            id = value
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
                ?? c.decode(String.self, forKey: .sessionId)
        }
    }
    enum CodingKeys: String, CodingKey { case id, sessionId }
}

struct ManifestAttentionItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let sessionId: String
    let kind: String
    let title: String?
}

struct ManifestActiveTurn: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let sessionId: String
    let state: String?
}

struct ManifestChain: Sendable, Equatable {
    let revision: Int64
    let cursor: String
    let reset: Bool
    let sessions: [SessionSummary]
    let tombstones: Set<String>
    let attention: [ManifestAttentionItem]
    let activeTurns: [ManifestActiveTurn]
    let transcriptHeads: [String: Int]
    let deviceRegistered: Bool?
    let capabilities: Set<String>
    let serverTime: Double?

    init(validating pages: [SyncManifestPage]) throws {
        guard let first = pages.first else { throw ManifestValidationError.emptyChain }
        var expected: String? = nil
        for (index, page) in pages.enumerated() {
            guard page.revision == first.revision else { throw ManifestValidationError.revisionChanged }
            if index > 0, page.cursor != expected { throw ManifestValidationError.brokenCursorChain }
            expected = page.nextCursor
            guard page.hasMore == (page.nextCursor != nil) else { throw ManifestValidationError.invalidPagination }
        }
        guard pages.last?.hasMore == false else { throw ManifestValidationError.incompleteChain }
        revision = first.revision
        cursor = pages.last!.cursor
        reset = first.reset
        sessions = pages.flatMap(\.sessions)
        tombstones = Set(pages.flatMap(\.tombstones))
        attention = pages.flatMap(\.attention)
        activeTurns = pages.flatMap(\.activeTurns)
        transcriptHeads = pages.reduce(into: [:]) { $0.merge($1.transcriptHeads) { _, new in new } }
        deviceRegistered = pages.compactMap(\.deviceRegistered).last
        capabilities = Set(pages.flatMap(\.capabilities))
        serverTime = pages.compactMap(\.serverTime).last
    }
}

enum ManifestValidationError: Error { case emptyChain, revisionChanged, brokenCursorChain, invalidPagination, incompleteChain }

enum ManifestFreshness: Sendable, Equatable { case cached, fresh, partial }

struct ManifestProjection: Sendable, Equatable {
    let revision: Int64
    let cursor: String?
    let sessions: [SessionSummary]
    let attention: [ManifestAttentionItem]
    let activeTurns: [ManifestActiveTurn]
    let transcriptHeads: [String: Int]
    let capabilities: Set<String>
    let freshness: ManifestFreshness
    let lastSyncedAt: Date?

    init(revision: Int64, cursor: String?, sessions: [SessionSummary], attention: [ManifestAttentionItem], activeTurns: [ManifestActiveTurn], transcriptHeads: [String: Int], capabilities: Set<String>, freshness: ManifestFreshness, lastSyncedAt: Date? = nil) {
        self.revision = revision; self.cursor = cursor; self.sessions = sessions
        self.attention = attention; self.activeTurns = activeTurns
        self.transcriptHeads = transcriptHeads; self.capabilities = capabilities
        self.freshness = freshness; self.lastSyncedAt = lastSyncedAt
    }

    static let empty = ManifestProjection(revision: 0, cursor: nil, sessions: [], attention: [], activeTurns: [], transcriptHeads: [:], capabilities: [], freshness: .cached)
}
