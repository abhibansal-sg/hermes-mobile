import Foundation
import GRDB
import CryptoKit

struct RelayV2WireFrame: Codable, Equatable, Sendable {
    let sessionID: String
    let turnID: String?
    let kind: String
    let body: JSONValue

    enum CodingKeys: String, CodingKey {
        case sessionID = "sid"
        case turnID = "turn"
        case kind, body
    }
}

struct RelayV2FrameBatch: Codable, Equatable, Sendable {
    let streamID: String
    let firstSequence: Int64
    let frames: [RelayV2WireFrame]

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case firstSequence = "first_seq"
        case frames
    }
}

private struct RelayV2FullWireItem: Codable {
    let itemID: String
    let sessionID: String
    let turnID: String?
    let type: String
    let status: String
    let ordinal: Int
    let revision: Int64
    let summary: String
    let body: JSONValue

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case type, status
        case ordinal = "ord"
        case revision = "rev"
        case summary, body
    }
}

private struct RelayV2DeltaWire: Codable {
    struct Operation: Codable {
        let operation: String
        let path: String
        let offset: Int
        let data: String
        enum CodingKeys: String, CodingKey {
            case operation = "op"
            case path, offset, data
        }
    }
    let itemID: String
    let fromRevision: Int64
    let toRevision: Int64
    let operations: [Operation]
    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case fromRevision = "from_rev"
        case toRevision = "to_rev"
        case operations = "ops"
    }
}

private struct RelayV2CheckpointWire: Codable {
    struct Tombstone: Codable {
        let itemID: String
        let deletedAtRevision: Int64
        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case deletedAtRevision = "deleted_at_revision"
        }
    }
    let streamID: String
    let throughSequence: Int64
    let sessionID: String
    let snapshotRevision: Int64
    let replace: Bool
    let items: [RelayV2FullWireItem]
    let tombstones: [Tombstone]
    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case throughSequence = "through_seq"
        case sessionID = "session_id"
        case snapshotRevision = "snapshot_revision"
        case replace, items, tombstones
    }
}

private enum RelayV2CheckpointApplication: Equatable {
    case applied
    case duplicate
    case stale
}

/// A text append that became durable in the same WAL transaction as its stream
/// watermark. The client uses this narrow result to update only the affected
/// rendered part instead of rebuilding an entire session for every delta.
struct RelayV2CommittedTextDelta: Equatable, Sendable {
    let sessionID: String
    let itemID: String
    let fromRevision: Int64
    let toRevision: Int64
    let data: String
}

struct RelayV2DatabaseApplyResult: Equatable, Sendable {
    let committedTextDeltas: [RelayV2CommittedTextDelta]
}

private struct RelayV2StoredTextChunk: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "relay_v2_item_text_chunks"

    let accountID: String
    let sessionID: String
    let itemID: String
    let fromRevision: Int64
    let throughRevision: Int64
    let utf8Count: Int64
    let text: String
    let createdAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case sessionID = "session_id"
        case itemID = "item_id"
        case fromRevision = "from_revision"
        case throughRevision = "through_revision"
        case utf8Count = "utf8_count"
        case text
        case createdAtMilliseconds = "created_at_ms"
    }
}

private struct RelayV2TextItemKey: Hashable {
    let sessionID: String
    let itemID: String
}

private struct RelayV2PendingTextAppend {
    let key: RelayV2TextItemKey
    let fromRevision: Int64
    var throughRevision: Int64
    var currentUTF8Offset: Int64
    var pieces: [String]
}

struct RelayV2StoredItem: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "relay_v2_items"

    let accountID: String
    let sessionID: String
    let itemID: String
    var turnID: String?
    var ordinal: Int
    var summary: String?
    var sortSequence: Int64?
    var revision: Int64
    var itemType: String
    var bodyJSON: Data
    /// Materialized UTF-8 byte end of `/body/text`, including append chunks.
    /// Kept on the item row so each new delta validates its offset in O(1).
    var textUTF8End: Int64
    var status: String
    var localOptimistic: Bool
    var updatedAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case sessionID = "session_id"
        case itemID = "item_id"
        case turnID = "turn_id"
        case ordinal = "ordinal"
        case summary
        case sortSequence = "sort_sequence"
        case revision
        case itemType = "item_type"
        case bodyJSON = "body_json"
        case textUTF8End = "text_utf8_end"
        case status
        case localOptimistic = "local_optimistic"
        case updatedAtMilliseconds = "updated_at_ms"
    }

    var body: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: bodyJSON) }

    var chatItem: ChatItem {
        ChatItem(
            itemID: itemID,
            type: ChatItemType(wire: itemType),
            rawType: itemType,
            status: ChatItemStatus(wire: status),
            ord: ordinal,
            summary: summary,
            body: body ?? .null
        )
    }
}

struct RelayV2StoredEvent: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "relay_v2_events"
    let accountID: String
    let streamID: String
    let sequence: Int64
    let sessionID: String
    let turnID: String?
    let kind: String
    let bodyJSON: Data
    let receivedAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case streamID = "stream_id"
        case sequence = "seq"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case kind
        case bodyJSON = "body_json"
        case receivedAtMilliseconds = "received_at_ms"
    }

    var body: JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: bodyJSON)) ?? .object([:]) }
}

struct RelayV2StreamState: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "relay_v2_streams"

    let accountID: String
    let streamID: String
    var throughSequence: Int64
    var updatedAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case streamID = "stream_id"
        case throughSequence = "through_seq"
        case updatedAtMilliseconds = "updated_at_ms"
    }
}

struct RelayV2ControlOutboxRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "relay_v2_control_outbox"
    let accountID: String
    let controlKind: String
    let stableKey: String
    let envelopeJSON: Data
    let createdAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case controlKind = "control_kind"
        case stableKey = "stable_key"
        case envelopeJSON = "envelope_json"
        case createdAtMilliseconds = "created_at_ms"
    }
}

/// Terminal account-level revocation. This row deliberately has no foreign-key
/// relationship to `relay_v2_accounts`: deleting or reconstructing account
/// metadata must never resurrect a credential that the Agent or Hub revoked.
struct RelayV2AccountRevocationRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "relay_v2_account_revocations"

    let accountID: String
    let revokedAtMilliseconds: Int64
    let source: String
    let messageID: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case revokedAtMilliseconds = "revoked_at_ms"
        case source
        case messageID = "message_id"
    }
}

struct RelayV2DatabaseConfiguration: Sendable {
    static let databaseName = "hermes_relay_v2.sqlite"
    let databaseURL: URL

    init(containerURL: URL) {
        self.databaseURL = containerURL.appendingPathComponent(Self.databaseName)
    }

