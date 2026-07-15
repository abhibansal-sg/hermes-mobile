import Foundation
import GRDB
import Observation

/// The already-normalized Phase-1 durable-work partition.
///
/// This type deliberately does not parse URLs or profile names. The app builds it
/// from Phase-1's cache/sync identity and the share extension uses `nil` until the
/// main app binds an unscoped share job.
struct WorkScope: Codable, Equatable, Hashable, Sendable {
    let serverID: String
    let profileID: String

    init(serverID: String, profileID: String) throws {
        guard !serverID.isEmpty, !profileID.isEmpty else {
            throw WorkRepositoryError.invalidScope
        }
        self.serverID = serverID
        self.profileID = profileID
    }
}

enum WorkJobKind: String, Codable, CaseIterable, Sendable {
    case prompt
    case share
    case appIntent = "app_intent"
}

enum WorkJobState: String, Codable, CaseIterable, Sendable {
    case waitingForScope = "waiting_for_scope"
    case queued
    case creatingDestination = "creating_destination"
    case uploading
    case submitting
    case accepted
    case retryWait = "retry_wait"
    case failed
    case completed
    case cancelled
    case expired

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .expired:
            true
        default:
            false
        }
    }
}

enum WorkIntentKind: String, Codable, CaseIterable, Sendable {
    case askHermes = "ask_hermes"
    case openSessions = "open_sessions"
    case newSession = "new_session"
}

struct WorkDraft: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "drafts"

    var draftID: String
    var serverID: String
    var profileID: String
    var contextKey: String
    var storedSessionID: String?
    var text: String
    var cwd: String?
    var modelSelectionJSON: String?
    var createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case draftID = "draft_id"
        case serverID = "server_id"
        case profileID = "profile_id"
        case contextKey = "context_key"
        case storedSessionID = "stored_session_id"
        case text, cwd
        case modelSelectionJSON = "model_selection_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct WorkJob: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable, Identifiable {
    static let databaseTableName = "work_jobs"

    var jobID: String
    var kind: WorkJobKind
    var clientMessageID: String
    var serverID: String?
    var profileID: String?
    var state: WorkJobState
    var intentKind: WorkIntentKind?
    var text: String?
    var sourceURL: String?
    var comment: String?
    var storedSessionID: String?
    var destinationSessionID: String?
    var payloadHash: String
    var attemptCount: Int
    var nextAttemptAt: Double?
    var lastErrorCode: String?
    var lastErrorMessage: String?
    var leaseOwner: String?
    var leaseExpiresAt: Double?
    var expiresAt: Double?
    var legacyImportKey: String?
    var createdAt: Double
    var updatedAt: Double
    var acceptedAt: Double?
    var completedAt: Double?

    var id: String { jobID }
    var scope: WorkScope? {
        guard let serverID, let profileID else { return nil }
        return try? WorkScope(serverID: serverID, profileID: profileID)
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case kind
        case clientMessageID = "client_message_id"
        case serverID = "server_id"
        case profileID = "profile_id"
        case state
        case intentKind = "intent_kind"
        case text
        case sourceURL = "source_url"
        case comment
        case storedSessionID = "stored_session_id"
        case destinationSessionID = "destination_session_id"
        case payloadHash = "payload_hash"
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
        case lastErrorCode = "last_error_code"
        case lastErrorMessage = "last_error_message"
        case leaseOwner = "lease_owner"
        case leaseExpiresAt = "lease_expires_at"
        case expiresAt = "expires_at"
        case legacyImportKey = "legacy_import_key"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case acceptedAt = "accepted_at"
        case completedAt = "completed_at"
    }
}

struct WorkAsset: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "work_assets"

    var assetID: String
    var relativePath: String
    var mimeType: String
    var byteCount: Int
    var sha256: String
    var createdAt: Double
    var lastAccessedAt: Double

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case relativePath = "relative_path"
        case mimeType = "mime_type"
        case byteCount = "byte_count"
        case sha256
        case createdAt = "created_at"
        case lastAccessedAt = "last_accessed_at"
    }
}

