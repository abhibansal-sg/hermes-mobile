import Foundation
import GRDB

enum TransferKind: String, Codable, Sendable, DatabaseValueConvertible {
    case upload
    case download
    case export
}
enum TransferState: String, Codable, Sendable, DatabaseValueConvertible {
    case staged
    case running
    case retryWaiting = "retry_waiting"
    case suspended
    case completed
    case failed
    case cancelled
}

/// Durable, non-secret description of a background transfer.
///
/// Authentication is deliberately absent. Credentials are resolved from the
/// Keychain-backed connection at task creation time and only live in the
/// in-memory URLRequest owned by URLSession.
struct TransferRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "transfers"

    let id: String
    var kind: TransferKind
    var state: TransferState
    var remoteURL: String
    var localFilePath: String?
    var destinationFilePath: String?
    var taskIdentifier: Int?
    var ownerJobId: String?
    var ownerWakeDelivered: Bool
    var responseBody: Data?
    var resumeData: Data?
    var retryCount: Int
    var nextRetryAt: Double?
    var httpStatus: Int?
    var errorCode: String?
    var createdAt: Double
    var updatedAt: Double
}