    static func appGroup() throws -> RelayV2DatabaseConfiguration {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) else {
            throw RelayV2ProtocolError.transport("Relay app-group storage is unavailable")
        }
        return RelayV2DatabaseConfiguration(containerURL: container)
    }
}

actor RelayV2Database {
    let pool: DatabasePool

    init(configuration: RelayV2DatabaseConfiguration) throws {
        try FileManager.default.createDirectory(
            at: configuration.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        self.pool = try DatabasePool(path: configuration.databaseURL.path, configuration: config)
        try Self.makeMigrator().migrate(pool)
        try? (configuration.databaseURL as NSURL).setResourceValue(
            true, forKey: .isExcludedFromBackupKey
        )
    }

    static func inMemory() throws -> RelayV2Database {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-v2-\(UUID().uuidString)", isDirectory: true)
        return try RelayV2Database(configuration: .init(containerURL: directory))
    }

    func registerAccount(
        accountID: String,
        localDeviceID: String,
        agentRouteID: String,
        deviceRouteID: String,
        currentKeyGeneration: UInt32,
        nowMilliseconds: Int64
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_v2_accounts(
                        account_id, local_device_id, agent_route_id, device_route_id,
                        current_key_generation, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        local_device_id=excluded.local_device_id,
                        agent_route_id=excluded.agent_route_id,
                        device_route_id=excluded.device_route_id,
                        current_key_generation=excluded.current_key_generation,
                        updated_at_ms=excluded.updated_at_ms
                    """,
                arguments: [
                    accountID, localDeviceID, agentRouteID, deviceRouteID,
                    currentKeyGeneration, nowMilliseconds, nowMilliseconds,
                ]
            )
        }
    }

    /// Records the first terminal revocation for an account. The first writer
    /// wins so a later replay cannot rewrite the crash-forensics boundary.
    func recordAccountRevocation(
        accountID: String,
        source: String,
        messageID: String?,
        revokedAtMilliseconds: Int64
    ) async throws {
        guard RelayV2Wire.isToken(accountID), !source.isEmpty,
              messageID.map(RelayV2Wire.isToken) ?? true else {
            throw RelayV2ProtocolError.invalidArgument(field: "account_revocation")
        }
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO relay_v2_account_revocations(
                        account_id,revoked_at_ms,source,message_id
                    ) VALUES (?,?,?,?)
                    ON CONFLICT(account_id) DO NOTHING
                    """,
                arguments: [accountID, revokedAtMilliseconds, source, messageID]
            )
        }
    }

    func accountRevocation(accountID: String) async throws -> RelayV2AccountRevocationRecord? {
        try await pool.read { db in
            try RelayV2AccountRevocationRecord.fetchOne(db, key: accountID)
        }
    }

    func isAccountRevoked(accountID: String) async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM relay_v2_account_revocations WHERE account_id=?)",
                arguments: [accountID]
            ) ?? false
        }
    }

    /// Commits replay admission, stream watermark, item revisions, tombstones,
    /// and checkpoint replacement in one WAL transaction. A crash exposes either
    /// the entire batch or none of it.
    @discardableResult
    func apply(
        accountID: String,
        messageID: String,
        batch: RelayV2FrameBatch,
        receivedAtMilliseconds: Int64,
        outboundControlEnvelope: RelayV2OuterEnvelope? = nil,
        outboundControlKind: String = "stream_ack",
        outboundStableKey: String? = nil
    ) async throws -> RelayV2DatabaseApplyResult {
        try await pool.write { db in
            try Self.requireAccountActive(accountID, db: db)
            if try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM relay_v2_seen_messages WHERE account_id=? AND message_id=?)",
                arguments: [accountID, messageID]
            ) == true {
                throw RelayV2ProtocolError.replayDetected
            }
            try db.execute(
                sql: "INSERT INTO relay_v2_seen_messages(account_id,message_id,received_at_ms) VALUES (?,?,?)",
                arguments: [accountID, messageID, receivedAtMilliseconds]
            )

            var through = try Int64.fetchOne(
                db,
                sql: "SELECT through_seq FROM relay_v2_streams WHERE account_id=? AND stream_id=?",
                arguments: [accountID, batch.streamID]
            ) ?? 0
            var pendingTextAppends: [RelayV2TextItemKey: RelayV2PendingTextAppend] = [:]
            var pendingTextOrder: [RelayV2TextItemKey] = []
            var committedTextDeltas: [RelayV2CommittedTextDelta] = []

            func flushPendingTextAppends() throws {
                for key in pendingTextOrder {
                    guard let append = pendingTextAppends[key] else { continue }
                    let data = append.pieces.joined()
                    try Self.persist(
                        textAppend: append,
                        accountID: accountID,
                        data: data,
                        now: receivedAtMilliseconds,
                        db: db
                    )
                    committedTextDeltas.append(.init(
                        sessionID: key.sessionID,
                        itemID: key.itemID,
                        fromRevision: append.fromRevision,
                        toRevision: append.throughRevision,
                        data: data
                    ))
                }
                pendingTextAppends.removeAll(keepingCapacity: true)
                pendingTextOrder.removeAll(keepingCapacity: true)
            }

            guard batch.firstSequence > 0, !batch.frames.isEmpty else {
                throw RelayV2ProtocolError.invalidArgument(field: "frame_batch")
            }
            for (offset, frame) in batch.frames.enumerated() {
                let (sequence, overflow) = batch.firstSequence.addingReportingOverflow(Int64(offset))
                guard !overflow else {
                    throw RelayV2ProtocolError.invalidArgument(field: "frame_batch.first_seq")
                }
                let frameData = try RelayV2Wire.canonicalJSON(frame)
                let frameHash = Data(SHA256.hash(data: frameData))
                if sequence <= through {
                    let storedHash = try Data.fetchOne(
                        db,
                        sql: "SELECT frame_hash FROM relay_v2_stream_frames WHERE account_id=? AND stream_id=? AND seq=?",
                        arguments: [accountID, batch.streamID, sequence]
                    )
                    // A checkpoint is an authoritative discontinuity. Sequences
                    // it covered may intentionally have no local hash after a
                    // reinstall or retention prune; ignore those late batches.
                    guard storedHash == nil || storedHash == frameHash else {
                        throw RelayV2ProtocolError.conflict(
                            "A relay sequence was replayed with different content"
                        )
                    }
                    continue
                }
                if sequence > through + 1, frame.kind == "checkpoint" {
                    let checkpoint = try Self.decode(RelayV2CheckpointWire.self, from: frame.body)
                    guard checkpoint.streamID == batch.streamID,
                          checkpoint.sessionID == frame.sessionID,
                          checkpoint.throughSequence >= through,
                          checkpoint.throughSequence == sequence - 1 else {
                        throw RelayV2ProtocolError.conflict("Invalid checkpoint discontinuity")
                    }
                    through = checkpoint.throughSequence
                }
                guard sequence == through + 1 else {
                    throw RelayV2ProtocolError.conflict(
                        "Relay stream gap: expected \(through + 1), received \(sequence)"
                    )
                }
                if frame.kind == "item.delta" {
                    let delta = try Self.decode(RelayV2DeltaWire.self, from: frame.body)
                    let key = RelayV2TextItemKey(
                        sessionID: frame.sessionID,
                        itemID: delta.itemID
                    )
                    let wasPending = pendingTextAppends[key] != nil
                    if let append = try Self.accumulate(
                        delta: delta,
                        sessionID: frame.sessionID,
                        accountID: accountID,
                        existing: pendingTextAppends[key],
                        db: db
                    ) {
                        pendingTextAppends[key] = append
                        if !wasPending { pendingTextOrder.append(key) }
                    }
                } else {
                    // A full item or checkpoint is authoritative over every
                    // preceding append in wire order, so make those chunks
                    // visible to its revision/content checks first.
                    try flushPendingTextAppends()
                    try Self.apply(
                        wireFrame: frame,
                        streamID: batch.streamID,
                        accountID: accountID,
                        sequence: sequence,
                        now: receivedAtMilliseconds,
                        db: db
                    )
                }
                try RelayV2StoredEvent(
                    accountID: accountID,
                    streamID: batch.streamID,
                    sequence: sequence,
                    sessionID: frame.sessionID,
                    turnID: frame.turnID,
                    kind: frame.kind,
                    bodyJSON: try JSONEncoder().encode(frame.body),
                    receivedAtMilliseconds: receivedAtMilliseconds
                ).insert(db)
                try db.execute(
                    sql: "INSERT INTO relay_v2_stream_frames(account_id,stream_id,seq,frame_hash) VALUES (?,?,?,?)",
                    arguments: [accountID, batch.streamID, sequence, frameHash]
                )
                through = sequence
            }

            try flushPendingTextAppends()

            try db.execute(
                sql: """
                    INSERT INTO relay_v2_streams(account_id,stream_id,through_seq,updated_at_ms)
                    VALUES (?,?,?,?)
                    ON CONFLICT(account_id,stream_id) DO UPDATE SET
                        through_seq=excluded.through_seq, updated_at_ms=excluded.updated_at_ms
                    """,
                arguments: [accountID, batch.streamID, through, receivedAtMilliseconds]
            )
            if let outboundControlEnvelope, let outboundStableKey {
                try Self.queueControl(
                    accountID: accountID, kind: outboundControlKind, stableKey: outboundStableKey,
                    envelope: outboundControlEnvelope, now: receivedAtMilliseconds, db: db
                )
            }
            try Self.pruneRetention(accountID: accountID, streamID: batch.streamID, now: receivedAtMilliseconds, db: db)
            return RelayV2DatabaseApplyResult(committedTextDeltas: committedTextDeltas)
        }
    }

    func items(accountID: String, sessionID: String) async throws -> [RelayV2StoredItem] {
        try await pool.read { db in
            let items = try RelayV2StoredItem
                .filter(Column("account_id") == accountID && Column("session_id") == sessionID)
                .order(
                    Column("sort_sequence").ascNullsLast,
                    Column("turn_id"),
                    Column("ordinal"),
                    Column("item_id")
                )
                .fetchAll(db)
            return try Self.materializeTextChunks(
                in: items,
                accountID: accountID,
                sessionID: sessionID,
                db: db
            )
        }
    }

    #if DEBUG
    func textChunkStorageForTesting(
        accountID: String,
        sessionID: String,
        itemID: String
    ) async throws -> (
        count: Int,
        baseText: String?,
        appendedUTF8Count: Int64,
        textUTF8End: Int64?
    ) {
        try await pool.read { db in
            let item = try RelayV2StoredItem.fetchOne(
                db,
                key: [
                    "account_id": accountID,
                    "session_id": sessionID,
                    "item_id": itemID,
                ]
            )
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS chunk_count
                    FROM relay_v2_item_text_chunks
                    WHERE account_id=? AND session_id=? AND item_id=?
                    """,
                arguments: [accountID, sessionID, itemID]
            )
            let baseText = item?.body?["text"]?.stringValue
            let baseUTF8Count = Int64(baseText?.utf8.count ?? 0)
            return (
                count: row?["chunk_count"] ?? 0,
                baseText: baseText,
                appendedUTF8Count: max(0, (item?.textUTF8End ?? 0) - baseUTF8Count),
                textUTF8End: item?.textUTF8End
            )
        }
    }
    #endif

    func events(
        accountID: String,
        streamID: String,
        firstSequence: Int64,
        throughSequence: Int64
    ) async throws -> [RelayV2StoredEvent] {
        try await pool.read { db in
            try RelayV2StoredEvent
                .filter(Column("account_id") == accountID
                    && Column("stream_id") == streamID
                    && Column("seq") >= firstSequence
                    && Column("seq") <= throughSequence)
                .order(Column("seq"))
                .fetchAll(db)
        }
    }

    func applyCheckpoint(
        accountID: String,
        messageID: String,
        body: [String: JSONValue],
        receivedAtMilliseconds: Int64,
        outboundControlEnvelope: RelayV2OuterEnvelope? = nil,
        outboundControlKind: String = "stream_ack",
        outboundStableKey: String? = nil
    ) async throws {
        let checkpoint = try Self.decode(RelayV2CheckpointWire.self, from: .object(body))
        try await pool.write { db in
            try Self.requireAccountActive(accountID, db: db)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM relay_v2_seen_messages WHERE account_id=? AND message_id=?)", arguments: [accountID, messageID]) != true else {
                throw RelayV2ProtocolError.replayDetected
            }
            let application = try Self.apply(
                checkpoint: checkpoint, accountID: accountID,
                now: receivedAtMilliseconds, db: db
            )
            if application != .stale {
                try db.execute(
                    sql: """
                        INSERT INTO relay_v2_streams(account_id,stream_id,through_seq,updated_at_ms)
                        VALUES (?,?,?,?) ON CONFLICT(account_id,stream_id) DO UPDATE SET
                        through_seq=MAX(through_seq,excluded.through_seq),updated_at_ms=excluded.updated_at_ms
                        """,
                    arguments: [
                        accountID, checkpoint.streamID, checkpoint.throughSequence,
                        receivedAtMilliseconds,
                    ]
                )
            }
            try db.execute(sql: "INSERT INTO relay_v2_seen_messages(account_id,message_id,received_at_ms) VALUES (?,?,?)", arguments: [accountID, messageID, receivedAtMilliseconds])
            // The checkpoint authorizes skipping every earlier sequence even
            // when this device never received (and therefore never hashed) it.
            if application != .stale {
                try db.execute(
                    sql: "DELETE FROM relay_v2_stream_frames WHERE account_id=? AND stream_id=? AND seq <= ?",
                    arguments: [accountID, checkpoint.streamID, checkpoint.throughSequence]
                )
            }
            if let outboundControlEnvelope, let outboundStableKey {
                try Self.queueControl(
                    accountID: accountID, kind: outboundControlKind, stableKey: outboundStableKey,
                    envelope: outboundControlEnvelope, now: receivedAtMilliseconds, db: db
                )
            }
            try Self.pruneRetention(accountID: accountID, streamID: checkpoint.streamID, now: receivedAtMilliseconds, db: db)
        }
    }

    func streamState(accountID: String, streamID: String) async throws -> RelayV2StreamState? {
        try await pool.read { db in
            try RelayV2StreamState.fetchOne(db, key: ["account_id": accountID, "stream_id": streamID])
        }
    }

    func hasSeen(accountID: String, messageID: String) async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM relay_v2_seen_messages WHERE account_id=? AND message_id=?)",
                arguments: [accountID, messageID]
            ) ?? false
        }
    }

    func recordSeen(accountID: String, messageID: String, receivedAtMilliseconds: Int64) async throws {
        try await pool.write { db in
            try Self.requireAccountActive(accountID, db: db)
            if try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM relay_v2_seen_messages WHERE account_id=? AND message_id=?)",
                arguments: [accountID, messageID]
            ) == true {
                throw RelayV2ProtocolError.replayDetected
            }
            try db.execute(
                sql: "INSERT INTO relay_v2_seen_messages(account_id,message_id,received_at_ms) VALUES (?,?,?)",
                arguments: [accountID, messageID, receivedAtMilliseconds]
            )
        }
    }

    func recordSeenAndQueueControl(
        accountID: String,
        messageID: String,
        envelope: RelayV2OuterEnvelope,
        kind: String,
        stableKey: String,
        receivedAtMilliseconds: Int64
    ) async throws {
        try await pool.write { db in
            try Self.requireAccountActive(accountID, db: db)
            if try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM relay_v2_seen_messages WHERE account_id=? AND message_id=?)",
                arguments: [accountID, messageID]
            ) != true {
                try db.execute(
                    sql: "INSERT INTO relay_v2_seen_messages(account_id,message_id,received_at_ms) VALUES (?,?,?)",
                    arguments: [accountID, messageID, receivedAtMilliseconds]
                )
            }
            try Self.queueControl(
                accountID: accountID, kind: kind, stableKey: stableKey,
                envelope: envelope, now: receivedAtMilliseconds, db: db
            )
        }
    }

    func pendingControl(accountID: String) async throws -> [RelayV2ControlOutboxRecord] {
        try await pool.read { db in
            try RelayV2ControlOutboxRecord
                .filter(Column("account_id") == accountID)
                .order(Column("created_at_ms"), Column("stable_key"))
                .fetchAll(db)
        }
    }

    func removeControl(accountID: String, kind: String, stableKey: String) async throws {
        try await pool.write { db in
            _ = try RelayV2ControlOutboxRecord.deleteOne(
                db, key: ["account_id": accountID, "control_kind": kind, "stable_key": stableKey]
            )
        }
    }

    func replaceControl(
        accountID: String,
        kind: String,
        stableKey: String,
        envelope: RelayV2OuterEnvelope,
        nowMilliseconds: Int64
    ) async throws {
        let encoded = try envelope.canonicalJSON()
        try await pool.write { db in
            try Self.requireAccountActive(accountID, db: db)
            try db.execute(
                sql: """
                    INSERT INTO relay_v2_control_outbox(
                        account_id,control_kind,stable_key,envelope_json,created_at_ms
                    ) VALUES (?,?,?,?,?) ON CONFLICT(account_id,control_kind,stable_key)
                    DO UPDATE SET envelope_json=excluded.envelope_json,created_at_ms=excluded.created_at_ms
                    """,
                arguments: [accountID, kind, stableKey, encoded, nowMilliseconds]
            )
        }
    }

    private static func queueControl(
        accountID: String,
        kind: String,
        stableKey: String,
        envelope: RelayV2OuterEnvelope,
        now: Int64,
        db: Database
    ) throws {
        let encoded = try envelope.canonicalJSON()
        try db.execute(
            sql: """
                INSERT INTO relay_v2_control_outbox(
                    account_id,control_kind,stable_key,envelope_json,created_at_ms
                ) VALUES (?,?,?,?,?) ON CONFLICT(account_id,control_kind,stable_key) DO NOTHING
                """,
            arguments: [accountID, kind, stableKey, encoded, now]
        )
        if let stored = try Data.fetchOne(
            db,
            sql: "SELECT envelope_json FROM relay_v2_control_outbox WHERE account_id=? AND control_kind=? AND stable_key=?",
            arguments: [accountID, kind, stableKey]
        ), stored != encoded,
           !["stream_ack", "delivery_receipt", "sync_request"].contains(kind) {
            throw RelayV2ProtocolError.conflict("Control receipt key was reused with different content")
        }
    }

    func insertOptimisticItem(
        accountID: String,
        sessionID: String,
        itemID: String,
        body: JSONValue,
        nowMilliseconds: Int64
    ) async throws {
        try await pool.write { db in
            try Self.requireAccountActive(accountID, db: db)
            if let existing = try RelayV2StoredItem.fetchOne(
                db,
                key: ["account_id": accountID, "session_id": sessionID, "item_id": itemID]
            ) {
                // A late RPC response can race the canonical stream. Revision
                // zero is only a placeholder and must never replace an item
                // the Agent has already authored.
                if !existing.localOptimistic || existing.revision > 0 { return }
                return
            }
            try RelayV2StoredItem(
                accountID: accountID,
                sessionID: sessionID,
                itemID: itemID,
                turnID: nil,
                ordinal: Int.max,
                summary: nil,
                sortSequence: nil,
                revision: 0,
                itemType: "userMessage",
                bodyJSON: try JSONEncoder().encode(body),
                textUTF8End: Int64((body["text"]?.stringValue ?? "").utf8.count),
                status: "local_optimistic",
                localOptimistic: true,
                updatedAtMilliseconds: nowMilliseconds
            ).insert(db)
        }
    }

    func bindSessionAlias(
        accountID: String,
        originSessionID: String,
        liveSessionID: String,
        nowMilliseconds: Int64
    ) async throws {
        guard RelayV2Wire.isToken(accountID), RelayV2Wire.isToken(originSessionID),
              RelayV2Wire.isToken(liveSessionID) else {
            throw RelayV2ProtocolError.invalidArgument(field: "session_alias")
        }
        try await pool.write { db in
            try Self.requireAccountActive(accountID, db: db)
            try db.execute(
                sql: """
                    INSERT INTO relay_v2_session_aliases(
                        account_id,origin_session_id,live_session_id,updated_at_ms
                    ) VALUES (?,?,?,?)
                    ON CONFLICT(account_id,origin_session_id) DO UPDATE SET
                        live_session_id=excluded.live_session_id,
                        updated_at_ms=excluded.updated_at_ms
                    """,
                arguments: [accountID, originSessionID, liveSessionID, nowMilliseconds]
            )
        }
    }

    func originSessionID(accountID: String, liveSessionID: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT origin_session_id FROM relay_v2_session_aliases
                    WHERE account_id=? AND live_session_id=?
                    ORDER BY updated_at_ms DESC LIMIT 1
                    """,
                arguments: [accountID, liveSessionID]
            )
        }
    }

    func liveSessionID(accountID: String, originSessionID: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT live_session_id FROM relay_v2_session_aliases
                    WHERE account_id=? AND origin_session_id=?
                    """,
                arguments: [accountID, originSessionID]
            )
        }
    }

    /// Returns the canonical origin projection. HRP/2 now emits phone-facing
    /// frames under the origin id; the live partition merge remains as a
    /// downgrade bridge for relays from before that contract was tightened.
    func projectionItems(
        accountID: String,
        incomingSessionID: String
    ) async throws -> (originSessionID: String, items: [RelayV2StoredItem]) {
        let origin = try await originSessionID(
            accountID: accountID, liveSessionID: incomingSessionID
        ) ?? incomingSessionID
        let originItems = try await items(accountID: accountID, sessionID: origin)
        guard origin != incomingSessionID else { return (origin, originItems) }
        let liveItems = try await items(accountID: accountID, sessionID: incomingSessionID)
        var merged = originItems
        var indices = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.itemID, $0.offset) })
        for item in liveItems {
            if let index = indices[item.itemID] {
                merged[index] = item
            } else {
                indices[item.itemID] = merged.count
                merged.append(item)
            }
        }
        return (origin, merged)
    }

    private static func apply(
        wireFrame: RelayV2WireFrame,
        streamID: String,
        accountID: String,
        sequence: Int64,
        now: Int64,
        db: Database
    ) throws {
        if wireFrame.kind == "checkpoint" {
            let checkpoint = try decode(RelayV2CheckpointWire.self, from: wireFrame.body)
            guard checkpoint.streamID == streamID,
                  checkpoint.sessionID == wireFrame.sessionID else {
                throw RelayV2ProtocolError.conflict("Checkpoint crossed a stream or session boundary")
            }
            try apply(checkpoint: checkpoint, accountID: accountID, now: now, db: db)
            return
        }
        if wireFrame.kind == "item.started" || wireFrame.kind == "item.completed" {
            let item = try decode(RelayV2FullWireItem.self, from: wireFrame.body)
            guard item.sessionID == wireFrame.sessionID else {
                throw RelayV2ProtocolError.conflict("Item crossed a session boundary")
            }
            try apply(fullItem: item, accountID: accountID, sortSequence: sequence, now: now, db: db)
            return
        }
        guard wireFrame.kind != "item.delta" else {
            throw RelayV2ProtocolError.conflict("Item delta bypassed the append transaction")
        }
    }

    private static func apply(
        fullItem item: RelayV2FullWireItem,
        accountID: String,
        sortSequence: Int64? = nil,
        now: Int64,
        db: Database
    ) throws {
        guard item.revision > 0, !item.type.isEmpty else {
            throw RelayV2ProtocolError.invalidArgument(field: "item")
        }
        let existing = try RelayV2StoredItem.fetchOne(
            db,
            key: ["account_id": accountID, "session_id": item.sessionID, "item_id": item.itemID]
        )
        if let existing {
            if item.revision < existing.revision { return }
            if item.revision == existing.revision {
                guard try canonicalPersistedContent(existing, db: db)
                    == canonicalPersistedContent(item) else {
                    throw RelayV2ProtocolError.conflict(
                        "Item revision was reused with different content"
                    )
                }
                return
            }
        }
        let tombstoneRevision = try Int64.fetchOne(
            db,
            sql: "SELECT revision FROM relay_v2_tombstones WHERE account_id=? AND session_id=? AND item_id=?",
            arguments: [accountID, item.sessionID, item.itemID]
        )
        if let tombstoneRevision, tombstoneRevision >= item.revision { return }
        let textUTF8End = Int64((item.body["text"]?.stringValue ?? "").utf8.count)
        try db.execute(
            sql: """
                INSERT INTO relay_v2_items(
                    account_id,session_id,item_id,turn_id,ordinal,summary,sort_sequence,
                    revision,item_type,body_json,text_utf8_end,status,local_optimistic,updated_at_ms
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(account_id,session_id,item_id) DO UPDATE SET
                    turn_id=excluded.turn_id, ordinal=excluded.ordinal, summary=excluded.summary,
                    sort_sequence=COALESCE(relay_v2_items.sort_sequence,excluded.sort_sequence),
                    revision=excluded.revision,item_type=excluded.item_type,
                    body_json=excluded.body_json,text_utf8_end=excluded.text_utf8_end,
                    status=excluded.status,
                    local_optimistic=0,updated_at_ms=excluded.updated_at_ms
                WHERE excluded.revision > relay_v2_items.revision
                """,
            arguments: [
                accountID, item.sessionID, item.itemID, item.turnID, item.ordinal, item.summary,
                sortSequence, item.revision, item.type, try JSONEncoder().encode(item.body),
                textUTF8End, item.status, false, now,
            ]
        )
        try db.execute(
            sql: "DELETE FROM relay_v2_tombstones WHERE account_id=? AND session_id=? AND item_id=? AND revision < ?",
            arguments: [accountID, item.sessionID, item.itemID, item.revision]
        )
        // Full started/completed frames and checkpoint items are authoritative
        // replacements. Any append chunks represented by an older revision are
        // now folded into the supplied body and must not render twice.
        try db.execute(
            sql: "DELETE FROM relay_v2_item_text_chunks WHERE account_id=? AND session_id=? AND item_id=?",
            arguments: [accountID, item.sessionID, item.itemID]
        )
    }

    private static func canonicalPersistedContent(
        _ item: RelayV2FullWireItem
    ) throws -> Data {
        try canonicalPersistedContent(
            itemID: item.itemID,
            sessionID: item.sessionID,
            turnID: item.turnID,
            type: item.type,
            status: item.status,
            ordinal: item.ordinal,
            revision: item.revision,
            summary: item.summary,
            body: item.body
        )
    }

    private static func canonicalPersistedContent(
        _ item: RelayV2StoredItem,
        db: Database
    ) throws -> Data {
        let materialized = try materializeTextChunks(in: item, db: db)
        guard !materialized.localOptimistic, let body = materialized.body else {
            throw RelayV2ProtocolError.conflict(
                "Canonical item content is unavailable for an equal revision"
            )
        }
        return try canonicalPersistedContent(
            itemID: materialized.itemID,
            sessionID: materialized.sessionID,
            turnID: materialized.turnID,
            type: materialized.itemType,
            status: materialized.status,
            ordinal: materialized.ordinal,
            revision: materialized.revision,
            summary: materialized.summary,
            body: body
        )
    }

    private static func canonicalPersistedContent(
        itemID: String,
        sessionID: String,
        turnID: String?,
        type: String,
        status: String,
        ordinal: Int,
        revision: Int64,
        summary: String?,
        body: JSONValue
    ) throws -> Data {
        try RelayV2Wire.canonicalJSON([
            "item_id": .string(itemID),
            "session_id": .string(sessionID),
            "turn_id": turnID.map(JSONValue.string) ?? .null,
            "type": .string(type),
            "status": .string(status),
            "ord": .number(Double(ordinal)),
            "rev": .number(Double(revision)),
            "summary": summary.map(JSONValue.string) ?? .null,
            "body": body,
        ] as [String: JSONValue])
    }

    private static func accumulate(
        delta: RelayV2DeltaWire,
        sessionID: String,
        accountID: String,
        existing pending: RelayV2PendingTextAppend?,
        db: Database
    ) throws -> RelayV2PendingTextAppend? {
        let operation = delta.operations.first
        guard delta.toRevision == delta.fromRevision + 1,
              delta.operations.count == 1,
              let operation,
              operation.operation == "append_utf8", operation.path == "/body/text" else {
            throw RelayV2ProtocolError.conflict("Invalid item delta revision")
        }

        var append: RelayV2PendingTextAppend
        if let pending {
            append = pending
        } else {
            guard let stored = try RelayV2StoredItem.fetchOne(
                db,
                key: [
                    "account_id": accountID,
                    "session_id": sessionID,
                    "item_id": delta.itemID,
                ]
            ) else {
                throw RelayV2ProtocolError.conflict(
                    "Delta arrived before its item checkpoint"
                )
            }
            let tombstoneRevision = try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM relay_v2_tombstones WHERE account_id=? AND session_id=? AND item_id=?",
                arguments: [accountID, sessionID, delta.itemID]
            )
            if let tombstoneRevision, tombstoneRevision >= delta.toRevision { return nil }
            if delta.toRevision <= stored.revision { return nil }
            append = RelayV2PendingTextAppend(
                key: .init(sessionID: sessionID, itemID: delta.itemID),
                fromRevision: stored.revision,
                throughRevision: stored.revision,
                currentUTF8Offset: stored.textUTF8End,
                pieces: []
            )
        }

        if delta.toRevision <= append.throughRevision { return append }
        guard delta.fromRevision == append.throughRevision else {
            throw RelayV2ProtocolError.conflict("Invalid item delta revision")
        }
        guard Int64(operation.offset) == append.currentUTF8Offset else {
            throw RelayV2ProtocolError.conflict("Item delta UTF-8 offset mismatch")
        }
        let (nextOffset, overflow) = append.currentUTF8Offset.addingReportingOverflow(
            Int64(operation.data.utf8.count)
        )
        guard !overflow else {
            throw RelayV2ProtocolError.conflict("Item delta UTF-8 offset overflow")
        }
        append.throughRevision = delta.toRevision
        append.currentUTF8Offset = nextOffset
        append.pieces.append(operation.data)
        return append
    }

    private static func persist(
        textAppend append: RelayV2PendingTextAppend,
        accountID: String,
        data: String,
        now: Int64,
        db: Database
    ) throws {
        try RelayV2StoredTextChunk(
            accountID: accountID,
            sessionID: append.key.sessionID,
            itemID: append.key.itemID,
            fromRevision: append.fromRevision,
            throughRevision: append.throughRevision,
            utf8Count: Int64(data.utf8.count),
            text: data,
            createdAtMilliseconds: now
        ).insert(db)
        try db.execute(
            sql: """
                UPDATE relay_v2_items
                SET revision=?, text_utf8_end=?, updated_at_ms=?
                WHERE account_id=? AND session_id=? AND item_id=? AND revision=?
                """,
            arguments: [
                append.throughRevision, append.currentUTF8Offset, now, accountID,
                append.key.sessionID, append.key.itemID, append.fromRevision,
            ]
        )
        guard db.changesCount == 1 else {
            throw RelayV2ProtocolError.conflict("Item delta revision changed during commit")
        }
    }

    private static func materializeTextChunks(
        in items: [RelayV2StoredItem],
        accountID: String,
        sessionID: String,
        db: Database
    ) throws -> [RelayV2StoredItem] {
        guard !items.isEmpty else { return items }
        let chunks = try RelayV2StoredTextChunk
            .filter(
                Column("account_id") == accountID
                    && Column("session_id") == sessionID
            )
            .order(Column("item_id"), Column("from_revision"))
            .fetchAll(db)
        let byItem = Dictionary(grouping: chunks, by: \.itemID)
        return try items.map { item in
            try materializeTextChunks(
                in: item,
                chunks: byItem[item.itemID] ?? []
            )
        }
    }

    private static func materializeTextChunks(
        in item: RelayV2StoredItem,
        db: Database
    ) throws -> RelayV2StoredItem {
        let chunks = try RelayV2StoredTextChunk
            .filter(
                Column("account_id") == item.accountID
                    && Column("session_id") == item.sessionID
                    && Column("item_id") == item.itemID
            )
            .order(Column("from_revision"))
            .fetchAll(db)
        return try materializeTextChunks(in: item, chunks: chunks)
    }

    private static func materializeTextChunks(
        in item: RelayV2StoredItem,
        chunks: [RelayV2StoredTextChunk]
    ) throws -> RelayV2StoredItem {
        guard !chunks.isEmpty else { return item }
        var materialized = item
        var body = item.body?.objectValue ?? [:]
        let baseText = body["text"]?.stringValue ?? ""
        body["text"] = .string(([baseText] + chunks.map(\.text)).joined())
        materialized.bodyJSON = try JSONEncoder().encode(JSONValue.object(body))
        return materialized
    }

    @discardableResult
    private static func apply(
        checkpoint: RelayV2CheckpointWire,
        accountID: String,
        now: Int64,
        db: Database
    ) throws -> RelayV2CheckpointApplication {
        let checkpointHash = Data(SHA256.hash(
            data: try RelayV2Wire.canonicalJSON(checkpoint)
        ))
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT revision,content_hash FROM relay_v2_checkpoints WHERE account_id=? AND session_id=?",
            arguments: [accountID, checkpoint.sessionID]
        )
        if let existing {
            let existingRevision: Int64 = existing["revision"]
            let existingHash: Data? = existing["content_hash"]
            if checkpoint.snapshotRevision < existingRevision { return .stale }
            if checkpoint.snapshotRevision == existingRevision {
                guard existingHash == checkpointHash else {
                    throw RelayV2ProtocolError.conflict(
                        "Checkpoint revision was reused with different content"
                    )
                }
                return .duplicate
            }
        }
        if checkpoint.replace {
            let retainedItemIDs = Set(checkpoint.items.map(\.itemID))
            let existingItems = try RelayV2StoredItem
                .filter(
                    Column("account_id") == accountID
                        && Column("session_id") == checkpoint.sessionID
                )
                .fetchAll(db)
            for omitted in existingItems where !omitted.localOptimistic
                && omitted.revision <= checkpoint.snapshotRevision
                && !retainedItemIDs.contains(omitted.itemID) {
                // Omission from an authoritative replacement snapshot is an
                // implicit deletion through the snapshot revision. Persist that
                // boundary before removing the row so a late full frame cannot
                // resurrect it. Items authored after the snapshot are preserved.
                try db.execute(
                    sql: """
                        INSERT INTO relay_v2_tombstones(
                            account_id,session_id,item_id,revision,created_at_ms
                        ) VALUES (?,?,?,?,?)
                        ON CONFLICT(account_id,session_id,item_id) DO UPDATE SET
                          revision=MAX(revision,excluded.revision),
                          created_at_ms=excluded.created_at_ms
                        """,
                    arguments: [
                        accountID, checkpoint.sessionID, omitted.itemID,
                        checkpoint.snapshotRevision, now,
                    ]
                )
                try db.execute(
                    sql: "DELETE FROM relay_v2_items WHERE account_id=? AND session_id=? AND item_id=? AND local_optimistic=0 AND revision <= ?",
                    arguments: [
                        accountID, checkpoint.sessionID, omitted.itemID,
                        checkpoint.snapshotRevision,
                    ]
                )
            }
        }
        for tombstone in checkpoint.tombstones {
            try db.execute(
                sql: "DELETE FROM relay_v2_items WHERE account_id=? AND session_id=? AND item_id=? AND local_optimistic=0 AND revision <= ?",
                arguments: [
                    accountID, checkpoint.sessionID, tombstone.itemID,
                    tombstone.deletedAtRevision,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO relay_v2_tombstones(account_id,session_id,item_id,revision,created_at_ms)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(account_id,session_id,item_id) DO UPDATE SET
                      revision=MAX(revision,excluded.revision), created_at_ms=excluded.created_at_ms
                    """,
                arguments: [
                    accountID, checkpoint.sessionID, tombstone.itemID,
                    tombstone.deletedAtRevision, now,
                ]
            )
        }
        for (index, item) in checkpoint.items.enumerated() {
            guard item.sessionID == checkpoint.sessionID else {
                throw RelayV2ProtocolError.conflict("Checkpoint crossed session boundaries")
            }
            try apply(fullItem: item, accountID: accountID, sortSequence: Int64(index), now: now, db: db)
        }
        try db.execute(
            sql: """
                INSERT INTO relay_v2_checkpoints(
                    account_id,session_id,revision,through_seq,replace_state,created_at_ms,content_hash
                ) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(account_id,session_id) DO UPDATE SET
                    revision=excluded.revision, through_seq=excluded.through_seq,
                    replace_state=excluded.replace_state, created_at_ms=excluded.created_at_ms,
                    content_hash=excluded.content_hash
                WHERE excluded.revision > relay_v2_checkpoints.revision
                """,
            arguments: [
                accountID, checkpoint.sessionID, checkpoint.snapshotRevision,
                checkpoint.throughSequence, checkpoint.replace, now, checkpointHash,
            ]
        )
        return .applied
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private static func requireAccountActive(_ accountID: String, db: Database) throws {
        if try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM relay_v2_account_revocations WHERE account_id=?)",
            arguments: [accountID]
        ) == true {
            throw RelayV2ProtocolError.revoked
        }
    }

    private static func pruneRetention(accountID: String, streamID: String, now: Int64, db: Database) throws {
        let seenCutoff = now - 14 * 24 * 60 * 60 * 1_000
        try db.execute(
            sql: "DELETE FROM relay_v2_seen_messages WHERE account_id=? AND received_at_ms < ?",
            arguments: [accountID, seenCutoff]
        )
        for table in ["relay_v2_stream_frames", "relay_v2_events"] {
            try db.execute(
                sql: """
                    DELETE FROM \(table) WHERE account_id=? AND stream_id=? AND seq < COALESCE(
                        (SELECT MAX(seq) - 4096 FROM \(table) WHERE account_id=? AND stream_id=?), 0
                    )
                    """,
                arguments: [accountID, streamID, accountID, streamID]
            )
        }
    }

    #if DEBUG
    /// Builds a legacy database at an exact migration boundary so tests can
    /// prove forward migration of durable stream state rather than only a fresh
    /// schema. This seam is absent from release builds.
    static func migrateForTesting(
        _ writer: some DatabaseWriter,
        through identifier: String
    ) throws {
        try makeMigrator().migrate(writer, upTo: identifier)
    }
    #endif

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("relay-v2-1") { db in
            try db.execute(sql: """
                CREATE TABLE relay_v2_accounts(
                    account_id TEXT PRIMARY KEY NOT NULL,
                    local_device_id TEXT NOT NULL,
                    agent_route_id TEXT NOT NULL,
                    device_route_id TEXT NOT NULL,
                    current_key_generation INTEGER NOT NULL CHECK(current_key_generation > 0),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );
                CREATE TABLE relay_v2_devices(
                    account_id TEXT NOT NULL REFERENCES relay_v2_accounts(account_id) ON DELETE CASCADE,
                    device_id TEXT NOT NULL,
                    route_id TEXT NOT NULL,
                    key_generation INTEGER NOT NULL,
                    revoked_at_ms INTEGER,
                    PRIMARY KEY(account_id, device_id)
                );
                CREATE TABLE relay_v2_streams(
                    account_id TEXT NOT NULL,
                    stream_id TEXT NOT NULL,
                    through_seq INTEGER NOT NULL DEFAULT 0,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id, stream_id)
                );
                CREATE TABLE relay_v2_stream_frames(
                    account_id TEXT NOT NULL,
                    stream_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    frame_hash BLOB NOT NULL,
                    PRIMARY KEY(account_id, stream_id, seq)
                );
                CREATE TABLE relay_v2_seen_messages(
                    account_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    received_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id, message_id)
                );
                CREATE INDEX relay_v2_seen_received ON relay_v2_seen_messages(received_at_ms);
                CREATE TABLE relay_v2_items(
                    account_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    item_type TEXT NOT NULL,
                    body_json BLOB NOT NULL,
                    status TEXT NOT NULL,
                    local_optimistic INTEGER NOT NULL DEFAULT 0,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id, session_id, item_id)
                );
                CREATE INDEX relay_v2_items_session
                    ON relay_v2_items(account_id, session_id, updated_at_ms);
                CREATE TABLE relay_v2_tombstones(
                    account_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id, session_id, item_id)
                );
                CREATE TABLE relay_v2_checkpoints(
                    account_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    through_seq INTEGER NOT NULL,
                    replace_state INTEGER NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id, session_id)
                );
                CREATE TABLE relay_v2_session_aliases(
                    account_id TEXT NOT NULL,
                    origin_session_id TEXT NOT NULL,
                    live_session_id TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id, origin_session_id)
                );
                """)
        }
        migrator.registerMigration("relay-v2-2-control-outbox") { db in
            try db.execute(sql: """
                CREATE TABLE relay_v2_control_outbox(
                    account_id TEXT NOT NULL,
                    control_kind TEXT NOT NULL,
                    stable_key TEXT NOT NULL,
                    envelope_json BLOB NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id,control_kind,stable_key)
                );
                CREATE INDEX relay_v2_control_outbox_created
                    ON relay_v2_control_outbox(account_id,created_at_ms);
                """)
        }
        migrator.registerMigration("relay-v2-3-events-and-item-order") { db in
            try db.execute(sql: """
                ALTER TABLE relay_v2_items ADD COLUMN turn_id TEXT;
                ALTER TABLE relay_v2_items ADD COLUMN ordinal INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE relay_v2_items ADD COLUMN summary TEXT;
                ALTER TABLE relay_v2_items ADD COLUMN sort_sequence INTEGER;
                CREATE INDEX relay_v2_items_render_order
                    ON relay_v2_items(account_id,session_id,sort_sequence,turn_id,ordinal,item_id);
                CREATE TABLE relay_v2_events(
                    account_id TEXT NOT NULL,
                    stream_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    session_id TEXT NOT NULL,
                    turn_id TEXT,
                    kind TEXT NOT NULL,
                    body_json BLOB NOT NULL,
                    received_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id,stream_id,seq)
                );
                CREATE INDEX relay_v2_events_session
                    ON relay_v2_events(account_id,session_id,seq);
                """)
        }
        migrator.registerMigration("relay-v2-4-checkpoint-content-hash") { db in
            try db.execute(sql: """
                ALTER TABLE relay_v2_checkpoints ADD COLUMN content_hash BLOB;
                """)
        }
        migrator.registerMigration("relay-v2-5-account-revocations") { db in
            try db.execute(sql: """
                CREATE TABLE relay_v2_account_revocations(
                    account_id TEXT PRIMARY KEY NOT NULL,
                    revoked_at_ms INTEGER NOT NULL,
                    source TEXT NOT NULL,
                    message_id TEXT
                );
                """)
        }
        migrator.registerMigration("relay-v2-6-item-text-chunks") { db in
            try db.execute(sql: """
                CREATE TABLE relay_v2_item_text_chunks(
                    account_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    from_revision INTEGER NOT NULL,
                    through_revision INTEGER NOT NULL,
                    utf8_count INTEGER NOT NULL CHECK(utf8_count >= 0),
                    text TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(account_id,session_id,item_id,from_revision),
                    FOREIGN KEY(account_id,session_id,item_id)
                        REFERENCES relay_v2_items(account_id,session_id,item_id)
                        ON DELETE CASCADE,
                    CHECK(through_revision > from_revision)
                );
                CREATE INDEX relay_v2_item_text_chunks_order
                    ON relay_v2_item_text_chunks(
                        account_id,session_id,item_id,from_revision
                    );
                """)
        }
        migrator.registerMigration("relay-v2-7-item-text-utf8-end") { db in
            try db.execute(sql: """
                ALTER TABLE relay_v2_items
                    ADD COLUMN text_utf8_end INTEGER NOT NULL DEFAULT 0
                    CHECK(text_utf8_end >= 0);
                """)

            // Older installs derived the next append offset by summing every
            // historical chunk. Materialize the same value once at migration;
            // all later commits update it transactionally with the item revision.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT i.account_id, i.session_id, i.item_id, i.body_json,
                           COALESCE(c.appended_utf8_count, 0) AS appended_utf8_count
                    FROM relay_v2_items AS i
                    LEFT JOIN (
                        SELECT account_id, session_id, item_id,
                               SUM(utf8_count) AS appended_utf8_count
                        FROM relay_v2_item_text_chunks
                        GROUP BY account_id, session_id, item_id
                    ) AS c
                      ON c.account_id = i.account_id
                     AND c.session_id = i.session_id
                     AND c.item_id = i.item_id
                    """
            )
            for row in rows {
                let accountID: String = row["account_id"]
                let sessionID: String = row["session_id"]
                let itemID: String = row["item_id"]
                let bodyData: Data = row["body_json"]
                let body = try JSONDecoder().decode(JSONValue.self, from: bodyData)
                let baseUTF8Count = Int64((body["text"]?.stringValue ?? "").utf8.count)
                let appendedUTF8Count: Int64 = row["appended_utf8_count"]
                let (textUTF8End, overflow) = baseUTF8Count.addingReportingOverflow(
                    appendedUTF8Count
                )
                guard !overflow else {
                    throw RelayV2ProtocolError.conflict(
                        "Migrated item text exceeded the UTF-8 offset range"
                    )
                }
                try db.execute(
                    sql: """
                        UPDATE relay_v2_items SET text_utf8_end=?
                        WHERE account_id=? AND session_id=? AND item_id=?
                    """,
                    arguments: [
                        textUTF8End, accountID, sessionID, itemID,
                    ]
                )
            }
        }
        return migrator
    }
}