struct WorkJobAsset: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "job_assets"

    var jobID: String
    var assetID: String
    var ordinal: Int
    var transferID: String?
    var remotePath: String?
    var state: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case assetID = "asset_id"
        case ordinal
        case transferID = "transfer_id"
        case remotePath = "remote_path"
        case state
    }
}

struct WorkDraftAsset: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "draft_assets"

    var draftID: String
    var assetID: String
    var ordinal: Int

    enum CodingKeys: String, CodingKey {
        case draftID = "draft_id"
        case assetID = "asset_id"
        case ordinal
    }
}

struct WorkTransfer: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "transfers"

    var transferID: String
    var backgroundSessionID: String
    var taskIdentifier: Int?
    var direction: String
    var purpose: String
    var serverID: String
    var profileID: String
    var ownerJobID: String?
    var sourceRelativePath: String?
    var destinationRelativePath: String?
    var requestURL: String
    var requestMethod: String
    var mimeType: String?
    var expectedBytes: Int?
    var transferredBytes: Int
    var resumeData: Data?
    var state: String
    var attemptCount: Int
    var nextAttemptAt: Double?
    var lastErrorCode: String?
    var lastErrorMessage: String?
    var createdAt: Double
    var updatedAt: Double
    var completedAt: Double?

    enum CodingKeys: String, CodingKey {
        case transferID = "transfer_id"
        case backgroundSessionID = "background_session_id"
        case taskIdentifier = "task_identifier"
        case direction, purpose
        case serverID = "server_id"
        case profileID = "profile_id"
        case ownerJobID = "owner_job_id"
        case sourceRelativePath = "source_relative_path"
        case destinationRelativePath = "destination_relative_path"
        case requestURL = "request_url"
        case requestMethod = "request_method"
        case mimeType = "mime_type"
        case expectedBytes = "expected_bytes"
        case transferredBytes = "transferred_bytes"
        case resumeData = "resume_data"
        case state
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
        case lastErrorCode = "last_error_code"
        case lastErrorMessage = "last_error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
    }
}

struct WorkAssetInput: Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String

    init(data: Data, mimeType: String, fileExtension: String) {
        self.data = data
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }
}

struct WorkJobInput: Sendable {
    var jobID: UUID
    var kind: WorkJobKind
    var scope: WorkScope?
    var state: WorkJobState
    var intentKind: WorkIntentKind?
    var text: String?
    var sourceURL: String?
    var comment: String?
    var storedSessionID: String?
    var expiresAt: Date?
    var legacyImportKey: String?
    var createdAt: Date?

    init(
        jobID: UUID = UUID(),
        kind: WorkJobKind,
        scope: WorkScope?,
        state: WorkJobState? = nil,
        intentKind: WorkIntentKind? = nil,
        text: String? = nil,
        sourceURL: String? = nil,
        comment: String? = nil,
        storedSessionID: String? = nil,
        expiresAt: Date? = nil,
        legacyImportKey: String? = nil,
        createdAt: Date? = nil
    ) {
        self.jobID = jobID
        self.kind = kind
        self.scope = scope
        self.state = state ?? (scope == nil ? .waitingForScope : .queued)
        self.intentKind = intentKind
        self.text = text
        self.sourceURL = sourceURL
        self.comment = comment
        self.storedSessionID = storedSessionID
        self.expiresAt = expiresAt
        self.legacyImportKey = legacyImportKey
        self.createdAt = createdAt
    }
}

struct WorkRepositorySnapshot: Equatable, Sendable {
    var jobs: [WorkJob]
    var drafts: [WorkDraft]

    static let empty = WorkRepositorySnapshot(jobs: [], drafts: [])
}

struct WorkDatabasePragmas: Equatable, Sendable {
    let journalMode: String
    let foreignKeysEnabled: Bool
    let busyTimeoutMilliseconds: Int
}

@MainActor
@Observable
final class WorkRepositoryObservation {
    private(set) var snapshot: WorkRepositorySnapshot = .empty

    func publish(_ snapshot: WorkRepositorySnapshot) {
        self.snapshot = snapshot
    }
}
