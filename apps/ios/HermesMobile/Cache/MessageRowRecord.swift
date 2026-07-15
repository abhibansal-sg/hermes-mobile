import Foundation
import GRDB

// MARK: - MessageRowRecord
//
// One row per StoredMessage (HUMAN sessions only; cron sessions are never
// transcript-cached per the decided scope). The StoredMessage is encoded as
// a JSON blob via StoredMessageMirror. See CONTRACT-OFFLINE-CACHE.md §2.2.

struct MessageRowRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// FK -> session_cache.id (ON DELETE CASCADE)
    var sessionId: String
    /// Position in the fetched transcript (0-based); rebuild order authority
    var ordinal: Int
    /// Global autoincrement `id` from the wire row (cursor; may be nil pre-merge)
    var wireId: Int?
    /// StoredMessage.role (sql-side filtering/debug)
    var role: String
    /// StoredMessage.timestamp
    var timestamp: Double?
    /// The FULL StoredMessage (via StoredMessageMirror), JSON-encoded
    var rowJSON: Data

    static let databaseTableName = "message_row_cache"
}

// MARK: - MessageRowRecord factory

extension MessageRowRecord {
    /// Build a MessageRowRecord from a StoredMessage at a given ordinal position.
    static func make(
        sessionId: String,
        ordinal: Int,
        wireId: Int?,
        message: StoredMessage
    ) throws -> MessageRowRecord {
        let mirror = message.toMirror()
        let data = try JSONEncoder().encode(mirror)
        return MessageRowRecord(
            sessionId: sessionId,
            ordinal: ordinal,
            wireId: wireId,
            role: message.role,
            timestamp: message.timestamp,
            rowJSON: data
        )
    }

    /// Decode the persisted StoredMessage from rowJSON.
    func decodeStoredMessage() throws -> StoredMessage {
        let mirror = try JSONDecoder().decode(StoredMessageMirror.self, from: rowJSON)
        return mirror.toStoredMessage()
    }
}
